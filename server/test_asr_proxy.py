# -*- coding: utf-8 -*-
"""FC /asr route tests (press-and-hold cloud ASR fallback).

Same guard discipline as /vision -- demo token, rate caps,
body cap -- but an INDEPENDENT limiter, a pinned ASR model
and a {"text": ...}-only whitelist response. Fixtures only:
the poster is a fake and no real API is ever called.
"""
import base64
import json
import unittest

import amap_proxy

TOKEN = "test-token-not-real"
KEY = "fixture-dashscope-key"
AMAP_KEY = "fixture-amap-key"

WAV_BYTES = b"RIFF" + b"\x00" * 96  # 100-byte fake clip


def _upstream_ok(text="去图书馆"):
    return json.dumps({
        "choices": [{
            "message": {"role": "assistant", "content": text}
        }]
    }).encode()


class CapturingPoster:
    def __init__(self, resp=None, exc=None):
        self.calls = []
        self.resp = resp if resp is not None else _upstream_ok()
        self.exc = exc

    def __call__(self, url, body, api_key):
        self.calls.append((url, body, api_key))
        if self.exc is not None:
            raise self.exc
        return 200, self.resp


def _event(body_bytes, token=TOKEN, path="/asr"):
    headers = {}
    if token is not None:
        headers["X-Mingtu-Vision-Token"] = token
    return {
        "headers": headers,
        "rawPath": path,
        "body": body_bytes.decode("utf-8"),
        "isBase64Encoded": False,
    }


def _asr_body(audio_bytes=WAV_BYTES, **overrides):
    payload = {
        "audio": "data:audio/wav;base64,"
                 + base64.b64encode(audio_bytes).decode(),
        "format": "wav",
    }
    payload.update(overrides)
    return json.dumps(payload).encode()


def _handle(event, **kw):
    kw.setdefault("dashscope_key", KEY)
    kw.setdefault("expected_token", TOKEN)
    kw.setdefault("poster", CapturingPoster())
    kw.setdefault("limiter", amap_proxy.VisionRateLimiter(10, 100))
    kw.setdefault("asr_limiter", amap_proxy.VisionRateLimiter(10, 60))
    return amap_proxy.fc_handle_event(event, **kw)


