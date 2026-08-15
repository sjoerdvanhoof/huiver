"""Core ML export of T3, Chatterbox Nano's autoregressive backbone.

Nano's T3 is a 12-layer GPT-2 small with the token embedding removed: the
sequence it reads is assembled by hand out of a speaker embedding, 375 speech
tokens cloned off the reference clip, the text, and a start-of-speech token.
It emits speech tokens one at a time, which the S3Gen decoder later turns into
audio.

Two models come out of here rather than one, because a Core ML state belongs to
exactly one MLModel and prefill and decode want different shapes:

  T3Prefill  stateless, flexible text length, returns the filled KV cache
  T3Decode   stateful, fixed shapes, one token in and one distribution out

Swift copies the prefill cache into the decode model's state once per chunk
(~30 MB, under a millisecond) and then runs the fixed-shape decode step a few
hundred times. That is the whole point of the split: the hot loop has no
flexible dimension, so it can stay on the Neural Engine.

The GPT-2 forward pass is re-implemented here rather than traced out of
transformers. It is forty lines, it lets prefill and decode share one attention
implementation, and it keeps the graph free of the Python-level `int(x.size(1))`
calls that a traced HF model bakes in as constants.
"""

from __future__ import annotations

import numpy as np
import torch
import torch.nn.functional as F
from torch import nn

from common import (
    COND_PREFIX_LEN,
    HEAD_DIM,
    MAX_CONTEXT,
    N_EMBD,
    N_HEAD,
    N_LAYER,
    SPEECH_VOCAB,
    START_SPEECH_TOKEN,
    check,
)


# What an unattendable position contributes to the attention logits. Not -inf:
# the whole graph runs in float16 on device, where -inf survives the addition
# but turns any all-masked row into NaN. -1e4 is far below any real logit and
# well inside float16's range, so softmax sees a clean zero either way.
MASKED = -1e4


def _gelu_new(x: torch.Tensor) -> torch.Tensor:
    """GPT-2's tanh approximation of GELU, spelled out so it traces cleanly."""
    return (
        0.5
        * x
        * (1.0 + torch.tanh(0.7978845608028654 * (x + 0.044715 * torch.pow(x, 3.0))))
    )


class Block(nn.Module):
    """One GPT-2 block, weights lifted straight off the HF module.

    Attention is split into `attend_causal` (prefill, whole sequence at once)
    and `attend_cached` (decode, one query against the cache) so the two export
    paths cannot drift apart.
    """

    def __init__(self, hf_block: nn.Module):
        super().__init__()
        self.ln_1 = hf_block.ln_1
        self.ln_2 = hf_block.ln_2
        # HF's Conv1D holds (in, out), so these are used as plain matmuls.
        self.attn_w = nn.Parameter(hf_block.attn.c_attn.weight.data.clone())
        self.attn_b = nn.Parameter(hf_block.attn.c_attn.bias.data.clone())
        self.proj_w = nn.Parameter(hf_block.attn.c_proj.weight.data.clone())
        self.proj_b = nn.Parameter(hf_block.attn.c_proj.bias.data.clone())
        self.fc_w = nn.Parameter(hf_block.mlp.c_fc.weight.data.clone())
        self.fc_b = nn.Parameter(hf_block.mlp.c_fc.bias.data.clone())
        self.mlp_proj_w = nn.Parameter(hf_block.mlp.c_proj.weight.data.clone())
        self.mlp_proj_b = nn.Parameter(hf_block.mlp.c_proj.bias.data.clone())

    def qkv(self, x: torch.Tensor):
        """(B, L, 768) -> three (B, 12, L, 64) heads."""
        fused = torch.addmm(
            self.attn_b, x.reshape(-1, N_EMBD), self.attn_w
        ).view(x.shape[0], -1, 3 * N_EMBD)
        q, k, v = fused.split(N_EMBD, dim=2)
        shape = (x.shape[0], -1, N_HEAD, HEAD_DIM)
        return (
            q.view(shape).transpose(1, 2),
            k.view(shape).transpose(1, 2),
            v.view(shape).transpose(1, 2),
        )

    def out_proj(self, attn: torch.Tensor) -> torch.Tensor:
        merged = attn.transpose(1, 2).reshape(-1, N_EMBD)
        return torch.addmm(self.proj_b, merged, self.proj_w).view(
            attn.shape[0], -1, N_EMBD
        )

    def mlp(self, x: torch.Tensor) -> torch.Tensor:
        h = torch.addmm(self.fc_b, x.reshape(-1, N_EMBD), self.fc_w)
        h = _gelu_new(h)
        h = torch.addmm(self.mlp_proj_b, h, self.mlp_proj_w)
        return h.view(x.shape[0], -1, N_EMBD)


