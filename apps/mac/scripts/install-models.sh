#!/usr/bin/env bash
#
# Put exported models where the Mac Xcode project expects them.
#
#   ./scripts/install-models.sh [source-dir ...]
#
# With no arguments it takes the Nano export the iOS app already uses, plus
# apps/mac/build-mtl when a Multilingual export exists. The .mlpackages are
# compiled to .mlmodelc here rather than by Xcode — same reasoning as the iOS
# script: doing it once by hand keeps a huge build step out of every clean
# build, and makes it obvious what is actually shipping.
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
else
  [ -d "$repo/apps/ios/build" ] && sources+=("$repo/apps/ios/build")
  [ -d "$here/build-mtl" ] && sources+=("$here/build-mtl")
fi

if [ ${#sources[@]} -eq 0 ]; then
  echo "No model exports found. Export first:  bun run ios:export" >&2
  exit 1
fi

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

# The tokenizer is three small files from the Nano checkpoint, and the engine
# reads them from beside the models.
snapshot="$(ls -d "$HOME"/.cache/huggingface/hub/models--ResembleAI--chatterbox-nano/snapshots/*/ 2>/dev/null | head -1 || true)"
if [ -n "$snapshot" ]; then
  for file in vocab.json merges.txt added_tokens.json; do
    cp "$snapshot/$file" "$models/$file"
  done
  echo "copied tokenizer files"
else
  echo "warning: Nano checkpoint not in the HF cache; tokenizer files not copied" >&2
fi

# Voices come from where export_voices.py wrote them for the iOS app — the
# .voice format is platform-agnostic, so both apps ship the same files.
voice_src="$repo/apps/ios/build-voices"
if compgen -G "$voice_src/*.voice" >/dev/null 2>&1; then
  cp "$voice_src"/*.voice "$voice_src/voices.json" "$voices/"
  # Previews are optional: a voice without one just has no play button.
  cp "$voice_src"/*.preview.wav "$voices/" 2>/dev/null || true
  echo "copied $(ls "$voices"/*.voice | wc -l | tr -d ' ') voices"
elif compgen -G "$voices/*.voice" >/dev/null 2>&1; then
  echo "no voices in $voice_src; keeping the $(ls "$voices"/*.voice | wc -l | tr -d ' ') already installed"
else
  echo "warning: no voices anywhere — run: bun run ios:voices" >&2
fi

echo
du -sh "$models" "$voices" 2>/dev/null || true
echo "ready — now run: bun run mac:build && bun run mac:run"
