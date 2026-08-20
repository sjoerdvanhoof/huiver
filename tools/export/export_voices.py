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
    load_multilingual,
    load_nano,
)

MAGIC = b"HVOI"
VERSION = 1

# For naming the per-language voices. Only the languages the Swift tokenizer
# will read — see MTLTokenizer, which declines the five that need a normaliser
# this project does not port.
LANGUAGE_NAMES = {
    "ar": "Arabic", "da": "Danish", "de": "German", "el": "Greek", "en": "English",
    "es": "Spanish", "fi": "Finnish", "fr": "French", "hi": "Hindi", "it": "Italian",
    "ms": "Malay", "nl": "Dutch", "no": "Norwegian", "pl": "Polish",
    "pt": "Portuguese", "sv": "Swedish", "sw": "Swahili", "tr": "Turkish",
}

# The desktop app's descriptions, so a voice reads the same on both.
# name, what the voice sounds like, and who it sounds like.
#
# The third field is the persona: `detail` describes the recording, this
# describes the reader. It is what makes choosing a voice a choice about who
# reads your book rather than a choice between "UK female, measured" and "UK
# female, crisp".
READERS = {
    "lv_klett": (
        "Elizabeth",
        "US female, clear and literary",
        "Reads as though the book matters and you have all evening. Best for "
        "long novels you intend to finish.",
    ),
    "lv_savage": (
        "Karen",
        "US female, warm and storybook",
        "The voice of someone reading to a room. Unhurried, fond of the "
        "characters, good company at bedtime.",
    ),
    "lv_shallenberg": (
        "Kara",
        "US female, bright and brisk",
        "Keeps things moving. Suits non-fiction and anything you want to get "
        "through rather than linger over.",
    ),
    "lv_golding": (
        "Ruth",
        "UK female, measured",
        "Unshowy and exact, the way a good documentary is narrated. Never gets "
        "between you and the sentence.",
    ),
    "lv_samuel": (
        "Cori",
        "UK female, crisp",
        "Precise and a little dry. Handles complicated prose without letting it "
        "become a performance.",
    ),
    "lv_smith": (
        "Mark",
        "US male, steady and even",
        "Even-tempered to the point of being restful. The safe choice for a "
        "book you will listen to for twenty hours.",
    ),
    "lv_chenevert": (
        "Phil",
        "US male, lively",
        "Enjoys the material and lets you hear it. Good for adventure, comedy, "
        "and anything with dialogue worth acting.",
    ),
    "lv_neufeld": (
        "Bob",
        "US male, deep and unhurried",
        "Low, slow and settled. The one to fall asleep to, which is either the "
        "point or the problem.",
    ),
    "lv_clarke": (
        "David",
        "UK male, crisp and precise",
        "Articulate and slightly formal. Suits history, biography and anything "
        "with footnotes.",
    ),
    "lv_praetzellis": (
        "Adrian",
        "UK male, characterful",
        "Has opinions about the characters and does the voices. Excellent for "
        "classics, distracting for a manual.",
    ),
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


def write_voice(path: Path, conds, cond_prompt_len: int = 375) -> None:
    speaker = fit(conds.t3.speaker_emb.reshape(1, -1), SPEAKER_EMBED_SIZE, 1)
    cond_prompt = fit(conds.t3.cond_prompt_speech_tokens.reshape(1, -1), cond_prompt_len, 1)
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
                cond_prompt_len,
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
        "--multilingual",
        action="store_true",
        help="clone through Chatterbox Multilingual rather than Nano",
    )
    ap.add_argument(
        "--clips",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "apps" / "web" / "data" / "voices",
        help="where the desktop app keeps its reference clips",
    )
    ap.add_argument(
        "--language-clips",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "tools" / "voices" / "clips",
        help="one native reader per language, named <code>.wav",
    )
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    # The two checkpoints have their own voice encoders and their own
    # conditioning length — 150 speech tokens against Nano's 375, because the
    # multilingual T3 resamples the prompt through a perceiver instead of
    # prefixing it whole. A voice cloned through one is not readable by the
    # other, which is why this is a flag and not a shared output directory.
    if args.multilingual:
        print("loading Chatterbox Multilingual")
        model = load_multilingual()
        cond_prompt_len = model.t3.hp.speech_cond_prompt_len
        default_voice = ("mtl_default", "Multilingual", "the model's own voice")
    else:
        print("loading Chatterbox Nano")
        model = load_nano()
        cond_prompt_len = 375
        default_voice = ("nano_default", "Nano", "the model's own voice")
    print(f"  conditioning prompt: {cond_prompt_len} speech tokens")
    if model.conds is None:
        raise SystemExit("this checkpoint has no conds.pt, so it has no built-in voice")

    # Saved aside immediately: cloning a clip overwrites model.conds, and this
    # is the only way back to the voice that ships in the weights.
    builtin = model.conds

    entries = []

    def emit(
        voice_id: str,
        name: str,
        detail: str,
        conds,
        persona: str | None = None,
        language: str = "en",
    ) -> None:
        filename = f"{voice_id}.voice"
        write_voice(args.out / filename, conds, cond_prompt_len=cond_prompt_len)
        # The language travels with the voice because the accent does: the model
        # reads any language in any voice, but it reads it *with the reference
        # clip's accent*, so this is what lets the app offer a reader who
        # belongs to the book.
        entry = dict(id=voice_id, name=name, detail=detail, file=filename, language=language)
        if persona:
            entry["persona"] = persona
        entries.append(entry)
        size = (args.out / filename).stat().st_size
        print(f"  {voice_id:<18} {name:<12} {size/1024:.0f} KB")

    emit(
        default_voice[0],
        default_voice[1],
        default_voice[2],
        builtin,
        "Chatterbox as it comes, with no one cloned into it. Neutral, "
        "reliable, and the fastest thing here to start with.",
    )

    clips = []
    for folder, prefix in ((args.clips / "builtin", ""), (args.clips / "recorded", "rec_")):
        if folder.is_dir():
            clips += [(prefix, path) for path in sorted(folder.glob("*.wav"))]
    if not clips:
        print(f"  no reference clips under {args.clips} — run: bun run voices")

    # One native reader per language, from tools/voices. Named `<code>.wav`, so
    # the file name is the language — see find_language_clips.py, which is what
    # establishes that the reader really speaks it.
    language_clips = sorted(args.language_clips.glob("*.wav")) if args.language_clips.is_dir() else []
    if not language_clips:
        print(f"  no per-language clips under {args.language_clips}")

    for clip in language_clips:
        code = clip.stem
        language = LANGUAGE_NAMES.get(code, code)
        model.prepare_conditionals(str(clip))
        emit(
            f"lang_{code}",
            language,
            f"native {language} reader",
            model.conds,
            f"A LibriVox reader recorded in {language}. The accent comes from the "
            f"clip rather than from the text, so this is the one to pick for a "
            f"{language} book.",
            language=code,
        )

    for prefix, clip in clips:
        stem = clip.stem
        name, detail, persona = READERS.get(
            stem, (stem.replace("_", " ").title(), "your recording", None)
        )
        # prepare_conditionals cuts the clip to the model's own windows: fifteen
        # seconds for the speech encoder, ten for the decoder. Ten seconds at
        # 25 Hz is exactly the 250 tokens the export is shaped for.
        model.prepare_conditionals(str(clip))
        emit(prefix + stem, name, detail, model.conds, persona)

    manifest = args.out / "voices.json"
    manifest.write_text(json.dumps(dict(voices=entries), indent=2) + "\n")
    print(f"wrote {manifest} — {len(entries)} voices")


if __name__ == "__main__":
    main()