class T3Prefill(nn.Module):
    """Read the conditioning prefix and the text, return the first logits.

    The text length is the one flexible dimension in the whole export. Nothing
    downstream of it depends on a Python-level length: positions arrive as an
    input, and the causal mask is `is_causal=True` rather than a materialised
    triangle, so the traced graph is genuinely length-agnostic.
    """

    def __init__(self, t3: nn.Module):
        super().__init__()
        self.blocks = nn.ModuleList(Block(b) for b in t3.tfmr.h)
        self.ln_f = t3.tfmr.ln_f
        self.wpe = t3.tfmr.wpe
        self.text_emb = t3.text_emb
        self.speech_emb = t3.speech_emb
        self.spkr_enc = t3.cond_enc.spkr_enc
        self.speech_head = t3.speech_head
        # The conditioning prefix always sits at positions 0..375, so only the
        # text's positions have to be handed in.
        self.prefix_positions = torch.arange(COND_PREFIX_LEN, dtype=torch.long).unsqueeze(0)
        self.bos = torch.full((1, 1), START_SPEECH_TOKEN, dtype=torch.long)

    def forward(
        self,
        speaker_emb: torch.Tensor,  # (1, 256)
        prompt_tokens: torch.Tensor,  # (1, 375) int32
        text_tokens: torch.Tensor,  # (1, T) int32
        text_positions: torch.Tensor,  # (1, T) int32 — 376 .. 376+T-1
        bos_position: torch.Tensor,  # (1, 1) int32 — 376+T
    ):
        spkr = self.spkr_enc(speaker_emb).unsqueeze(1)  # (1, 1, 768)
        prompt = self.speech_emb(prompt_tokens.long())  # (1, 375, 768)
        text = self.text_emb(text_tokens.long())  # (1, T, 768)
        bos = self.speech_emb(self.bos)  # (1, 1, 768)
        x = torch.cat([spkr, prompt, text, bos], dim=1)

        # text_tokens and text_positions are declared with one shared RangeDim,
        # so the sequence and its positions cannot disagree about how long the
        # text is. When they were separate flexible inputs Core ML could not
        # prove the two concatenations matched and rejected the graph.
        positions = torch.cat(
            [self.prefix_positions, text_positions.long(), bos_position.long()], dim=1
        )
        x = x + self.wpe(positions)

        # The causal mask, built by broadcasting the positions against
        # themselves. `is_causal=True` would be equivalent, but Core ML
        # synthesises its mask from the sequence length and then cannot prove
        # the result is broadcastable once that length is symbolic; a mask
        # derived from a real tensor carries its shape along with it.
        key_pos = positions.view(1, 1, 1, -1)
        query_pos = positions.view(1, 1, -1, 1)
        bias = (1.0 - (key_pos <= query_pos).to(x.dtype)) * MASKED

        keys, values = [], []
        for block in self.blocks:
            h = block.ln_1(x)
            q, k, v = block.qkv(h)
            keys.append(k)
            values.append(v)
            attn = F.scaled_dot_product_attention(q, k, v, attn_mask=bias)
            x = x + block.out_proj(attn)
            x = x + block.mlp(block.ln_2(x))

        last = self.ln_f(x[:, -1:, :])
        logits = self.speech_head(last).view(1, SPEECH_VOCAB)
        # (12, 1, 12, L, 64) — one tensor rather than 24 outputs, so the Swift
        # side copies it into the decode state with two memcpys.
        return logits, torch.stack(keys, dim=0), torch.stack(values, dim=0)


class T3Decode(nn.Module):
    """One speech token in, one distribution over the next token out.

    Stateful: the KV cache lives in Core ML as two `MAX_CONTEXT`-long buffers
    that never cross the Swift boundary. Without this the loop would have to
    hand ~30 MB back and forth on every one of several hundred steps, which is
    slower than having no cache at all.
    """

    def __init__(self, t3: nn.Module):
        super().__init__()
        self.blocks = nn.ModuleList(Block(b) for b in t3.tfmr.h)
        self.ln_f = t3.tfmr.ln_f
        self.wpe = t3.tfmr.wpe
        self.speech_emb = t3.speech_emb
        self.speech_head = t3.speech_head
        shape = (N_LAYER, 1, N_HEAD, MAX_CONTEXT, HEAD_DIM)
        self.register_buffer("k_cache", torch.zeros(shape), persistent=False)
        self.register_buffer("v_cache", torch.zeros(shape), persistent=False)
        # A plain attribute, not a buffer: only the two caches may become Core
        # ML states, and a third mutable-looking buffer confuses the converter.
        self.slots = torch.arange(MAX_CONTEXT, dtype=torch.float32)

    def forward(
        self,
        token: torch.Tensor,  # (1, 1) int32
        position: torch.Tensor,  # (1,) int32 — absolute slot for this token
    ):
        x = self.speech_emb(token.long()) + self.wpe(position.long()).unsqueeze(1)

        # Everything at or before `position` is real; the rest of the cache is
        # whatever the last chunk left there, and has to be masked out rather
        # than trusted.
        live = (self.slots <= position.to(self.slots.dtype)).view(1, 1, 1, MAX_CONTEXT)
        bias = (1.0 - live.to(x.dtype)) * MASKED

        begin = position.long()
        end = begin + 1
        for i, block in enumerate(self.blocks):
            h = block.ln_1(x)
            q, k, v = block.qkv(h)
            self.k_cache[i, :, :, begin:end, :] = k
            self.v_cache[i, :, :, begin:end, :] = v
            attn = F.scaled_dot_product_attention(
                q, self.k_cache[i], self.v_cache[i], attn_mask=bias
            )
            x = x + block.out_proj(attn)
            x = x + block.mlp(block.ln_2(x))

        logits = self.speech_head(self.ln_f(x)).view(1, SPEECH_VOCAB)
        return logits


