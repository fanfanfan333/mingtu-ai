# Mingtu route proxy (server side)

Minimal proxy that holds the Amap Web Service key so the app never
does. The app calls `GET /walking?origin=lon,lat&destination=lon,lat`
on this proxy; the proxy adds the key server-side and forwards to
Amap's `/v3/direction/walking`, returning the body verbatim.

## Deploy (manual, not automated by this repo)

Required environment on the server:

- `AMAP_WEB_KEY` — the Amap Web Service key. Inject it via your
  process manager / secret store (e.g. a systemd `EnvironmentFile`
  with mode 600, or container secrets). Never commit it, never put
  it in the app build, never log it.

Optional:

- `PORT` — listen port (default 8080).
- `AMAP_UPSTREAM_BASE` — upstream override for tests only; leave
  unset in production.

Also recommended: bind the key to this server's egress IP in the
Amap console (IP whitelist), and put the proxy behind HTTPS.

Run: `python3 amap_proxy.py` (stdlib only, Python 3.10+).

Tests (localhost fixtures only, no real API calls):
`python3 -m unittest test_amap_proxy -v`

App side: build/run the app with
`--dart-define=MINGTU_ROUTE_PROXY_URL=https://your-proxy-host`
(a URL is not a secret). Without it the app honestly announces
that the route service is not deployed and does not navigate.
