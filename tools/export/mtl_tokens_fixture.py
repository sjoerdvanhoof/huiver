#!/usr/bin/env python
"""Freeze the speech tokens the reference loop produces, greedily.

    python mtl_tokens_fixture.py

Writes packages/huiverkit/Tests/HuiverKitTests/Fixtures/mtl-tokens.json.

This is the fixture that answers "is the Swift decode loop right?" for a
language other than the one the parity harness happens to use. The tokenizer is
already checked against Python and the Core ML packages against torch — but both
of those were checked on English text, and a language tag is one token in a
prompt of sixty. Greedy, so there is a single right answer to compare against.
"""

from __future__ import annotations

import json
from pathlib import Path

import torch

from common import load_multilingual
from mtl_reference import MultilingualReference, SamplingOptions

CASES = [
    ("The quiet harbour town woke slowly.", "en"),
    ("Het stadje aan de haven werd langzaam wakker.", "nl"),
    ("De schrijver liep langzaam door de oude stad en dacht aan zijn jeugd.", "nl"),
]
STEPS = 24

# How far apart the top two candidates have to be for the choice between them to
# mean anything.
#
# A converted model runs in float16 and its weights are quantised, so its logits
# sit a little away from torch's — a few hundredths, measured. Where two
# candidates are closer together than that, which one argmax returns is a coin
# toss, and comparing the tokens would be testing the coin. So the gap travels
# with the fixture and the Swift side stops comparing where it closes.
DECISIVE = 0.15


def greedy(reference, text: str, language: str, options):
    """Greedy tokens, and how decisive each step was.

    Written out here rather than calling `reference.generate` because the gap
    between the top two candidates is only visible inside the loop, and it is
    the thing that says whether a later disagreement is a fault or a tie.
    """
    import torch

    tokens = reference.text_tokens(text, language)
    embeds = reference.prefix_embeds(tokens, options.cfg_weight)
    logits, cache = reference.forward(embeds, None)

    ids, gaps = [], []
    for step in range(STEPS):
        guided = reference.cfg(logits[:, -1], options.cfg_weight)[0]
        top = torch.topk(guided, 2)
        token = int(top.indices[0])
        ids.append(token)
        gaps.append(round(float(top.values[0] - top.values[1]), 6))
        if token == reference.hp.stop_speech_token:
            break
        logits, cache = reference.forward(
            reference.step_embeds(torch.tensor([[token]]), step), cache
        )
    return ids, gaps


def main():
    model = load_multilingual()
    reference = MultilingualReference(model)
    options = SamplingOptions()

    cases = []
    with torch.inference_mode():
        for text, language in CASES:
            ids, gaps = greedy(reference, text, language, options)
            cases.append(
                {"text": text, "language": language, "tokens": ids, "gaps": gaps}
            )
            decisive = 0
            for gap in gaps:
                if gap <= DECISIVE:
                    break
                decisive += 1
            print(f"{language}: {ids[:8]} — {decisive}/{len(ids)} steps decisive")

    out = Path(__file__).resolve().parents[2] / (
        "packages/huiverkit/Tests/HuiverKitTests/Fixtures/mtl-tokens.json"
    )
    out.write_text(
        json.dumps({"steps": STEPS, "decisive": DECISIVE, "cases": cases}, ensure_ascii=False)
        + "\n"
    )
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