# --------------------------------------------------------------------- parity


def prefill_inputs(cond, text_tokens: torch.Tensor):
    """The five prefill tensors, in order. Mirrored by the Swift engine."""
    n_text = int(text_tokens.shape[1])
    return (
        cond.speaker_emb,
        cond.cond_prompt_speech_tokens.to(torch.int32),
        text_tokens.to(torch.int32),
        torch.arange(
            COND_PREFIX_LEN, COND_PREFIX_LEN + n_text, dtype=torch.int32
        ).unsqueeze(0),
        torch.tensor([[COND_PREFIX_LEN + n_text]], dtype=torch.int32),
    )


def reference_run(model, text_tokens: torch.Tensor, n_steps: int):
    """Greedy tokens straight from the original model, for comparison.

    Sampling is done in Swift, so what has to match is the logits, not the
    audio. Greedy decoding makes any drift show up as a diverging token rather
    than as a slightly different-sounding sentence.
    """
    t3 = model.t3
    cond = model.conds.t3
    start = START_SPEECH_TOKEN * torch.ones_like(text_tokens[:, :1])
    embeds, _ = t3.prepare_input_embeds(
        t3_cond=cond, text_tokens=text_tokens, speech_tokens=start, cfg_weight=0.0
    )
    with torch.inference_mode():
        out = t3.tfmr(inputs_embeds=embeds, use_cache=True)
        past = out.past_key_values
        logits = t3.speech_head(out[0][:, -1:])[:, -1, :]
        first = logits.clone()
        tokens = []
        for _ in range(n_steps):
            nxt = logits.argmax(dim=-1, keepdim=True)
            tokens.append(int(nxt))
            out = t3.tfmr(
                inputs_embeds=t3.speech_emb(nxt), past_key_values=past, use_cache=True
            )
            past = out.past_key_values
            logits = t3.speech_head(out[0])[:, -1, :]
    return first, tokens


def verify(model, prefill: T3Prefill, decode: T3Decode, text_tokens: torch.Tensor):
    """Check the re-implementation against the original, in torch.

    Run before conversion: a mismatch here is a bug in this file, whereas a
    mismatch after conversion is a bug in coremltools, and telling those two
    apart afterwards is miserable.
    """
    cond = model.conds.t3
    n_text = text_tokens.shape[1]
    prefix_len = COND_PREFIX_LEN + n_text + 1

    with torch.inference_mode():
        logits, k, v = prefill(*prefill_inputs(cond, text_tokens))

    want_first, want_tokens = reference_run(model, text_tokens, n_steps=8)
    ok = check("prefill logits", logits, want_first, atol=2e-3, rtol=2e-3)

    decode.k_cache.zero_()
    decode.v_cache.zero_()
    decode.k_cache[:, :, :, :prefix_len, :] = k
    decode.v_cache[:, :, :, :prefix_len, :] = v

    got_tokens = []
    step_logits = logits
    with torch.inference_mode():
        for i in range(len(want_tokens)):
            nxt = step_logits.argmax(dim=-1, keepdim=True).to(torch.int32)
            got_tokens.append(int(nxt))
            step_logits = decode(
                nxt, torch.tensor([prefix_len + i], dtype=torch.int32)
            )
    match = got_tokens == want_tokens
    print(f"  decode tokens: {got_tokens} vs {want_tokens} {'ok' if match else 'FAIL'}")
    return ok and match


def build(model):
    """The two torch modules, ready to trace."""
    prefill = T3Prefill(model.t3).eval()
    decode = T3Decode(model.t3).eval()
    for p in list(prefill.parameters()) + list(decode.parameters()):
        p.requires_grad_(False)
    return prefill, decode
