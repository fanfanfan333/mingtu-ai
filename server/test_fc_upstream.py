"""Upstream pinning tests (Codex FC re-test, 2026-11-09):
the vision Authorization header and the walking keyed URL may
ONLY go to the pinned endpoints; environment overrides are
gone; upstream redirects are never followed.
"""

import json
import os
import threading
import unittest
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

import amap_proxy
from amap_proxy import (
    VISION_UPSTREAM_DEFAULT,
    fc_handle_event,
    handle_vision_body,
    post_upstream,
)

VISION_TOKEN = "fixture-vision-token"
DASHSCOPE_KEY = "fixture-dashscope-key"


def _vision_body():
    return json.dumps({
        "model": "qwen3.7-flash",
        "messages": [{
            "role": "user",
            "content": [
                {"type": "image_url",
                 "image_url": {"url": "data:image/jpeg;base64,AAAA"}},
                {"type": "text", "text": "describe"},
            ],
        }],
    }).encode()


class _CapturingPoster:
    def __init__(self):
        self.calls = []

    def __call__(self, url, body, key):
        self.calls.append((url, body, key))
        content = json.dumps({"scene": "室内", "obstacles": []})
        return 200, json.dumps({
            "choices": [{"message": {"role": "assistant",
                                     "content": content}}]
        }).encode()


class UpstreamPinTest(unittest.TestCase):
    def test_non_whitelisted_vision_upstream_is_refused(self):
        poster = _CapturingPoster()
        status, body = handle_vision_body(
            _vision_body(),
            dashscope_key=DASHSCOPE_KEY,
            vision_upstream="https://evil.example.com/v1/chat",
            poster=poster,
        )
        self.assertEqual(status, 502)
        self.assertIn("upstream not allowed", body.decode())
        self.assertEqual(poster.calls, [])  # key never sent

    def test_env_override_is_ignored_by_fc_handler(self):
        poster = _CapturingPoster()
        event = {
            "requestContext": {"http": {"method": "POST"}},
            "rawPath": "/vision",
            "headers": {"x-mingtu-vision-token": VISION_TOKEN},
            "body": _vision_body().decode(),
            "isBase64Encoded": False,
        }
        with mock.patch.dict(
            os.environ, {"DASHSCOPE_UPSTREAM_BASE": "https://evil.example.com/x"}
        ):
            resp = fc_handle_event(
                event,
                dashscope_key=DASHSCOPE_KEY,
                expected_token=VISION_TOKEN,
                poster=poster,
            )
        self.assertEqual(resp["statusCode"], 200)
        self.assertEqual(len(poster.calls), 1)
        self.assertEqual(poster.calls[0][0], VISION_UPSTREAM_DEFAULT)

    def test_walking_upstream_is_pinned(self):
        calls = []

        def fetcher(url):
            calls.append(url)
            return 200, b"{}"

        server = amap_proxy.make_server(
            0, "fixture-amap-key", "https://evil.example.com/walk",
            fetcher=fetcher,
        )
        port = server.server_address[1]
        t = threading.Thread(target=server.serve_forever)
        t.daemon = True
        t.start()
        try:
            import urllib.request
            url = (f"http://127.0.0.1:{port}/walking"
                   "?origin=120.441723,37.724409"
                   "&destination=120.443212,37.723667")
            try:
                urllib.request.urlopen(url, timeout=5)
                status = 200
            except urllib.error.HTTPError as e:
                status = e.code
        finally:
            server.shutdown()
            server.server_close()
        self.assertEqual(status, 502)
        self.assertEqual(calls, [])


class _Redirector(BaseHTTPRequestHandler):
    target_port = None
    hits = 0

    def do_POST(self):  # noqa: N802
        type(self).hits += 1
        self.send_response(302)
        self.send_header(
            "Location", f"http://127.0.0.1:{type(self).target_port}/stolen")
        self.end_headers()

    def log_message(self, *args):
        pass


class _Target(BaseHTTPRequestHandler):
    hits = 0
    auth_seen = []

    def do_POST(self):  # noqa: N802
        type(self).hits += 1
        type(self).auth_seen.append(self.headers.get("Authorization"))
        self.send_response(200)
        self.end_headers()

    def log_message(self, *args):
        pass


class RedirectTest(unittest.TestCase):
    def test_redirect_is_not_followed_and_key_not_resent(self):
        target = ThreadingHTTPServer(("127.0.0.1", 0), _Target)
        redirector = ThreadingHTTPServer(("127.0.0.1", 0), _Redirector)
        _Redirector.target_port = target.server_address[1]
        for srv in (target, redirector):
            t = threading.Thread(target=srv.serve_forever)
            t.daemon = True
            t.start()
        try:
            url = f"http://127.0.0.1:{redirector.server_address[1]}/x"
            with self.assertRaises(urllib.error.HTTPError) as cm:
                post_upstream(url, b"{}", "fixture-dashscope-key")
            self.assertEqual(cm.exception.code, 302)
        finally:
            target.shutdown()
            redirector.shutdown()
        self.assertEqual(_Target.hits, 0)
        self.assertEqual(_Target.auth_seen, [])


if __name__ == "__main__":
    unittest.main()
