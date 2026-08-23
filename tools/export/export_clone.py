#!/usr/bin/env python
"""Export the voice cloner for either checkpoint.

    python export_clone.py --out ../../apps/ios/build                 # Nano
    python export_clone.py --multilingual --out ../../apps/mac/build-mtl

One recording in, the five tensors of a voice out — the whole of
`export_voices.py`'s cloning, as a Core ML package the app can run itself. The
graph is `mtl_clone_export`, which is checkpoint-agnostic: the tokenizer, the
mel front-ends and CAMPPlus are the same modules in both checkpoints, and the
voice encoder differs only in its weights. What differs between the two exports
is the name and the length of the conditioning prompt.

Nano's is 375 tokens against the multilingual's 150, and the extra 225 are
zeros — six seconds of speech is what `prepare_conditionals` tokenises for
either model, and `export_voices.py` has always padded that to whatever the T3
asks for. Every voice the phone ships is that shape, so the cloner makes the
same one; `verify_clone.py --nano` is what holds it to that.
"""

from __future__ import annotations

import argparse
from pathlib import Path

# Nano's T3 asks for a 375-token conditioning prompt, and gets it from fifteen
# seconds of speech at 25 Hz — `ChatterboxTurboTTS.ENC_COND_LEN`. The
# multilingual checkpoint's is six seconds and 150 tokens.
NANO_COND_SECONDS = 15
NANO_COND_PROMPT_LEN = NANO_COND_SECONDS * 25


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, required=True, help="directory to write the .mlpackage into")
    ap.add_argument(
        "--multilingual", action="store_true",
        help="export the Mac's cloner instead of the phone's",
    )
    ap.add_argument(
        "--precision", choices=["fp16", "fp32"], default="fp16",
        help="two of the five outputs are tokens, so this matters more than "
             "usual (default: %(default)s; see mtl_clone_export)",
    )
    ap.add_argument(
        "--quantize", choices=["none", "int8", "int4"], default="none",
        help="weight quantisation; int8 measurably breaks the tokens "
             "(default: %(default)s)",
    )
    args = ap.parse_args()

    import mtl_clone_export as C
    from common import load_multilingual, load_nano

    args.out.mkdir(parents=True, exist_ok=True)

    if args.multilingual:
        print("loading Chatterbox Multilingual")
        model = load_multilingual()
        name = "MTLVoiceCloner"
        cond_seconds = C.COND_SECONDS
    else:
        print("loading Chatterbox Nano")
        model = load_nano()
        name = "VoiceCloner"
        cond_seconds = NANO_COND_SECONDS

    print(
        f"cloner: {name}, {cond_seconds}s conditioning window "
        f"({cond_seconds * 25} tokens)"
    )
    C.export(
        model,
        args.out,
        quant=args.quantize,
        precision=args.precision,
        name=name,
        cond_seconds=cond_seconds,
    )


if __name__ == "__main__":
    main()