class AsrGuardTest(unittest.TestCase):
    def test_missing_or_wrong_token_401(self):
        for token in (None, "wrong-token"):
            resp = _handle(_event(_asr_body(), token=token))
            self.assertEqual(resp["statusCode"], 401)
            self.assertEqual(json.loads(resp["body"]),
                             {"error": "unauthorized"})
            self.assertNotIn(KEY, resp["body"])

    def test_server_without_token_configured_fails_closed_503(self):
        resp = amap_proxy.fc_handle_event(
            _event(_asr_body()),
            dashscope_key=KEY, expected_token="",
            poster=CapturingPoster(),
            limiter=amap_proxy.VisionRateLimiter(10, 100),
            asr_limiter=amap_proxy.VisionRateLimiter(10, 60))
        self.assertEqual(resp["statusCode"], 503)
        self.assertEqual(json.loads(resp["body"]),
                         {"error": "vision_not_configured"})

    def test_no_dashscope_key_503_asr_not_configured(self):
        resp = _handle(_event(_asr_body()), dashscope_key="")
        self.assertEqual(resp["statusCode"], 503)
        self.assertEqual(json.loads(resp["body"]),
                         {"error": "asr_not_configured"})

    def test_rate_limited_429_and_poster_not_called(self):
        poster = CapturingPoster()
        limiter = amap_proxy.VisionRateLimiter(1, 100)
        first = _handle(_event(_asr_body()),
                        poster=poster, asr_limiter=limiter)
        self.assertEqual(first["statusCode"], 200)
        second = _handle(_event(_asr_body()),
                         poster=poster, asr_limiter=limiter)
        self.assertEqual(second["statusCode"], 429)
        self.assertEqual(json.loads(second["body"]),
                         {"error": "rate_limited"})
        self.assertEqual(len(poster.calls), 1)

    def test_limiters_are_independent(self):
        # Exhaust the VISION limiter: /asr must still work.
        poster = CapturingPoster()
        vision_limiter = amap_proxy.VisionRateLimiter(1, 100)
        self.assertTrue(vision_limiter.allow())
        self.assertFalse(vision_limiter.allow())
        resp = _handle(_event(_asr_body()), poster=poster,
                       limiter=vision_limiter)
        self.assertEqual(resp["statusCode"], 200)
        # And exhausting ASR leaves the vision limiter alone:
        asr_limiter = amap_proxy.VisionRateLimiter(1, 100)
        self.assertTrue(asr_limiter.allow())
        self.assertFalse(asr_limiter.allow())
        vision_body = json.dumps({
            "model": "qwen3.7-flash",
            "messages": [{"role": "user", "content": "x"}],
        }).encode()
        resp = _handle(_event(vision_body, path="/vision"),
                       poster=poster, asr_limiter=asr_limiter)
        self.assertEqual(resp["statusCode"], 200)

    def test_body_too_large_413(self):
        big = b"x" * (amap_proxy.ASR_MAX_BODY_BYTES + 1)
        resp = _handle(_event(big))
        self.assertEqual(resp["statusCode"], 413)
        self.assertEqual(json.loads(resp["body"]),
                         {"error": "body too large"})

    def test_audio_too_large_400(self):
        big_audio = b"\x00" * (amap_proxy.ASR_MAX_AUDIO_BYTES + 1)
        resp = _handle(_event(_asr_body(big_audio)))
        self.assertEqual(resp["statusCode"], 400)

    def test_audio_must_be_wav_data_uri(self):
        for bad in (
            {"audio": "https://example.invalid/x.wav"},
            {"audio": "data:audio/mp3;base64,AAAA"},
            {"audio": "data:audio/wav;base64,!!!not-base64!!!"},
            {"format": "wav"},
            {"audio": "data:audio/wav;base64,AAAA", "format": "mp3"},
        ):
            resp = _handle(_event(json.dumps(bad).encode()))
            self.assertEqual(resp["statusCode"], 400, bad)

    def test_model_mismatch_400_and_exact_model_ok(self):
        resp = _handle(_event(_asr_body(model="qwen3.7-flash")))
        self.assertEqual(resp["statusCode"], 400)
        self.assertEqual(json.loads(resp["body"]),
                         {"error": "model not allowed"})
        resp = _handle(_event(_asr_body(model="qwen3-asr-flash")))
        self.assertEqual(resp["statusCode"], 200)

    def test_upstream_pin_rejects_and_poster_not_called(self):
        poster = CapturingPoster()
        resp = _handle(_event(_asr_body()), poster=poster,
                       asr_upstream="https://evil.invalid/chat")
        self.assertEqual(resp["statusCode"], 502)
        self.assertEqual(poster.calls, [])

    def test_upstream_body_shape_and_key_handling(self):
        poster = CapturingPoster()
        resp = _handle(_event(_asr_body()), poster=poster)
        self.assertEqual(resp["statusCode"], 200)
        self.assertEqual(len(poster.calls), 1)
        url, body, api_key = poster.calls[0]
        self.assertEqual(url, amap_proxy.ASR_UPSTREAM_DEFAULT)
        self.assertEqual(api_key, KEY)
        sent = json.loads(body.decode())
        self.assertEqual(sent["model"], "qwen3-asr-flash")
        self.assertEqual(sent["stream"], False)
        self.assertEqual(sent["asr_options"],
                         {"language": "zh", "enable_itn": False})
        content = sent["messages"][0]["content"]
        self.assertEqual(content[0]["type"], "input_audio")
        self.assertTrue(
            content[0]["input_audio"]["data"].startswith(
                "data:audio/wav;base64,"))

    def test_response_whitelist_text_only_and_secret_stripped(self):
        poster = CapturingPoster(
            resp=_upstream_ok("去图书馆" + KEY + "尾"))
        resp = _handle(_event(_asr_body()), poster=poster)
        self.assertEqual(resp["statusCode"], 200)
        out = json.loads(resp["body"])
        self.assertEqual(set(out.keys()), {"text"})
        self.assertNotIn(KEY, resp["body"])
        self.assertEqual(out["text"], "去图书馆尾")

    def test_response_truncated_to_200(self):
        poster = CapturingPoster(resp=_upstream_ok("好" * 300))
        resp = _handle(_event(_asr_body()), poster=poster)
        out = json.loads(resp["body"])
        self.assertEqual(len(out["text"]), 200)

    def test_upstream_exception_502_fixed(self):
        poster = CapturingPoster(exc=RuntimeError("boom " + KEY))
        resp = _handle(_event(_asr_body()), poster=poster)
        self.assertEqual(resp["statusCode"], 502)
        self.assertEqual(json.loads(resp["body"]),
                         {"error": "upstream failure"})
        self.assertNotIn(KEY, resp["body"])

    def test_upstream_timeout_504(self):
        poster = CapturingPoster(exc=TimeoutError("slow"))
        resp = _handle(_event(_asr_body()), poster=poster)
        self.assertEqual(resp["statusCode"], 504)

    def test_upstream_bad_shape_502(self):
        poster = CapturingPoster(resp=b"not json at all")
        resp = _handle(_event(_asr_body()), poster=poster)
        self.assertEqual(resp["statusCode"], 502)

    def test_vision_path_never_enters_asr_branch(self):
        # A /vision request with an ASR-shaped body is a vision
        # request (model gate), never an ASR success.
        resp = _handle(_event(_asr_body(), path="/vision"))
        self.assertEqual(resp["statusCode"], 400)


if __name__ == "__main__":
    unittest.main()
