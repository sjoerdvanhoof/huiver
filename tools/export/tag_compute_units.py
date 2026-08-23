#!/usr/bin/env python
"""Record `computeUnits` on an already-exported .mlpackage.

    python tag_compute_units.py ../../apps/ios/build

`export_models.py` writes this itself now. This exists for packages exported
before it did: re-running the export means re-tracing and re-verifying against
torch, and the only thing that has to change is one metadata string.

The value is what `ComputeUnits.ladder(for:)` reads on the Swift side, out of
the compiled model's `metadata.json`, *before* the load — so it is what decides
whether a package is ever offered to the Neural Engine. Editing it here is
enough; the weights are untouched and `bun run ios:install` picks the new
metadata up when it compiles the .mlmodelc.
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

import coremltools as ct

# Same split as UNITS in export_models.py, and for the same reasons. Nothing
# goes to the Neural Engine: the three that would waste a compile there, and
# T3Decode, which compiles for it and then fails every prediction.
DEFAULTS = {
    "S3Flow": "cpu_gpu",
    "S3Vocoder": "cpu_gpu",
    "T3Prefill": "cpu_gpu",
    "T3Decode": "cpu_gpu",
}


def tag(package: Path, units: str) -> None:
    # `skip_model_load` is the point of the exercise: loading an S3Flow for the
    # Neural Engine is the quarter-hour compile this whole change is about.
    model = ct.models.MLModel(str(package), skip_model_load=True)
    if model.user_defined_metadata.get("computeUnits") == units:
        print(f"  {package.name}: already {units}")
        return
    model.user_defined_metadata["computeUnits"] = units
    # Saving to the same path through a temporary one: coremltools writes the
    # package rather than editing it in place.
    staged = package.with_name(f"{package.stem}.retag.mlpackage")
    if staged.exists():
        shutil.rmtree(staged)
    model.save(str(staged))
    shutil.rmtree(package)
    staged.rename(package)
    print(f"  {package.name}: computeUnits = {units}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("directory", type=Path, help="directory of .mlpackages to tag")
    ap.add_argument(
        "--units", choices=["all", "cpu_gpu", "cpu"],
        help="tag every package with this instead of the per-model default",
    )
    args = ap.parse_args()

    packages = sorted(args.directory.glob("*.mlpackage"))
    if not packages:
        sys.exit(f"No .mlpackage files in {args.directory}")

    for package in packages:
        name = package.stem
        units = args.units or DEFAULTS.get(name)
        if units is None:
            print(f"  {package.name}: left alone")
            continue
        tag(package, units)


if __name__ == "__main__":
    main()
