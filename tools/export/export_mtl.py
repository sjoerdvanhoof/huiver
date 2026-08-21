#!/usr/bin/env python
"""Convert the multilingual T3 to Core ML, for the Mac.

    python export_mtl.py --out ../../apps/mac/build          # both packages
    python export_mtl.py --out /tmp/mtl --only decode        # the risky one

The twin of `export_models.py`, and deliberately a separate entry point: this
model is the Mac's, it takes a different environment's worth of memory to
convert, and Nano's export must stay runnable while this one is being taught to
work.

Run `verify_mtl.py` first. It compares the modules traced here against a second
implementation of the decode loop and then against `transformers` itself, which
is what makes a disagreement *after* conversion mean "coremltools changed
something" rather than "one of these was wrong all along".
"""

from __future__ import annotations

import argparse
import shutil
import time
from pathlib import Path

import numpy as np
import torch

import coremltools as ct

import mil_ops  # noqa: F401 — registers the torch ops coremltools is missing
from common import (
    DEFAULT_GEN_TOKENS,
    MEL_HOP,
    MEL_DIM,
    S3GEN_SIL,
    S3GEN_SR,
    MTL_CACHE_SHAPE,
    MTL_CFG_ROWS,
    MTL_COND_PREFIX_LEN,
    MTL_COND_PROMPT_LEN,
    MTL_HEAD_DIM,
    MTL_MAX_CONTEXT,
    MTL_MAX_GEN_TOKENS,
    MTL_MAX_TEXT_TOKENS,
    MTL_N_HEAD,
    MTL_N_LAYER,
    MTL_SPEECH_VOCAB,
    MTL_START_SPEECH_TOKEN,
    MTL_START_TEXT_TOKEN,
    MTL_STOP_SPEECH_TOKEN,
    MTL_STOP_TEXT_TOKEN,
    TOKEN_MEL_RATIO,
    load_multilingual,
)

# The 23 the checkpoint speaks, in the order chatterbox lists them. The Swift
# engine reads this back out of the model's metadata, which is the mechanism the
# iOS app already uses to decide what it can read.
LANGUAGES = "ar,da,de,el,en,es,fi,fr,he,hi,it,ja,ko,ms,nl,no,pl,pt,ru,sv,sw,tr,zh"

TEXT = "The quiet harbour town woke slowly. Gulls turned above the jetty."


