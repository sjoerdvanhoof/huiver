#!/usr/bin/env python
"""Freeze what MTLTokenizer does, so the Swift port can be held to it.

    python mtl_tokenizer_fixture.py

Writes packages/huiverkit/Tests/HuiverKitTests/Fixtures/mtl-tokenizer.json:
a list of (text, language, ids) taken from chatterbox's own tokenizer, plus the
pieces the Swift side needs to reproduce it.

A fixture rather than a description, because the thing being ported is a
HuggingFace `tokenizers` pipeline — an added-token split, a Whitespace
pre-tokenizer and a 265-merge BPE — and the only honest way to know a
re-implementation matches is to compare it against the original's output on text
that exercises each stage.
"""

from __future__ import annotations

import json
from pathlib import Path

from common import multilingual_snapshot_dir

# The languages that need no external normaliser. Chinese, Japanese, Hebrew,
# Korean and Russian each route through a separate package (cangjie, pykakasi,
# dicta, ...) before tokenising, and none of that is ported — see MTLTokenizer
# on the Swift side, which refuses them rather than mispronouncing them.
LANGUAGES = ["en", "nl", "de", "fr", "es", "it", "pt", "sv", "da", "no", "fi", "pl", "tr"]

CASES = [
    ("The quiet harbour town woke slowly.", "en"),
    ("Gulls turned above the jetty; the tide was out.", "en"),
    ("Het stadje aan de haven werd langzaam wakker.", "nl"),
    ("Zij zei: 'Kom nou!' — en liep weg.", "nl"),
    ("Der Hafen erwachte langsam, und die Möwen kreisten.", "de"),
    ("Le port s'éveillait lentement — déjà.", "fr"),
    ("El pueblo despertó despacio, muy despacio.", "es"),
    ("Il porto si svegliò lentamente.", "it"),
    ("A vila acordou devagar.", "pt"),
    ("Staden vaknade långsamt.", "sv"),
    ("Byen vågnede langsomt.", "da"),
    ("Byen våknet langsomt.", "no"),
    ("Kaupunki heräsi hitaasti.", "fi"),
    ("Miasteczko obudziło się wolno.", "pl"),
    ("Kasaba yavaşça uyandı.", "tr"),
    # The awkward ones: numbers, repeated punctuation, a stretch of caps, an
    # unknown script, and text that is nothing but spaces.
    ("Chapter 12: 3,000 miles (roughly).", "en"),
    ("WAIT!!! ... why?", "en"),
    ("Mr. O'Hara-Smith's dog", "en"),
    ("naïve café façade", "fr"),
    ("   ", "en"),
    ("日本語", "en"),
    ("", "en"),
]


def main():
    from chatterbox.models.tokenizers.tokenizer import MTLTokenizer

    snapshot = multilingual_snapshot_dir()
    tokenizer = MTLTokenizer(str(snapshot / "grapheme_mtl_merged_expanded_v1.json"))

    cases = []
    for text, language in CASES:
        cases.append(
            {"text": text, "language": language, "ids": tokenizer.encode(text, language_id=language)}
        )
    # Every supported language's tag, on the same sentence, so a wrong tag id
    # cannot hide behind a right one.
    for language in LANGUAGES:
        cases.append(
            {
                "text": "one two three",
                "language": language,
                "ids": tokenizer.encode("one two three", language_id=language),
            }
        )

    out = Path(__file__).resolve().parents[2] / (
        "packages/huiverkit/Tests/HuiverKitTests/Fixtures/mtl-tokenizer.json"
    )
    out.write_text(json.dumps({"cases": cases}, ensure_ascii=False, indent=1) + "\n")
    print(f"wrote {out} — {len(cases)} cases")


if __name__ == "__main__":
    main()
