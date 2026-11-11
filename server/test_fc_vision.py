# -*- coding: utf-8 -*-
"""FC vision guards: demo-token validation, per-minute/per-day
caps, body-size cap, output cap, structured errors, and the key
never appearing in any error body. Fixtures only -- the poster
is a fake and no real API is ever called."""
import base64
import json
import unittest

import amap_proxy

TOKEN = "test-placeholder-not-a-key"
KEY = "fixture-dashscope-key"
UPSTREAM_OK = json.dumps({
    "choices": [{
        "message": {
            "role": "assistant",
            "content": json.dumps(
                {"scene": "室内", "obstacles": []}, ensure_ascii=False),
        }
    }]
}).encode()


class FakeClock:
    def __init__(self, now=1_700_000_000.0):
        self.now = now

    def __call__(self):
        return self.now


class CapturingPoster:
    def __init__(self):
        self.calls = []

    def __call__(self, url, body, api_key):
        self.calls.append((url, body, api_key))
        return 200, UPSTREAM_OK


def _event(body_bytes, token=TOKEN, path="/vision", b64=False):
    headers = {}
    if token is not None:
        headers["X-Mingtu-Vision-Token"] = token
    return {
        "headers": headers,
        "rawPath": path,
        "body": (base64.b64encode(body_bytes).decode()
                 if b64 else body_bytes.decode("utf-8")),
        "isBase64Encoded": b64,
    }


def _vision_body(**overrides):
    payload = {
        "model": "qwen3.7-flash",
        "messages": [{"role": "user", "content": [
            {"type": "image_url",
             "image_url": {"url": "data:image/png;base64,AAAA"}},
            {"type": "text", "text": "x"},
        ]}],
        "max_tokens": 256,
        "enable_thinking": False,
    }
    payload.update(overrides)
    return json.dumps(payload).encode()


def _handle(event, **kw):
    kw.setdefault("dashscope_key", KEY)
    kw.setdefault("expected_token", TOKEN)
    kw.setdefault("poster", CapturingPoster())
    kw.setdefault("limiter", amap_proxy.VisionRateLimiter(10, 100))
    return amap_proxy.fc_handle_event(event, **kw)


class LimiterTest(unittest.TestCase):
    def test_per_minute_cap_and_window_reset(self):
        clock = FakeClock()
        lim = amap_proxy.VisionRateLimiter(3, 100, clock=clock)
        self.assertTrue(lim.allow())
        self.assertTrue(lim.allow())
        self.assertTrue(lim.allow())
        self.assertFalse(lim.allow())
        clock.now += 61
        self.assertTrue(lim.allow())

    def test_per_day_cap(self):
        clock = FakeClock()
        lim = amap_proxy.VisionRateLimiter(1000, 2, clock=clock)
        self.assertTrue(lim.allow())
        self.assertTrue(lim.allow())
        self.assertFalse(lim.allow())
        clock.now += 86401
        self.assertTrue(lim.allow())


class FcVisionGuardTest(unittest.TestCase):
    def test_missing_or_wrong_token_401_and_no_secret_echo(self):
        for token in (None, "wrong-token"):
            resp = _handle(_event(_vision_body(), token=token))
            self.assertEqual(resp["statusCode"], 401)
            self.assertEqual(json.loads(resp["body"]),
                             {"error": "unauthorized"})
            self.assertNotIn(KEY, resp["body"])
            self.assertNotIn("wrong-token", resp["body"])

    def test_server_without_token_configured_fails_closed_503(self):
        resp = amap_proxy.fc_handle_event(
            _event(_vision_body()),
            dashscope_key=KEY, expected_token="",
            poster=CapturingPoster(),
            limiter=amap_proxy.VisionRateLimiter(10, 100))
        self.assertEqual(resp["statusCode"], 503)
        self.assertEqual(json.loads(resp["body"]),
                         {"error": "vision_not_configured"})

    def test_rate_limited_429_structured(self):
        poster = CapturingPoster()
        limiter = amap_proxy.VisionRateLimiter(1, 100)
        first = _handle(_event(_vision_body()),
                        poster=poster, limiter=limiter)
        self.assertEqual(first["statusCode"], 200)
        second = _handle(_event(_vision_body()),
                         poster=poster, limiter=limiter)
        self.assertEqual(second["statusCode"], 429)
        self.assertEqual(json.loads(second["body"]),
                         {"error": "rate_limited"})
        self.assertEqual(len(poster.calls), 1)  # never forwarded

    def test_body_too_large_413(self):
        big = b"x" * (amap_proxy.VISION_MAX_BODY_BYTES + 1)
        resp = _handle(_event(big))
        self.assertEqual(resp["statusCode"], 413)

    def test_output_cap_and_thinking_off_enforced(self):
        poster = CapturingPoster()
        resp = _handle(
            _event(_vision_body(max_tokens=99999,
                                enable_thinking=True)),
            poster=poster)
        self.assertEqual(resp["statusCode"], 200)
        sent = json.loads(poster.calls[0][1])
        self.assertEqual(sent["max_tokens"],
                         amap_proxy.VISION_MAX_TOKENS)
        self.assertIs(sent["enable_thinking"], False)
        # The key travelled only in the poster's key argument.
        self.assertEqual(poster.calls[0][2], KEY)
        self.assertNotIn(KEY, resp["body"])

    def test_valid_call_returns_structured_enum_json(self):
        resp = _handle(_event(_vision_body()))
        self.assertEqual(resp["statusCode"], 200)
        out = json.loads(resp["body"])
        self.assertEqual(out["scene"], "室内")
        self.assertTrue(out["parsed"])

    def test_base64_body_accepted(self):
        resp = _handle(_event(_vision_body(), b64=True))
        self.assertEqual(resp["statusCode"], 200)

    def test_non_vision_path_404(self):
        resp = _handle(_event(b"{}", path="/walking"))
        self.assertEqual(resp["statusCode"], 404)


class EnvWiringTest(unittest.TestCase):
    def test_key_env_name_is_the_fc_name(self):
        source = open(amap_proxy.CORE_FILE, encoding="utf-8").read()
        self.assertIn('os.environ.get("MINGTU_DASHSCOPE_API_KEY"', source)
        self.assertNotIn('os.environ.get("DASHSCOPE_API_KEY"', source)
        self.assertIn('os.environ.get("MINGTU_VISION_TOKEN"', source)


if __name__ == "__main__":
    unittest.main()
