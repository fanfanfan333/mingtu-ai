# -*- coding: utf-8 -*-
"""FC /asr route tests (press-and-hold cloud ASR fallback).

Same guard discipline as /vision -- demo token, rate caps,
body cap -- but an INDEPENDENT limiter, a pinned ASR model
and a {"text": ...}-only whitelist response. Fixtures only:
the poster is a fake and no real API is ever called.
"""
import base64
import json
import struct
import unittest

import amap_proxy

TOKEN = "test-token-not-real"
KEY = "fixture-dashscope-key"
AMAP_KEY = "fixture-amap-key"

def make_wav(rate=16000, channels=1, bits=16, seconds=2.0,
             audio_format=1):
    """Build a real RIFF/WAVE byte string by hand (fixture
    builder for the PTT-2 header validation tests)."""
    bytes_per_sample = bits // 8
    frames = int(rate * seconds)
    data = b"\x00" * (frames * channels * bytes_per_sample)
    byte_rate = rate * channels * bytes_per_sample
    block_align = channels * bytes_per_sample
    fmt = struct.pack(
        "<HHIIHH", audio_format, channels, rate, byte_rate,
        block_align, bits)
    riff_size = 4 + (8 + len(fmt)) + (8 + len(data))
    return (b"RIFF" + struct.pack("<I", riff_size) + b"WAVE"
            + b"fmt " + struct.pack("<I", len(fmt)) + fmt
            + b"data" + struct.pack("<I", len(data)) + data)


# The default clip for the pre-existing guard tests: a REAL
# WAV now (16 kHz mono 16-bit PCM, 2 s) -- the PTT-2 header
# validation rejects the old 100-byte fake header.
WAV_BYTES = make_wav()


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


