#!/usr/bin/env bash
# Fetch the pothole second-detector model from its OFFICIAL
# source and verify it before any build.
#
# Source : https://huggingface.co/tahaUgan/pothole-yolo11n/resolve/main/pothole2v.tflite
#          (Hugging Face model repo tahaUgan/pothole-yolo11n,
#           file pothole2v.tflite at the repo root; repo
#           revision 5cc2892b1366ca3c70d4ef4b13f1a940dddb2cc5,
#           verified 2026-11-11 via the HF API)
# Target : assets/models/pothole/pothole2v.tflite (bundled
#           when present: pubspec declares the DIRECTORY
#           assets/models/pothole/, so the weight rides
#           along only if this script has placed it there;
#           the ultralytics_yolo resolver copies assets/...
#           paths to the documents directory at runtime)
# Size   : 10552936 bytes
# SHA256 : 4fe02a0894985cdafda11e6aa13c354af4323172fae9f18384143d40b7339afb
#          (matches the LFS sha256 recorded by Hugging Face
#           for this file, and the locally downloaded copy)
# License: CC BY 4.0 (model card front-matter
#          "license: cc-by-4.0" and the repo tag
#          "license:cc-by-4.0"). Attribution: tahaUgan --
#          "pothole-yolo11n" (see README, YOLO model section).
# Classes: 0 = Pothole, 1 = Sewage-Manhole (model card).
#          Only class 0 is mapped into the hazard system
#          (label 'pothole'); class 1 is EXPLICITLY
#          DISCARDED by the scanner (M3 COMMIT23 ruling:
#          most manholes are closed and walkable, the
#          model cannot tell open from closed).
# Input  : [1, 3, 320, 320] (320x320), output [1, 6, 2100]
#          (4 box + 2 classes) -- read from the TFLite
#          flatbuffer itself, 2026-11-11.
#
# The weights are NOT committed to this repository, and --
# unlike the main model -- NO build depends on this script
# having run (M3 COMMIT23 zero-burden rule): pubspec
# declares only the directory, so a clean checkout builds
# fine without the weight; the default demo package ships
# without it. Run this script only for a build that should
# actually carry the detector's weight.
# The script is idempotent: a present, verified file is kept.
set -euo pipefail
cd "$(dirname "$0")/.."

URL="https://huggingface.co/tahaUgan/pothole-yolo11n/resolve/main/pothole2v.tflite"
TARGET="assets/models/pothole/pothole2v.tflite"
EXPECTED_SHA256="4fe02a0894985cdafda11e6aa13c354af4323172fae9f18384143d40b7339afb"
EXPECTED_SIZE="10552936"

verify() {
  local f="$1"
  [ -f "$f" ] || return 1
  [ "$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")" = "$EXPECTED_SIZE" ] || return 1
  echo "$EXPECTED_SHA256  $f" | sha256sum -c --status 2>/dev/null \
    || [ "$(shasum -a 256 "$f" | awk '{print $1}')" = "$EXPECTED_SHA256" ]
}

if verify "$TARGET"; then
  echo "Pothole model already present and verified: $TARGET"
  exit 0
fi

mkdir -p assets/models/pothole
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
echo "Downloading $URL"
curl -fL --retry 3 -o "$TMP" "$URL"
if ! verify "$TMP"; then
  echo "ERROR: downloaded model failed SHA256/size verification; refusing to install it." >&2
  exit 1
fi
mv "$TMP" "$TARGET"
trap - EXIT
echo "Pothole model installed and verified: $TARGET ($EXPECTED_SIZE bytes, sha256 $EXPECTED_SHA256)"
