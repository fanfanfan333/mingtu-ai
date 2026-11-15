#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
manifest=""; apk=""
for path in "$@"; do
  case "$path" in *.apk) apk="$path" ;; *) manifest="$path" ;; esac
done
if [[ $# -eq 0 ]]; then
  base=build/app/intermediates/merged_manifest/release
  preferred="$base/processReleaseMainManifest/AndroidManifest.xml"
  if [[ -f "$preferred" ]]; then
    manifest="$preferred"
  else
    manifest=$(find "$base" -path '*processReleaseMainManifest*/AndroidManifest.xml' -type f -print -quit 2>/dev/null || true)
    if [[ -z "$manifest" ]]; then
      manifest=$(find "$base" -name AndroidManifest.xml -type f -print -quit 2>/dev/null || true)
    fi
  fi
  if [[ -f build/app/outputs/flutter-apk/app-release.apk ]]; then apk=build/app/outputs/flutter-apk/app-release.apk; fi
fi
if [[ -z "$manifest" && -z "$apk" ]]; then echo 'No release manifest or APK found.' >&2; exit 1; fi
if [[ -n "$manifest" ]]; then
  python3 - "$manifest" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
a = '{http://schemas.android.com/apk/res/android}'
forbidden = {'android.permission.FOREGROUND_SERVICE', 'android.permission.FOREGROUND_SERVICE_LOCATION', 'android.permission.FOREGROUND_SERVICE_DATA_SYNC', 'android.permission.ACCESS_BACKGROUND_LOCATION'}
bad = False
for entry in root:
    if entry.tag in ('uses-permission', 'uses-permission-sdk-23') and entry.get(a+'name') in forbidden:
        print('Forbidden permission:', entry.get(a+'name'), file=sys.stderr)
        bad = True
print('Remaining services (name, enabled, exported, foregroundServiceType):')
geo = 'com.baseflow.geolocator.GeolocatorLocationService'
found = False
for service in root.findall('./application/service'):
    name = service.get(a+'name', '(unspecified)')
    kind = service.get(a+'foregroundServiceType', '')
    print(' | '.join(service.get(a+x, '(unspecified)') for x in ('name', 'enabled', 'exported', 'foregroundServiceType')))
    if name == geo:
        found = True
        if kind != 'location': bad = True
    elif kind: bad = True
if not found: bad = True
if bad:
    print('Invalid permissions or foreground service configuration.', file=sys.stderr)
    sys.exit(1)
PY
fi
if [[ -n "$apk" ]]; then
  sdk=/workspace/tools/android-sdk/build-tools
  aapt=$(find "$sdk" -type f -name aapt | sort -V | tail -n 1)
  [[ -n "$aapt" ]] || { echo 'aapt unavailable' >&2; exit 1; }
  permissions=$("$aapt" dump permissions "$apk")
  if printf '%s\n' "$permissions" | grep -E "uses-permission[^:]*:.*android.permission.(FOREGROUND_SERVICE(_LOCATION|_DATA_SYNC)?|ACCESS_BACKGROUND_LOCATION)(['\" ]|$)"; then
    echo 'Forbidden APK permission found.' >&2; exit 1
  fi
  echo 'APK services (name, enabled, exported, foregroundServiceType):'
  "$aapt" dump xmltree "$apk" AndroidManifest.xml | python3 -c '
import re, sys
lines = sys.stdin.read().splitlines()
services = []
current = None
for line in lines:
    element = re.match(r"(\s*)E: ([^ ]+)", line)
    if element:
        indent, tag = len(element.group(1)), element.group(2)
        if current is not None and indent <= current[0]: current = None
        if tag == "service":
            current = (indent, {})
            services.append(current[1])
        continue
    if current is None: continue
    attr = re.match(r"(\s*)A: android:(name|enabled|exported|foregroundServiceType)(?:\([^)]*\))?=(.*)", line)
    if not attr or len(attr.group(1)) != current[0] + 2: continue
    key, value = attr.group(2), attr.group(3).strip()
    raw = re.search(r"\(Raw: \"([^\"]*)\"\)", value)
    quoted = re.match(r"\"([^\"]*)\"", value)
    if raw: value = raw.group(1)
    elif quoted: value = quoted.group(1)
    elif key == "foregroundServiceType" and re.search(r"0x0*8\b", value): value = "location"
    current[1].setdefault(key, value)
geo = "com.baseflow.geolocator.GeolocatorLocationService"
bad = not services
found = False
for service in services:
    print(" | ".join(service.get(k, "(unspecified)") for k in ("name", "enabled", "exported", "foregroundServiceType")))
    name, kind = service.get("name"), service.get("foregroundServiceType", "")
    if not name or name.startswith("(type"): bad = True
    if name == geo:
        found = True
        if kind != "location": bad = True
    elif kind: bad = True
if not found or bad:
    print("Invalid or unparseable APK service configuration.", file=sys.stderr)
    sys.exit(1)
'
fi
