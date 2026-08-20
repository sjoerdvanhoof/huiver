#!/usr/bin/env python
"""Freeze the multilingual sampler's output, so the Swift port can be held to it.

    python mtl_sampler_fixture.py

Writes packages/huiverkit/Tests/HuiverKitTests/Fixtures/mtl-sampler.json.

The filters themselves are ordinary — a penalty, a temperature, min-p, top-p —
and `verify_mtl.py --only sampler` already checks each one against the
`LogitsProcessor` HuggingFace composes. What this fixture pins down is the part
that has no reference implementation to compare against: *the order*. Applied
in Nano's order the same four filters give a different distribution, and the
difference is a voice rather than an error.
"""

from __future__ import annotations

import json
from pathlib import Path

import torch

from mtl_reference import MultilingualReference, SamplingOptions


def main():
    options = SamplingOptions()
    torch.manual_seed(7)

    cases = []
    for index, (width, history_size, scale) in enumerate(
        [(8194, 40, 3.0), (8194, 1, 1.0), (256, 12, 0.5), (256, 0, 6.0)]
    ):
        logits = torch.randn(1, width) * scale
        history = torch.randint(0, width, (1, history_size)) if history_size else torch.zeros(1, 0, dtype=torch.long)

        # The order under test: penalty, temperature, min-p, top-p. Guidance
        # has already happened inside the model by this point, so it is not
        # part of this.
        out = MultilingualReference.repetition_penalty(
            logits.clone(), history, options.repetition_penalty
        )
        out = out / options.temperature
        out = MultilingualReference.min_p(out, options.min_p)
        out = MultilingualReference.top_p(out, options.top_p)

        cases.append(
            {
                "logits": logits[0].tolist(),
                "history": sorted(set(history[0].tolist())),
                "filtered": [None if not torch.isfinite(v) else v.item() for v in out[0]],
                "options": {
                    "temperature": options.temperature,
                    "minP": options.min_p,
                    "topP": options.top_p,
                    "repetitionPenalty": options.repetition_penalty,
                },
            }
        )
        print(f"case {index}: {width} wide, {len(cases[-1]['history'])} penalised, "
              f"{sum(v is None for v in cases[-1]['filtered'])} filtered out")

    out = Path(__file__).resolve().parents[2] / (
        "packages/huiverkit/Tests/HuiverKitTests/Fixtures/mtl-sampler.json"
    )
    out.write_text(json.dumps({"cases": cases}) + "\n")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
