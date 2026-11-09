#!/usr/bin/env python3
"""Minimal Amap walking-route proxy for Mingtu AI.

Why this exists: the Amap Web Service key must never ship in the
app (a public APK can be unpacked and the key extracted). The key
lives ONLY in this server's environment variable AMAP_WEB_KEY.
The app calls this proxy without any credential; the proxy adds
the key and forwards to Amap's /v3/direction/walking.

Contract:
    GET /walking?origin=lon,lat&destination=lon,lat
    -> a response REBUILT from whitelisted fields only (status,
    sanitised info, first path's distance/duration/steps). The
    upstream body is never passed through: if it echoes the key
    anywhere, the echo cannot reach the client.
    Invalid/missing coordinates -> 400 {"error": "..."} (no upstream call).
    Any other path -> 404.

    POST /vision   (low-frequency cloud vision assist)
    Body: an OpenAI-compatible chat JSON whose "model" MUST be
    exactly "qwen3.7-flash" (lowercase; the server pins it --
    anything else, including an uppercase variant, -> 400).
    The proxy forwards to the Beijing DashScope compatible
    endpoint with the server-side DashScope key as a Bearer token,
    clamps max_tokens to 256 and forces "enable_thinking": false.
    -> a response REBUILT from whitelisted fields only (first
    choice's message role/content, secret-stripped). Upstream
    errors become a generic 502; upstream text never crosses.
    No DashScope key configured on the server -> 503 (no call).
    Oversize body (> 3 MB) -> 413 (no call).

Environment:
    AMAP_WEB_KEY       (required) Amap Web Service key. Read from
                       the environment only; never logged, never
                       echoed, never returned to clients.
    DASHSCOPE_API_KEY  (optional) DashScope key for /vision, same
                       handling: environment only, never logged,
                       never returned. Without it /vision answers
                       503 and the app degrades to local detection.
    PORT               (optional, default 8080) listen port.
    AMAP_UPSTREAM_BASE (optional, default
                       https://restapi.amap.com/v3/direction/walking)
                       upstream endpoint; overridable ONLY so the
                       contract tests can point at a local stub --
                       production must leave it unset.
    DASHSCOPE_UPSTREAM_BASE (optional, default
                       https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions)
                       same test-only override rule.

Deployment notes: bind the key to this server's egress IP in the
Amap console (IP whitelist), run behind HTTPS (e.g. a reverse
proxy), and deploy on the server with a process manager that
injects the environment (systemd EnvironmentFile, container
secrets, etc.). No account form or console step is automated here.

Logging: only method + path (NO query string) is written to the
access log, so neither coordinates nor any key can leak into logs
through this process.
"""

import json
import os
import re
import socket
import sys
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM_DEFAULT = "https://restapi.amap.com/v3/direction/walking"

VISION_MODEL = "qwen3.7-flash"  # exact lowercase id; uppercase 404s upstream
VISION_MAX_TOKENS = 256
VISION_MAX_BODY_BYTES = 3 * 1024 * 1024
VISION_UPSTREAM_TIMEOUT_S = 20  # explicit upstream timeout for /vision
VISION_UPSTREAM_DEFAULT = (
    "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
)


def _valid_lonlat(value):
    """True for 'lon,lat' with in-range numeric parts."""
    if not value:
        return False
    parts = value.split(",")
    if len(parts) != 2:
        return False
    try:
        lon = float(parts[0])
        lat = float(parts[1])
    except ValueError:
        return False
    return -180.0 <= lon <= 180.0 and -90.0 <= lat <= 90.0


def build_upstream_url(base, origin, destination, key):
    """Compose the Amap upstream URL. The key appears ONLY here,
    in a server-side outbound request -- never in client responses
    or logs."""
    query = urllib.parse.urlencode(
        {
            "origin": origin,
            "destination": destination,
            "key": key,
            "output": "json",
        }
    )
    return base + "?" + query


def _strip_secrets(value, secrets):
    """Remove any secret substring from a string value,
    CASE-INSENSITIVELY: an upstream echoing the key in a different
    letter case (fixture-key vs FIXTURE-KEY) is still an echo.
    Applied to every free-text field that survives the whitelist,
    as defence in depth."""
    if not isinstance(value, str):
        return value
    for secret in secrets:
        if secret:
            value = re.sub(re.escape(secret), "", value, flags=re.IGNORECASE)
    return value


def _contains_secret(value, secrets):
    lowered = value.lower()
    return any(secret and secret.lower() in lowered for secret in secrets)


def _coerce_text(value, secrets, max_len):
    """Force a value to a bounded string: non-strings become "",
    secrets are stripped, length is capped."""
    if not isinstance(value, str):
        return ""
    return _strip_secrets(value, secrets)[:max_len]


