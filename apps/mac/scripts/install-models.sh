#!/usr/bin/env bash
#
# Put exported models where the Mac Xcode project expects them.
#
#   ./scripts/install-models.sh [source-dir ...]
#
# With no arguments it installs the **Multilingual** export from
# apps/mac/build-mtl. The Mac app is multilingual-only — Nano stayed on the
# phone — so a source without the MTL packages is refused rather than
# installed.
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
fi

if [ ${#sources[@]} -eq 0 ]; then
  echo "No model exports found. Export first:  bun run mac:models" >&2
  exit 1
fi

# The Mac app only runs the multilingual checkpoint. Refuse anything else up
# front — installing Nano's packages would just make the app fail at load.
multilingual=0
for source_dir in "${sources[@]}"; do
  if compgen -G "$source_dir/MTL*.mlpackage" >/dev/null 2>&1; then multilingual=1; fi
done
if [ "$multilingual" -ne 1 ]; then
  echo "error: no MTL*.mlpackage in: ${sources[*]} — the Mac app is multilingual-only. Run: bun run mac:models" >&2
  exit 1
fi
echo "installing Chatterbox Multilingual"

# Whatever was there is replaced rather than added to, so a stale set is never
# left behind for the engine to find.
rm -rf "$models" "$voices"
mkdir -p "$models" "$voices"

found=0
for source_dir in "${sources[@]}"; do
  for package in "$source_dir"/*.mlpackage; do
    [ -e "$package" ] || continue
    name="$(basename "$package" .mlpackage)"
    # The multilingual T3 runs on MLX (MTLT3Backbone.safetensors below); its
    # Core ML pair is verification tooling, not something to ship — the two of
    # them are a gigabyte the engine would never load.
    case "$name" in MTLT3Prefill|MTLT3Decode) continue ;; esac
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

# The MLX backbone rides along when the export produced one: the engine runs
# the multilingual token loop on MLX when these files are present, and falls
# back to the Core ML pair when they are not. The metallib is MLX's Metal
# kernel library from the mlx python wheel — the app does not need it (Xcode
# compiles the kernels into mlx-swift_Cmlx.bundle), but `swift test` cannot
# compile Metal, so `bun run kit:test` copies this one into the test bundle.
for extra in MTLT3Backbone.safetensors MTLT3Backbone.json; do
  for source_dir in "${sources[@]}"; do
    if [ -f "$source_dir/$extra" ]; then
      cp "$source_dir/$extra" "$models/$extra"
      echo "copied $extra"
    fi
  done
done
if [ ! -f "$models/MTLT3Backbone.safetensors" ]; then
  echo "error: multilingual needs MTLT3Backbone.safetensors and there is no Core ML fallback — run: bun run mac:backbone" >&2
  exit 1
fi
metallib="$repo/tools/export/.venv-chatterbox/lib/python3.11/site-packages/mlx/lib/mlx.metallib"
if [ -f "$metallib" ]; then
  cp "$metallib" "$here/mlx.metallib"
  echo "copied mlx.metallib"
elif [ ! -f "$here/mlx.metallib" ]; then
  echo "warning: no mlx.metallib — pip install mlx into the chatterbox venv, or the MLX path will not start" >&2
fi

# The tokenizer lives beside the models: one grapheme vocabulary.
snapshot="$(ls -d "$HOME"/.cache/huggingface/hub/models--ResembleAI--chatterbox/snapshots/*/ 2>/dev/null | head -1 || true)"
if [ -n "$snapshot" ]; then
  cp "$snapshot/grapheme_mtl_merged_expanded_v1.json" "$models/"
  echo "copied tokenizer"
else
  echo "warning: checkpoint not in the HF cache; tokenizer not copied" >&2
fi

# Voices come from where export_voices.py wrote them. A voice cloned through
# Nano is not readable here — the conditioning prompt is 150 speech tokens
# against Nano's 375 — so only the multilingual clones are installed, and the
# engine would refuse the mismatch anyway.
voice_src="$repo/apps/mac/build-voices-mtl"
if compgen -G "$voice_src/*.voice" >/dev/null 2>&1; then
  cp "$voice_src"/*.voice "$voice_src/voices.json" "$voices/"
  # Previews are optional: a voice without one just has no play button.
  cp "$voice_src"/*.preview.wav "$voices/" 2>/dev/null || true
  echo "copied $(ls "$voices"/*.voice | wc -l | tr -d ' ') voices"
elif compgen -G "$voices/*.voice" >/dev/null 2>&1; then
  echo "no voices in $voice_src; keeping the $(ls "$voices"/*.voice | wc -l | tr -d ' ') already installed"
else
  echo "warning: no voices in $voice_src — run: bun run mac:voices" >&2
fi

echo
du -sh "$models" "$voices" 2>/dev/null || true
echo "ready — now run: bun run mac:build && bun run mac:run"
