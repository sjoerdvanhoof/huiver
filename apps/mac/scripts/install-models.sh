#!/usr/bin/env bash
#
# Put exported models where the Mac Xcode project expects them.
#
#   ./scripts/install-models.sh [source-dir ...]
#
# With no arguments it installs the **Multilingual** export from
# apps/mac/build-mtl if there is one, and falls back to the Nano export the iOS
# app uses if there is not. One or the other, never both: the engine runs
# whichever models it finds, and two full sets is 3.5 GB in the bundle of which
# half would never be read.
#
# The .mlpackages are compiled to .mlmodelc here rather than by Xcode — same
# reasoning as the iOS script: doing it once by hand keeps a huge build step out
# of every clean build, and makes it obvious what is actually shipping.
#
# Models/ and Voices/ are folder references in the project, so whatever ends up
# in them is copied into the app bundle verbatim, structure and all.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$here/../.." && pwd)"
models="$here/Models"
voices="$here/Voices"

sources=()
if [ $# -gt 0 ]; then
  sources=("$@")
elif compgen -G "$here/build-mtl/*.mlpackage" >/dev/null 2>&1; then
  sources=("$here/build-mtl")
elif [ -d "$repo/apps/ios/build" ]; then
  sources=("$repo/apps/ios/build")
fi

# Which checkpoint this is comes from the packages themselves, not from which
# branch above chose them — otherwise passing a directory explicitly (an int8
# build, say) would install multilingual models beside Nano's tokenizer and
# English-only voices, and the engine would refuse the mismatch.
multilingual=0
for source_dir in "${sources[@]}"; do
  if compgen -G "$source_dir/MTL*.mlpackage" >/dev/null 2>&1; then multilingual=1; fi
done
if [ ${#sources[@]} -gt 0 ]; then
  echo "installing Chatterbox $([ "$multilingual" -eq 1 ] && echo Multilingual || echo Nano)"
fi

if [ ${#sources[@]} -eq 0 ]; then
  echo "No model exports found. Export first:  bun run ios:export" >&2
  exit 1
fi

# Whatever was there is replaced rather than added to: switching from Nano to
# Multilingual must not leave the other one behind for the engine to find.
rm -rf "$models" "$voices"
mkdir -p "$models" "$voices"

found=0
for source_dir in "${sources[@]}"; do
  for package in "$source_dir"/*.mlpackage; do
    [ -e "$package" ] || continue
    name="$(basename "$package" .mlpackage)"
    echo "compiling $name"
    rm -rf "$models/$name.mlmodelc"
    xcrun coremlcompiler compile "$package" "$models" >/dev/null
    found=$((found + 1))
  done
done

if [ "$found" -eq 0 ]; then
  echo "No .mlpackage files in: ${sources[*]}" >&2
  exit 1
fi

# The tokenizer lives beside the models, and which one depends on which model:
# Nano reads GPT-2's three files, Multilingual one grapheme vocabulary.
if [ "$multilingual" -eq 1 ]; then
  snapshot="$(ls -d "$HOME"/.cache/huggingface/hub/models--ResembleAI--chatterbox/snapshots/*/ 2>/dev/null | head -1 || true)"
  tokenizer_files=(grapheme_mtl_merged_expanded_v1.json)
else
  snapshot="$(ls -d "$HOME"/.cache/huggingface/hub/models--ResembleAI--chatterbox-nano/snapshots/*/ 2>/dev/null | head -1 || true)"
  tokenizer_files=(vocab.json merges.txt added_tokens.json)
fi
if [ -n "$snapshot" ]; then
  for file in "${tokenizer_files[@]}"; do
    cp "$snapshot/$file" "$models/$file"
  done
  echo "copied ${#tokenizer_files[@]} tokenizer file(s)"
else
  echo "warning: checkpoint not in the HF cache; tokenizer files not copied" >&2
fi

# Voices come from where export_voices.py wrote them. A voice cloned through one
# checkpoint is not readable by the other — the conditioning prompt is 150
# speech tokens against Nano's 375 — so the multilingual models get the
# multilingual clones, and the engine would refuse the mismatch anyway.
if [ "$multilingual" -eq 1 ]; then
  voice_src="$repo/apps/mac/build-voices-mtl"
else
  voice_src="$repo/apps/ios/build-voices"
fi
if compgen -G "$voice_src/*.voice" >/dev/null 2>&1; then
  cp "$voice_src"/*.voice "$voice_src/voices.json" "$voices/"
  # Previews are optional: a voice without one just has no play button.
  cp "$voice_src"/*.preview.wav "$voices/" 2>/dev/null || true
  echo "copied $(ls "$voices"/*.voice | wc -l | tr -d ' ') voices"
elif compgen -G "$voices/*.voice" >/dev/null 2>&1; then
  echo "no voices in $voice_src; keeping the $(ls "$voices"/*.voice | wc -l | tr -d ' ') already installed"
else
  if [ "$multilingual" -eq 1 ]; then
    echo "warning: no voices in $voice_src — run: bun run mac:voices" >&2
  else
    echo "warning: no voices anywhere — run: bun run ios:voices" >&2
  fi
fi

echo
du -sh "$models" "$voices" 2>/dev/null || true
echo "ready — now run: bun run mac:build && bun run mac:run"
