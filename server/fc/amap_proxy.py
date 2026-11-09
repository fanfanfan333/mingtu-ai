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
    MINGTU_DASHSCOPE_API_KEY  (optional) DashScope key for
                       /vision, same
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

Threat model (see server/README.md for the full version): the
upstream provider is treated as potentially echoing / hostile.
Substring "cleaning" is NOT a security control (it is bypassable
by case, full-width forms, zero-width characters and splitting
the secret across fields), so NO upstream free text crosses this
proxy at all: every response is rebuilt from structured fields --
fixed enums, bounded integers, validated coordinate structures,
and (for /vision) an enum-only JSON scene rebuilt field by
field. Normalisation (NFKC + zero-width removal) and secret
stripping survive only as belt-and-braces on the polyline input,
never as the control itself. Accepted residual risk, documented
in the README: a purely numeric low-entropy "key" that coincides
with a legitimate bounded-integer field value (e.g. a distance)
is indistinguishable from data -- real keys are high-entropy
tokens and the upstream is the key's own provider.
"""

import base64
import json
import os
import re
import hmac
import socket
import threading
import time
import sys
import unicodedata
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


_ZERO_WIDTH = ("\u200b", "\u200c", "\u200d", "\ufeff", "\u2060")


def _normalize_text(value):
    """NFKC-normalise a string and remove zero-width characters.
    Full-width lookalikes fold to their standard forms and
    invisible joiners vanish, so downstream exact-match checks
    (enums, secret substrings) cannot be evaded by encoding
    tricks."""
    value = unicodedata.normalize("NFKC", value)
    for zw in _ZERO_WIDTH:
        value = value.replace(zw, "")
    return value


def _strip_secrets(value, secrets):
    """Remove secret substrings from a string, CASE-INSENSITIVELY,
    after NFKC + zero-width normalisation of both the value and
    the secret. BELT-AND-BRACES ONLY: the actual control is the
    structural whitelist (no free text crosses); this is applied
    to the polyline input, the one place raw upstream text is
    parsed rather than rebuilt."""
    if not isinstance(value, str):
        return value
    value = _normalize_text(value)
    for secret in secrets:
        if secret:
            needle = _normalize_text(secret)
            if needle:
                value = re.sub(
                    re.escape(needle), "", value, flags=re.IGNORECASE
                )
    return value


def _contains_secret(value, secrets):
    lowered = _normalize_text(value).lower()
    return any(
        secret and _normalize_text(secret).lower() in lowered
        for secret in secrets
    )


def _coerce_text(value, secrets, max_len):
    """Force a value to a bounded, normalised string. Retained
    for internal use only -- no upstream free text is forwarded
    to clients any more (see the threat model)."""
    if not isinstance(value, str):
        return ""
    return _strip_secrets(value, secrets)[:max_len]


def _coerce_bounded_int(value, max_value):
    """Force a value to a bounded INTEGER in [0, max_value]:
    numeric strings parse, anything else (junk, NaN, infinities,
    booleans) becomes 0, the result is rounded and clamped, and
    it is re-emitted as an int -- the upstream representation
    (string/float/formatting) never crosses."""
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
    return int(min(max(round(number), 0), max_value))


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
    (non-string, unknown text, an echoed key) becomes "". The
    candidate is NFKC-normalised and zero-width-stripped first,
    so an enum padded with invisible characters still has to be
    exactly the enum to pass."""
    if isinstance(value, str) and _normalize_text(value).strip() in allowed:
        return _normalize_text(value).strip()
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
                    "distance": _coerce_bounded_int(step.get("distance"), 100_000),
                    "duration": _coerce_bounded_int(step.get("duration"), 86_400),
                }
            )
    out = {
        "status": "1",
        "route": {
            "paths": [
                {
                    "distance": _coerce_bounded_int(first.get("distance"), 100_000),
                    "duration": _coerce_bounded_int(first.get("duration"), 86_400),
                    "steps": steps,
                }
            ]
        },
    }
    return json.dumps(out).encode("utf-8")