class AsrWavValidationTest(unittest.TestCase):
    """MT-1111-PTT-2: hand-parsed RIFF validation, the
    10.5 s duration cap, and the no-quota-on-failure rule."""

    def test_valid_16k_mono_2s_200(self):
        poster = CapturingPoster()
        resp = _handle(_event(_asr_body(make_wav(seconds=2.0))),
                       poster=poster)
        self.assertEqual(resp["statusCode"], 200)
        self.assertEqual(len(poster.calls), 1)

    def test_8khz_5s_within_duration_200(self):
        # 8000 Hz is a LEGAL sample rate now (not 16k-only).
        resp = _handle(_event(_asr_body(
            make_wav(rate=8000, seconds=5.0))))
        self.assertEqual(resp["statusCode"], 200)

    def test_8khz_20s_is_320044_bytes_and_too_long_no_quota(self):
        clip = make_wav(rate=8000, seconds=20.0)
        self.assertEqual(len(clip), 320044)  # 44 header + 320000
        poster = CapturingPoster()
        limiter = amap_proxy.VisionRateLimiter(1, 100)
        resp = _handle(_event(_asr_body(clip)), poster=poster,
                       asr_limiter=limiter)
        self.assertEqual(resp["statusCode"], 400)
        self.assertEqual(json.loads(resp["body"]),
                         {"error": "audio too long"})
        self.assertEqual(poster.calls, [])
        # No quota consumed: the single slot is still free.
        self.assertTrue(limiter.allow())

    def test_duration_boundary_10_5_ok_10_6_too_long(self):
        ok = _handle(_event(_asr_body(make_wav(seconds=10.5))))
        self.assertEqual(ok["statusCode"], 200)
        over = _handle(_event(_asr_body(make_wav(seconds=10.6))))
        self.assertEqual(over["statusCode"], 400)
        self.assertEqual(json.loads(over["body"]),
                         {"error": "audio too long"})

    def test_12s_16k_too_long(self):
        resp = _handle(_event(_asr_body(make_wav(seconds=12.0))))
        self.assertEqual(resp["statusCode"], 400)
        self.assertEqual(json.loads(resp["body"]),
                         {"error": "audio too long"})

    def test_stereo_rejected(self):
        resp = _handle(_event(_asr_body(make_wav(channels=2))))
        self.assertEqual(resp["statusCode"], 400)
        self.assertEqual(json.loads(resp["body"]),
                         {"error": "audio format not allowed"})

    def test_8bit_rejected(self):
        resp = _handle(_event(_asr_body(make_wav(bits=8))))
        self.assertEqual(resp["statusCode"], 400)
        self.assertEqual(json.loads(resp["body"]),
                         {"error": "audio format not allowed"})

    def test_non_pcm_rejected(self):
        resp = _handle(_event(_asr_body(make_wav(audio_format=3))))
        self.assertEqual(resp["statusCode"], 400)
        self.assertEqual(json.loads(resp["body"]),
                         {"error": "audio format not allowed"})

    def test_sample_rate_too_low_rejected(self):
        resp = _handle(_event(_asr_body(
            make_wav(rate=4000, seconds=1.0))))
        self.assertEqual(resp["statusCode"], 400)
        self.assertEqual(json.loads(resp["body"]),
                         {"error": "audio format not allowed"})

    def test_non_wav_bytes_rejected(self):
        resp = _handle(_event(_asr_body(b"NOTAWAV" + b"\x00" * 60)))
        self.assertEqual(resp["statusCode"], 400)
        self.assertEqual(json.loads(resp["body"]),
                         {"error": "audio format not allowed"})

    def test_truncated_wav_rejected(self):
        resp = _handle(_event(_asr_body(make_wav()[:30])))
        self.assertEqual(resp["statusCode"], 400)

    # --- CDX2: malformed-WAV fixtures that used to reach
    # the upstream and spend quota. Each must be a fixed
    # 400 with poster uncalled and the limiter untouched.

    def _assert_rejected_no_upstream_no_quota(self, clip):
        poster = CapturingPoster()
        limiter = amap_proxy.VisionRateLimiter(1, 100)
        resp = _handle(_event(_asr_body(clip)), poster=poster,
                       asr_limiter=limiter)
        self.assertEqual(resp["statusCode"], 400)
        self.assertEqual(json.loads(resp["body"]),
                         {"error": "audio format not allowed"})
        self.assertEqual(poster.calls, [])
        # No quota consumed: the single slot is still free.
        self.assertTrue(limiter.allow())

    def test_malformed_riff_size_rejected(self):
        # riff-size: the RIFF declared size disagrees with
        # the actual file length (here: declared 100 bytes
        # short; the >1-byte slack is not a pad).
        clip = bytearray(make_wav(seconds=2.0))
        declared = struct.unpack("<I", clip[4:8])[0]
        clip[4:8] = struct.pack("<I", declared - 100)
        self._assert_rejected_no_upstream_no_quota(bytes(clip))

    def test_malformed_data_truncated_rejected(self):
        # data-truncated: the data chunk DECLARES more
        # bytes than are actually present in the file.
        fmt = struct.pack("<HHIIHH", 1, 1, 16000, 32000, 2, 16)
        actual_data = b"\x00" * 2000
        declared_data = 20000
        riff_size = 4 + (8 + len(fmt)) + (8 + actual_data.__len__())
        clip = (b"RIFF" + struct.pack("<I", riff_size) + b"WAVE"
                + b"fmt " + struct.pack("<I", len(fmt)) + fmt
                + b"data" + struct.pack("<I", declared_data)
                + actual_data)
        self._assert_rejected_no_upstream_no_quota(clip)

    def test_malformed_data_size_small_rejected(self):
        # data-size-small: the data chunk DECLARES fewer
        # bytes than are actually present, and the surplus
        # bytes cannot form a legal following chunk (they
        # are PCM silence whose "chunk header" declares a
        # size far past the end of the file). RIFF size is
        # consistent with the ACTUAL length, so only the
        # chunk walk can catch this.
        fmt = struct.pack("<HHIIHH", 1, 1, 16000, 32000, 2, 16)
        actual_data = b"\x00" * 6400
        declared_data = 3200
        riff_size = 4 + (8 + len(fmt)) + (8 + len(actual_data))
        clip = (b"RIFF" + struct.pack("<I", riff_size) + b"WAVE"
                + b"fmt " + struct.pack("<I", len(fmt)) + fmt
                + b"data" + struct.pack("<I", declared_data)
                + actual_data)
        self._assert_rejected_no_upstream_no_quota(clip)

    def test_malformed_extra_bad_chunk_rejected(self):
        # extra-bad-chunk: a structurally broken extra
        # chunk after data -- its declared size runs far
        # past the end of the file. RIFF size matches the
        # actual length; the extra chunk is the defect.
        good = make_wav(seconds=1.0)
        extra = b"JUNK" + struct.pack("<I", 100000) + b"\x00" * 4
        clip = bytearray(good + extra)
        clip[4:8] = struct.pack("<I", len(clip) - 8)
        self._assert_rejected_no_upstream_no_quota(bytes(clip))

    # --- MT-1111-ALIGN-B: four more structural defects,
    # each still a fixed 400 with poster uncalled and the
    # limiter untouched (the shared assertion above).

    def test_malformed_chunk_pad_overrun_rejected(self):
        # pad-overrun: an extra chunk declares an ODD size
        # whose content fits exactly, but the mandatory
        # pad byte does not fit in the remaining bytes.
        good = make_wav(seconds=1.0)
        extra = b"JUNK" + struct.pack("<I", 3) + b"abc"
        clip = bytearray(good + extra)
        clip[4:8] = struct.pack("<I", len(clip) - 8)
        self._assert_rejected_no_upstream_no_quota(bytes(clip))

    def test_malformed_fmt_after_data_rejected(self):
        # fmt-after-data: both chunks are individually
        # well-formed, but fmt must precede data.
        fmt = struct.pack("<HHIIHH", 1, 1, 16000, 32000, 2, 16)
        data = b"\x00" * 3200
        riff_size = 4 + (8 + len(data)) + (8 + len(fmt))
        clip = (b"RIFF" + struct.pack("<I", riff_size) + b"WAVE"
                + b"data" + struct.pack("<I", len(data)) + data
                + b"fmt " + struct.pack("<I", len(fmt)) + fmt)
        self._assert_rejected_no_upstream_no_quota(clip)

    def test_malformed_data_not_block_align_multiple_rejected(self):
        # data size 3 is not a multiple of blockAlign (2).
        # The odd-size pad byte IS present, so only the
        # frame-alignment rule can catch this.
        fmt = struct.pack("<HHIIHH", 1, 1, 16000, 32000, 2, 16)
        data = b"\x00" * 3
        riff_size = 4 + (8 + len(fmt)) + (8 + len(data) + 1)
        clip = (b"RIFF" + struct.pack("<I", riff_size) + b"WAVE"
                + b"fmt " + struct.pack("<I", len(fmt)) + fmt
                + b"data" + struct.pack("<I", len(data)) + data
                + b"\x00")
        self._assert_rejected_no_upstream_no_quota(clip)

    def test_malformed_data_empty_rejected(self):
        # Empty data chunk: structurally walkable, but a
        # zero-byte clip carries no audio frame at all.
        fmt = struct.pack("<HHIIHH", 1, 1, 16000, 32000, 2, 16)
        riff_size = 4 + (8 + len(fmt)) + 8
        clip = (b"RIFF" + struct.pack("<I", riff_size) + b"WAVE"
                + b"fmt " + struct.pack("<I", len(fmt)) + fmt
                + b"data" + struct.pack("<I", 0))
        self._assert_rejected_no_upstream_no_quota(clip)

    def test_validation_failure_consumes_no_quota(self):
        # A stereo clip is rejected BEFORE the limiter: with
        # a 1-per-minute limiter the follow-up VALID clip
        # must still pass (the failure spent nothing).
        limiter = amap_proxy.VisionRateLimiter(1, 100)
        bad = _handle(_event(_asr_body(make_wav(channels=2))),
                      asr_limiter=limiter)
        self.assertEqual(bad["statusCode"], 400)
        good = _handle(_event(_asr_body()), asr_limiter=limiter)
        self.assertEqual(good["statusCode"], 200)


if __name__ == "__main__":
    unittest.main()