def quantize(model, mode: str):
    """Shrink the weights, leaving activations alone.

    The same trade Nano's export makes, and it defaults the same way: weight-only
    quantisation is what actually decides how much memory the app holds and how
    much of the model fits in cache, and unlike activation quantisation it needs
    no calibration data. Two of these packages hold a 500M-parameter backbone
    each, so it is the difference between 2.3 GB in the bundle and rather less.
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
    for key, value in meta.items():
        model.user_defined_metadata[key] = str(value)
    model.save(str(path))
    size = sum(f.stat().st_size for f in path.rglob("*") if f.is_file())
    print(f"  wrote {path.name}  {size / 1e6:.0f} MB")


# Which processors a package is allowed to use.
#
# The prefill is deliberately not `ALL`. A flexible text dimension over thirty
# layers has to be compiled for the Neural Engine at load time, and that compile
# is what takes a 16 GB machine down — silently, with no exception to catch.
# Prefill runs once per chunk against a GPU that is idle anyway, so the engine
# buys nothing here; the decode step, which runs hundreds of times, keeps it.
UNITS = {
    "all": ct.ComputeUnit.ALL,
    "cpu_gpu": ct.ComputeUnit.CPU_AND_GPU,
    "cpu": ct.ComputeUnit.CPU_ONLY,
}


def export_prefill(
    model, modules, tokens, out: Path, skip_load: bool = False,
    units: str = "cpu_gpu", quant: str = "int8",
):
    import mtl_t3_export as X

    prefill, _ = modules
    example = X.prefill_inputs(model.conds.t3, tokens)
    print("prefill: tracing")
    traced = torch.jit.trace(prefill, example)

    # One RangeDim instance for the text, as Nano's export does: coremltools
    # treats the same object as the same symbol, which is what lets it prove
    # downstream shapes line up.
    text_dim = ct.RangeDim(
        lower_bound=1, upper_bound=MTL_MAX_TEXT_TOKENS, default=int(tokens.shape[1])
    )
    print("prefill: converting")
    started = time.time()
    converted = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="speaker_emb", shape=(1, 256), dtype=np.float32),
            ct.TensorType(
                name="prompt_tokens", shape=(1, MTL_COND_PROMPT_LEN), dtype=np.int32
            ),
            ct.TensorType(name="text_tokens", shape=(1, text_dim), dtype=np.int32),
            ct.TensorType(name="emotion", shape=(1, 1), dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="logits", dtype=np.float32),
            ct.TensorType(name="k_cache", dtype=np.float16),
            ct.TensorType(name="v_cache", dtype=np.float16),
        ],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT16,
        compute_units=UNITS[units],
        # Converting and loading are separable, and worth separating here: a
        # flexible-shape model of this size is compiled at load time, and that
        # is where a 16 GB machine falls over. `--skip-load` writes the package
        # and leaves the compile to whoever opens it.
        skip_model_load=skip_load,
    )
    print(f"  converted in {time.time() - started:.0f}s")
    save(
        quantize(converted, quant),
        out,
        "MTLT3Prefill",
        dict(
            condPrefixLen=MTL_COND_PREFIX_LEN,
            # The text has to arrive bracketed by these, and the checkpoint
            # asserts it (`_ensure_BOT_EOT`). Nano needs no such thing — T3
            # wraps the sequence itself there — so the engine keys off their
            # presence rather than off the variant.
            startTextToken=MTL_START_TEXT_TOKEN,
            stopTextToken=MTL_STOP_TEXT_TOKEN,
            # How long a voice's conditioning prompt is. Nano's is the prefix
            # minus its speaker token; here the perceiver resamples 150 tokens
            # down to 32 latents, so the two numbers are unrelated and the
            # engine has to be told rather than deriving one from the other.
            condPromptLen=MTL_COND_PROMPT_LEN,
            maxTextTokens=MTL_MAX_TEXT_TOKENS,
            cfgRows=MTL_CFG_ROWS,
            # Read by whoever loads this: the flexible text dimension must not
            # be compiled for the Neural Engine. See UNITS.
            computeUnits=units,
            languages=LANGUAGES,
        ),
    )
    return converted


def export_decode(model, modules, out: Path, quant: str = "int8"):
    _, decode = modules
    decode.k_cache.zero_()
    decode.v_cache.zero_()

    print("decode: tracing")
    example = (
        torch.tensor([[MTL_START_SPEECH_TOKEN]], dtype=torch.int32),
        torch.tensor([40], dtype=torch.int32),
        torch.tensor([1], dtype=torch.int32),
        torch.tensor([0.5], dtype=torch.float32),
    )
    traced = torch.jit.trace(decode, example)

    def state(name):
        return ct.StateType(
            wrapped_type=ct.TensorType(shape=MTL_CACHE_SHAPE, dtype=np.float16), name=name
        )

    print("decode: converting")
    started = time.time()
    converted = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="token", shape=(1, 1), dtype=np.int32),
            ct.TensorType(name="position", shape=(1,), dtype=np.int32),
            ct.TensorType(name="speech_position", shape=(1,), dtype=np.int32),
            ct.TensorType(name="cfg_weight", shape=(1,), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        states=[state("k_cache"), state("v_cache")],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
    )
    print(f"  converted in {time.time() - started:.0f}s")
    save(
        quantize(converted, quant),
        out,
        "MTLT3Decode",
        dict(
            maxContext=MTL_MAX_CONTEXT,
            maxGenTokens=MTL_MAX_GEN_TOKENS,
            nLayer=MTL_N_LAYER,
            nHead=MTL_N_HEAD,
            headDim=MTL_HEAD_DIM,
            speechVocab=MTL_SPEECH_VOCAB,
            startSpeechToken=MTL_START_SPEECH_TOKEN,
            stopSpeechToken=MTL_STOP_SPEECH_TOKEN,
            cfgRows=MTL_CFG_ROWS,
            languages=LANGUAGES,
        ),
    )
    return converted


def export_flow(
    model, out: Path, gen_tokens: int, prompt_tokens: int,
    units: str = "cpu_gpu", quant: str = "int8",
):
    """Speech tokens to mel: the ten-step guided solver.

    Not offered to the Neural Engine either, and this one is the clearest case:
    the ten solver steps are *unrolled* into the graph, so the ANE compiler is
    handed ten copies of the estimator over two thousand mel frames and does not
    come back. Twenty minutes in it had produced nothing; on the GPU the whole
    conversion is a couple of minutes.
    """
    import mtl_s3_export as S

    flow = S.build(model, gen_tokens)
    if prompt_tokens != flow.prompt_tokens:
        flow = S.MTLFlow(model.s3gen, gen_tokens, prompt_tokens).eval()

    prompt_feat_len = prompt_tokens * TOKEN_MEL_RATIO
    n_mel = (prompt_tokens + gen_tokens) * TOKEN_MEL_RATIO
    example = (
        torch.zeros(1, prompt_tokens, dtype=torch.int32),
        torch.zeros(1, gen_tokens, dtype=torch.int32),
        torch.zeros(1, prompt_feat_len, MEL_DIM),
        torch.zeros(1, 192),
        torch.zeros(1, MEL_DIM, n_mel),
    )
    print(f"flow: tracing ({prompt_tokens} prompt + {gen_tokens} gen tokens)")
    traced = torch.jit.trace(flow, example)

    print("flow: converting")
    started = time.time()
    converted = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="prompt_tokens", shape=(1, prompt_tokens), dtype=np.int32),
            ct.TensorType(name="gen_tokens", shape=(1, gen_tokens), dtype=np.int32),
            ct.TensorType(
                name="prompt_feat", shape=(1, prompt_feat_len, MEL_DIM), dtype=np.float32
            ),
            ct.TensorType(name="embedding", shape=(1, 192), dtype=np.float32),
            ct.TensorType(name="noise", shape=(1, MEL_DIM, n_mel), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="mel", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT16,
        compute_units=UNITS[units],
    )
    print(f"  converted in {time.time() - started:.0f}s")
    save(
        quantize(converted, quant),
        out,
        "MTLS3Flow" if gen_tokens == DEFAULT_GEN_TOKENS else f"MTLS3Flow{gen_tokens}",
        dict(
            genTokens=gen_tokens,
            promptTokenLen=prompt_tokens,
            promptFeatLen=prompt_feat_len,
            tokenMelRatio=TOKEN_MEL_RATIO,
            # The same speech-token silence Nano pads with: both checkpoints
            # share the S3 tokenizer and its 6561-token vocabulary, so what is
            # silence in one is silence in the other.
            silenceToken=S3GEN_SIL,
            melFrames=n_mel,
            cfmSteps=S.CFM_STEPS,
            cfgRate=S.CFM_CFG_RATE,
            computeUnits=units,
        ),
    )
    return converted


def export_vocoder(model, out: Path, gen_tokens: int, quant: str = "int8"):
    """Mel to waveform.

    `HiFTGenerator` is the same module in both checkpoints, so this is Nano's
    exporter run against the multilingual weights rather than a second one —
    including its stand-ins for the DFTs Core ML will not trace.
    """
    from s3_export import Vocoder

    frames = gen_tokens * TOKEN_MEL_RATIO
    vocoder = Vocoder(model.s3gen, frames).eval()
    for parameter in vocoder.parameters():
        parameter.requires_grad_(False)

    print("vocoder: tracing")
    traced = torch.jit.trace(vocoder, (torch.randn(1, MEL_DIM, frames),))
    print("vocoder: converting")
    started = time.time()
    converted = ct.convert(
        traced,
        inputs=[ct.TensorType(name="mel", shape=(1, MEL_DIM, frames), dtype=np.float32)],
        outputs=[ct.TensorType(name="waveform", dtype=np.float32)],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT16,
        # Off the Neural Engine, like the prefill but for a different reason:
        # the ANE compiler simply fails on this graph ("ANECCompile() FAILED"),
        # and Core ML then falls back on its own — correctly, but after wasting
        # the compile and logging an error that looks like a bug. The DFT
        # stand-ins are the likely cause and the GPU runs them happily.
        compute_units=ct.ComputeUnit.CPU_AND_GPU,
    )
    print(f"  converted in {time.time() - started:.0f}s")
    save(
        quantize(converted, quant),
        out,
        "MTLS3Vocoder" if gen_tokens == DEFAULT_GEN_TOKENS else f"MTLS3Vocoder{gen_tokens}",
        dict(
            melFrames=frames,
            hop=MEL_HOP,
            sampleRate=S3GEN_SR,
            # The ANE compiler fails on this graph; see the note in
            # export_vocoder. Recorded so the engine does not spend a minute
            # rediscovering it on every launch.
            computeUnits="cpu_gpu",
        ),
    )
    return converted


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--only", choices=["prefill", "decode", "flow", "vocoder"])
    ap.add_argument(
        "--gen-tokens", type=int, nargs="+", default=[768],
        help="speech tokens the flow converts in one pass; several sizes mean "
        "several traced flow+vocoder pairs, because the conformer bakes its "
        "padding masks in at trace time and a graph traced at one length is "
        "quietly wrong at another. The engine picks the smallest installed "
        "window that fits each run of tokens.",
    )
    ap.add_argument(
        "--quantize", choices=["none", "int8", "int4"], default="int8",
        help="weight quantisation; none keeps float16 (default: int8, as Nano)",
    )
    ap.add_argument(
        "--flow-units", choices=sorted(UNITS), default="cpu_gpu",
        help="which processors the mel decoder may use (see export_flow)",
    )
    ap.add_argument(
        "--prompt-tokens", type=int, default=250,
        help="reference clip length in tokens; 250 is the ten seconds the voice export trims to",
    )
    ap.add_argument(
        "--skip-load", action="store_true", help="convert without compiling the result"
    )
    ap.add_argument(
        "--prefill-units", choices=sorted(UNITS), default="cpu_gpu",
        help="which processors the prefill package may use (see UNITS)",
    )
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    print("loading Chatterbox Multilingual")
    model = load_multilingual()

    import mtl_t3_export as X

    modules = X.build(model)
    tokens = model.tokenizer.text_to_tokens(TEXT, language_id="en")
    tokens = torch.nn.functional.pad(tokens, (1, 0), value=model.t3.hp.start_text_token)
    tokens = torch.nn.functional.pad(tokens, (0, 1), value=model.t3.hp.stop_text_token)

    with torch.no_grad():
        if args.only in (None, "prefill"):
            export_prefill(
                model, modules, tokens, args.out,
                skip_load=args.skip_load, units=args.prefill_units, quant=args.quantize,
            )
        if args.only in (None, "decode"):
            export_decode(model, modules, args.out, quant=args.quantize)
        for size in args.gen_tokens:
            if args.only in (None, "flow"):
                export_flow(
                    model, args.out, size, args.prompt_tokens,
                    units=args.flow_units, quant=args.quantize,
                )
            if args.only in (None, "vocoder"):
                export_vocoder(model, args.out, size, quant=args.quantize)


if __name__ == "__main__":
    main()
