"""FC two-way compatibility: old client <-> new FC, and the
shape facts behind new client <-> old FC.

The spare handset still runs the f951240 build, whose client
only understands the SCENE response shape and sends scene
requests with no "task" field. Redeploying the new FC build
must not break it: scene mode stays the mode the old client
was built against (no hazard pinning leaks into it).

Conversely, the new client pointed at an old (229601e-era,
pre-hazard) FC build receives scene-shaped answers to its
hazard requests; the strict hazard parser necessarily
collapses those to the all-unknown assessment. The
behavioural Dart test for that direction lives in
test/avoidance_and_hazard_test.dart ("an old-FC scene-shaped
answer collapses to unknown"); here we pin the shape facts
it relies on.

Fixtures only -- the poster is a local fake, no network, no
real keys.
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


def old_scene_request():
    """The f951240-era scene request: model + messages, no
    "task" field, and an over-large max_tokens the proxy has
    always clamped to VISION_MAX_TOKENS."""
    return json.dumps(
        {
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
    ).encode()


class CapturingPoster:
    def __init__(self, response):
        self.response = response
        self.calls = []

    def __call__(self, url, body, key):
        self.calls.append((url, body, key))
        return 200, self.response


def old_client_accepts(body_bytes):
    """The f951240 client's scene-parse rule, replicated: the
    structured body is adopted only when "parsed" is true;
    anything else is the "uncertain" failure."""
    out = json.loads(body_bytes.decode())
    return out.get("parsed") is True


class OldClientAgainstNewFc(unittest.TestCase):
    def test_scene_request_still_gets_a_scene_answer(self):
        content = json.dumps({
            "scene": "室外",
            "obstacles": [
                {"type": "行人", "direction": "正前方",
                 "proximity": "较近", "confidence": 0.9}
            ],
        })
        poster = CapturingPoster(chat_body(content))
        status, body = proxy.handle_vision_body(
            old_scene_request(),
            dashscope_key=KEY,
            vision_upstream=proxy.VISION_UPSTREAM_DEFAULT,
            poster=poster,
        )
        self.assertEqual(status, 200)
        out = json.loads(body.decode())
        self.assertEqual(out["scene"], "室外")
        self.assertTrue(out["parsed"])
        self.assertEqual(len(out["obstacles"]), 1)
        self.assertEqual(out["obstacles"][0]["type"], "行人")
        self.assertEqual(out["obstacles"][0]["direction"], "正前方")
        self.assertEqual(out["obstacles"][0]["proximity"], "较近")
        # The old client's own acceptance rule takes it.
        self.assertTrue(old_client_accepts(body))

    def test_scene_request_gets_no_hazard_pinning(self):
        poster = CapturingPoster(
            chat_body(json.dumps({"scene": "室外", "obstacles": []}))
        )
        status, _body = proxy.handle_vision_body(
            old_scene_request(),
            dashscope_key=KEY,
            vision_upstream=proxy.VISION_UPSTREAM_DEFAULT,
            poster=poster,
        )
        self.assertEqual(status, 200)
        sent = json.loads(poster.calls[0][1].decode())
        self.assertNotIn("response_format", sent)
        self.assertNotIn("temperature", sent)
        self.assertNotIn("task", sent)
        self.assertEqual(sent["max_tokens"], proxy.VISION_MAX_TOKENS)
        text = sent["messages"][0]["content"][1]["text"]
        self.assertEqual(text, proxy.VISION_PROMPT)


class NewClientAgainstOldFcShape(unittest.TestCase):
    def test_old_scene_shape_lacks_every_hazard_key(self):
        # What an old (pre-hazard) FC build answers with: the
        # scene shape. It carries "parsed" but none of the
        # hazard fields, so the new client's strict hazard
        # parser necessarily collapses it to the all-unknown
        # assessment (parsed == False), and the app announces
        # the fixed downgrade sentence for it.
        old_answer = {"scene": "室外", "obstacles": [], "parsed": True}
        for key in ("type", "direction", "distance_level",
                    "confidence", "path_status"):
            self.assertNotIn(key, old_answer)


if __name__ == "__main__":
    unittest.main()
