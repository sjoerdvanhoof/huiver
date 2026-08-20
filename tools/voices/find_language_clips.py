#!/usr/bin/env python
"""Find one native LibriVox reader per language, and prove it is native.

    python find_language_clips.py --languages nl,de,fr
    python find_language_clips.py                     # every language we support

Chatterbox clones whatever clip it is handed, accent and all — so a Dutch book
read with an English reference clip is an English speaker reading Dutch, which is
exactly what it sounds like. The fix is a reference clip per language, and the
hard part is not the cloning but *finding* the clips: archive.org has thousands
of LibriVox recordings, catalogued by ISO 639-3 code, of wildly varying quality.

So each candidate is checked rather than trusted. A thirteen-second clip is cut
out of the middle of a chapter, transcribed with Whisper, and accepted only if
the recogniser agrees about the language and hears actual words. That last part
matters more than it sounds: the top hit for several languages is a chapter that
opens with thirty seconds of music, or a recording so quiet the transcript comes
back empty.

What comes out is written to `clips.json` beside this file — the item, the file
and the offset — which is data the fetch step can replay without ever running a
recogniser again.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent

# The languages the Swift MTLTokenizer will read, by ISO 639-1 → 639-3, which is
# what archive.org catalogues LibriVox with.
LANGUAGES = {
    "nl": "nld", "de": "deu", "fr": "fra", "es": "spa", "it": "ita",
    "pt": "por", "sv": "swe", "da": "dan", "no": "nor", "fi": "fin",
    "pl": "pol", "tr": "tur", "el": "ell", "ar": "ara", "hi": "hin",
    "ms": "msa", "sw": "swa",
}

CLIP_SECONDS = 13
SAMPLE_RATE = 24000
# Offsets to try, in order. The first minutes of a LibriVox chapter are the
# formulaic announcement; later is ordinary narration.
OFFSETS = [120, 240, 420]


def search(code: str, rows: int) -> list[dict]:
    query = f"collection:librivoxaudio AND language:{code}"
    fields = ("identifier", "title", "creator", "downloads")
    url = (
        "https://archive.org/advancedsearch.php?q="
        + urllib.parse.quote(query)
        + "".join(f"&fl%5B%5D={field}" for field in fields)
        + f"&sort%5B%5D=downloads+desc&rows={rows}&page=1&output=json"
    )
    with urllib.request.urlopen(url, timeout=90) as response:
        return json.load(response)["response"]["docs"]


def mp3s(identifier: str) -> list[str]:
    """The item's 64 kbps MP3s, by name, which is chapter order."""
    files = []
    for attempt in range(3):
        try:
            with urllib.request.urlopen(
                f"https://archive.org/metadata/{identifier}", timeout=90
            ) as response:
                files = json.load(response).get("files", [])
            break
        except Exception:
            if attempt == 2:
                raise
            time.sleep(2 + 3 * attempt)
    names = sorted(
        f["name"] for f in files
        if f.get("name", "").endswith(".mp3") and "64kb" in f.get("name", "")
    )
    if names:
        return names
    return sorted(f["name"] for f in files if f.get("name", "").endswith(".mp3"))


def cut(identifier: str, name: str, offset: int, out: Path) -> bool:
    """Thirteen seconds from the middle of a chapter, without the chapter.

    ffmpeg range-requests its way to the offset, so this pulls a few hundred
    kilobytes rather than a whole hour.

    Retried, because archive.org answers a burst of range requests with 5XX far
    more often than it answers them with the file — and a transient 502 read as
    "this recording is unusable" is how a language ends up with no voice for no
    reason.
    """
    url = f"https://archive.org/download/{identifier}/{urllib.parse.quote(name)}"
    command = [
        "ffmpeg", "-nostdin", "-loglevel", "error", "-y",
        # Ride out a dropped connection mid-download rather than failing the
        # candidate.
        "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "5",
        "-user_agent", "huiver-voice-finder/1 (+https://github.com/sjoerdvanhoof)",
        "-ss", str(offset), "-i", url, "-t", str(CLIP_SECONDS),
        "-ac", "1", "-ar", str(SAMPLE_RATE),
        # Same loudness target as the English pack, so no voice arrives louder
        # than the others.
        "-af", "loudnorm=I=-19:TP=-2:LRA=7",
        str(out),
    ]
    for attempt in range(3):
        if subprocess.run(command, timeout=300).returncode == 0 and out.exists():
            return True
        time.sleep(2 + 3 * attempt)
    return False