def _coerce_number(value, max_value):
    """Force a value to a bounded number: numeric strings parse,
    anything else (including strings with trailing junk) becomes
    0, negatives clamp to 0, huge values clamp to max_value.
    Integral results are returned as int."""
    if isinstance(value, bool):
        return 0
    if isinstance(value, (int, float)):
        number = float(value)
    elif isinstance(value, str):
        try:
            number = float(value.strip())
        except ValueError:
            return 0
    else:
        return 0
    if number != number or number in (float("inf"), float("-inf")):
        return 0
    number = min(max(number, 0.0), float(max_value))
    return int(number) if number == int(number) else number


_COORD_PART = re.compile(r"-?\d{1,3}(\.\d{1,6})?$")


def _coerce_polyline(value, secrets):
    """Force a polyline to a rebuilt "lon,lat;lon,lat" string.

    A polyline can itself BE a key echo when the key is synthetic
    and coordinate-shaped (e.g. the key literally looks like
    "116.400000,39.900000"): parsing alone would faithfully
    re-emit it. Defence, in order:
    1. Strip secret substrings (case-insensitive) from the RAW
       string first -- a coordinate-shaped key is removed before
       it can parse as a point.
    2. Parse strictly: each part must be plain decimal notation
       with at most 6 decimal places ("1e2", "nan", 7+ decimals
       are dropped), lon in -180..180, lat in -90..90, at most
       500 points. Illegal pairs are dropped pair by pair.
    3. Rebuild at fixed 6-decimal precision from the parsed
       numbers -- the upstream text itself never crosses.
    4. Post-check: if the rebuilt string still contains a secret
       substring, drop the offending pairs (paranoia for a key
       re-formed by formatting); if it persists, return "".
    """
    if not isinstance(value, str):
        return ""
    cleaned = _strip_secrets(value, secrets)
    pairs = []
    for raw_pair in cleaned.split(";"):
        parts = raw_pair.split(",")
        if len(parts) != 2:
            continue
        if not (_COORD_PART.match(parts[0]) and _COORD_PART.match(parts[1])):
            continue
        lon = float(parts[0])
        lat = float(parts[1])
        if -180.0 <= lon <= 180.0 and -90.0 <= lat <= 90.0:
            pairs.append("%.6f,%.6f" % (lon, lat))
        if len(pairs) >= 500:
            break
    if pairs and _contains_secret(";".join(pairs), secrets):
        pairs = [p for p in pairs if not _contains_secret(p, secrets)]
    out = ";".join(pairs)
    if _contains_secret(out, secrets):
        return ""
    return out


# Amap walking-step ENUM fields. The spoken navigation prompt is
# generated by the CLIENT from these enums + the numeric distance
# (see adapters/amap_client.dart AmapStepSpeaker); the upstream
# free-text "instruction"/"road" fields are NOT forwarded at all,
# so no upstream sentence can reach a blind user's ears verbatim.
_WALK_ACTIONS = frozenset(
    [
        "左转",
        "右转",
        "向左前方",
        "向右前方",
        "向左后方",
        "向右后方",
        "直行",
        "靠左",
        "靠右",
        "通过路口",
        "调头",
        "到达",
    ]
)
_WALK_ORIENTATIONS = frozenset(
    ["东", "南", "西", "北", "东北", "东南", "西北", "西南"]
)


def _coerce_enum(value, allowed):
    """Force a value to a fixed enum member; anything else
    (non-string, unknown text, an echoed key) becomes ""."""
    if isinstance(value, str) and value in allowed:
        return value
    return ""


