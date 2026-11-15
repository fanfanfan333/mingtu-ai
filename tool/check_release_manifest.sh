#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
manifest=""; apk=""
for path in "$@"; do
  case "$path" in *.apk) apk="$path" ;; *) manifest="$path" ;; esac
done
if [[ -z "$manifest" ]]; then
  manifest=$(find build/app/intermediates/merged_manifest/release -name AndroidManifest.xml -type f -print -quit 2>/dev/null || true)
fi
if [[ -z "$apk" && -f build/app/outputs/flutter-apk/app-release.apk ]]; then apk=build/app/outputs/flutter-apk/app-release.apk; fi
if [[ -z "$manifest" && -z "$apk" ]]; then echo 'No release manifest or APK found.' >&2; exit 1; fi
if [[ -n "$manifest" ]]; then
  python3 - "$manifest" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
a = '{http://schemas.android.com/apk/res/android}'
t = '{http://schemas.android.com/tools}'
forbidden = {'android.permission.FOREGROUND_SERVICE', 'android.permission.FOREGROUND_SERVICE_DATA_SYNC', 'android.permission.ACCESS_BACKGROUND_LOCATION'}
for entry in root:
    if entry.tag in ('uses-permission', 'uses-permission-sdk-23') and entry.get(a+'name') in forbidden and entry.get(t+'node') != 'remove':
        print('Forbidden permission:', entry.get(a+'name'), file=sys.stderr)
        sys.exit(1)
print('Remaining services (name, enabled, exported, foregroundServiceType):')
for service in root.findall('./application/service'):
    if service.get(t+'node') != 'remove':
        print(' | '.join(service.get(a+x, '(unspecified)') for x in ('name', 'enabled', 'exported', 'foregroundServiceType')))
PY
fi
if [[ -n "$apk" ]]; then
  sdk=/workspace/tools/android-sdk/build-tools
  aapt=$(find "$sdk" -type f -name aapt2 | sort -V | tail -n 1)
  if [[ -z "$aapt" ]]; then aapt=$(find "$sdk" -type f -name aapt | sort -V | tail -n 1); fi
  [[ -n "$aapt" ]] || { echo 'aapt/aapt2 unavailable' >&2; exit 1; }
  permissions=$($aapt dump permissions "$apk")
  if printf '%s\n' "$permissions" | grep -E "uses-permission[^:]*:.*(android.permission.FOREGROUND_SERVICE(_DATA_SYNC)?|android.permission.ACCESS_BACKGROUND_LOCATION)(['\" ]|$)"; then
    echo 'Forbidden APK permission found.' >&2; exit 1
  fi
  echo 'APK services (name, enabled, exported, foregroundServiceType):'
  if [[ ${aapt##*/} == aapt2 ]]; then
    tree=$("$aapt" dump xmltree "$apk" --file AndroidManifest.xml)
  else
    tree=$("$aapt" dump xmltree "$apk" AndroidManifest.xml)
  fi
  printf '%s\n' "$tree" | python3 -c '
import re, sys
lines = sys.stdin.read().splitlines()
service = None
for line in lines:
    match = re.match(r"(\s*)E: ([^ ]+)", line)
    if match:
        indent, tag = len(match.group(1)), match.group(2)
        if service is not None and indent <= service[0]:
            print(" | ".join(service[1].get(k, "(unspecified)") for k in ("name", "enabled", "exported", "foregroundServiceType")))
            service = None
        if tag == "service": service = (indent, {})
    if service is not None:
        attr = re.search(r"A: android:(name|enabled|exported|foregroundServiceType)(?:\([^)]*\))?=(.*)", line)
        if attr: service[1][attr.group(1)] = attr.group(2).strip()
if service is not None:
    print(" | ".join(service[1].get(k, "(unspecified)") for k in ("name", "enabled", "exported", "foregroundServiceType")))
'
fi
