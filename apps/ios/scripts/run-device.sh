#!/usr/bin/env bash
#
# Build and install on a connected iPhone.
#
#   ./scripts/run-device.sh [device-id] [--debug] [--launch]
#
# With no device id the one connected iPhone is used, and it complains if there
# is more than one rather than picking.
#
# Release by default, deliberately. The token loop and the sampler are ordinary
# Swift, and a Debug build compiles them at -Onone, which makes the model look
# several times slower than it is. Pass --debug when you want breakpoints and
# do not care about the timings.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$here/Huiver.xcodeproj"
configuration=Release
device=""
launch=0

for arg in "$@"; do
  case "$arg" in
    --debug) configuration=Debug ;;
    --launch) launch=1 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *) device="$arg" ;;
  esac
done

if [ ! -d "$here/Models" ] || [ -z "$(ls -A "$here/Models" 2>/dev/null)" ]; then
  echo "No models in $here/Models — run: bun run ios:install" >&2
  exit 1
fi

if [ -z "$device" ]; then
  # iOS reuses device names across handsets, so the udid is the only
  # unambiguous answer; a bare --device would also list simulators.
  #
  # Written for bash 3.2, which is what /bin/bash on macOS still is: no
  # mapfile, no readarray, no associative arrays.
  devices="$(
    xcodebuild -project "$project" -scheme Huiver -showdestinations 2>/dev/null \
      | grep "platform:iOS," | grep -v Simulator | grep -v placeholder \
      | sed -E 's/.*id:([^,]+), name:(.*) \}/\1 \2/' || true
  )"
  count="$(printf '%s' "$devices" | grep -c . || true)"

  if [ "$count" -eq 0 ]; then
    echo "No iPhone found. Plug one in, unlock it, and trust this Mac." >&2
    echo "Developer Mode must be on: Settings > Privacy & Security > Developer Mode." >&2
    exit 1
  fi
  if [ "$count" -gt 1 ]; then
    echo "More than one device connected — pass the id you want:" >&2
    printf '  %s\n' "$devices" >&2
    exit 1
  fi
  device="${devices%% *}"
  echo "device: ${devices#* }  ($device)"
fi

echo "building $configuration"
xcodebuild -project "$project" -scheme Huiver \
  -configuration "$configuration" \
  -destination "id=$device" \
  -allowProvisioningUpdates \
  build

app="$(
  xcodebuild -project "$project" -scheme Huiver -configuration "$configuration" \
    -destination "id=$device" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ TARGET_BUILD_DIR /{d=$2} / FULL_PRODUCT_NAME /{n=$2} END{print d"/"n}'
)"
echo "installing $(du -sh "$app" | cut -f1) — this takes a minute over USB"
xcrun devicectl device install app --device "$device" "$app"

if [ "$launch" -eq 1 ]; then
  xcrun devicectl device process launch --device "$device" com.hoofkantoor.huiver
fi

echo
echo "installed. Look for 'huiver nano' on the home screen."
echo "First launch after a re-export compiles the models for the device (minutes);"
echo "the app shows a progress screen while it does."
