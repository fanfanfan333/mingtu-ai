"""Cloud event modes (M2 section 3.3): task=crossing_info and
task=detour on the vision handler.

Same discipline as hazard mode: the proxy pins each mode's
prompt, validates the upstream answer field by field through
fixed enums, drops extra fields, never copies upstream text,
and collapses ANY deviation to the mode's unknown form.
Transport-level failures keep the existing fixed-error
discipline (502/504 with a fixed error body -- the client maps
those to its failure vocabulary and announces the downgrade);
it is CONTENT anomalies that degrade to the unknown form.

Fixtures only -- the poster is a local fake, no network, no
real keys. KEY below is an obviously fake fixture value in the
style the existing server tests already use.
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
        if isinstance(self.response, Exception):
            raise self.response
        return 200, self.response


def run_mode(task, upstream_body, key=KEY):
    poster = CapturingPoster(upstream_body)
    status, body = proxy.handle_vision_body(
        vision_request(task=task),
        dashscope_key=key,
        vision_upstream=proxy.VISION_UPSTREAM_DEFAULT,
        poster=poster,
    )
    return status, body, poster


def crossing_content(**overrides):
    inner = {"light": "green", "countdown_s": 30, "crosswalk_visible": True}
    inner.update(overrides)
    return json.dumps(inner)


def detour_content(**overrides):
    inner = {"blocked": True, "open_side": "left"}
    inner.update(overrides)
    return json.dumps(inner)


class CrossingRequestPinning(unittest.TestCase):
    def test_upstream_payload_is_pinned_like_hazard(self):
        status, _body, poster = run_mode(
            "crossing_info", chat_body(crossing_content()))
        self.assertEqual(status, 200)
        self.assertEqual(len(poster.calls), 1)
        sent = json.loads(poster.calls[0][1].decode())
        self.assertEqual(sent["response_format"], {"type": "json_object"})
        self.assertEqual(sent["temperature"], 0)
        self.assertEqual(sent["max_tokens"], proxy.HAZARD_MAX_TOKENS)
        self.assertNotIn("task", sent)  # control field not forwarded
        text = sent["messages"][0]["content"][1]["text"]
        self.assertEqual(text, proxy.CROSSING_PROMPT)
        self.assertIn("json", text)

    def test_detour_prompt_is_pinned_too(self):
        status, _body, poster = run_mode(
            "detour", chat_body(detour_content()))
        self.assertEqual(status, 200)
        sent = json.loads(poster.calls[0][1].decode())
        text = sent["messages"][0]["content"][1]["text"]
        self.assertEqual(text, proxy.DETOUR_PROMPT)


class CrossingWhitelist(unittest.TestCase):
    def test_conforming_answer_passes_field_by_field(self):
        status, body, _poster = run_mode(
            "crossing_info",
            chat_body(crossing_content(extra="drop me", note="x" * 5000)),
        )
        self.assertEqual(status, 200)
        out = json.loads(body.decode())
        self.assertEqual(
            out,
            {"light": "green", "countdown_s": 30,
             "crosswalk_visible": True, "parsed": True},
        )
        # The overlong upstream text appears nowhere.
        self.assertNotIn("x" * 100, body.decode())

    def test_null_and_absent_countdown_are_legitimate(self):
        for content in (
            crossing_content(countdown_s=None),
            json.dumps({"light": "red", "crosswalk_visible": False}),
        ):
            status, body, _poster = run_mode(
                "crossing_info", chat_body(content))
            self.assertEqual(status, 200)
            out = json.loads(body.decode())
            self.assertTrue(out["parsed"], content)
            self.assertIsNone(out["countdown_s"])

    def test_enum_out_of_range_collapses_to_unknown(self):
        status, body, _poster = run_mode(
            "crossing_info", chat_body(crossing_content(light="purple")))
        self.assertEqual(status, 200)
        out = json.loads(body.decode())
        self.assertEqual(out["light"], "unknown")
        self.assertFalse(out["parsed"])

    def test_bad_countdowns_collapse_whole_answer(self):
        # Boolean is not an integer; out-of-range and
        # fractional countdowns are deviations, and the
        # hazard granularity collapses the whole answer.
        for bad in (True, 100, -1, 30.5, "30"):
            status, body, _poster = run_mode(
                "crossing_info", chat_body(crossing_content(countdown_s=bad)))
            self.assertEqual(status, 200)
            out = json.loads(body.decode())
            self.assertFalse(out["parsed"], repr(bad))
            self.assertEqual(out["light"], "unknown")

    def test_non_bool_crosswalk_collapses(self):
        for bad in ("yes", 1, None):
            status, body, _poster = run_mode(
                "crossing_info",
                chat_body(crossing_content(crosswalk_visible=bad)))
            out = json.loads(body.decode())
            self.assertFalse(out["parsed"], repr(bad))

    def test_prose_and_broken_json_collapse_to_unknown(self):
        for content in ("现在是绿灯，可以走了", "{not json", "[1,2]"):
            status, body, _poster = run_mode(
                "crossing_info", chat_body(content))
            self.assertEqual(status, 200)
            out = json.loads(body.decode())
            self.assertFalse(out["parsed"], content)
            self.assertEqual(out["light"], "unknown")

    def test_secret_shaped_strings_never_cross(self):
        # A key-shaped string smuggled into an extra field
        # or into the light value itself must not appear
        # in the rebuilt response.
        for content in (
            crossing_content(debug=KEY),
            crossing_content(light=KEY),
        ):
            status, body, _poster = run_mode(
                "crossing_info", chat_body(content))
            self.assertEqual(status, 200)
            self.assertNotIn(KEY, body.decode())


class DetourWhitelist(unittest.TestCase):
    def test_conforming_answer_passes_field_by_field(self):
        status, body, _poster = run_mode(
            "detour", chat_body(detour_content(extra="drop me")))
        self.assertEqual(status, 200)
        out = json.loads(body.decode())
        self.assertEqual(
            out, {"blocked": True, "open_side": "left", "parsed": True})

    def test_side_out_of_range_collapses_and_never_asserts_blocked(self):
        status, body, _poster = run_mode(
            "detour", chat_body(detour_content(open_side="up")))
        out = json.loads(body.decode())
        self.assertFalse(out["parsed"])
        self.assertEqual(out["open_side"], "unknown")
        # The unknown form must not carry the affirmative
        # claim even though the model said blocked=true.
        self.assertFalse(out["blocked"])

    def test_non_bool_blocked_collapses(self):
        for bad in ("yes", 1, None):
            status, body, _poster = run_mode(
                "detour", chat_body(detour_content(blocked=bad)))
            out = json.loads(body.decode())
            self.assertFalse(out["parsed"], repr(bad))
            self.assertFalse(out["blocked"])

    def test_prose_collapses_to_unknown_form(self):
        status, body, _poster = run_mode(
            "detour", chat_body("前面堵了，从左边走"))
        self.assertEqual(status, 200)
        out = json.loads(body.decode())
        self.assertEqual(
            out, {"blocked": False, "open_side": "unknown", "parsed": False})

    def test_secret_shaped_strings_never_cross(self):
        status, body, _poster = run_mode(
            "detour", chat_body(detour_content(open_side=KEY, debug=KEY)))
        self.assertEqual(status, 200)
        self.assertNotIn(KEY, body.decode())


class GuardsAndNeighbours(unittest.TestCase):
    def test_unconfigured_proxy_refuses_before_any_upstream_call(self):
        for task in ("crossing_info", "detour"):
            poster = CapturingPoster(chat_body(crossing_content()))
            status, _body = proxy.handle_vision_body(
                vision_request(task=task),
                dashscope_key="",
                vision_upstream=proxy.VISION_UPSTREAM_DEFAULT,
                poster=poster,
            )
            self.assertEqual(status, 503)
            self.assertEqual(len(poster.calls), 0)

    def test_upstream_exception_is_the_fixed_502_not_an_unknown_form(self):
        # Transport discipline is unchanged from hazard
        # mode: a poster failure is the fixed 502 error
        # (the client maps it to a failure and announces
        # the downgrade); only CONTENT anomalies degrade
        # to a mode's unknown form.
        for task in ("crossing_info", "detour"):
            status, body, poster = run_mode(
                task, RuntimeError("boom"))
            self.assertEqual(status, 502)
            self.assertEqual(json.loads(body.decode()),
                             {"error": "upstream failure"})
            self.assertEqual(len(poster.calls), 1)

    def test_non_chat_shaped_upstream_body_is_502(self):
        status, _body, _poster = run_mode(
            "crossing_info", b"<html>not a chat body</html>")
        self.assertEqual(status, 502)

    def test_scene_and_hazard_modes_are_untouched_by_the_new_dispatch(self):
        # Scene mode: no strict pinning, scene whitelist.
        poster = CapturingPoster(
            chat_body(json.dumps({"scene": "室外", "obstacles": []})))
        status, body = proxy.handle_vision_body(
            vision_request(),
            dashscope_key=KEY,
            vision_upstream=proxy.VISION_UPSTREAM_DEFAULT,
            poster=poster,
        )
        self.assertEqual(status, 200)
        sent = json.loads(poster.calls[0][1].decode())
        self.assertNotIn("response_format", sent)
        self.assertTrue(json.loads(body.decode())["parsed"])
        # Hazard mode still routes to the hazard whitelist.
        hazard_inner = {
            "type": "curb", "direction": "center",
            "distance_level": "near", "confidence": 0.9,
            "path_status": {"suggested_action": "stop", "summary": "路沿"},
        }
        status, body, _poster = run_mode(
            "hazard_scan", chat_body(json.dumps(hazard_inner)))
        self.assertEqual(status, 200)
        out = json.loads(body.decode())
        self.assertTrue(out["parsed"])
        self.assertEqual(out["type"], "curb")

    def test_unknown_task_falls_back_to_scene_mode(self):
        # An unrecognised task value is not a strict mode:
        # it follows the pre-existing default (scene),
        # exactly as an absent task did before 3.3.
        poster = CapturingPoster(
            chat_body(json.dumps({"scene": "室内", "obstacles": []})))
        status, _body = proxy.handle_vision_body(
            vision_request(task="something_else"),
            dashscope_key=KEY,
            vision_upstream=proxy.VISION_UPSTREAM_DEFAULT,
            poster=poster,
        )
        self.assertEqual(status, 200)
        sent = json.loads(poster.calls[0][1].decode())
        self.assertNotIn("response_format", sent)


if __name__ == "__main__":
    unittest.main()
