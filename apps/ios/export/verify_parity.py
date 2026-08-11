#!/usr/bin/env python
"""Check the exported Core ML models against the original torch model.

    python verify_parity.py --models ../Huiver/Models

Conversion is the part of this pipeline most likely to be quietly wrong: a
model that loads, runs and produces plausible-sounding noise looks exactly like
a model that works. So this compares against torch at three levels, from the
one that localises a fault best to the one that matters most:

  1. prefill logits, and greedy tokens through the decode loop
  2. mel frames out of the flow decoder, for a fixed token sequence
  3. the waveform, end to end, against the same seed

Sampling lives in Swift, so greedy decoding is used throughout: drift shows up
as a token that differs rather than as a sentence that sounds slightly off.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import torch

import coremltools as ct

from common import (
    COND_PREFIX_LEN,
    MEL_DIM,
    PROMPT_FEAT_LEN,
    PROMPT_TOKEN_LEN,
    S3GEN_SIL,
    TOKEN_MEL_RATIO,
    load_nano,
)

TEXT = "The quiet harbour town woke slowly. Gulls turned above the jetty."


def report(name: str, got: np.ndarray, want: np.ndarray, tol: float) -> bool:
    got, want = np.asarray(got, np.float64), np.asarray(want, np.float64)
    if got.shape != want.shape:
        print(f"  {name}: SHAPE {got.shape} != {want.shape}")
        return False
    err = np.abs(got - want).max()
    denom = np.linalg.norm(got) * np.linalg.norm(want)
    corr = float((got.ravel() @ want.ravel()) / denom) if denom else 1.0
    ok = corr >= tol
    print(f"  {name}: max abs err {err:.4f}, correlation {corr:.6f} {'ok' if ok else 'FAIL'}")
    return ok


def check_t3(model, models: Path, steps: int) -> bool:
    prefill = ct.models.MLModel(str(models / "T3Prefill.mlpackage"))
    decode = ct.models.MLModel(str(models / "T3Decode.mlpackage"))
    cond = model.conds.t3
    ids = model.tokenizer(TEXT, return_tensors="pt").input_ids
    n_text = int(ids.shape[1])
    prefix_len = COND_PREFIX_LEN + n_text + 1

    import t3_export as T

    names = ("speaker_emb", "prompt_tokens", "text_tokens", "text_positions", "bos_position")
    out = prefill.predict(
        {
            name: t.detach().numpy().astype(np.float32 if name == "speaker_emb" else np.int32)
            for name, t in zip(names, T.prefill_inputs(cond, ids))
        }
    )

    want_first, want_tokens = T.reference_run(model, ids, n_steps=steps)
    ok = report("T3 prefill logits", out["logits"][0], want_first[0].numpy(), 0.9995)

    # Seed the decode model's state with the cache prefill just produced. This
    # is the one piece of glue Core ML does not do for us, and the same two
    # writes happen on the Swift side.
    state = decode.make_state()
    for name, value in (("k_cache", out["k_cache"]), ("v_cache", out["v_cache"])):
        buf = np.zeros_like(state.read_state(name))
        buf[:, :, :, :prefix_len, :] = value
        state.write_state(name, buf)

    got = []
    logits = out["logits"]
    for i in range(steps):
        nxt = int(np.argmax(logits[0]))
        got.append(nxt)
        logits = decode.predict(
            {
                "token": np.array([[nxt]], dtype=np.int32),
                "position": np.array([prefix_len + i], dtype=np.int32),
            },
            state=state,
        )["logits"]
    same = got == want_tokens
    print(f"  T3 decode tokens: {got}")
    print(f"                vs: {want_tokens} {'ok' if same else 'FAIL'}")
    return ok and same


def check_s3(model, models: Path, seed: int) -> bool:
    flow = ct.models.MLModel(str(models / "S3Flow.mlpackage"))
    voc = ct.models.MLModel(str(models / "S3Vocoder.mlpackage"))
    gen_tokens = int(flow.user_defined_metadata["genTokens"])

    gen = model.conds.gen
    torch.manual_seed(seed)
    real = torch.randint(0, 6000, (1, 120), dtype=torch.int32)
    padded = torch.full((1, gen_tokens), S3GEN_SIL, dtype=torch.int32)
    padded[:, : real.shape[1]] = real

    n_mel = (PROMPT_TOKEN_LEN + gen_tokens) * TOKEN_MEL_RATIO
    noise = torch.randn(1, MEL_DIM, n_mel)

    import s3_export as S

    want_mel, want_wav = S.reference_run(model, padded, noise)

    got_mel = flow.predict(
        {
            "prompt_tokens": gen["prompt_token"].detach().numpy().astype(np.int32),
            "gen_tokens": padded.detach().numpy().astype(np.int32),
            "prompt_feat": gen["prompt_feat"].detach().numpy().astype(np.float32),
            "embedding": gen["embedding"].detach().numpy().astype(np.float32),
            "noise": noise.detach().numpy().astype(np.float32),
        }
    )["mel"]
    ok = report("S3 flow mel", got_mel[0], want_mel[0].numpy(), 0.999)

    got_wav = voc.predict({"mel": got_mel.astype(np.float32)})["waveform"]
    want = want_wav[0].numpy()
    got = got_wav[0]

    # Not compared sample by sample, and not because of conversion error. The
    # vocoder's source module draws a random phase per harmonic and random
    # excitation noise on every call, so two runs of the *original* model do not
    # agree either; the export replaces both with constants. What has to match is
    # the envelope -- where the energy is, and how much of it -- so that is what
    # is checked, with the raw correlation printed for information.
    print(f"  S3 vocoder samples: correlation {correlation(got, want):.6f} (expected < 1: see below)")
    frame = 480
    trim = (min(len(got), len(want)) // frame) * frame
    envelope = lambda x: np.sqrt((x[:trim].reshape(-1, frame) ** 2).mean(axis=1))  # noqa: E731
    ok &= report("S3 vocoder envelope", envelope(got), envelope(want), 0.99)
    return ok


def correlation(got: np.ndarray, want: np.ndarray) -> float:
    got, want = np.asarray(got, np.float64).ravel(), np.asarray(want, np.float64).ravel()
    n = min(len(got), len(want))
    denom = np.linalg.norm(got[:n]) * np.linalg.norm(want[:n])
    return float(got[:n] @ want[:n] / denom) if denom else 1.0


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--models", type=Path, required=True)
    ap.add_argument("--steps", type=int, default=8, help="decode steps to compare")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--only", choices=["t3", "s3"])
    args = ap.parse_args()

    print("loading Chatterbox Nano")
    model = load_nano()
    ok = True
    if args.only != "s3":
        print("T3:")
        ok &= check_t3(model, args.models, args.steps)
    if args.only != "t3":
        print("S3:")
        ok &= check_s3(model, args.models, args.seed)
    print("PASS" if ok else "FAIL")
    raise SystemExit(0 if ok else 1)


if __name__ == "__main__":
    main()
