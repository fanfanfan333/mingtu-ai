#!/usr/bin/env python3
"""Contract tests for the /vision endpoint of amap_proxy.py.

Localhost only, fake upstream poster: NO real API is ever called
and both "keys" here are fixture strings, not credentials.
Run: python3 -m unittest test_vision_proxy -v (from this directory).
"""

import io
import json
import os
import sys
import threading
import unittest
import urllib.error
import urllib.request
from contextlib import redirect_stderr

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import amap_proxy

AMAP_FIXTURE_KEY = "fixture-amap-key"
DASH_FIXTURE_KEY = "fixture-dashscope-key"
VISION_OK = json.dumps(
    {
        "choices": [
            {
                "message": {
                    "role": "assistant",
                    "content": json.dumps(
                        {
                            "scene": "室内",
                            "obstacles": [
                                {
                                    "type": "桌子",
                                    "direction": "正前方",
                                    "proximity": "较近",
                                    "confidence": 0.9,
                                }
                            ],
                        }
                    ),
                }
            }
        ]
    }
).encode()


class CapturingPoster:
    def __init__(self):
        self.calls = []

    def __call__(self, url, body, api_key):
        self.calls.append((url, body, api_key))
        return 200, VISION_OK


def _post(port, path, body_bytes):
    req = urllib.request.Request(
        "http://127.0.0.1:%d%s" % (port, path),
        data=body_bytes,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def _vision_body(**overrides):
    payload = {
        "model": "qwen3.7-flash",
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "image_url", "image_url": {"url": "data:image/png;base64,AAAA"}},
                    {"type": "text", "text": "描述"},
                ],
            }
        ],
        "max_tokens": 256,
        "enable_thinking": False,
    }
    payload.update(overrides)
    return json.dumps(payload).encode()


class VisionProxyTest(unittest.TestCase):
    def setUp(self):
        self.poster = CapturingPoster()
        self.logs = io.StringIO()
        self._stderr_cm = redirect_stderr(self.logs)
        self._stderr_cm.__enter__()
        self.server = amap_proxy.make_server(
            0,
            AMAP_FIXTURE_KEY,
            dashscope_key=DASH_FIXTURE_KEY,
            poster=self.poster,
        )
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.daemon = True
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self._stderr_cm.__exit__(None, None, None)

    def test_vision_structured_response_key_only_in_upstream_call(self):
        status, body = _post(self.port, "/vision", _vision_body())
        self.assertEqual(status, 200)
        # The response is REBUILT structured enum JSON: the chat
        # envelope and the model's raw content never cross.
        out = json.loads(body)
        self.assertEqual(out["scene"], "室内")
        self.assertEqual(out["parsed"], True)
        self.assertEqual(out["obstacles"][0]["type"], "桌子")
        self.assertEqual(out["obstacles"][0]["confidence"], 0.9)
        self.assertNotIn("choices", body.decode())
        self.assertNotIn("content", body.decode())
        self.assertEqual(len(self.poster.calls), 1)
        url, sent_body, sent_key = self.poster.calls[0]
        # Key handed to the upstream poster (which puts it in the
        # Authorization header), default Beijing compatible URL.
        self.assertEqual(sent_key, DASH_FIXTURE_KEY)
        self.assertIn("dashscope.aliyuncs.com/compatible-mode/v1", url)
        # ...and the key appears NOWHERE client-visible or in logs.
        self.assertNotIn(DASH_FIXTURE_KEY, body.decode())
        self.assertNotIn(DASH_FIXTURE_KEY, self.logs.getvalue())
        forwarded = json.loads(sent_body)
        self.assertEqual(forwarded["model"], "qwen3.7-flash")

    def test_server_clamps_tokens_and_forces_thinking_off(self):
        status, _ = _post(
            self.port,
            "/vision",
            _vision_body(max_tokens=4000, enable_thinking=True),
        )
        self.assertEqual(status, 200)
        forwarded = json.loads(self.poster.calls[0][1])
        self.assertEqual(forwarded["max_tokens"], 256)
        self.assertIs(forwarded["enable_thinking"], False)

    def test_model_is_pinned_exact_lowercase(self):
        for bad in ("QWEN3.7-FLASH", "Qwen3.7-Flash", "qwen3-vl-flash", "gpt-4o"):
            status, _ = _post(self.port, "/vision", _vision_body(model=bad))
            self.assertEqual(status, 400, bad)
        self.assertEqual(self.poster.calls, [])

    def test_missing_dashscope_key_503_without_upstream_call(self):
        server = amap_proxy.make_server(
            0, AMAP_FIXTURE_KEY, dashscope_key="", poster=self.poster
        )
        port = server.server_address[1]
        t = threading.Thread(target=server.serve_forever)
        t.daemon = True
        t.start()
        try:
            status, body = _post(port, "/vision", _vision_body())
        finally:
            server.shutdown()
            server.server_close()
        self.assertEqual(status, 503)
        self.assertIn("not configured", body.decode())
        self.assertEqual(self.poster.calls, [])

    def test_oversize_body_413_without_upstream_call(self):
        big = _vision_body(pad="x" * (amap_proxy.VISION_MAX_BODY_BYTES + 10))
        status, _ = _post(self.port, "/vision", big)
        self.assertEqual(status, 413)
        self.assertEqual(self.poster.calls, [])

    def test_invalid_json_and_missing_messages_400(self):
        status, _ = _post(self.port, "/vision", b"{not json")
        self.assertEqual(status, 400)
        status, _ = _post(
            self.port, "/vision", json.dumps({"model": "qwen3.7-flash"}).encode()
        )
        self.assertEqual(status, 400)
        self.assertEqual(self.poster.calls, [])

    def test_unknown_post_path_404(self):
        status, _ = _post(self.port, "/walking", _vision_body())
        self.assertEqual(status, 404)
        self.assertEqual(self.poster.calls, [])


if __name__ == "__main__":
    unittest.main()
