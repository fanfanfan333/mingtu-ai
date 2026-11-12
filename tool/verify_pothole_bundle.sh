#!/usr/bin/env bash
# Verify BOTH build shapes of the pothole asset (NAVHAZ M3,
# COMMIT23 zero-burden rule):
#
#   shape A (no weight): `flutter build bundle` succeeds and
#     the produced flutter_assets contain NO pothole model --
#     this is the clean-checkout / default demo shape.
#   shape B (weight in place): the same build succeeds and
#     flutter_assets contain the weight at its asset key,
#     byte-identical in size to the verified file.
#
# The pubspec declares only the DIRECTORY
# assets/models/pothole/ (with a committed .gitkeep), so
# neither shape may fail on the pothole asset. (The MAIN
# model keeps its single-file declaration by design: if
# assets/models/yolo11n.tflite is missing this script runs
# tool/fetch_model.sh first -- that discipline is unchanged
# and not what is being verified here.)
#
# The script is state-restoring: whatever it found in
# assets/models/pothole/ is what it leaves there.
# Exit 0 = both shapes verified.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v flutter >/dev/null 2>&1; then
  # This VM keeps its toolchain off PATH.
  [ -f "$HOME/toolchains/env.sh" ] && . "$HOME/toolchains/env.sh"
fi

WEIGHT="assets/models/pothole/pothole2v.tflite"
BUNDLED="build/flutter_assets/assets/models/pothole/pothole2v.tflite"
STASH="$(mktemp -d)/pothole2v.tflite"
HAD_WEIGHT=0
[ -f "$WEIGHT" ] && HAD_WEIGHT=1

restore() {
  if [ "$HAD_WEIGHT" = "1" ]; then
    mkdir -p assets/models/pothole
    [ -f "$STASH" ] && mv "$STASH" "$WEIGHT"
  fi
}
trap restore EXIT

if [ ! -f assets/models/yolo11n.tflite ]; then
  echo "Main model missing; running tool/fetch_model.sh (its own discipline)."
  bash tool/fetch_model.sh
fi

echo "== shape A: no pothole weight =="
if [ "$HAD_WEIGHT" = "1" ]; then mv "$WEIGHT" "$STASH"; fi
flutter build bundle >/dev/null
if [ -e "$BUNDLED" ]; then
  echo "FAIL: pothole weight leaked into a weightless bundle." >&2
  exit 1
fi
echo "OK: build succeeded, bundle contains no pothole weight."

echo "== shape B: pothole weight in place =="
if [ "$HAD_WEIGHT" = "1" ]; then
  mv "$STASH" "$WEIGHT"
else
  bash tool/fetch_pothole_model.sh
fi
flutter build bundle >/dev/null
if [ ! -f "$BUNDLED" ]; then
  echo "FAIL: weight present on disk but missing from the bundle." >&2
  exit 1
fi
DISK_SIZE="$(stat -c%s "$WEIGHT")"
BUNDLE_SIZE="$(stat -c%s "$BUNDLED")"
if [ "$DISK_SIZE" != "$BUNDLE_SIZE" ]; then
  echo "FAIL: bundled weight size $BUNDLE_SIZE != on-disk $DISK_SIZE." >&2
  exit 1
fi
echo "OK: build succeeded, bundle carries the weight ($BUNDLE_SIZE bytes)."
echo "Both pothole bundle shapes verified."
