#!/usr/bin/env python
"""Check the converted voice cloner against chatterbox's own cloning.

    python verify_clone.py --models ../../apps/mac/build-mtl
    python verify_clone.py --models ../../apps/mac/build-mtl --clip ../voices/clips/nl.wav

Cloning is five tensors, and they fail differently. Two of them are *tokens*: an
argmin over a codebook, so precision-sensitive in a way the others are not — at
float32 the exported model reproduces all 400 of them, at float16 about half,
and at int8 fewer still. The other three are embeddings and a mel, which move by
a millionth at any precision.

Which raises the question the token count cannot answer: does it *matter*?
Measured, no. A clone built from the float16 export renders speech whose speaker
embedding sits 0.897 from the reference clip, against 0.900 for float32 — the
tokens that differ are acoustically neighbouring entries, and the identity is
carried by the embeddings. So the tokens are held exactly where they can be (in
torch, and at float32) and reported where they cannot, and the gate for a
converted model is the cosine of the tensors that decide who it sounds like.

The comparison is against `prepare_conditionals`, with one substitution made
explicit: upstream resamples the clip twice with two different resamplers
(torchaudio for the decoder's path, librosa's `kaiser_fast` for the voice
encoder's) and the exported model resamples once. So librosa's is pointed at
torchaudio's here, or the difference under test would be a resampler rather than
a conversion.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
import torchaudio

from common import load_multilingual
from mtl_clone_export import CLIP_24K, OUTPUTS, S3GEN_SR, TARGET_LUFS, VoiceCloner


def normalise_loudness(audio: np.ndarray, target_lufs: float = TARGET_LUFS) -> np.ndarray:
    """`ChatterboxTurboTTS.norm_loudness`, which Nano applies and the Mac's
    checkpoint does not.

    One gain over the whole clip, so it belongs outside the graph — the app does
    it in Swift (`Loudness`) and this does it here, and the two are held together
    by `LoudnessTests` rather than by hope.
    """
    import pyloudnorm as ln

    meter = ln.Meter(S3GEN_SR)
    loudness = meter.integrated_loudness(audio)
    gain = 10.0 ** ((target_lufs - loudness) / 20.0)
    if not np.isfinite(gain) or gain <= 0:
        return audio
    return (audio * gain).astype(np.float32)


def load_clip(path: Path, seconds: int = 10) -> np.ndarray:
    """`seconds` at 24 kHz, padded if the clip is short."""
    audio, rate = sf.read(str(path), dtype="float32")
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if rate != S3GEN_SR:
        audio = torchaudio.functional.resample(
            torch.tensor(audio), rate, S3GEN_SR
        ).numpy()
    # Trimmed before anything else, because the voice encoder trims too —
    # `embeds_from_wavs(trim_top_db=20)` — and comparing a trimmed clip against
    # an untrimmed one measures the silence at the front rather than the
    # conversion. The app trims for the same reason: a reference clip should be
    # speech.
    import librosa

    audio, _ = librosa.effects.trim(audio, top_db=20)
    samples = seconds * S3GEN_SR
    clip = np.zeros(samples, dtype=np.float32)
    take = min(samples, len(audio))
    clip[:take] = audio[:take]
    return clip


def upstream(model, clip: np.ndarray, path: Path):
    """What `prepare_conditionals` makes of the same ten seconds."""
    import librosa

    original = librosa.resample

    def resample(y, *, orig_sr, target_sr, **kwargs):
        return torchaudio.functional.resample(
            torch.tensor(y).float(), orig_sr, target_sr
        ).numpy()

    librosa.resample = resample
    try:
        model.prepare_conditionals(str(path))
    finally:
        librosa.resample = original
    conds = model.conds
    return (
        conds.t3.speaker_emb,
        conds.t3.cond_prompt_speech_tokens,
        conds.gen["prompt_token"],
        conds.gen["prompt_feat"],
        conds.gen["embedding"],
    )


def cosine(a: torch.Tensor, b: torch.Tensor) -> float:
    a, b = a.reshape(-1).double(), b.reshape(-1).double()
    return float(a @ b / (a.norm() * b.norm()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models", type=Path, required=True)
    parser.add_argument(
        "--clip", type=Path, default=Path(__file__).resolve().parents[1] / "voices/clips/nl.wav"
    )
    parser.add_argument(
        "--nano", action="store_true",
        help="check the phone's cloner against Chatterbox Nano instead",
    )
    args = parser.parse_args()

    import coremltools as ct

    from verify_mtl import load_package

    if args.nano:
        from common import load_nano
        from export_clone import NANO_COND_SECONDS

        print("loading Chatterbox Nano")
        model = load_nano()
        name = "VoiceCloner"
        cond_seconds = NANO_COND_SECONDS
    else:
        print("loading Chatterbox Multilingual")
        model = load_multilingual()
        name = "MTLVoiceCloner"
        cond_seconds = 6
    clip = load_clip(args.clip, seconds=max(cond_seconds, 10))

    # A file of exactly the seconds under test, so both sides see the same audio
    # rather than the same intention.
    trimmed = Path("/tmp/huiver-clone-clip.wav")
    sf.write(trimmed, clip, S3GEN_SR)

    # Upstream normalises inside `prepare_conditionals`, so it is handed the
    # clip as recorded; the cloner is handed the normalised one, which is what
    # the app will hand it. Comparing the two is therefore also a check that the
    # normalisation is the same normalisation.
    want = upstream(model, clip, trimmed)
    if args.nano:
        clip = normalise_loudness(clip)
    wav = torch.tensor(clip)[None]

    print("torch:")
    with torch.inference_mode():
        torch_out = VoiceCloner(model, cond_seconds=cond_seconds)(wav)
    ok = report(torch_out, want)

    package = args.models / f"{name}.mlpackage"
    if package.exists():
        print("core ml:")
        cloner = load_package(package)
        predicted = cloner.predict({"wav24": clip[None]})
        precision = cloner.user_defined_metadata.get("precision", "fp16")
        got = [torch.tensor(predicted[output]) for output in OUTPUTS]
        ok &= report(got, want, exact=precision == "fp32")
        print(f"  ({precision}; tokens are only exact at fp32, and need not be)")
    else:
        print(f"no {package.name} — export it first")

    print("PASS" if ok else "FAIL")
    raise SystemExit(0 if ok else 1)


def report(got, want, exact: bool = True) -> bool:
    """Compare five tensors.

    `exact` demands the tokens match, which is right for torch and for a
    float32 export and wrong for anything quantised — see the note at the top.
    """
    ok = True
    for name, mine, theirs in zip(OUTPUTS, got, want):
        mine = torch.as_tensor(mine).float()
        theirs = torch.as_tensor(theirs).detach().float()
        if "token" in name:
            a = mine.reshape(-1).long()
            b = theirs.reshape(-1).long()
            count = min(a.numel(), b.numel())
            same = int((a[:count] == b[:count]).sum())
            good = same == count or not exact
            label = "ok  " if same == count else ("    " if good else "FAIL")
            print(f"  {name:<20} {label}  {same}/{count} identical")
        else:
            similarity = cosine(mine, theirs)
            # A mel is not an embedding: its bins live on a log scale where a
            # spectral null costs half a unit and nothing audible, so the mel is
            # judged by correlation and the embeddings by how far they point
            # apart.
            floor = 0.999 if "feat" in name else 0.9995
            good = similarity > floor
            print(f"  {name:<20} {'ok  ' if good else 'FAIL'}  cosine {similarity:.6f}")
        ok = ok and good
    return ok


if __name__ == "__main__":
    main()
