#!/usr/bin/env python
"""Cut the reference clips `clips.json` names, without a recogniser.

    python fetch_language_clips.py                 # everything in clips.json
    python fetch_language_clips.py --only nl,de

Writes `clips/<code>.wav` beside this file: thirteen seconds of one native
reader per language, loudness-matched, at 24 kHz mono — which is what
`export_voices.py` turns into a voice.

Separate from `find_language_clips.py` on purpose. Finding a clip means
searching archive.org, downloading candidates and transcribing them to check
the language is really what the catalogue claims; replaying a found clip means
one range request. The first is research and needs Whisper; the second is a
build step and should need nothing.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import time
import urllib.parse
from pathlib import Path

HERE = Path(__file__).resolve().parent
CLIP_SECONDS = 13
SAMPLE_RATE = 24000


def cut(item: str, name: str, offset: int, out: Path) -> bool:
    url = f"https://archive.org/download/{item}/{urllib.parse.quote(name)}"
    command = [
        "ffmpeg", "-nostdin", "-loglevel", "error", "-y",
        "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5",
        "-user_agent", "huiver-voice-fetch/1",
        "-ss", str(offset), "-i", url, "-t", str(CLIP_SECONDS),
        "-ac", "1", "-ar", str(SAMPLE_RATE),
        "-af", "loudnorm=I=-19:TP=-2:LRA=7",
        str(out),
    ]
    # archive.org answers a burst of range requests with 5XX often enough that
    # one attempt is not a verdict.
    for attempt in range(3):
        if subprocess.run(command, timeout=300).returncode == 0 and out.exists():
            return True
        time.sleep(2 + 3 * attempt)
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clips", type=Path, default=HERE / "clips.json")
    parser.add_argument("--out", type=Path, default=HERE / "clips")
    parser.add_argument("--only", help="comma-separated language codes")
    args = parser.parse_args()

    catalogue = json.loads(args.clips.read_text())["clips"]
    wanted = args.only.split(",") if args.only else list(catalogue)
    args.out.mkdir(parents=True, exist_ok=True)

    for language in wanted:
        entry = catalogue.get(language)
        if entry is None:
            print(f"{language}: not in {args.clips.name}")
            continue
        destination = args.out / f"{language}.wav"
        if destination.exists():
            print(f"{language}: already have it")
            continue
        ok = cut(entry["item"], entry["file"], entry["offsetSeconds"], destination)
        size = destination.stat().st_size // 1024 if ok else 0
        print(f"{language}: {'ok' if ok else 'FAILED'} {entry['item']} — {size} KB")


if __name__ == "__main__":
    main()
