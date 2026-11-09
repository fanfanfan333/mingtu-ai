#!/usr/bin/env bash
# Fetch the bundled YOLO model from the OFFICIAL Ultralytics
# release and verify it before any build.
#
# Source : https://github.com/ultralytics/yolo-flutter-app/releases/download/v0.2.0/yolo11n_int8.tflite
#          (Ultralytics yolo-flutter-app release v0.2.0,
#           YOLO11n object detection, int8-quantized TFLite)
# Target : assets/models/yolo11n.tflite (bundled in the APK;
#           the ultralytics_yolo resolver copies assets/...
#           paths to the documents directory at runtime)
# Size   : 2831727 bytes
# SHA256 : 414ff688f0c47cbe03cadd3118d22b9024f68e097c8c33bbb25f704d1ca0624d
# License: AGPL-3.0 (Ultralytics)
#
# Run this BEFORE `flutter build apk`: the pubspec declares
# the asset, and the build fails while the file is missing.
# The script is idempotent: a present, verified file is kept.
set -euo pipefail
cd "$(dirname "$0")/.."

URL="https://github.com/ultralytics/yolo-flutter-app/releases/download/v0.2.0/yolo11n_int8.tflite"
TARGET="assets/models/yolo11n.tflite"
EXPECTED_SHA256="414ff688f0c47cbe03cadd3118d22b9024f68e097c8c33bbb25f704d1ca0624d"
EXPECTED_SIZE="2831727"

verify() {
  local f="$1"
  [ -f "$f" ] || return 1
  [ "$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")" = "$EXPECTED_SIZE" ] || return 1
  echo "$EXPECTED_SHA256  $f" | sha256sum -c --status 2>/dev/null \
    || [ "$(shasum -a 256 "$f" | awk '{print $1}')" = "$EXPECTED_SHA256" ]
}

if verify "$TARGET"; then
  echo "Model already present and verified: $TARGET"
  exit 0
fi

mkdir -p assets/models
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
echo "Model installed and verified: $TARGET ($EXPECTED_SIZE bytes, sha256 $EXPECTED_SHA256)"
