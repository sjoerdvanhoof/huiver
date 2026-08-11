#!/usr/bin/env python
"""Turn reference clips into the voice files the iOS app bundles.

    python export_voices.py --out ../Huiver/Voices

Chatterbox has no voice roster: it clones whatever ten-to-fifteen second clip it
is handed. Doing that on the phone would mean shipping three more networks -- a
speech tokenizer, a speaker encoder and an x-vector model -- so huiver does the
cloning here, once, on the Mac, and ships the numbers that come out.

What each voice reduces to is about 165 KB:

    speaker_emb     (256,)      who is speaking, for T3
    cond_prompt     (375,)      speech tokens of them reading the passage
    prompt_token    (250,)      the same clip again, for the mel decoder
    prompt_feat     (500, 80)   and as mel frames
    embedding       (192,)      an x-vector, for the mel decoder

The clip itself never leaves the Mac, and none of these can be turned back into
it. The lengths are fixed rather than per-voice, which is what lets the mel
decoder be a single fixed-shape Core ML model -- see common.PROMPT_TOKEN_LEN.

Sources, in the order they are picked up:

    the model's own voice        always; it lives in the weights
    apps/web/data/voices/builtin the LibriVox pack, if `bun run voices` was run
    apps/web/data/voices/recorded anything recorded in the web app
"""

from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path

import numpy as np
import torch

from common import (
    MEL_DIM,
    PROMPT_FEAT_LEN,
    PROMPT_TOKEN_LEN,
    S3GEN_SR,
    SPEAKER_EMBED_SIZE,
    XVECTOR_DIM,
    load_nano,
)

MAGIC = b"HVOI"
VERSION = 1

# The desktop app's descriptions, so a voice reads the same on both.
READERS = {
    "lv_klett": ("Elizabeth", "US female, clear and literary"),
    "lv_savage": ("Karen", "US female, warm and storybook"),
    "lv_shallenberg": ("Kara", "US female, bright and brisk"),
    "lv_golding": ("Ruth", "UK female, measured"),
    "lv_samuel": ("Cori", "UK female, crisp"),
    "lv_smith": ("Mark", "US male, steady and even"),
    "lv_chenevert": ("Phil", "US male, lively"),
    "lv_neufeld": ("Bob", "US male, deep and unhurried"),
    "lv_clarke": ("David", "UK male, crisp and precise"),
    "lv_praetzellis": ("Adrian", "UK male, characterful"),
}


def fit(tensor: torch.Tensor, length: int, dim: int, pad_value=0) -> torch.Tensor:
    """Trim or pad along `dim` so every voice has identical shapes.

    A clip is cut to exactly ten seconds before this, so in practice nothing is
    padded; the branch is here because a checkpoint whose frame rate differs by
    one would otherwise produce a voice file the app silently misreads.
    """
    have = tensor.shape[dim]
    if have == length:
        return tensor
    if have > length:
        return tensor.narrow(dim, 0, length)
    shape = list(tensor.shape)
    shape[dim] = length - have
    return torch.cat([tensor, torch.full(shape, pad_value, dtype=tensor.dtype)], dim=dim)


def write_voice(path: Path, conds) -> None:
    speaker = fit(conds.t3.speaker_emb.reshape(1, -1), SPEAKER_EMBED_SIZE, 1)
    cond_prompt = fit(conds.t3.cond_prompt_speech_tokens.reshape(1, -1), 375, 1)
    gen = conds.gen
    prompt_token = fit(gen["prompt_token"].reshape(1, -1), PROMPT_TOKEN_LEN, 1)
    prompt_feat = fit(gen["prompt_feat"].reshape(1, -1, MEL_DIM), PROMPT_FEAT_LEN, 1)
    embedding = fit(gen["embedding"].reshape(1, -1), XVECTOR_DIM, 1)

    with path.open("wb") as out:
        out.write(MAGIC)
        out.write(
            struct.pack(
                "<7I",
                VERSION,
                SPEAKER_EMBED_SIZE,
                375,
                PROMPT_TOKEN_LEN,
                PROMPT_FEAT_LEN,
                MEL_DIM,
                XVECTOR_DIM,
            )
        )
        for tensor, dtype in (
            (speaker, np.float32),
            (cond_prompt, np.int32),
            (prompt_token, np.int32),
            (prompt_feat, np.float32),
            (embedding, np.float32),
        ):
            out.write(
                np.ascontiguousarray(tensor.detach().cpu().numpy().ravel(), dtype=dtype).tobytes()
            )


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument(
        "--clips",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "web" / "data" / "voices",
        help="where the desktop app keeps its reference clips",
    )
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    print("loading Chatterbox Nano")
    model = load_nano()
    if model.conds is None:
        raise SystemExit("this checkpoint has no conds.pt, so it has no built-in voice")

    # Saved aside immediately: cloning a clip overwrites model.conds, and this
    # is the only way back to the voice that ships in the weights.
    builtin = model.conds

    entries = []

    def emit(voice_id: str, name: str, detail: str, conds) -> None:
        filename = f"{voice_id}.voice"
        write_voice(args.out / filename, conds)
        entries.append(dict(id=voice_id, name=name, detail=detail, file=filename))
        size = (args.out / filename).stat().st_size
        print(f"  {voice_id:<18} {name:<12} {size/1024:.0f} KB")

    emit("nano_default", "Nano", "the model's own voice", builtin)

    clips = []
    for folder, prefix in ((args.clips / "builtin", ""), (args.clips / "recorded", "rec_")):
        if folder.is_dir():
            clips += [(prefix, path) for path in sorted(folder.glob("*.wav"))]
    if not clips:
        print(f"  no reference clips under {args.clips} — run: bun run voices")

    for prefix, clip in clips:
        stem = clip.stem
        name, detail = READERS.get(stem, (stem.replace("_", " ").title(), "your recording"))
        # prepare_conditionals cuts the clip to the model's own windows: fifteen
        # seconds for the speech encoder, ten for the decoder. Ten seconds at
        # 25 Hz is exactly the 250 tokens the export is shaped for.
        model.prepare_conditionals(str(clip))
        emit(prefix + stem, name, detail, model.conds)

    manifest = args.out / "voices.json"
    manifest.write_text(json.dumps(dict(voices=entries), indent=2) + "\n")
    print(f"wrote {manifest} — {len(entries)} voices")


if __name__ == "__main__":
    main()