# The vision model is instructed (client-side AND pinned again
# here, server-side) to answer with JSON ONLY, using exactly
# these enums. The proxy parses that JSON and rebuilds it field
# by field: upstream prose NEVER crosses, so an upstream that
# answers "前方安全，可以通过" (or echoes a key) produces the
# structured "parsed": false response and the client announces
# uncertainty instead of speaking the text.
VISION_PROMPT = (
    "只输出一个 JSON 对象，不要输出任何其他文字："
    '{"scene": 场景, "obstacles": [{"type": 类型, '
    '"direction": 方位, "proximity": 远近, '
    '"confidence": 0到1的小数}]}。'
    "场景只能是：室内、室外、楼梯间、电梯内、路口、不确定。"
    "类型只能是：行人、自行车、电动车、汽车、公交车、柱子、"
    "台阶、楼梯、墙壁、门、桌子、椅子、树木、护栏、指示牌、其他。"
    "方位只能是：正前方、左前方、右前方、左侧、右侧、后方。"
    "远近只能是：很近、较近、较远。"
    "不要做任何安全判断，不要输出 JSON 以外的任何内容。"
)
VISION_SCENES = frozenset(
    ["室内", "室外", "楼梯间", "电梯内", "路口", "不确定"]
)
VISION_TYPES = frozenset(
    [
        "行人", "自行车", "电动车", "汽车", "公交车", "柱子",
        "台阶", "楼梯", "墙壁", "门", "桌子", "椅子", "树木",
        "护栏", "指示牌", "其他",
    ]
)
VISION_DIRECTIONS = frozenset(
    ["正前方", "左前方", "右前方", "左侧", "右侧", "后方"]
)
VISION_PROXIMITIES = frozenset(["很近", "较近", "较远"])
VISION_MIN_CONFIDENCE = 0.5
VISION_MAX_OBSTACLES = 5


