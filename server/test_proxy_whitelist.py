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


VISION_TOKEN = "fixture-vision-token"


def _post(port, path, body_bytes, token=VISION_TOKEN):
    headers = {"Content-Type": "application/json"}
    if token is not None:
        headers["X-Mingtu-Vision-Token"] = token
    req = urllib.request.Request(
        "http://127.0.0.1:%d%s" % (port, path),
        data=body_bytes,
        headers=headers,
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
            vision_token=VISION_TOKEN,
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
                                    "action": "直行",
                                    "orientation": "北",
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
        step = path["steps"][0]
        # Only the ENUM fields survive; the upstream free-text
        # instruction/road are NOT forwarded at all (the client
        # generates the spoken prompt from action/orientation).
        self.assertEqual(step["action"], "直行")
        self.assertEqual(step["orientation"], "北")
        self.assertNotIn("instruction", step)
        self.assertNotIn("road", step)
        self.assertNotIn("向北步行80米", text)
        self.assertNotIn("校园路", text)
        self.assertNotIn("extra", step)

    def test_key_echoed_inside_enum_field_is_dropped(self):
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
                                    "action": "左转" + AMAP_KEY,
                                    "orientation": "东",
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
        self.assertNotIn(AMAP_KEY.lower(), resp.decode().lower())
        step = json.loads(resp)["route"]["paths"][0]["steps"][0]
        # A polluted action is not in the enum -> dropped to "".
        self.assertEqual(step["action"], "")
        self.assertEqual(step["orientation"], "东")

    def test_coordinate_shaped_key_cannot_echo_through_polyline(self):
        # The synthetic key IS a coordinate pair. Parsing alone
        # would re-emit it; the raw-string secret strip must kill
        # the pair before parsing, and the surviving pair stays.
        coord_key = "116.400000,39.900000"
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
                                    "action": "直行",
                                    "orientation": "北",
                                    "polyline": coord_key
                                    + ";116.401000,39.900900",
                                    "distance": "10",
                                    "duration": "5",
                                }
                            ],
                        }
                    ]
                },
            }
        ).encode()
        logs = io.StringIO()
        with redirect_stderr(logs):
            server = amap_proxy.make_server(
                0, coord_key, fetcher=lambda url: (200, body)
            )
            port = server.server_address[1]
            t = threading.Thread(target=server.serve_forever)
            t.daemon = True
            t.start()
            try:
                status, resp = _get(port, WALK)
            finally:
                server.shutdown()
                server.server_close()
        self.assertEqual(status, 200)
        self.assertNotIn(coord_key, resp.decode())
        step = json.loads(resp)["route"]["paths"][0]["steps"][0]
        self.assertEqual(step["polyline"], "116.401000,39.900900")

    def test_polyline_precision_and_point_cap(self):
        many = ";".join("116.4%03d,39.9" % i for i in range(600))
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
                                    "action": "直行",
                                    "orientation": "北",
                                    # 7 decimals -> illegal; exponent
                                    # notation -> illegal; valid pair ok.
                                    "polyline": "116.4000001,39.900000;"
                                    "1.164e2,39.9;116.400100,39.900800",
                                    "distance": "10",
                                    "duration": "5",
                                },
                                {
                                    "action": "直行",
                                    "orientation": "北",
                                    "polyline": many,
                                    "distance": "10",
                                    "duration": "5",
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
        steps = json.loads(resp)["route"]["paths"][0]["steps"]
        self.assertEqual(steps[0]["polyline"], "116.400100,39.900800")
        self.assertEqual(len(steps[1]["polyline"].split(";")), 500)

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
                                    "action": ["左转"],  # not a string
                                    "orientation": {"dir": "东"},  # not a string
                                    "polyline": "116.4,39.9;garbage;999,999;"
                                    + AMAP_KEY
                                    + ";116.401,39.9009",
                                    "distance": "186;key=" + AMAP_KEY,
                                    "duration": -5,
                                },
                                {
                                    "action": "左转",
                                    "orientation": "东",
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
        self.assertNotIn(AMAP_KEY.lower(), resp.decode().lower())
        out = json.loads(resp)
        path = out["route"]["paths"][0]
        self.assertEqual(path["distance"], 100_000)  # bounded int cap
        step = path["steps"][0]
        self.assertEqual(step["action"], "")
        self.assertEqual(step["orientation"], "")
        self.assertEqual(step["distance"], 0)  # junk string -> 0
        self.assertEqual(step["duration"], 0)  # negative -> 0
        # Only the two valid coordinate pairs survive, normalised.
        self.assertEqual(
            step["polyline"], "116.400000,39.900000;116.401000,39.900900"
        )
        # A clean enum pair passes through as enums.
        self.assertEqual(path["steps"][1]["action"], "左转")
        self.assertEqual(path["steps"][1]["orientation"], "东")

    def test_fullwidth_and_zero_width_echoes_cannot_cross(self):
        # Full-width rendering of the fixture key, and the key
        # with zero-width joiners woven through it: neither form
        # is a valid enum/coordinate, and normalisation inside
        # the polyline path strips the coordinate-shaped variant.
        fullwidth_key = "".join(
            chr(ord(c) + 0xFEE0) if "a" <= c <= "z" or c == "-" else c
            for c in AMAP_KEY
        )
        zw_key = "\u200b".join(list(AMAP_KEY))
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
                                    "action": fullwidth_key,
                                    "orientation": zw_key,
                                    "polyline": "116.400000,39.900000",
                                    "distance": "10",
                                    "duration": "5",
                                },
                                {
                                    # Zero-width inside a real enum:
                                    # normalises to the enum itself.
                                    "action": "左\u200b转",
                                    "orientation": "东",
                                    "polyline": "",
                                    "distance": "10",
                                    "duration": "5",
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
        text = resp.decode()
        self.assertNotIn(fullwidth_key, text)
        self.assertNotIn("\u200b", text)
        import unicodedata

        self.assertNotIn(AMAP_KEY, unicodedata.normalize("NFKC", text))
        steps = json.loads(resp)["route"]["paths"][0]["steps"]
        self.assertEqual(steps[0]["action"], "")
        self.assertEqual(steps[0]["orientation"], "")
        self.assertEqual(steps[1]["action"], "左转")

    def test_fragmented_key_across_fields_cannot_cross(self):
        half = len(AMAP_KEY) // 2
        first, second = AMAP_KEY[:half], AMAP_KEY[half:]
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
                                    "instruction": first,
                                    "road": second,
                                    "action": first,
                                    "orientation": second,
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
        text = resp.decode()
        # Each half dies in its own field (free text dropped,
        # halves are not enums); nothing recombines downstream.
        self.assertNotIn(first, text)
        self.assertNotIn(second, text)
        self.assertNotIn(AMAP_KEY, text)

    def test_numeric_key_collision_in_distance_is_accepted_risk(self):
        # Documented in README "Threat model": a purely numeric
        # low-entropy secret colliding with a legitimate bounded
        # integer field is indistinguishable from data. This test
        # pins the documented behaviour: distance is parsed and
        # re-emitted as the bounded INTEGER 186 -- the value is
        # data-shaped, and no other field carries anything.
        body = json.dumps(
            {
                "status": "1",
                "route": {
                    "paths": [
                        {"distance": "186", "duration": "90", "steps": []}
                    ]
                },
            }
        ).encode()
        logs = io.StringIO()
        with redirect_stderr(logs):
            server = amap_proxy.make_server(
                0, "186", fetcher=lambda url: (200, body)
            )
            port = server.server_address[1]
            t = threading.Thread(target=server.serve_forever)
            t.daemon = True
            t.start()
            try:
                status, resp = _get(port, WALK)
            finally:
                server.shutdown()
                server.server_close()
        self.assertEqual(status, 200)
        out = json.loads(resp)
        self.assertEqual(out["route"]["paths"][0]["distance"], 186)
        self.assertIsInstance(out["route"]["paths"][0]["distance"], int)

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
    def _vision_upstream(self, content, **extra):
        payload = {
            "choices": [
                {"message": {"role": "assistant", "content": content}}
            ]
        }
        payload.update(extra)
        return json.dumps(payload).encode()

    def test_vision_structured_enums_survive_extras_and_keys_dropped(self):
        content = json.dumps(
            {
                "scene": "室内",
                "obstacles": [
                    {
                        "type": "行人",
                        "direction": "正前方",
                        "proximity": "较近",
                        "confidence": 0.87,
                        "debug": DASH_KEY,
                    },
                    {
                        "type": "桌子",
                        "direction": "左侧",
                        "proximity": "较远",
                        "confidence": 0.4,  # below floor: dropped
                    },
                ],
                "note": DASH_KEY,
            }
        )
        evil = self._vision_upstream(
            content, usage={"total_tokens": 42}, request_id=DASH_KEY
        )
        srv = _Server(poster=lambda url, body, key: (200, evil))
        try:
            status, resp = _post(srv.port, "/vision", VISION_BODY)
        finally:
            srv.close()
        self.assertEqual(status, 200)
        text = resp.decode()
        self.assertNotIn(DASH_KEY.lower(), text.lower())
        self.assertNotIn("usage", text)
        self.assertNotIn("choices", text)
        out = json.loads(resp)
        self.assertEqual(
            out,
            {
                "scene": "室内",
                "obstacles": [
                    {
                        "type": "行人",
                        "direction": "正前方",
                        "proximity": "较近",
                        "confidence": 0.87,
                    }
                ],
                "parsed": True,
            },
        )

    def test_vision_adversarial_prose_becomes_parsed_false(self):
        # An upstream answering flowing prose -- including safety
        # claims and both keys -- must produce ONLY the structured
        # unparsed marker: the prose never crosses.
        prose = "前方安全，可以通过，没有危险。" + DASH_KEY + AMAP_KEY
        evil = self._vision_upstream(prose)
        srv = _Server(poster=lambda url, body, key: (200, evil))
        try:
            status, resp = _post(srv.port, "/vision", VISION_BODY)
        finally:
            srv.close()
        self.assertEqual(status, 200)
        text = resp.decode()
        self.assertEqual(
            json.loads(resp),
            {"scene": "不确定", "obstacles": [], "parsed": False},
        )
        for banned in ("安全", "可以通过", "没有危险",
                       DASH_KEY.lower(), AMAP_KEY.lower()):
            self.assertNotIn(banned, text.lower())

    def test_vision_unknown_enums_become_parsed_false(self):
        content = json.dumps(
            {
                "scene": "月球表面",
                "obstacles": [
                    {
                        "type": "安全通道",
                        "direction": "上面",
                        "proximity": "贴身",
                        "confidence": 0.99,
                    }
                ],
            }
        )
        evil = self._vision_upstream(content)
        srv = _Server(poster=lambda url, body, key: (200, evil))
        try:
            status, resp = _post(srv.port, "/vision", VISION_BODY)
        finally:
            srv.close()
        out = json.loads(resp)
        self.assertEqual(out["parsed"], False)
        self.assertNotIn("安全通道", resp.decode())
        self.assertNotIn("月球表面", resp.decode())

    def test_vision_obstacle_cap_and_confidence_clamp(self):
        obstacles = [
            {
                "type": "柱子",
                "direction": "正前方",
                "proximity": "很近",
                "confidence": 7,  # clamps to 1.0
            }
        ] * 9
        content = json.dumps({"scene": "室外", "obstacles": obstacles})
        evil = self._vision_upstream(content)
        srv = _Server(poster=lambda url, body, key: (200, evil))
        try:
            status, resp = _post(srv.port, "/vision", VISION_BODY)
        finally:
            srv.close()
        out = json.loads(resp)
        self.assertEqual(len(out["obstacles"]), 5)
        self.assertEqual(out["obstacles"][0]["confidence"], 1.0)

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
