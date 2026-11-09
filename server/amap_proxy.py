#!/usr/bin/env python3
"""Minimal Amap walking-route proxy for Mingtu AI.

Why this exists: the Amap Web Service key must never ship in the
app (a public APK can be unpacked and the key extracted). The key
lives ONLY in this server's environment variable AMAP_WEB_KEY.
The app calls this proxy without any credential; the proxy adds
the key and forwards to Amap's /v3/direction/walking.

Contract:
    GET /walking?origin=lon,lat&destination=lon,lat
    -> the Amap response body, verbatim, content-type JSON.
    Invalid/missing coordinates -> 400 {"error": "..."} (no upstream call).
    Any other path -> 404.

Environment:
    AMAP_WEB_KEY       (required) Amap Web Service key. Read from
                       the environment only; never logged, never
                       echoed, never returned to clients.
    PORT               (optional, default 8080) listen port.
    AMAP_UPSTREAM_BASE (optional, default
                       https://restapi.amap.com/v3/direction/walking)
                       upstream endpoint; overridable ONLY so the
                       contract tests can point at a local stub --
                       production must leave it unset.

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
import sys
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM_DEFAULT = "https://restapi.amap.com/v3/direction/walking"


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


def fetch_upstream(url, timeout=10):
    """GET the upstream and return (status, body-bytes). Isolated
    so tests can substitute a fake without any network."""
    req = urllib.request.Request(url, headers={"User-Agent": "mingtu-amap-proxy/1"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 (fixed https host by config)
        return resp.status, resp.read()


class WalkingHandler(BaseHTTPRequestHandler):
    # Injected by make_server: api_key, upstream_base, fetcher.
    api_key = None
    upstream_base = UPSTREAM_DEFAULT
    fetcher = staticmethod(fetch_upstream)

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
        self._send_json(200, body)


def make_server(port, api_key, upstream_base=UPSTREAM_DEFAULT, fetcher=None):
    handler = type(
        "BoundWalkingHandler",
        (WalkingHandler,),
        {
            "api_key": api_key,
            "upstream_base": upstream_base,
            "fetcher": staticmethod(fetcher or fetch_upstream),
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
    server = make_server(port, key, upstream)
    sys.stderr.write("amap proxy listening on port %d\n" % port)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
