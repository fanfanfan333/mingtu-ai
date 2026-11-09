# Mingtu route proxy (server side)

Minimal proxy that holds the provider keys so the app never does.
The app calls `GET /walking?origin=lon,lat&destination=lon,lat`
on this proxy; the proxy adds the Amap key server-side, forwards
to Amap's `/v3/direction/walking`, and returns a response REBUILT
from a structural whitelist (see Threat model) -- the upstream
body is never returned.

It also serves the low-frequency cloud-vision assist:
`POST /vision` with an OpenAI-compatible chat body. The model is
pinned server-side to `qwen3.7-flash` (exact lowercase id),
`max_tokens` is clamped to 256, `enable_thinking` is forced
off, and the instruction text is replaced server-side with a
pinned JSON-only prompt; the proxy forwards to the Beijing
DashScope compatible endpoint with the server-side DashScope
key as Bearer token. The response is rebuilt as structured enum
JSON (`scene`, `obstacles[]` with enum type/direction/proximity
plus a clamped confidence, and a `parsed` flag) -- upstream
prose never reaches the app, which generates its spoken Chinese
from those enums with its own templates.

## Threat model

Assets: the Amap and DashScope keys in this process's
environment. Adversary: a buggy or hostile upstream (or a
response tampered with inside the provider's own systems) that
echoes the key or injects text toward a blind user's ears.
Assumed bypass techniques: verbatim echo, case changes,
full-width lookalikes, zero-width characters, splitting the
secret across several fields, and hiding it inside
coordinate-shaped or numeric values.

Controls (structural, not textual): substring "cleaning" is
explicitly NOT a control here -- it cannot survive the encoding
tricks above. Instead, NO upstream free text crosses this proxy:

- `/walking`: `status` is a fixed two-value enum, failure `info`
  is a fixed string, distances/durations are parsed and
  re-emitted as bounded integers (0..100000 m, 0..86400 s),
  step prompts travel as enum fields (`action`, `orientation`)
  from which the app generates its own Chinese, and the
  polyline is rebuilt from strictly validated coordinate pairs
  (plain decimal, <= 6 decimals, in range, <= 500 points).
- `/vision`: the model's answer is parsed as JSON and rebuilt
  from enum fields only; non-conforming content yields
  `parsed: false` and the app announces uncertainty.

NFKC normalisation, zero-width removal and (case-insensitive)
secret stripping are kept as belt-and-braces on the one input
that is parsed rather than rebuilt (the polyline string) and
inside enum matching -- never as the control itself.

Accepted residual risk: a purely numeric, low-entropy "key"
that coincides with a legitimate bounded-integer value (for
example a distance of exactly 186) is indistinguishable from
real data in that field, and no structural rule can separate
them. This is accepted because real provider keys are
high-entropy tokens (not small integers), the upstream is the
key's own provider, and numeric fields carry no other content.
Operators must still use the providers' real keys -- never a
short numeric string -- as the server secret.

A malicious upstream could also encode information across
several individually legitimate numeric or coordinate fields
(a covert channel spread over many values). No per-field
structural rule can close that either. This is likewise
accepted, on an explicit trust basis: the upstream here IS
Amap -- the issuer of the key itself -- so an upstream turned
malicious would already hold the secret, and exfiltrating it
to its own customer-facing responses would gain it nothing.
The posture is "trust the upstream, accepted"; the proxy code
is intentionally unchanged for this risk.

## Deploy (manual, not automated by this repo)

Required environment on the server:

- `AMAP_WEB_KEY` — the Amap Web Service key. Inject it via your
  process manager / secret store (e.g. a systemd `EnvironmentFile`
  with mode 600, or container secrets). Never commit it, never put
  it in the app build, never log it.

Optional:

- `MINGTU_DASHSCOPE_API_KEY` — DashScope key for `/vision`,
  same handling. (Renamed 2026-11-09 for the Function Compute
  deployment; see DEPLOY_FC.md.) Without it `/vision` answers
  503 and the app degrades
  to local detection; `/walking` is unaffected.
- `PORT` — listen port (default 8080).
- `AMAP_UPSTREAM_BASE` / `DASHSCOPE_UPSTREAM_BASE` — upstream
  overrides for tests only; leave unset in production.

Also recommended: bind the key to this server's egress IP in the
Amap console (IP whitelist), and put the proxy behind HTTPS.

Run: `python3 amap_proxy.py` (stdlib only, Python 3.10+).

Tests (localhost fixtures only, no real API calls):
`python3 -m unittest discover -s . -p 'test_*.py'`

App side: build/run the app with
`--dart-define=MINGTU_ROUTE_PROXY_URL=https://your-proxy-host`
(a URL is not a secret). Without it the app honestly announces
that the route service is not deployed and does not navigate.


## Cloud vision on Function Compute (2026-11-09)

`/vision` is deployed to Alibaba Cloud Function Compute as an
HTTP-trigger function. The deployable package is the
self-contained `fc/` directory (`fc/index.py` re-exports
`handler` from `fc/amap_proxy.py`; Python standard library
only; configure the function handler as `index.handler`).
Package it with `fc/build_zip.sh` -> `mingtu-fc.zip`. The
standalone server in this directory loads the same
implementation through the `amap_proxy.py` shim. The FC handler adds the anti-abuse guard
chain in front of the same structured pipeline: the demo token
(`MINGTU_VISION_TOKEN`, header `X-Mingtu-Vision-Token`,
constant-time compare, fail closed when unset on the server),
per-minute / per-day caps (`MINGTU_VISION_PER_MINUTE`,
`MINGTU_VISION_PER_DAY`; in-memory per instance — an abuse
brake, not an exact quota), the body-size cap and the output
cap. Rejections are structured JSON (`unauthorized` /
`rate_limited` / `vision_not_configured`) and the app announces
"识图暂时不可用". Step-by-step deployment: see `DEPLOY_FC.md`.
The standalone server in this directory applies the same
guards to `/vision`; `/walking` is unchanged.
