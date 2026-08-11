#!/usr/bin/env bash
#
# Put exported models where the Xcode project expects them.
#
#   ./scripts/install-models.sh [source-dir]
#
# The .mlpackages are compiled to .mlmodelc here rather than by Xcode. Xcode
# would happily compile them during the build, but the result is the same and
# doing it once by hand keeps a 700 MB build step out of every clean build --
# and makes it obvious what is actually shipping.
#
# Models/ and Voices/ are folder references in the project, so whatever ends up
# in them is copied into the app bundle verbatim, structure and all.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="${1:-$here/build}"
models="$here/Models"
voices="$here/Voices"

if [ ! -d "$source_dir" ]; then
  echo "No such directory: $source_dir" >&2
  echo "Export first:  bun run ios:export" >&2
  exit 1
fi

mkdir -p "$models" "$voices"

found=0
for package in "$source_dir"/*.mlpackage; do
  [ -e "$package" ] || continue
  name="$(basename "$package" .mlpackage)"
  echo "compiling $name"
  rm -rf "$models/$name.mlmodelc"
  xcrun coremlcompiler compile "$package" "$models" >/dev/null
  found=$((found + 1))
done

if [ "$found" -eq 0 ]; then
  echo "No .mlpackage files in $source_dir" >&2
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

# Voices come from where export_voices.py wrote them. Resolved and compared
# against the destination before copying: macOS filesystems are usually
# case-insensitive, so a stray "voices" path is the same directory as "Voices",
# and cp onto itself fails the whole script rather than doing nothing.
voice_src="${2:-$here/build-voices}"
if [ -d "$voice_src" ] && [ "$(cd "$voice_src" && pwd -P)" = "$(cd "$voices" && pwd -P)" ]; then
  echo "voices already in place"
elif compgen -G "$voice_src/*.voice" >/dev/null 2>&1; then
  cp "$voice_src"/*.voice "$voice_src/voices.json" "$voices/"
  echo "copied $(ls "$voices"/*.voice | wc -l | tr -d ' ') voices"
elif compgen -G "$voices/*.voice" >/dev/null 2>&1; then
  echo "no voices in $voice_src; keeping the $(ls "$voices"/*.voice | wc -l | tr -d ' ') already installed"
else
  echo "warning: no voices anywhere — run: bun run ios:voices" >&2
fi

echo
du -sh "$models" "$voices" 2>/dev/null || true
echo "ready — now run: bun run ios:device"