def whitelist_walking_body(raw_body, secrets):
    """Rebuild the /walking response from whitelisted fields, with
    every field FORCED to a fixed enum / type / bound (values are
    coerced, never merely copied):

    - status: the fixed enum "1" or "0" (anything not exactly the
      success marker becomes "0"). A key echoed in status dies here.
    - info on failure: the FIXED string "UPSTREAM_ERROR". Upstream
      error text never crosses at all.
    - distance/duration: coerced numbers (0..10^7 m / 0..10^6 s).
    - step action/orientation: fixed ENUMS (see _WALK_ACTIONS /
      _WALK_ORIENTATIONS); the client generates the spoken Chinese
      prompt from them. Upstream free text (instruction, road)
      is dropped entirely.
    - step polyline: rebuilt from validated coordinate pairs only
      (see _coerce_polyline for the coordinate-shaped-key defence).
    Returns bytes, or None for an unexpected top-level shape
    (-> generic 502).
    """
    try:
        payload = json.loads(raw_body.decode("utf-8"))
    except Exception:
        return None
    if not isinstance(payload, dict):
        return None
    status = "1" if str(payload.get("status")) == "1" else "0"
    if status != "1":
        return json.dumps(
            {"status": "0", "info": "UPSTREAM_ERROR"}
        ).encode("utf-8")
    route = payload.get("route")
    paths = route.get("paths") if isinstance(route, dict) else None
    if not isinstance(paths, list) or not paths or not isinstance(paths[0], dict):
        return None
    first = paths[0]
    steps = []
    raw_steps = first.get("steps")
    if isinstance(raw_steps, list):
        for step in raw_steps[:200]:
            if not isinstance(step, dict):
                continue
            steps.append(
                {
                    "action": _coerce_enum(step.get("action"), _WALK_ACTIONS),
                    "orientation": _coerce_enum(
                        step.get("orientation"), _WALK_ORIENTATIONS
                    ),
                    "polyline": _coerce_polyline(step.get("polyline"), secrets),
                    "distance": _coerce_number(step.get("distance"), 10_000_000),
                    "duration": _coerce_number(step.get("duration"), 1_000_000),
                }
            )
    out = {
        "status": "1",
        "route": {
            "paths": [
                {
                    "distance": _coerce_number(first.get("distance"), 10_000_000),
                    "duration": _coerce_number(first.get("duration"), 1_000_000),
                    "steps": steps,
                }
            ]
        },
    }
    return json.dumps(out).encode("utf-8")


def whitelist_vision_body(raw_body, secrets):
    """Rebuild the /vision response: first choice only, role FORCED
    to the fixed enum "assistant" (an echoed key in role dies
    here), content coerced to a secret-stripped string capped at
    2000 chars. Upstream error objects / unexpected shapes ->
    None (generic 502; upstream text never crosses)."""
    try:
        payload = json.loads(raw_body.decode("utf-8"))
    except Exception:
        return None
    if not isinstance(payload, dict) or payload.get("error") is not None:
        return None
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices:
        return None
    first = choices[0]
    if not isinstance(first, dict):
        return None
    message = first.get("message")
    if not isinstance(message, dict):
        return None
    content = message.get("content")
    if not isinstance(content, str):
        return None
    out = {
        "choices": [
            {
                "message": {
                    "role": "assistant",
                    "content": _coerce_text(content, secrets, 2000),
                }
            }
        ]
    }
    return json.dumps(out).encode("utf-8")


