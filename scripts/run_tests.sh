#!/bin/sh
# Mingtu AI v0.1 test runner.
# Tries `flutter test` first (needs a Flutter SDK).
# Falls back to a standalone Dart harness for the pure-Dart core tests
# (needs a Dart SDK and the `test` package; see the harness note below).
# If neither is available, this script FAILS loudly - it never claims
# tests passed when they did not run.
set -e
cd "$(dirname "$0")/.."

if command -v flutter >/dev/null 2>&1; then
  echo "Running: flutter test"
  flutter test
  exit 0
fi

if command -v dart >/dev/null 2>&1; then
  echo "Flutter not found; trying standalone Dart harness for core tests."
  echo "Harness: copy lib/ and test/ into a temp package with package:test,"
  echo "create a pubspec with name mingtu_ai and dependency test, then dart test."
  HARNESS_DIR="$(mktemp -d)/mingtu-test-harness"
  mkdir -p "$HARNESS_DIR"
  cp -r lib test "$HARNESS_DIR/"
  cat > "$HARNESS_DIR/pubspec.yaml" <<'EOF'
name: mingtu_ai
environment:
  sdk: ">=3.0.0 <4.0.0"
dev_dependencies:
  test: ^1.24.0
EOF
  cd "$HARNESS_DIR"
  dart pub get
  dart test
  exit 0
fi

echo "ERROR: neither flutter nor dart was found."
echo "Install the Flutter SDK, then run: flutter test"
echo "Tests were NOT run. Do not report them as passed."
exit 1
