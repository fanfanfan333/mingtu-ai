#!/usr/bin/env python3
"""Whitelist / key-echo tests for amap_proxy.py (Codex re-test).

A hostile-or-buggy upstream that ECHOES the key back -- in a debug
field, a URL, a step instruction, an error string, a vision
description -- must never leak it to the client: the proxy rebuilds
every response from whitelisted fields only and strips secret
substrings from the fields it keeps. Localhost fixtures only; the
"keys" are fixture strings. Run: python3 -m unittest
test_proxy_whitelist -v (from this directory).
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

AMAP_KEY = "fixture-amap-key"
DASH_KEY = "fixture-dashscope-key"


def _get(port, path):
    try:
        with urllib.request.urlopen(
            "http://127.0.0.1:%d%s" % (port, path), timeout=5
        ) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


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


class _Server:
    def __init__(self, fetcher=None, poster=None):
        self.logs = io.StringIO()
        self._cm = redirect_stderr(self.logs)
        self._cm.__enter__()
        self.server = amap_proxy.make_server(
            0,
            AMAP_KEY,
            fetcher=fetcher,
            dashscope_key=DASH_KEY,
            poster=poster,
        )
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.daemon = True
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self._cm.__exit__(None, None, None)


WALK = "/walking?origin=116.4,39.9&destination=116.401,39.9009"


class WalkingWhitelistTest(unittest.TestCase):
    def test_upstream_echoing_key_everywhere_cannot_leak(self):
        evil_body = json.dumps(
            {
                "status": "1",
                "info": "OK",
                "count": "1",
                "debug_url": "https://restapi.amap.com/x?key=" + AMAP_KEY,
                "echoed_key": AMAP_KEY,
                "route": {
                    "origin": "116.4,39.9",
                    "taxi_cost": "99",
                    "paths": [
                        {
                            "distance": "186",
                            "duration": "150",
                            "restriction": "0",
                            "steps": [
                                {
                                    "instruction": "向北步行80米",
                                    "road": "校园路",
                                    "polyline": "116.4,39.9;116.4001,39.9008",
                                    "distance": "80",
                                    "duration": "60",
                                    "extra": AMAP_KEY,
                                }
                            ],
                        },
                        {"distance": "9999", "duration": "1", "steps": []},
                    ],
                },
            }
        ).encode()
        srv = _Server(fetcher=lambda url: (200, evil_body))
        try:
            status, body = _get(srv.port, WALK)
        finally:
            srv.close()
        self.assertEqual(status, 200)
        text = body.decode()
        # The key survives NOWHERE: not as a field, not in a URL.
        self.assertNotIn(AMAP_KEY, text)
        self.assertNotIn("debug_url", text)
        self.assertNotIn("echoed_key", text)
        self.assertNotIn("taxi_cost", text)
        self.assertNotIn("9999", text)  # only the first path is kept
        out = json.loads(body)
        self.assertEqual(out["status"], "1")
        path = out["route"]["paths"][0]
        # distance/duration are coerced to NUMBERS by the whitelist.
        self.assertEqual(path["distance"], 186)
        self.assertEqual(path["duration"], 150)
        self.assertEqual(path["steps"][0]["instruction"], "向北步行80米")
        self.assertNotIn("extra", path["steps"][0])

    def test_key_echoed_inside_a_kept_field_is_stripped(self):
        body = json.dumps(
            {
                "status": "1",
                "route": {
                    "paths": [
                        {
                            "distance": "10",
                            "duration": "5",
                            "steps": [
                                {
                                    "instruction": "前行" + AMAP_KEY + "十米",
                                    "road": "",
                                    "polyline": "",
                                    "distance": "10",
                                    "duration": "5",
                                }
                            ],
                        }
                    ]
                },
            }
        ).encode()
        srv = _Server(fetcher=lambda url: (200, body))
        try:
            status, resp = _get(srv.port, WALK)
        finally:
            srv.close()
        self.assertEqual(status, 200)
        self.assertNotIn(AMAP_KEY, resp.decode())
        out = json.loads(resp)
        self.assertEqual(
            out["route"]["paths"][0]["steps"][0]["instruction"], "前行十米"
        )

    def test_failure_info_is_a_fixed_enum_and_nothing_else_crosses(self):
        body = json.dumps(
            {
                "status": "0",
                "info": "INVALID_USER_KEY key=" + AMAP_KEY,
                "infocode": "10001",
                "debug": AMAP_KEY,
            }
        ).encode()
        srv = _Server(fetcher=lambda url: (200, body))
        try:
            status, resp = _get(srv.port, WALK)
        finally:
            srv.close()
        self.assertEqual(status, 200)
        self.assertNotIn(AMAP_KEY, resp.decode())
        self.assertNotIn("INVALID_USER_KEY", resp.decode())
        out = json.loads(resp)
        # Upstream error text never crosses: fixed enum only.
        self.assertEqual(out, {"status": "0", "info": "UPSTREAM_ERROR"})

    def test_status_field_is_a_fixed_enum(self):
        # A key echoed inside status, or a non-string status type,
        # must collapse to the "0" enum value with the fixed info.
        for evil_status in ("1" + AMAP_KEY, {"echo": AMAP_KEY}, [AMAP_KEY], 2):
            body = json.dumps(
                {"status": evil_status, "route": {"paths": [{"distance": "1"}]}}
            ).encode()
            srv = _Server(fetcher=lambda url, b=body: (200, b))
            try:
                status, resp = _get(srv.port, WALK)
            finally:
                srv.close()
            self.assertEqual(status, 200)
            self.assertNotIn(AMAP_KEY, resp.decode())
            self.assertEqual(
                json.loads(resp), {"status": "0", "info": "UPSTREAM_ERROR"}
            )

    def test_nested_fields_are_type_coerced_and_rebuilt(self):
        body = json.dumps(
            {
                "status": "1",
                "route": {
                    "paths": [
                        {
                            "distance": 10**12,  # clamps to 10^7
                            "duration": "150",
                            "steps": [
                                {
                                    "instruction": [AMAP_KEY],  # not a string
                                    "road": {"name": AMAP_KEY},  # not a string
                                    "polyline": "116.4,39.9;garbage;999,999;"
                                    + AMAP_KEY
                                    + ";116.401,39.9009",
                                    "distance": "186;key=" + AMAP_KEY,
                                    "duration": -5,
                                },
                                {
                                    "instruction": "长" * 500,  # caps at 200
                                    "road": "校园路",
                                    "polyline": "116.4,39.9",
                                    "distance": "80",
                                    "duration": "60",
                                },
                            ],
                        }
                    ]
                },
            }
        ).encode()
        srv = _Server(fetcher=lambda url: (200, body))
        try:
            status, resp = _get(srv.port, WALK)
        finally:
            srv.close()
        self.assertEqual(status, 200)
        self.assertNotIn(AMAP_KEY, resp.decode())
        out = json.loads(resp)
        path = out["route"]["paths"][0]
        self.assertEqual(path["distance"], 10_000_000)
        step = path["steps"][0]
        self.assertEqual(step["instruction"], "")
        self.assertEqual(step["road"], "")
        self.assertEqual(step["distance"], 0)  # junk string -> 0
        self.assertEqual(step["duration"], 0)  # negative -> 0
        # Only the two valid coordinate pairs survive, normalised.
        self.assertEqual(
            step["polyline"], "116.400000,39.900000;116.401000,39.900900"
        )
        self.assertEqual(len(path["steps"][1]["instruction"]), 200)

    def test_non_json_upstream_body_becomes_generic_502(self):
        srv = _Server(
            fetcher=lambda url: (200, ("error page key=" + AMAP_KEY).encode())
        )
        try:
            status, resp = _get(srv.port, WALK)
        finally:
            srv.close()
        self.assertEqual(status, 502)
        self.assertNotIn(AMAP_KEY, resp.decode())
        self.assertEqual(json.loads(resp), {"error": "upstream failure"})


VISION_BODY = json.dumps(
    {
        "model": "qwen3.7-flash",
        "messages": [{"role": "user", "content": [{"type": "text", "text": "描述"}]}],
        "max_tokens": 256,
        "enable_thinking": False,
    }
).encode()


class VisionWhitelistTest(unittest.TestCase):
    def test_vision_content_kept_extras_dropped_key_stripped(self):
        evil = json.dumps(
            {
                "choices": [
                    {
                        "message": {
                            "role": "assistant",
                            "content": "桌上有一本书。" + DASH_KEY,
                        },
                        "finish_reason": "stop",
                        "logprobs": {"debug": DASH_KEY},
                    }
                ],
                "usage": {"total_tokens": 42},
                "request_id": DASH_KEY,
            }
        ).encode()
        srv = _Server(poster=lambda url, body, key: (200, evil))
        try:
            status, resp = _post(srv.port, "/vision", VISION_BODY)
        finally:
            srv.close()
        self.assertEqual(status, 200)
        text = resp.decode()
        self.assertNotIn(DASH_KEY, text)
        self.assertNotIn("usage", text)
        self.assertNotIn("logprobs", text)
        out = json.loads(resp)
        self.assertEqual(
            out["choices"][0]["message"]["content"], "桌上有一本书。"
        )

    def test_vision_role_is_forced_to_fixed_enum(self):
        for evil_role in (DASH_KEY, {"role": DASH_KEY}, 42, None):
            evil = json.dumps(
                {
                    "choices": [
                        {
                            "message": {
                                "role": evil_role,
                                "content": "画面描述。",
                            }
                        }
                    ]
                }
            ).encode()
            srv = _Server(poster=lambda url, body, key, e=evil: (200, e))
            try:
                status, resp = _post(srv.port, "/vision", VISION_BODY)
            finally:
                srv.close()
            self.assertEqual(status, 200)
            self.assertNotIn(DASH_KEY, resp.decode())
            out = json.loads(resp)
            self.assertEqual(out["choices"][0]["message"]["role"], "assistant")
            self.assertEqual(
                out["choices"][0]["message"]["content"], "画面描述。"
            )

    def test_vision_content_is_length_capped(self):
        evil = json.dumps(
            {"choices": [{"message": {"role": "assistant", "content": "长" * 5000}}]}
        ).encode()
        srv = _Server(poster=lambda url, body, key: (200, evil))
        try:
            status, resp = _post(srv.port, "/vision", VISION_BODY)
        finally:
            srv.close()
        self.assertEqual(status, 200)
        out = json.loads(resp)
        self.assertEqual(len(out["choices"][0]["message"]["content"]), 2000)

    def test_vision_upstream_timeout_is_fixed_504(self):
        def slow(url, body, key):
            raise TimeoutError("timed out after 20s " + DASH_KEY)

        srv = _Server(poster=slow)
        try:
            status, resp = _post(srv.port, "/vision", VISION_BODY)
        finally:
            srv.close()
        self.assertEqual(status, 504)
        self.assertNotIn(DASH_KEY, resp.decode())
        self.assertEqual(json.loads(resp), {"error": "upstream timeout"})

    def test_vision_upstream_error_becomes_generic_502(self):
        err = json.dumps(
            {"error": {"message": "bad key " + DASH_KEY, "code": "InvalidApiKey"}}
        ).encode()
        srv = _Server(poster=lambda url, body, key: (200, err))
        try:
            status, resp = _post(srv.port, "/vision", VISION_BODY)
        finally:
            srv.close()
        self.assertEqual(status, 502)
        self.assertNotIn(DASH_KEY, resp.decode())
        self.assertEqual(json.loads(resp), {"error": "upstream failure"})


if __name__ == "__main__":
    unittest.main()