def _coerce_confidence(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0.0
    number = float(value)
    if number != number or number in (float("inf"), float("-inf")):
        return 0.0
    return min(max(number, 0.0), 1.0)


def _vision_unparsed():
    return json.dumps(
        {"scene": "不确定", "obstacles": [], "parsed": False}
    ).encode("utf-8")


def whitelist_vision_body(raw_body, secrets):
    """Rebuild the /vision response as STRUCTURED ENUM JSON.

    The upstream chat body is expected to carry a JSON string in
    its first choice's message content. That string is parsed
    and every value is coerced: scene/type/direction/proximity
    through fixed enums, confidence clamped to [0, 1], obstacles
    below 0.5 confidence dropped, at most 5 kept. Free upstream
    text is never copied -- not the prose, not unknown enum
    values, nothing.

    Returns the structured bytes. "parsed" is False when the
    content was not conforming JSON (plain prose, adversarial
    text, wrong shapes, or every claimed obstacle had to be
    dropped for unknown enum values) -- the client announces
    "识别不确定" for it. Returns None only when the upstream
    body is not even the expected chat shape (-> generic 502).
    """
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
    try:
        inner = json.loads(content)
    except Exception:
        return _vision_unparsed()
    if not isinstance(inner, dict):
        return _vision_unparsed()
    scene_raw = inner.get("scene")
    if not isinstance(scene_raw, str):
        return _vision_unparsed()
    scene = _coerce_enum(scene_raw, VISION_SCENES)
    if not scene:
        return _vision_unparsed()
    raw_obstacles = inner.get("obstacles")
    if raw_obstacles is None:
        raw_obstacles = []
    if not isinstance(raw_obstacles, list):
        return _vision_unparsed()
    kept = []
    dropped_unknown = 0
    for item in raw_obstacles:
        if not isinstance(item, dict):
            dropped_unknown += 1
            continue
        otype = _coerce_enum(item.get("type"), VISION_TYPES)
        direction = _coerce_enum(item.get("direction"), VISION_DIRECTIONS)
        proximity = _coerce_enum(item.get("proximity"), VISION_PROXIMITIES)
        if not otype or not direction or not proximity:
            dropped_unknown += 1
            continue
        confidence = _coerce_confidence(item.get("confidence"))
        if confidence < VISION_MIN_CONFIDENCE:
            continue  # low-confidence drop: recognised as unreliable
        kept.append(
            {
                "type": otype,
                "direction": direction,
                "proximity": proximity,
                "confidence": round(confidence, 2),
            }
        )
        if len(kept) >= VISION_MAX_OBSTACLES:
            break
    if raw_obstacles and not kept and dropped_unknown == len(raw_obstacles):
        # The model claimed obstacles but every one was unrecognised
        # content: that is uncertainty, not "no obstacles".
        return _vision_unparsed()
    out = {"scene": scene, "obstacles": kept, "parsed": True}
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


# ------------------------------------------------------------------
# Cloud vision guards (anti-abuse) + shared vision handling.
#
# The vision endpoint is deployed on Alibaba Cloud Function
# Compute (see DEPLOY_FC.md) and, locally, by the standalone
# server below. Both transports share the same guard chain:
#   1. a demo token (header X-Mingtu-Vision-Token) checked with
#      a constant-time compare against MINGTU_VISION_TOKEN --
#      fail closed when the server has no token configured;
#   2. per-minute / per-day call caps (in-memory, per instance:
#      a best-effort brake, not a billing guarantee);
#   3. the request-body size cap (VISION_MAX_BODY_BYTES);
#   4. the server-side output cap (VISION_MAX_TOKENS) and the
#      pinned model/prompt, applied in handle_vision_body.
# Errors are structured JSON codes; no error body, log line or
# exception ever contains the demo token or the DashScope key.
# ------------------------------------------------------------------

VISION_TOKEN_HEADER = "x-mingtu-vision-token"
VISION_PER_MINUTE_DEFAULT = 10
VISION_PER_DAY_DEFAULT = 100


class VisionRateLimiter:
    """Fixed-window per-minute and per-day call caps.

    In-memory and per process instance: on Function Compute
    each instance counts separately, so treat the caps as an
    abuse brake, not an exact quota. The clock is injectable
    for tests.
    """

    def __init__(self, per_minute=VISION_PER_MINUTE_DEFAULT,
                 per_day=VISION_PER_DAY_DEFAULT, clock=None):
        self.per_minute = max(1, int(per_minute))
        self.per_day = max(1, int(per_day))
        self._clock = clock or time.time
        self._lock = threading.Lock()
        self._minute_window = None
        self._minute_count = 0
        self._day_window = None
        self._day_count = 0

    def allow(self):
        now = self._clock()
        minute = int(now // 60)
        day = int(now // 86400)
        with self._lock:
            if self._minute_window != minute:
                self._minute_window = minute
                self._minute_count = 0
            if self._day_window != day:
                self._day_window = day
                self._day_count = 0
            if (self._minute_count >= self.per_minute
                    or self._day_count >= self.per_day):
                return False
            self._minute_count += 1
            self._day_count += 1
            return True


def vision_reject_reason(token, expected_token, limiter):
    """Guard chain steps 1-2. Returns (status, error_code) to
    reject, or None to proceed. A rate slot is consumed only by
    an authorised call."""
    if not expected_token:
        return 503, "vision_not_configured"
    if not token or not hmac.compare_digest(token, expected_token):
        return 401, "unauthorized"
    if limiter is not None and not limiter.allow():
        return 429, "rate_limited"
    return None


def handle_vision_body(raw, *, dashscope_key, vision_upstream,
                       poster, amap_key=""):
    """Parse, pin, clamp, forward and whitelist one /vision
    request body. Returns (status, body_bytes). Pure with
    respect to transport: shared by the standalone HTTP server
    and the Function Compute handler."""
    if not raw:
        return 400, json.dumps({"error": "empty body"}).encode()
    if len(raw) > VISION_MAX_BODY_BYTES:
        return 413, json.dumps({"error": "body too large"}).encode()
    try:
        payload = json.loads(raw.decode("utf-8"))
    except Exception:
        return 400, json.dumps({"error": "invalid json"}).encode()
    if not isinstance(payload, dict) or payload.get("model") != VISION_MODEL:
        return 400, json.dumps({"error": "model not allowed"}).encode()
    if not isinstance(payload.get("messages"), list):
        return 400, json.dumps({"error": "messages required"}).encode()
    if not dashscope_key:
        return 503, json.dumps({"error": "vision not configured"}).encode()
    # Pin the instruction server-side: any text part the client
    # sent is replaced with the JSON-only prompt.
    for message in payload["messages"]:
        if not isinstance(message, dict):
            continue
        content = message.get("content")
        if isinstance(content, list):
            for part in content:
                if isinstance(part, dict) and part.get("type") == "text":
                    part["text"] = VISION_PROMPT
    # Clamp the output budget and disable thinking server-side.
    requested = payload.get("max_tokens")
    if not isinstance(requested, int) or requested <= 0:
        requested = VISION_MAX_TOKENS
    payload["max_tokens"] = min(requested, VISION_MAX_TOKENS)
    payload["enable_thinking"] = False
    body = json.dumps(payload).encode("utf-8")
    try:
        _status, resp_body = poster(vision_upstream, body, dashscope_key)
    except (TimeoutError, socket.timeout):
        return 504, json.dumps({"error": "upstream timeout"}).encode()
    except Exception:  # no detail: errors may embed headers
        return 502, json.dumps({"error": "upstream failure"}).encode()
    cleaned = whitelist_vision_body(resp_body, [amap_key, dashscope_key])
    if cleaned is None:
        return 502, json.dumps({"error": "upstream failure"}).encode()
    return 200, cleaned


# ------------------------------------------------------------------
# Alibaba Cloud Function Compute entry (HTTP trigger, built-in
# Python runtime). FC maps the HTTP request into an `event`
# JSON object (headers / queryParameters / body /
# isBase64Encoded) and expects a dict with statusCode /
# headers / body back -- see DEPLOY_FC.md for the official
# documentation links. The function is vision-only; walking
# keeps the standalone server (or the client's direct demo
# mode). Environment (FC console function configuration):
#   MINGTU_DASHSCOPE_API_KEY  the DashScope key (required)
#   MINGTU_VISION_TOKEN       the demo token clients must send
#   MINGTU_VISION_PER_MINUTE  optional cap (default 10)
#   MINGTU_VISION_PER_DAY     optional cap (default 100)
# ------------------------------------------------------------------

_FC_LIMITER = None


def _env_positive_int(name, default):
    try:
        value = int(os.environ.get(name, "") or default)
    except (TypeError, ValueError):
        return default
    return value if value > 0 else default


def _fc_limiter():
    global _FC_LIMITER
    if _FC_LIMITER is None:
        _FC_LIMITER = VisionRateLimiter(
            _env_positive_int(
                "MINGTU_VISION_PER_MINUTE", VISION_PER_MINUTE_DEFAULT),
            _env_positive_int(
                "MINGTU_VISION_PER_DAY", VISION_PER_DAY_DEFAULT),
        )
    return _FC_LIMITER


def fc_handle_event(event, *, dashscope_key=None, expected_token=None,
                    vision_upstream=None, poster=None, limiter=None):
    """Handle one FC HTTP-trigger event. The keyword overrides
    exist for tests; production reads the FC environment."""
    if dashscope_key is None:
        dashscope_key = os.environ.get("MINGTU_DASHSCOPE_API_KEY", "")
    if expected_token is None:
        expected_token = os.environ.get("MINGTU_VISION_TOKEN", "")
    if vision_upstream is None:
        vision_upstream = os.environ.get(
            "DASHSCOPE_UPSTREAM_BASE", VISION_UPSTREAM_DEFAULT)
    if poster is None:
        poster = post_upstream
    if limiter is None:
        limiter = _fc_limiter()
    if isinstance(event, (bytes, bytearray)):
        event = json.loads(event.decode("utf-8"))
    if isinstance(event, str):
        event = json.loads(event)
    if not isinstance(event, dict):
        return _fc_response(400, {"error": "invalid event"})
    headers = event.get("headers") or {}
    lowered = {str(k).lower(): str(v) for k, v in headers.items()}
    path = event.get("rawPath") or event.get("path") or ""
    raw_body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        try:
            body_bytes = base64.b64decode(raw_body)
        except Exception:
            return _fc_response(400, {"error": "invalid body encoding"})
    else:
        body_bytes = (raw_body.encode("utf-8")
                      if isinstance(raw_body, str) else bytes(raw_body))
    if "vision" not in path:
        return _fc_response(404, {"error": "not found"})
    reject = vision_reject_reason(
        lowered.get(VISION_TOKEN_HEADER), expected_token, limiter)
    if reject is not None:
        status, code = reject
        return _fc_response(status, {"error": code})
    status, body = handle_vision_body(
        body_bytes,
        dashscope_key=dashscope_key,
        vision_upstream=vision_upstream,
        poster=poster,
    )
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json; charset=utf-8"},
        "isBase64Encoded": False,
        "body": body.decode("utf-8"),
    }


def _fc_response(status, payload):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json; charset=utf-8"},
        "isBase64Encoded": False,
        "body": json.dumps(payload),
    }


def handler(event, context):
    """FC HTTP-trigger handler (configure as index.handler)."""
    return fc_handle_event(event)


class WalkingHandler(BaseHTTPRequestHandler):
    # Injected by make_server: api_key, upstream_base, fetcher,
    # dashscope_key, vision_upstream, poster.
    api_key = None
    upstream_base = UPSTREAM_DEFAULT
    fetcher = staticmethod(fetch_upstream)
    dashscope_key = ""
    vision_upstream = VISION_UPSTREAM_DEFAULT
    poster = staticmethod(post_upstream)
    vision_token = ""
    vision_limiter = None

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
        # Guard chain first (token, then rate cap): rejected
        # calls never read or forward a body.
        reject = vision_reject_reason(
            self.headers.get("X-Mingtu-Vision-Token"),
            self.vision_token,
            self.vision_limiter,
        )
        if reject is not None:
            status, code = reject
            self._send_json(status, json.dumps({"error": code}).encode())
            return
        length = int(self.headers.get("Content-Length") or 0)
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
        raw = self.rfile.read(length) if length > 0 else b""
        status, body = handle_vision_body(
            raw,
            dashscope_key=self.dashscope_key,
            vision_upstream=self.vision_upstream,
            poster=self.poster,
            amap_key=self.api_key or "",
        )
        self._send_json(status, body)

def make_server(
    port,
    api_key,
    upstream_base=UPSTREAM_DEFAULT,
    fetcher=None,
    dashscope_key="",
    vision_upstream=VISION_UPSTREAM_DEFAULT,
    poster=None,
    vision_token="",
    vision_limiter=None,
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
            "vision_token": vision_token,
            "vision_limiter": vision_limiter,
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
    dashscope_key = os.environ.get("MINGTU_DASHSCOPE_API_KEY", "")
    vision_upstream = os.environ.get(
        "DASHSCOPE_UPSTREAM_BASE", VISION_UPSTREAM_DEFAULT
    )
    server = make_server(
        port,
        key,
        upstream,
        dashscope_key=dashscope_key,
        vision_upstream=vision_upstream,
        vision_token=os.environ.get("MINGTU_VISION_TOKEN", ""),
        vision_limiter=VisionRateLimiter(
            _env_positive_int(
                "MINGTU_VISION_PER_MINUTE", VISION_PER_MINUTE_DEFAULT),
            _env_positive_int(
                "MINGTU_VISION_PER_DAY", VISION_PER_DAY_DEFAULT),
        ),
    )
    sys.stderr.write("amap proxy listening on port %d\n" % port)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
