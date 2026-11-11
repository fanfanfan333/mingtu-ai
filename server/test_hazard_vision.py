"""Hazard mode (task=hazard_scan) on the vision handler.

The walking scan's strict-JSON schema: the proxy pins the
hazard prompt and the JSON decoding parameters, validates
the upstream answer field by field, and collapses ANY
deviation to the all-unknown object. Fixtures only -- the
poster is a local fake, no network, no real keys.
"""

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent / "fc"))
import amap_proxy as proxy  # noqa: E402

KEY = "fixture-dashscope-key"


def chat_body(content):
    return json.dumps(
        {"choices": [{"message": {"content": content}}]}
    ).encode()


def hazard_content(**overrides):
    inner = {
        "type": "stairs_up",
        "direction": "center",
        "distance_level": "near",
        "confidence": 0.8,
        "path_status": {"suggested_action": "stop", "summary": "前方台阶"},
    }
    inner.update(overrides)
    return json.dumps(inner)


def vision_request(task=None):
    payload = {
        "model": proxy.VISION_MODEL,
        "messages": [
            {
                "role": "user",
                "content": [
                    {"type": "image_url",
                     "image_url": {"url": "data:image/png;base64,AA=="}},
                    {"type": "text", "text": "client prompt, replaced"},
                ],
            }
        ],
        "max_tokens": 999,
    }
    if task:
        payload["task"] = task
    return json.dumps(payload).encode()


class CapturingPoster:
    def __init__(self, response):
        self.response = response
        self.calls = []

    def __call__(self, url, body, key):
        self.calls.append((url, body, key))
        return 200, self.response


def run_hazard(upstream_body):
    poster = CapturingPoster(upstream_body)
    status, body = proxy.handle_vision_body(
        vision_request(task="hazard_scan"),
        dashscope_key=KEY,
        vision_upstream=proxy.VISION_UPSTREAM_DEFAULT,
        poster=poster,
    )
    return status, body, poster


class HazardRequestPinning(unittest.TestCase):
    def test_upstream_payload_is_pinned_for_strict_json(self):
        status, _body, poster = run_hazard(chat_body(hazard_content()))
        self.assertEqual(status, 200)
        self.assertEqual(len(poster.calls), 1)
        sent = json.loads(poster.calls[0][1].decode())
        self.assertEqual(sent["response_format"], {"type": "json_object"})
        self.assertEqual(sent["temperature"], 0)
        self.assertEqual(sent["max_tokens"], proxy.HAZARD_MAX_TOKENS)
        self.assertNotIn("task", sent)  # control field not forwarded
        text = sent["messages"][0]["content"][1]["text"]
        self.assertEqual(text, proxy.HAZARD_PROMPT)
        self.assertIn("json", text)

    def test_scene_mode_gets_no_hazard_pinning(self):
        poster = CapturingPoster(
            chat_body(json.dumps({"scene": "室外", "obstacles": []}))
        )
        status, _body = proxy.handle_vision_body(
            vision_request(),
            dashscope_key=KEY,
            vision_upstream=proxy.VISION_UPSTREAM_DEFAULT,
            poster=poster,
        )
        self.assertEqual(status, 200)
        sent = json.loads(poster.calls[0][1].decode())
        self.assertNotIn("response_format", sent)
        self.assertNotIn("temperature", sent)


class HazardWhitelist(unittest.TestCase):
    def test_conforming_answer_passes_field_by_field(self):
        status, body, _poster = run_hazard(chat_body(hazard_content()))
        self.assertEqual(status, 200)
        out = json.loads(body.decode())
        self.assertTrue(out["parsed"])
        self.assertEqual(out["type"], "stairs_up")
        self.assertEqual(out["direction"], "center")
        self.assertEqual(out["distance_level"], "near")
        self.assertEqual(out["path_status"]["suggested_action"], "stop")
        self.assertEqual(out["path_status"]["summary"], "前方台阶")

    def test_prose_collapses_to_unknown(self):
        status, body, _poster = run_hazard(
            chat_body("前方有台阶，请小心")
        )
        self.assertEqual(status, 200)
        out = json.loads(body.decode())
        self.assertFalse(out["parsed"])
        self.assertEqual(out["type"], "unknown")
        self.assertEqual(out["path_status"]["suggested_action"], "stop")

    def test_bad_enum_collapses_to_unknown(self):
        _s, body, _p = run_hazard(
            chat_body(hazard_content(type="ramp"))
        )
        self.assertEqual(json.loads(body.decode())["type"], "unknown")

    def test_long_summary_collapses_to_unknown(self):
        _s, body, _p = run_hazard(
            chat_body(hazard_content(path_status={
                "suggested_action": "stop",
                "summary": "这是一个超过十五个字的很长的概括文字",
            }))
        )
        self.assertFalse(json.loads(body.decode())["parsed"])

    def test_secret_shaped_summary_collapses_to_unknown(self):
        short_key = "skey123456"  # <= 15 chars: only the strip can fire
        poster = CapturingPoster(
            chat_body(hazard_content(path_status={
                "suggested_action": "stop",
                "summary": short_key,
            }))
        )
        status, body = proxy.handle_vision_body(
            vision_request(task="hazard_scan"),
            dashscope_key=short_key,
            vision_upstream=proxy.VISION_UPSTREAM_DEFAULT,
            poster=poster,
        )
        self.assertEqual(status, 200)
        out = json.loads(body.decode())
        self.assertFalse(out["parsed"])
        self.assertNotIn(short_key, body.decode())


if __name__ == "__main__":
    unittest.main()
