#!/usr/bin/env bash
# Build mingtu-fc.zip from this directory (the FC package).
#
# The package is intentionally self-contained and uses ONLY
# the Python standard library -- there are no third-party
# dependencies to install (no requirements.txt needed).
#
# Usage: ./build_zip.sh [output-path]
# Default output: ./mingtu-fc.zip (in this directory).
# The archive contains only the package's .py files at the
# zip root (index.py is the FC entry: handler = index.handler).
# It never contains .env files, keys, tests or __pycache__.
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-$PWD/mingtu-fc.zip}"
python3 - "$OUT" << 'PYEOF'
import os
import sys
import zipfile

out = sys.argv[1]
here = os.path.dirname(os.path.abspath(__file__))
if os.path.exists(out):
    os.remove(out)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
    for name in sorted(os.listdir(here)):
        if not name.endswith(".py"):
            continue
        if name.startswith("test_"):
            continue
        zf.write(os.path.join(here, name), arcname=name)
print("wrote", out)
PYEOF