def fetch_upstream(url, timeout=10):
    """GET the upstream and return (status, body-bytes). Isolated
    so tests can substitute a fake without any network."""
    req = urllib.request.Request(url, headers={"User-Agent": "mingtu-amap-proxy/1"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 (fixed https host by config)
        return resp.status, resp.read()


def post_upstream(url, body_bytes, api_key, timeout=VISION_UPSTREAM_TIMEOUT_S):
    """POST JSON to the DashScope compatible endpoint with the
    server-side key as a Bearer token. Isolated for tests. The key
    travels ONLY in this outbound Authorization header."""
    req = urllib.request.Request(
        url,
        data=body_bytes,
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer " + api_key,
            "User-Agent": "mingtu-amap-proxy/1",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
        return resp.status, resp.read()


class WalkingHandler(BaseHTTPRequestHandler):
    # Injected by make_server: api_key, upstream_base, fetcher,
    # dashscope_key, vision_upstream, poster.
    api_key = None
    upstream_base = UPSTREAM_DEFAULT
    fetcher = staticmethod(fetch_upstream)
    dashscope_key = ""
    vision_upstream = VISION_UPSTREAM_DEFAULT
    poster = staticmethod(post_upstream)

    def log_message(self, fmt, *args):  # noqa: A003 - stdlib name
        # Deliberately path-only: BaseHTTPRequestHandler's default
        # log includes the full request line (with query string).
        sys.stderr.write("proxy: %s %s\n" % (self.command, self.path.split("?")[0]))

    def _send_json(self, status, body_bytes):
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body_bytes)))
        self.end_headers()
        self.wfile.write(body_bytes)

    def do_GET(self):  # noqa: N802 - stdlib name
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/walking":
            self._send_json(404, json.dumps({"error": "not found"}).encode())
            return
        params = urllib.parse.parse_qs(parsed.query)
        origin = (params.get("origin") or [""])[0]
        destination = (params.get("destination") or [""])[0]
        if not _valid_lonlat(origin) or not _valid_lonlat(destination):
            self._send_json(
                400,
                json.dumps(
                    {"error": "origin and destination must be 'lon,lat'"}
                ).encode(),
            )
            return
        url = build_upstream_url(
            self.upstream_base, origin, destination, self.api_key
        )
        try:
            _status, body = self.fetcher(url)
        except Exception:  # upstream failure: no detail (may embed URL)
            self._send_json(502, json.dumps({"error": "upstream failure"}).encode())
            return
        # NEVER pass the upstream body through: rebuild from the
        # whitelist so an echoed key (or any extra field) cannot
        # reach the client.
        cleaned = whitelist_walking_body(
            body, [self.api_key, self.dashscope_key]
        )
        if cleaned is None:
            self._send_json(502, json.dumps({"error": "upstream failure"}).encode())
            return
        self._send_json(200, cleaned)

    def do_POST(self):  # noqa: N802 - stdlib name
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/vision":
            self._send_json(404, json.dumps({"error": "not found"}).encode())
            return
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            self._send_json(400, json.dumps({"error": "empty body"}).encode())
            return
        if length > VISION_MAX_BODY_BYTES:
            # Drain and discard before answering, so the client is
            # not cut off mid-send; the payload is never used.
            remaining = length
            while remaining > 0:
                chunk = self.rfile.read(min(65536, remaining))
                if not chunk:
                    break
                remaining -= len(chunk)
            self._send_json(413, json.dumps({"error": "body too large"}).encode())
            return
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except Exception:
            self._send_json(400, json.dumps({"error": "invalid json"}).encode())
            return
        if not isinstance(payload, dict) or payload.get("model") != VISION_MODEL:
            # The model is pinned server-side: the exact lowercase
            # id or nothing. An uppercase variant would 404
            # upstream; other models are out of scope and budget.
            self._send_json(400, json.dumps({"error": "model not allowed"}).encode())
            return
        if not isinstance(payload.get("messages"), list):
            self._send_json(400, json.dumps({"error": "messages required"}).encode())
            return
        if not self.dashscope_key:
            self._send_json(
                503, json.dumps({"error": "vision not configured"}).encode()
            )
            return
        # Clamp the output budget and disable thinking server-side
        # too -- a client asking for more does not get more.
        requested = payload.get("max_tokens")
        if not isinstance(requested, int) or requested <= 0:
            requested = VISION_MAX_TOKENS
        payload["max_tokens"] = min(requested, VISION_MAX_TOKENS)
        payload["enable_thinking"] = False
        body = json.dumps(payload).encode("utf-8")
        try:
            _status, resp_body = self.poster(
                self.vision_upstream, body, self.dashscope_key
            )
        except (TimeoutError, socket.timeout):
            # Explicit-timeout path: fixed body, no upstream detail.
            self._send_json(504, json.dumps({"error": "upstream timeout"}).encode())
            return
        except Exception:  # no detail: errors may embed headers
            self._send_json(502, json.dumps({"error": "upstream failure"}).encode())
            return
        # Whitelist rebuild, same rule as /walking: the upstream
        # body itself never crosses to the client.
        cleaned = whitelist_vision_body(
            resp_body, [self.api_key, self.dashscope_key]
        )
        if cleaned is None:
            self._send_json(502, json.dumps({"error": "upstream failure"}).encode())
            return
        self._send_json(200, cleaned)


def make_server(
    port,
    api_key,
    upstream_base=UPSTREAM_DEFAULT,
    fetcher=None,
    dashscope_key="",
    vision_upstream=VISION_UPSTREAM_DEFAULT,
    poster=None,
):
    handler = type(
        "BoundWalkingHandler",
        (WalkingHandler,),
        {
            "api_key": api_key,
            "upstream_base": upstream_base,
            "fetcher": staticmethod(fetcher or fetch_upstream),
            "dashscope_key": dashscope_key,
            "vision_upstream": vision_upstream,
            "poster": staticmethod(poster or post_upstream),
        },
    )
    return ThreadingHTTPServer(("127.0.0.1", port), handler)


def main():
    key = os.environ.get("AMAP_WEB_KEY", "")
    if not key:
        # Fail fast, without printing anything secret (there is none).
        sys.stderr.write("error: AMAP_WEB_KEY environment variable is required\n")
        return 1
    port = int(os.environ.get("PORT", "8080"))
    upstream = os.environ.get("AMAP_UPSTREAM_BASE", UPSTREAM_DEFAULT)
    # Optional: without it the /vision endpoint answers 503 and
    # the app degrades to local detection; /walking is unaffected.
    dashscope_key = os.environ.get("DASHSCOPE_API_KEY", "")
    vision_upstream = os.environ.get(
        "DASHSCOPE_UPSTREAM_BASE", VISION_UPSTREAM_DEFAULT
    )
    server = make_server(
        port,
        key,
        upstream,
        dashscope_key=dashscope_key,
        vision_upstream=vision_upstream,
    )
    sys.stderr.write("amap proxy listening on port %d\n" % port)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
