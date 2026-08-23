#!/usr/bin/env python
"""Render the voice previews the app ships with.

    python export_previews.py --out ../build-voices              # every voice
    python export_previews.py --out ../build-voices --only nano_default

The voice picker plays a sample of each voice. Synthesising that on the phone
would mean a fifteen-second wait the first time you tap one, and a warm engine
just to audition a voice — so it is rendered here instead, on the Mac, where
Chatterbox runs against torch and takes a couple of seconds.

The line is the desktop app's, from `apps/web/src/server/audio-routes.ts`, so a
voice auditions identically in the browser and on the phone.

Output is a 24 kHz mono 16-bit WAV per voice, about 250 KB — the same format
`WavFile` writes, so the app can read it without conversion.
"""

from __future__ import annotations

import argparse
import json
import struct
import wave
from pathlib import Path

import numpy as np

from common import S3GEN_SR, load_multilingual, load_nano

PREVIEW_TEXT = (
    "This is how I sound. If you like it, I can read your whole book, "
    "one chapter at a time."
)

# The same line per language, for the voices that have one. A Dutch reader
# auditioning in English tells you nothing about the thing you are choosing it
# for — the accent is the whole point of a per-language voice, and it only shows
# in that language.
PREVIEW_TEXTS = {
    "en": PREVIEW_TEXT,
    "nl": "Zo klink ik. Als je dit fijn vindt, lees ik je hele boek voor, "
          "kapittel voor kapittel.",
    "de": "So klinge ich. Wenn es dir gefällt, lese ich dir das ganze Buch vor, "
          "ein Kapitel nach dem anderen.",
    "fr": "Voilà comment je sonne. Si cela vous plaît, je peux vous lire tout le "
          "livre, un chapitre à la fois.",
    "es": "Así es como sueno. Si te gusta, puedo leerte todo el libro, "
          "un capítulo a la vez.",
    "it": "Ecco come suono. Se ti piace, posso leggerti tutto il libro, "
          "un capitolo alla volta.",
    "pt": "É assim que eu soo. Se gostar, posso ler o livro todo, "
          "um capítulo por vez.",
    "sv": "Så här låter jag. Om du tycker om det kan jag läsa hela boken för dig, "
          "ett kapitel i taget.",
    "da": "Sådan lyder jeg. Hvis du kan lide det, læser jeg hele bogen for dig, "
          "et kapitel ad gangen.",
    "no": "Slik høres jeg ut. Hvis du liker det, kan jeg lese hele boken for deg, "
          "ett kapittel om gangen.",
    "fi": "Tältä minä kuulostan. Jos pidät siitä, voin lukea koko kirjan sinulle, "
          "luku kerrallaan.",
    "pl": "Tak brzmię. Jeśli ci się podoba, przeczytam ci całą książkę, "
          "rozdział po rozdziale.",
    "tr": "Sesim böyle. Beğendiyseniz kitabın tamamını okuyabilirim, "
          "her seferinde bir bölüm.",
    "el": "Έτσι ακούγομαι. Αν σου αρέσει, μπορώ να σου διαβάσω ολόκληρο το βιβλίο, "
          "ένα κεφάλαιο τη φορά.",
    "ar": "هكذا أبدو. إذا أعجبك ذلك، يمكنني أن أقرأ لك الكتاب كله، فصلاً بعد فصل.",
    "hi": "मेरी आवाज़ ऐसी है। अगर आपको पसंद आए, तो मैं आपकी पूरी किताब पढ़ सकता हूँ, "
          "एक बार में एक अध्याय।",
}

# Matches the app's defaults in SamplingOptions, so the preview is
# representative rather than flattering.
TEMPERATURE = 0.8
TOP_P = 0.95
REPETITION_PENALTY = 1.2


