"""Dump the multilingual T3 backbone as safetensors, for the MLX decode loop.

The Core ML decode model runs one `prediction()` per speech token, and on an
M4 that call costs ~56 ms — the token loop is three quarters of a chapter's
wall clock. MLX runs the same thirty layers with a real KV cache at a fraction
of that, so the Swift engine replaces the *decode loop* with MLX and keeps
everything else: the Core ML prefill (which owns the perceiver and produces
the cache this loop starts from), the flow, the vocoder, and the sampler.

What this exports is therefore exactly what `MTLT3Decode` bakes into its
graph, and nothing else: the thirty blocks, the final norm, the speech head,
the speech embeddings (token and learned-position), and the precomputed rotary
tables. The tables are baked for the same reason the Core ML export bakes
them — llama3's frequency correction is four constants and a piecewise
formula, and re-deriving it in Swift is one more thing to get subtly wrong.

Weights are float16, which is the precision the Core ML graph runs at anyway.
`--quantize int4|int8` pre-quantizes the big projections with MLX's grouped
affine scheme for the memory-bound decode loop; the norms, embeddings and
tables stay float16.
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import torch

from common import (
    MTL_COND_PREFIX_LEN,
    MTL_COND_PROMPT_LEN,
    MTL_HEAD_DIM,
    MTL_MAX_CONTEXT,
    MTL_MAX_GEN_TOKENS,
    MTL_MAX_TEXT_TOKENS,
    MTL_N_EMBD,
    MTL_N_HEAD,
    MTL_N_LAYER,
    MTL_SPEECH_VOCAB,
    MTL_START_SPEECH_TOKEN,
    MTL_START_TEXT_TOKEN,
    MTL_STOP_SPEECH_TOKEN,
    MTL_STOP_TEXT_TOKEN,
    load_multilingual,
)


def collect(t3) -> dict[str, torch.Tensor]:
    """Every tensor the Swift loop needs, flat, named for the Swift side."""
    tensors: dict[str, torch.Tensor] = {}

    for index, layer in enumerate(t3.tfmr.layers):
        attn, mlp = layer.self_attn, layer.mlp
        prefix = f"layers.{index}"
        tensors[f"{prefix}.q"] = attn.q_proj.weight.data
        tensors[f"{prefix}.k"] = attn.k_proj.weight.data
        tensors[f"{prefix}.v"] = attn.v_proj.weight.data
        tensors[f"{prefix}.o"] = attn.o_proj.weight.data
        tensors[f"{prefix}.gate"] = mlp.gate_proj.weight.data
        tensors[f"{prefix}.up"] = mlp.up_proj.weight.data
        tensors[f"{prefix}.down"] = mlp.down_proj.weight.data
        tensors[f"{prefix}.norm_in"] = layer.input_layernorm.weight.data
        tensors[f"{prefix}.norm_post"] = layer.post_attention_layernorm.weight.data

    tensors["norm"] = t3.tfmr.norm.weight.data
    tensors["head"] = t3.speech_head.weight.data
    tensors["speech_emb"] = t3.speech_emb.weight.data
    tensors["speech_pos"] = t3.speech_pos_emb.emb.weight.data
    # The prefill runs on MLX too — flexible text lengths are what Core ML
    # re-specializes seconds over, per novel length — so the text side of the
    # embedding table comes along. Only the conditioning encoder stays in Core
    # ML (MTLCond below): its shapes are fixed, which is the case Core ML is
    # good at.
    tensors["text_emb"] = t3.text_emb.weight.data
    tensors["text_pos"] = t3.text_pos_emb.emb.weight.data

    # Baked, not derived — the only thing both sides then have to agree on is
    # the position index. Identical to the tables in the Core ML graphs.
    positions = torch.arange(MTL_MAX_CONTEXT)[None]
    cos, sin = t3.tfmr.rotary_emb(
        torch.zeros(1, MTL_MAX_CONTEXT, t3.cfg.hidden_size), positions
    )
    tensors["rope_cos"] = cos[0]
    tensors["rope_sin"] = sin[0]

    return {name: tensor.detach().clone().half().contiguous() for name, tensor in tensors.items()}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=Path("../../apps/mac/build-mtl"))
    parser.add_argument(
        "--quantize", choices=["none", "int8", "int4"], default="none",
        help="grouped affine quantisation of the projections (default: none, float16)",
    )
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    print("loading Chatterbox Multilingual (CPU)")
    started = time.time()
    model = load_multilingual()
    t3 = model.t3
    print(f"  loaded in {time.time() - started:.0f}s")

    from export_mtl import LANGUAGES

    config = {
        "cfgRows": 2,
        "nLayer": MTL_N_LAYER,
        "nHead": MTL_N_HEAD,
        "headDim": MTL_HEAD_DIM,
        "hidden": MTL_N_EMBD,
        "speechVocab": MTL_SPEECH_VOCAB,
        "startSpeechToken": MTL_START_SPEECH_TOKEN,
        "stopSpeechToken": MTL_STOP_SPEECH_TOKEN,
        "maxContext": MTL_MAX_CONTEXT,
        "maxGenTokens": MTL_MAX_GEN_TOKENS,
        "eps": t3.tfmr.norm.variance_epsilon,
        "scaling": t3.tfmr.layers[0].self_attn.scaling,
        "quantization": args.quantize,
        # What the engine used to read off the Core ML prefill's metadata,
        # which is not loaded at all when the backbone is installed.
        "condPrefixLen": MTL_COND_PREFIX_LEN,
        "condPromptLen": MTL_COND_PROMPT_LEN,
        "maxTextTokens": MTL_MAX_TEXT_TOKENS,
        "startTextToken": MTL_START_TEXT_TOKEN,
        "stopTextToken": MTL_STOP_TEXT_TOKEN,
        "speakerEmbeddingSize": 256,
        "languages": LANGUAGES,
    }

    tensors = collect(t3)

    if args.quantize != "none":
        import mlx.core as mx

        bits = {"int8": 8, "int4": 4}[args.quantize]
        group = 64
        config["quantGroupSize"] = group
        config["quantBits"] = bits
        quantized: dict[str, torch.Tensor] = {}
        for name, tensor in list(tensors.items()):
            # Only the per-layer projections: they are all of the per-token
            # memory traffic. Embedding *lookups* read one row, the head is
            # left dense so the logits keep full quality, and the norms and
            # tables are tiny.
            if not (name.startswith("layers.") and tensor.ndim == 2):
                continue
            array = mx.array(tensor.float().numpy()).astype(mx.float16)
            w_q, scales, biases = mx.quantize(array, group_size=group, bits=bits)
            # Bitcast to int32: safetensors has no uint32, and the Swift side
            # views it back before the quantized matmul.
            quantized[f"{name}.weight"] = torch.from_numpy(
                __import__("numpy").array(w_q.astype(mx.uint32))
            ).view(torch.int32)
            quantized[f"{name}.scales"] = torch.from_numpy(
                __import__("numpy").array(scales.astype(mx.float16))
            )
            quantized[f"{name}.biases"] = torch.from_numpy(
                __import__("numpy").array(biases.astype(mx.float16))
            )
            del tensors[name]
        tensors.update(quantized)

    from safetensors.torch import save_file

    out = args.out / "MTLT3Backbone.safetensors"
    save_file(tensors, str(out), metadata={"config": json.dumps(config)})
    (args.out / "MTLT3Backbone.json").write_text(json.dumps(config, indent=2) + "\n")

    total = sum(t.numel() * t.element_size() for t in tensors.values())
    print(f"wrote {out} ({total / 2**20:.0f} MiB, {args.quantize})")
    print(f"wrote {args.out / 'MTLT3Backbone.json'}")

    export_cond(model, args.out)


class MTLCond(torch.nn.Module):
    """The conditioning prefix on its own: speaker (1) + perceiver (32) + emotion (1).

    The one piece of the prefill that is not backbone weights, exported as its
    own Core ML model. Its shapes are fixed — a voice's prompt is always 150
    tokens — which is the case Core ML handles without the per-novel-length
    specialization stall that pushed the rest of the prefill onto MLX.
    """

    def __init__(self, t3):
        super().__init__()
        self.cond_enc = t3.cond_enc
        self.speech_emb = t3.speech_emb
        self.speech_pos = t3.speech_pos_emb.emb

    def forward(self, speaker_emb, prompt_tokens, emotion):
        prompt_emb = self.speech_emb(prompt_tokens.long())
        prompt_emb = prompt_emb + self.speech_pos(
            torch.arange(prompt_tokens.shape[1], device=prompt_tokens.device)
        )
        speaker = self.cond_enc.spkr_enc(speaker_emb)[:, None]
        latents = self.cond_enc.perceiver(prompt_emb)
        feeling = self.cond_enc.emotion_adv_fc(emotion.view(1, 1, 1))
        return torch.cat([speaker, latents, feeling], dim=1)


def export_cond(model, out: Path) -> None:
    import coremltools as ct
    import numpy as np

    from export_mtl import UNITS, save

    cond = MTLCond(model.t3).eval()
    for parameter in cond.parameters():
        parameter.requires_grad_(False)

    example = (
        torch.zeros(1, 256),
        torch.zeros(1, MTL_COND_PROMPT_LEN, dtype=torch.int32),
        torch.full((1, 1), 0.5),
    )
    print("cond: tracing and converting")
    traced = torch.jit.trace(cond, example)
    converted = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="speaker_emb", shape=(1, 256), dtype=np.float32),
            ct.TensorType(
                name="prompt_tokens", shape=(1, MTL_COND_PROMPT_LEN), dtype=np.int32
            ),
            ct.TensorType(name="emotion", shape=(1, 1), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="cond", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT16,
        compute_units=UNITS["cpu_gpu"],
    )
    save(
        converted, out, "MTLCond",
        dict(
            condPrefixLen=MTL_COND_PREFIX_LEN,
            condPromptLen=MTL_COND_PROMPT_LEN,
            computeUnits="cpu_gpu",
        ),
    )
    print(f"wrote {out / 'MTLCond.mlpackage'}")


if __name__ == "__main__":
    main()
