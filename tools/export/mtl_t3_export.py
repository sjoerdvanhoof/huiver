"""Core ML export of the multilingual T3, the Mac's autoregressive backbone.

The twin of `t3_export.py`, and the same two-model split for the same reason: a
Core ML state belongs to exactly one MLModel, and prefill and decode want
different shapes.

  MTLT3Prefill  stateless, flexible text length, returns the filled KV cache
  MTLT3Decode   stateful, fixed shapes, one token in and one distribution out

What is different from Nano, and it is not a detail: **every step is a batch of
two.** The unconditional row — the same prompt with its text embeddings zeroed
and its positions kept — is computed for every token, and the two rows are
combined as `cond + w · (cond − uncond)` before anything is sampled.

That combination happens *inside* the model rather than in Swift. Sampling stays
in Swift, as it does for Nano, but guidance is not sampling: it is a fixed piece
of arithmetic over both rows, and doing it here halves what crosses the boundary
each step (one distribution instead of two) and leaves one fewer thing for the
port to get wrong. `cfg_weight` is an input, so it stays adjustable.

The forward pass itself lives in `mtl_backbone.py`, checked against
`transformers` by `verify_mtl.py --only backbone` before any of this runs.
"""

from __future__ import annotations

import numpy as np
import torch
import torch.nn.functional as F
from torch import nn

from common import (
    MTL_CACHE_SHAPE,
    MTL_CFG_ROWS,
    MTL_COND_PREFIX_LEN,
    MTL_COND_PROMPT_LEN,
    MTL_HEAD_DIM,
    MTL_MAX_CONTEXT,
    MTL_N_HEAD,
    MTL_N_LAYER,
    MTL_SPEECH_VOCAB,
    MTL_START_SPEECH_TOKEN,
)
from mtl_backbone import MASKED, Block, rms_norm


class Rotary(nn.Module):
    """The precomputed rotary tables, as constants in the graph.

    llama3's frequency correction is four constants and a piecewise formula.
    Baking the table means neither the export nor the Swift side re-derives it,
    and the only thing they have to agree on is the position index.
    """

    def __init__(self, t3, max_context: int):
        super().__init__()
        positions = torch.arange(max_context)[None]
        cos, sin = t3.tfmr.rotary_emb(
            torch.zeros(1, max_context, t3.cfg.hidden_size), positions
        )
        self.register_buffer("cos", cos[0], persistent=False)
        self.register_buffer("sin", sin[0], persistent=False)


class MTLT3Prefill(nn.Module):
    """The whole prompt, both rows, in one pass.

    Inputs are the pieces the Mac has rather than an assembled sequence: the
    speaker embedding and the reference clip's speech tokens go through the
    conditioning encoder here, so the perceiver resampler is exported with the
    model that uses it rather than as a third package.
    """

    def __init__(self, t3):
        super().__init__()
        self.cond_enc = t3.cond_enc
        self.text_emb = t3.text_emb
        self.speech_emb = t3.speech_emb
        self.text_pos = t3.text_pos_emb.emb
        self.speech_pos = t3.speech_pos_emb.emb
        self.layers = nn.ModuleList(
            Block(layer, t3.tfmr.norm.variance_epsilon, t3.tfmr.layers[0].self_attn.scaling)
            for layer in t3.tfmr.layers
        )
        self.norm = nn.Parameter(t3.tfmr.norm.weight.data.clone())
        self.head = nn.Parameter(t3.speech_head.weight.data.clone())
        self.eps = t3.tfmr.norm.variance_epsilon
        self.rotary = Rotary(t3, MTL_MAX_CONTEXT)

    def conditioning(self, speaker_emb, prompt_tokens, emotion):
        """Speaker (1) + perceiver latents (32) + emotion (1)."""
        prompt_emb = self.speech_emb(prompt_tokens.long())
        prompt_emb = prompt_emb + self.speech_pos(
            torch.arange(prompt_tokens.shape[1], device=prompt_tokens.device)
        )
        speaker = self.cond_enc.spkr_enc(speaker_emb)[:, None]
        latents = self.cond_enc.perceiver(prompt_emb)
        feeling = self.cond_enc.emotion_adv_fc(emotion.view(1, 1, 1))
        return torch.cat([speaker, latents, feeling], dim=1)

    def forward(
        self,
        speaker_emb,  # (1, 256)
        prompt_tokens,  # (1, 150) int32
        text_tokens,  # (1, T) int32
        emotion,  # (1, 1)
    ):
        cond = self.conditioning(speaker_emb, prompt_tokens, emotion)

        text = self.text_emb(text_tokens.long())
        # The unconditional row loses the words and keeps the positions, in that
        # order. Reversing them is a different model — see `mtl_reference`.
        text = torch.cat([text, torch.zeros_like(text)], dim=0)
        text = text + self.text_pos(
            torch.arange(text_tokens.shape[1], device=text_tokens.device)
        )

        # The prompt ends with two start-of-speech tokens, both at learned
        # position 0. That is what the weights were trained against; a port that
        # tidies it away sounds nearly right, which is the worst kind of wrong.
        bos = torch.full(
            (1, 1), MTL_START_SPEECH_TOKEN, dtype=torch.long, device=text_tokens.device
        )
        one = self.speech_emb(bos) + self.speech_pos(torch.zeros(1, dtype=torch.long))
        both = one.expand(MTL_CFG_ROWS, -1, -1)

        x = torch.cat([cond.expand(MTL_CFG_ROWS, -1, -1), text, both, both], dim=1)

        length = x.shape[1]
        cos, sin = self.rotary.cos[:length], self.rotary.sin[:length]
        # Built by broadcasting positions against themselves rather than with
        # `is_causal`: Core ML synthesises its own mask from the sequence length
        # and cannot prove it broadcastable once that length is symbolic.
        slots = torch.arange(length, device=x.device)
        bias = (1.0 - (slots.view(1, 1, 1, -1) <= slots.view(1, 1, -1, 1)).to(x.dtype)) * MASKED

        keys, values = [], []
        for layer in self.layers:
            x, k, v = layer(x, cos, sin, MTL_N_HEAD, MTL_HEAD_DIM, mask=bias)
            keys.append(k)
            values.append(v)

        last = rms_norm(x[:, -1:, :], self.norm, self.eps)
        logits = F.linear(last, self.head).view(MTL_CFG_ROWS, MTL_SPEECH_VOCAB)
        # One tensor rather than sixty outputs, so Swift copies each cache into
        # the decode state with a single memcpy.
        return logits, torch.stack(keys, dim=0), torch.stack(values, dim=0)