def write_wav(path: Path, samples: np.ndarray, rate: int = S3GEN_SR) -> None:
    pcm = np.clip(samples, -1.0, 1.0)
    pcm = (pcm * 32767).round().astype("<i2")
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(rate)
        out.writeframes(pcm.tobytes())


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, required=True, help="where voices.json already is")
    ap.add_argument(
        "--only",
        action="append",
        help="render just this voice id; repeatable. Handy for auditioning the "
        "line before committing to all of them.",
    )
    ap.add_argument(
        "--clips",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "legacy" / "web" / "data" / "voices",
        help="where the desktop app keeps its reference clips",
    )
    ap.add_argument(
        "--language-clips",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "tools" / "voices" / "clips",
        help="the per-language readers, named <code>.wav",
    )
    ap.add_argument("--text", help="what every voice says, overriding the per-language lines")
    ap.add_argument(
        "--multilingual",
        action="store_true",
        help="render through Chatterbox Multilingual, each voice in its own language",
    )
    args = ap.parse_args()

    manifest_path = args.out / "voices.json"
    if not manifest_path.exists():
        raise SystemExit(f"No voices.json in {args.out} — run: bun run ios:voices")
    manifest = json.loads(manifest_path.read_text())

    wanted = set(args.only) if args.only else None
    targets = [v for v in manifest["voices"] if wanted is None or v["id"] in wanted]
    if not targets:
        raise SystemExit(f"No matching voices. Ids: {', '.join(v['id'] for v in manifest['voices'])}")

    if args.multilingual:
        print(f"loading Chatterbox Multilingual for {len(targets)} preview(s)")
        model = load_multilingual()
    else:
        print(f"loading Chatterbox Nano for {len(targets)} preview(s)")
        model = load_nano()
    builtin = model.conds

    for voice in targets:
        # The built-in voice is the one that lives in the weights; every other
        # is cloned from the clip it was exported from.
        if voice["id"] in ("nano_default", "mtl_default"):
            model.conds = builtin
            prompt = None
        else:
            stem = voice["id"].removeprefix("rec_")
            candidates = [
                args.clips / "builtin" / f"{stem}.wav",
                args.clips / "recorded" / f"{stem}.wav",
                # The per-language readers, named by language code.
                args.language_clips / f"{stem.removeprefix('lang_')}.wav",
            ]
            prompt = next((c for c in candidates if c.exists()), None)
            if prompt is None:
                print(f"  {voice['id']:<18} skipped — no reference clip")
                continue

        language = voice.get("language", "en")
        text = args.text or PREVIEW_TEXTS.get(language)
        if text is None:
            # Said out loud rather than quietly falling back to English: a
            # Turkish voice auditioning in English is exactly the thing a
            # per-language voice exists to avoid, and it is invisible unless
            # someone happens to listen.
            print(f"  {voice['id']:<18} no preview line for '{language}' — add one to PREVIEW_TEXTS")
            continue
        if args.multilingual:
            wav = model.generate(
                text,
                language_id=language,
                audio_prompt_path=str(prompt) if prompt else None,
                temperature=TEMPERATURE,
                repetition_penalty=REPETITION_PENALTY,
            )
        else:
            wav = model.generate(
                text,
                audio_prompt_path=str(prompt) if prompt else None,
                temperature=TEMPERATURE,
                top_p=TOP_P,
                repetition_penalty=REPETITION_PENALTY,
            )
        samples = wav.squeeze(0).detach().cpu().numpy()

        name = f"{voice['id']}.preview.wav"
        write_wav(args.out / name, samples)
        voice["preview"] = name
        seconds = len(samples) / S3GEN_SR
        size = (args.out / name).stat().st_size
        print(f"  {voice['id']:<18} {seconds:5.1f}s  {size/1024:5.0f} KB")

    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    rendered = sum(1 for v in manifest["voices"] if "preview" in v)
    print(f"wrote {manifest_path} — {rendered}/{len(manifest['voices'])} voices have a preview")


if __name__ == "__main__":
    main()
