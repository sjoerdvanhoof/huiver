#!/usr/bin/env python
"""Export Chatterbox Nano to Core ML.

    python export_models.py --out ../Huiver/Models

Produces four .mlpackages:

    T3Prefill    conditioning + text -> first speech logits, and the KV cache
    T3Decode     one speech token -> the next, stateful KV cache (the hot loop)
    S3Flow       speech tokens -> mel, two-step meanflow
    S3Vocoder    mel -> 24 kHz waveform

Nothing here downloads anything: the weights are the ones the desktop app
already fetched into ~/.cache/huggingface. Every stage checks itself against the
original torch module and refuses to write a model that does not match.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

import numpy as np
import torch

import coremltools as ct

import mil_ops  # noqa: F401 — registers the torch ops coremltools is missing
from common import (
    COND_PREFIX_LEN,
    COND_PROMPT_LEN,
    DEFAULT_GEN_TOKENS,
    HEAD_DIM,
    MAX_CONTEXT,
    MAX_GEN_TOKENS,
    MAX_TEXT_TOKENS,
    MEL_DIM,
    MEL_HOP,
    N_HEAD,
    N_LAYER,
    PROMPT_FEAT_LEN,
    PROMPT_TOKEN_LEN,
    S3GEN_SIL,
    S3GEN_SR,
    SPEAKER_EMBED_SIZE,
    SPEECH_TOKEN_RATE,
    SPEECH_VOCAB,
    START_SPEECH_TOKEN,
    STOP_SPEECH_TOKEN,
    TEXT_VOCAB,
    TOKEN_MEL_RATIO,
    load_nano,
)

CACHE_SHAPE = (N_LAYER, 1, N_HEAD, MAX_CONTEXT, HEAD_DIM)


def quantize(model, mode: str):
    """Shrink the weights, leaving activations alone.

    Weight-only quantisation is the right trade here: it is what actually
    determines how much RAM the app holds and how much of the model fits in
    cache, and unlike activation quantisation it needs no calibration data.
    """
    if mode == "none":
        return model
    from coremltools.optimize.coreml import (
        OpLinearQuantizerConfig,
        OptimizationConfig,
        linear_quantize_weights,
    )

    bits = {"int8": 8, "int4": 4}[mode]
    config = OptimizationConfig(
        global_config=OpLinearQuantizerConfig(
            mode="linear_symmetric", dtype=f"int{bits}", granularity="per_block",
            block_size=32,
        )
    )
    print(f"  quantising weights to int{bits}")
    return linear_quantize_weights(model, config=config)


def save(model, out: Path, name: str, meta: dict):
    path = out / f"{name}.mlpackage"
    if path.exists():
        shutil.rmtree(path)
    for k, v in meta.items():
        model.user_defined_metadata[k] = str(v)
    model.save(str(path))
    size = sum(f.stat().st_size for f in path.rglob("*") if f.is_file())
    print(f"  wrote {path.name}  {size/1e6:.0f} MB")


# ------------------------------------------------------------------------ T3


def export_t3(model, out: Path, quant: str, verify: bool):
    import t3_export as T

    print("T3: building modules")
    prefill, decode = T.build(model)

    sample_text = model.tokenizer(
        "The quiet harbour town woke slowly. Gulls turned above the jetty.",
        return_tensors="pt",
    ).input_ids
    if verify:
        print("T3: torch parity")
        if not T.verify(model, prefill, decode, sample_text):
            sys.exit("T3 re-implementation does not match the original model")

    cond = model.conds.t3
    n_text = int(sample_text.shape[1])
    example = T.prefill_inputs(cond, sample_text)

    print("T3: tracing prefill")
    traced = torch.jit.trace(prefill, example)
    # One RangeDim object, used for both text inputs: coremltools treats the
    # same instance as the same symbol, which is what lets it prove the token
    # sequence and its position ids are the same length.
    text_dim = ct.RangeDim(lower_bound=1, upper_bound=MAX_TEXT_TOKENS, default=n_text)
    print("T3: converting prefill")
    mlprefill = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="speaker_emb", shape=(1, SPEAKER_EMBED_SIZE), dtype=np.float32),
            ct.TensorType(name="prompt_tokens", shape=(1, COND_PROMPT_LEN), dtype=np.int32),
            ct.TensorType(name="text_tokens", shape=(1, text_dim), dtype=np.int32),
            ct.TensorType(name="text_positions", shape=(1, text_dim), dtype=np.int32),
            ct.TensorType(name="bos_position", shape=(1, 1), dtype=np.int32),
        ],
        outputs=[
            ct.TensorType(name="logits", dtype=np.float32),
            ct.TensorType(name="k_cache", dtype=np.float16),
            ct.TensorType(name="v_cache", dtype=np.float16),
        ],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
    )
    save(
        quantize(mlprefill, quant),
        out,
        "T3Prefill",
        dict(condPrefixLen=COND_PREFIX_LEN, maxTextTokens=MAX_TEXT_TOKENS),
    )

    print("T3: tracing decode")
    decode.k_cache.zero_()
    decode.v_cache.zero_()
    traced = torch.jit.trace(
        decode,
        (torch.tensor([[100]], dtype=torch.int32), torch.tensor([5], dtype=torch.int32)),
    )
    print("T3: converting decode")
    state = lambda name: ct.StateType(  # noqa: E731
        wrapped_type=ct.TensorType(shape=CACHE_SHAPE, dtype=np.float16), name=name
    )
    mldecode = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="token", shape=(1, 1), dtype=np.int32),
            ct.TensorType(name="position", shape=(1,), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        states=[state("k_cache"), state("v_cache")],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
    )
    save(
        quantize(mldecode, quant),
        out,
        "T3Decode",
        dict(
            maxContext=MAX_CONTEXT,
            maxGenTokens=MAX_GEN_TOKENS,
            nLayer=N_LAYER,
            nHead=N_HEAD,
            headDim=HEAD_DIM,
            speechVocab=SPEECH_VOCAB,
            startSpeechToken=START_SPEECH_TOKEN,
            stopSpeechToken=STOP_SPEECH_TOKEN,
        ),
    )


# --------------------------------------------------------------------- S3Gen


def export_s3(model, out: Path, quant: str, gen_tokens: int, verify: bool):
    import s3_export as S

    print("S3: building modules")
    flow, vocoder = S.build(model, gen_tokens)
    if verify:
        print("S3: torch parity")
        if not S.verify(model, flow, vocoder, gen_tokens):
            sys.exit("S3 re-implementation does not match the original model")

    n_tok = PROMPT_TOKEN_LEN + gen_tokens
    n_mel = n_tok * TOKEN_MEL_RATIO
    example = (
        torch.randint(0, 6000, (1, PROMPT_TOKEN_LEN), dtype=torch.int32),
        torch.randint(0, 6000, (1, gen_tokens), dtype=torch.int32),
        torch.randn(1, PROMPT_FEAT_LEN, MEL_DIM),
        torch.randn(1, 192),
        torch.randn(1, MEL_DIM, n_mel),
    )
    print("S3: tracing flow")
    traced = torch.jit.trace(flow, example)
    print("S3: converting flow")
    mlflow = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="prompt_tokens", shape=(1, PROMPT_TOKEN_LEN), dtype=np.int32),
            ct.TensorType(name="gen_tokens", shape=(1, gen_tokens), dtype=np.int32),
            ct.TensorType(name="prompt_feat", shape=(1, PROMPT_FEAT_LEN, MEL_DIM), dtype=np.float32),
            ct.TensorType(name="embedding", shape=(1, 192), dtype=np.float32),
            ct.TensorType(name="noise", shape=(1, MEL_DIM, n_mel), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="mel", dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
    )
    save(
        quantize(mlflow, quant),
        out,
        "S3Flow",
        dict(
            genTokens=gen_tokens,
            promptTokenLen=PROMPT_TOKEN_LEN,
            promptFeatLen=PROMPT_FEAT_LEN,
            tokenMelRatio=TOKEN_MEL_RATIO,
            silenceToken=S3GEN_SIL,
            tokenRate=SPEECH_TOKEN_RATE,
        ),
    )

    mel_frames = gen_tokens * TOKEN_MEL_RATIO
    print("S3: tracing vocoder")
    traced = torch.jit.trace(vocoder, (torch.randn(1, MEL_DIM, mel_frames),))
    print("S3: converting vocoder")
    mlvoc = ct.convert(
        traced,
        inputs=[ct.TensorType(name="mel", shape=(1, MEL_DIM, mel_frames), dtype=np.float32)],
        outputs=[ct.TensorType(name="waveform", dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
    )
    save(
        quantize(mlvoc, quant),
        out,
        "S3Vocoder",
        dict(melFrames=mel_frames, hop=MEL_HOP, sampleRate=S3GEN_SR),
    )


# ---------------------------------------------------------------------- main


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, required=True, help="directory to write .mlpackages into")
    ap.add_argument("--only", choices=["t3", "s3"], help="export just one half")
    ap.add_argument(
        "--quantize",
        choices=["none", "int8", "int4"],
        default="int8",
        help="weight quantisation; none keeps float16 (default: int8)",
    )
    ap.add_argument(
        "--gen-tokens",
        type=int,
        default=DEFAULT_GEN_TOKENS,
        help="speech tokens the flow decoder converts per pass (default: %(default)s)",
    )
    ap.add_argument("--no-verify", action="store_true", help="skip the torch parity checks")
    args = ap.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    print("loading Chatterbox Nano (this takes a moment)")
    model = load_nano()

    if args.only != "s3":
        export_t3(model, args.out, args.quantize, not args.no_verify)
    if args.only != "t3":
        export_s3(model, args.out, args.quantize, args.gen_tokens, not args.no_verify)

    manifest = args.out / "models.json"
    manifest.write_text(
        json.dumps(
            dict(
                model="chatterbox-nano",
                quantize=args.quantize,
                genTokens=args.gen_tokens,
                maxContext=MAX_CONTEXT,
                sampleRate=S3GEN_SR,
                textVocab=TEXT_VOCAB,
            ),
            indent=2,
        )
        + "\n"
    )
    print(f"wrote {manifest}")


if __name__ == "__main__":
    main()