class MTLT3Decode(nn.Module):
    """One speech token in, one guided distribution over the next one out.

    Stateful: the two caches live in Core ML and never cross the Swift boundary.
    At 333 MB the pair, handing them back and forth every step would be slower
    than having no cache at all.
    """

    def __init__(self, t3):
        super().__init__()
        self.speech_emb = t3.speech_emb
        self.speech_pos = t3.speech_pos_emb.emb
        self.layers = nn.ModuleList(
            Block(layer, t3.tfmr.norm.variance_epsilon, t3.tfmr.layers[0].self_attn.scaling)
            for layer in t3.tfmr.layers
        )
        self.norm = nn.Parameter(t3.tfmr.norm.weight.data.clone())
        self.head = nn.Parameter(t3.speech_head.weight.data.clone())
        self.eps = t3.tfmr.norm.variance_epsilon
        self.rotary = Rotary(t3, MTL_MAX_CONTEXT)
        self.register_buffer("k_cache", torch.zeros(MTL_CACHE_SHAPE), persistent=False)
        self.register_buffer("v_cache", torch.zeros(MTL_CACHE_SHAPE), persistent=False)
        # A plain attribute rather than a buffer: only the two caches may become
        # Core ML states, and a third mutable-looking buffer confuses the
        # converter.
        self.slots = torch.arange(MTL_MAX_CONTEXT, dtype=torch.float32)

    def forward(
        self,
        token,  # (1, 1) int32 — the same token for both rows
        position,  # (1,) int32 — absolute slot in the cache
        speech_position,  # (1,) int32 — learned position, counted from the BOS
        cfg_weight,  # (1,) float32
    ):
        x = self.speech_emb(token.long()) + self.speech_pos(speech_position.long()).unsqueeze(1)
        x = x.expand(MTL_CFG_ROWS, -1, -1)

        cos = self.rotary.cos.index_select(0, position.long())
        sin = self.rotary.sin.index_select(0, position.long())

        # Everything at or before `position` is real; the rest of the cache is
        # whatever the last chunk left there, and has to be masked rather than
        # trusted.
        live = (self.slots <= position.to(self.slots.dtype)).view(1, 1, 1, MTL_MAX_CONTEXT)
        bias = (1.0 - live.to(x.dtype)) * MASKED

        begin = position.long()
        end = begin + 1
        for index, layer in enumerate(self.layers):
            residual = x
            h = rms_norm(x, layer.norm_in, self.eps)
            q, k, v = layer.project(h, MTL_N_HEAD, MTL_HEAD_DIM)
            from mtl_backbone import apply_rope

            q, k = apply_rope(q, cos, sin), apply_rope(k, cos, sin)
            self.k_cache[index, :, :, begin:end, :] = k
            self.v_cache[index, :, :, begin:end, :] = v
            attended = F.scaled_dot_product_attention(
                q, self.k_cache[index], self.v_cache[index], attn_mask=bias
            )
            attended = attended.transpose(1, 2).reshape(
                MTL_CFG_ROWS, 1, MTL_N_HEAD * MTL_HEAD_DIM
            )
            x = residual + F.linear(attended, layer.o)
            x = x + layer.mlp_forward(rms_norm(x, layer.norm_post, self.eps))

        logits = F.linear(rms_norm(x, self.norm, self.eps), self.head)
        logits = logits.view(MTL_CFG_ROWS, MTL_SPEECH_VOCAB)
        # Guidance, here rather than in Swift: it is arithmetic over both rows
        # rather than a sampling decision, and combining here halves what
        # crosses the boundary every step.
        cond, uncond = logits[0:1], logits[1:2]
        return cond + cfg_weight * (cond - uncond)


def build(model):
    """The two torch modules, ready to trace."""
    prefill = MTLT3Prefill(model.t3).eval()
    decode = MTLT3Decode(model.t3).eval()
    for parameter in list(prefill.parameters()) + list(decode.parameters()):
        parameter.requires_grad_(False)
    return prefill, decode


def prefill_inputs(cond, text_tokens: torch.Tensor):
    """The four prefill tensors, in order. Mirrored by the Swift engine."""
    return (
        cond.speaker_emb.view(1, -1).float(),
        cond.cond_prompt_speech_tokens.view(1, MTL_COND_PROMPT_LEN).int(),
        text_tokens.view(1, -1).int(),
        cond.emotion_adv.view(1, 1).float(),
    )