def transcribe(path: Path, model):
    segments, info = model.transcribe(str(path), beam_size=5)
    text = " ".join(s.text.strip() for s in segments)
    return info.language, float(info.language_probability), text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--languages", help="comma-separated ISO 639-1 codes")
    parser.add_argument("--candidates", type=int, default=4, help="items to try per language")
    parser.add_argument("--out", type=Path, default=HERE / "clips.json")
    parser.add_argument(
        "--clips", type=Path, default=None, help="keep the accepted wavs here too"
    )
    args = parser.parse_args()

    from faster_whisper import WhisperModel

    print("loading the recogniser")
    recogniser = WhisperModel("base", device="cpu", compute_type="int8")

    wanted = args.languages.split(",") if args.languages else list(LANGUAGES)
    accepted = {}
    if args.out.exists():
        accepted = json.loads(args.out.read_text()).get("clips", {})

    for language in wanted:
        code = LANGUAGES.get(language)
        if code is None:
            print(f"{language}: not a language this project reads")
            continue
        print(f"\n=== {language} ({code}) ===")
        try:
            items = search(code, args.candidates)
        except Exception as error:
            print(f"  search failed: {error}")
            continue

        for item in items:
            identifier = item["identifier"]
            title = str(item.get("title", ""))[:48]
            try:
                names = mp3s(identifier)
            except Exception as error:
                print(f"  {identifier}: metadata failed ({error})")
                continue
            if len(names) < 2:
                print(f"  {identifier}: only {len(names)} audio file(s)")
                continue

            # The second file first — the first opens with the LibriVox
            # announcement — then a couple further in.
            choices = [names[index] for index in (1, 2, len(names) // 2) if index < len(names)]
            for name, offset in [(n, o) for n in dict.fromkeys(choices) for o in OFFSETS]:
                with tempfile.TemporaryDirectory() as directory:
                    clip = Path(directory) / f"{language}.wav"
                    if not cut(identifier, name, offset, clip):
                        print(f"  {identifier} @{offset}s: could not cut")
                        continue
                    heard, confidence, text = transcribe(clip, recogniser)
                    words = len(text.split())
                    verdict = (
                        "ok" if heard == language and confidence > 0.7 and words >= 8
                        else f"heard {heard} p={confidence:.2f}, {words} words"
                    )
                    print(f"  {identifier} @{offset}s: {verdict}")
                    if verdict != "ok":
                        continue

                    accepted[language] = {
                        "item": identifier,
                        "file": name,
                        "fileIndex": names.index(name),
                        "offsetSeconds": offset,
                        "title": title,
                        "reader": str(item.get("creator", "")),
                        "heard": heard,
                        "confidence": round(confidence, 3),
                        "transcript": text[:120],
                    }
                    if args.clips:
                        args.clips.mkdir(parents=True, exist_ok=True)
                        (args.clips / f"{language}.wav").write_bytes(clip.read_bytes())
                    break
            if language in accepted:
                break
        if language not in accepted:
            print(f"  {language}: nothing usable found")

    args.out.write_text(
        json.dumps({"clips": dict(sorted(accepted.items()))}, ensure_ascii=False, indent=1) + "\n"
    )
    print(f"\nwrote {args.out} — {len(accepted)} languages")


if __name__ == "__main__":
    main()
