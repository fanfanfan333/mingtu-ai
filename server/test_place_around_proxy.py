#!/usr/bin/env python3
"""Contract + whitelist / key-echo tests for GET /place/around.

Same skeleton as test_proxy_whitelist.py: a localhost
ThreadingHTTPServer from amap_proxy.make_server plus a stubbed
`fetcher`, so NO real API is ever called and the "key" here is a
fixture string, not a credential. Run: python3 -m unittest
test_place_around_proxy -v   (from this directory) or
python3 -m pytest test_place_around_proxy.py -q.

What is pinned here:
    - the response carries EXACTLY name/location/distance per POI;
    - a hostile-or-buggy upstream that echoes the key (in a name,
      in status, in info, inside a coordinate-shaped key) cannot
      get it across;
    - local validation (400) happens before any upstream call;
    - client-supplied radius is clamped, never forwarded verbatim;
    - the upstream endpoint pin (place_upstream) is a hard
      invariant -> any other base is 502;
    - unknown GET paths stay 404.
"""

import io
import json
import os
import sys
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
from contextlib import redirect_stderr

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import amap_proxy

AMAP_KEY = "fixture-amap-key"
DASH_KEY = "fixture-dashscope-key"

# location=116.4,39.9 & keywords=图书馆 (urlencoded: http.client
# only accepts ASCII in the request line).
PLACE = "/place/around?" + urllib.parse.urlencode(
    {"location": "116.4,39.9", "keywords": "图书馆"}
)


def _get(port, path):
    try:
        with urllib.request.urlopen(
            "http://127.0.0.1:%d%s" % (port, path), timeout=5
        ) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def _place_path(**params):
    query = {"location": "116.4,39.9", "keywords": "图书馆"}
    query.update(params)
    return "/place/around?" + urllib.parse.urlencode(query)


def _ok_body(pois, **extra):
    payload = {"status": "1", "info": "OK", "count": str(len(pois)), "pois": pois}
    payload.update(extra)
    return json.dumps(payload).encode()


class _RecordingFetcher:
    """Stub transport: records the outbound URL and answers with a
    fixed body."""

    def __init__(self, body):
        self.body = body
        self.urls = []

    def __call__(self, url):
        self.urls.append(url)
        return 200, self.body


class _Server:
    """Same fixture server as test_proxy_whitelist._Server, plus
    the injectable place_upstream used by the pin test."""

    def __init__(self, fetcher=None, api_key=AMAP_KEY, place_upstream=None):
        self.logs = io.StringIO()
        self._cm = redirect_stderr(self.logs)
        self._cm.__enter__()
        kwargs = {"dashscope_key": DASH_KEY}
        if place_upstream is not None:
            kwargs["place_upstream"] = place_upstream
        self.server = amap_proxy.make_server(
            0, api_key, fetcher=fetcher, **kwargs
        )
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.daemon = True
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self._cm.__exit__(None, None, None)


def _one_poi(**overrides):
    poi = {
        "name": "西城区第一图书馆",
        "location": "116.400000,39.900000",
        "distance": "186",
    }
    poi.update(overrides)
    return poi


class PlaceAroundHappyPathTest(unittest.TestCase):
    def test_valid_request_returns_only_three_keys_per_poi(self):
        fetcher = _RecordingFetcher(_ok_body([_one_poi()]))
        srv = _Server(fetcher=fetcher)
        try:
            status, body = _get(srv.port, PLACE)
        finally:
            srv.close()
        self.assertEqual(status, 200)
        out = json.loads(body)
        self.assertEqual(out["status"], "1")
        self.assertEqual(len(out["pois"]), 1)
        poi = out["pois"][0]
        # Exactly three keys: every extra upstream field is dropped.
        self.assertEqual(set(poi.keys()), {"name", "location", "distance"})
        self.assertEqual(poi["name"], "西城区第一图书馆")
        self.assertEqual(poi["location"], "116.400000,39.900000")
        # distance is re-emitted as a bounded INTEGER, not a string.
        self.assertEqual(poi["distance"], 186)
        self.assertIsInstance(poi["distance"], int)
        # No "count"/"info" passthrough.
        self.assertNotIn("count", out)
        # The key travelled only in the outbound URL...
        self.assertEqual(len(fetcher.urls), 1)
        self.assertIn("key=" + AMAP_KEY, fetcher.urls[0])
        # ...and the proxy's own log stays path-only.
        self.assertNotIn(AMAP_KEY, srv.logs.getvalue())

    def test_upstream_url_is_built_server_side(self):
        fetcher = _RecordingFetcher(_ok_body([]))
        srv = _Server(fetcher=fetcher)
        try:
            status, _body = _get(
                srv.port, _place_path(radius="2500", key="client-junk")
            )
        finally:
            srv.close()
        self.assertEqual(status, 200)
        url = fetcher.urls[0]
        self.assertTrue(
            url.startswith(amap_proxy.PLACE_UPSTREAM_DEFAULT), url
        )
        self.assertIn("radius=2500", url)
        self.assertIn("offset=10", url)
        self.assertIn("page=1", url)
        self.assertIn("sortrule=distance", url)
        self.assertIn("output=json", url)
        self.assertIn("key=" + AMAP_KEY, url)
        # A client-supplied key is never forwarded.
        self.assertNotIn("client-junk", url)

    def test_radius_is_clamped_and_junk_falls_back_to_default(self):
        cases = {
            "999999": "radius=50000",
            "1": "radius=100",
            "-500": "radius=100",
            "abc": "radius=3000",
            "3000.5": "radius=3000",
        }
        for sent, expected in cases.items():
            fetcher = _RecordingFetcher(_ok_body([]))
            srv = _Server(fetcher=fetcher)
            try:
                status, _body = _get(srv.port, _place_path(radius=sent))
            finally:
                srv.close()
            self.assertEqual(status, 200, sent)
            self.assertIn(expected, fetcher.urls[0], sent)
            self.assertNotIn("radius=" + sent + "&", fetcher.urls[0], sent)

    def test_empty_poi_list_is_a_legal_success(self):
        srv = _Server(fetcher=_RecordingFetcher(_ok_body([])))
        try:
            status, body = _get(srv.port, PLACE)
        finally:
            srv.close()
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"status": "1", "pois": []})


class PlaceAroundKeyEchoTest(unittest.TestCase):
    def test_upstream_echoing_key_everywhere_cannot_leak(self):
        evil = json.dumps(
            {
                "status": "1",
                "info": "OK " + AMAP_KEY,
                "count": "1",
                "debug_url": "https://restapi.amap.com/v3/place/around?key="
                + AMAP_KEY,
                "echoed_key": AMAP_KEY,
                "pois": [
                    {
                        "name": "图书馆" + AMAP_KEY,
                        "location": "116.4,39.9",
                        "distance": AMAP_KEY,
                        "address": AMAP_KEY,
                        "tel": AMAP_KEY,
                        "id": AMAP_KEY,
                        "typecode": "080300",
                    }
                ],
            }
        ).encode()
        srv = _Server(fetcher=lambda url: (200, evil))
        try:
            status, body = _get(srv.port, PLACE)
        finally:
            srv.close()
        self.assertEqual(status, 200)
        text = body.decode()
        self.assertNotIn(AMAP_KEY.lower(), text.lower())
        for banned in ("debug_url", "echoed_key", "address", "tel",
                       "id", "typecode"):
            self.assertNotIn(banned, text)
        out = json.loads(body)
        poi = out["pois"][0]
        # The name survives with the echo stripped out of it.
        self.assertEqual(poi["name"], "图书馆")
        # A key in the numeric field is data-shaped junk -> 0.
        self.assertEqual(poi["distance"], 0)

    def test_key_echoed_inside_status_is_a_fixed_enum(self):
        for evil_status in ("1" + AMAP_KEY, {"echo": AMAP_KEY},
                            [AMAP_KEY], 2):
            body = json.dumps(
                {"status": evil_status, "pois": [_one_poi()]}
            ).encode()
            srv = _Server(fetcher=lambda url, b=body: (200, b))
            try:
                status, resp = _get(srv.port, PLACE)
            finally:
                srv.close()
            self.assertEqual(status, 200)
            self.assertNotIn(AMAP_KEY, resp.decode())
            self.assertEqual(
                json.loads(resp), {"status": "0", "info": "UPSTREAM_ERROR"}
            )

    def test_failure_info_is_a_fixed_enum_and_nothing_else_crosses(self):
        body = json.dumps(
            {
                "status": "0",
                "info": "INVALID_USER_KEY key=" + AMAP_KEY,
                "infocode": "10001",
                "debug": AMAP_KEY,
                "pois": [_one_poi()],
            }
        ).encode()
        srv = _Server(fetcher=lambda url: (200, body))
        try:
            status, resp = _get(srv.port, PLACE)
        finally:
            srv.close()
        self.assertEqual(status, 200)
        text = resp.decode()
        self.assertNotIn(AMAP_KEY, text)
        self.assertNotIn("INVALID_USER_KEY", text)
        # Upstream error text never crosses: fixed enum only.
        self.assertEqual(json.loads(resp), {"status": "0", "info": "UPSTREAM_ERROR"})

    def test_control_characters_in_name_cannot_cross(self):
        body = _ok_body(
            [
                _one_poi(
                    name="图书\u0007馆\u202e\u200bA\nB\tC",
                    address=AMAP_KEY,
                )
            ]
        )
        srv = _Server(fetcher=lambda url: (200, body))
        try:
            status, resp = _get(srv.port, PLACE)
        finally:
            srv.close()
        self.assertEqual(status, 200)
        text = resp.decode()
        # json.dumps escapes non-ASCII, so a surviving control
        # character would appear as its backslash-u escape.
        for banned in ("\\u0007", "\\u202e", "\\u200b", "\\n", "\\t"):
            self.assertNotIn(banned, text)
        self.assertEqual(json.loads(resp)["pois"][0]["name"], "图书馆ABC")

    def test_name_is_truncated_to_forty_characters(self):
        long_name = "图" * 100
        srv = _Server(fetcher=lambda url: (200, _ok_body([_one_poi(name=long_name)])))
        try:
            status, resp = _get(srv.port, PLACE)
        finally:
            srv.close()
        self.assertEqual(status, 200)
        name = json.loads(resp)["pois"][0]["name"]
        self.assertEqual(len(name), 40)
        self.assertEqual(name, "图" * 40)

    def test_coordinate_shaped_key_cannot_echo_through_location(self):
        # A synthetic key that IS a coordinate pair. Validating
        # alone would re-emit it as a point; the raw-string secret
        # strip must kill it, and the surviving POI stays.
        coord_key = "116.400000,39.900000"
        body = _ok_body(
            [
                _one_poi(name="假点", location=coord_key),
                _one_poi(name="真图书馆", location="116.401000,39.900900"),
            ]
        )
        srv = _Server(fetcher=lambda url: (200, body), api_key=coord_key)
        try:
            status, resp = _get(srv.port, PLACE)
        finally:
            srv.close()
        self.assertEqual(status, 200)
        self.assertNotIn(coord_key, resp.decode())
        pois = json.loads(resp)["pois"]
        self.assertEqual(len(pois), 1)
        self.assertEqual(pois[0]["name"], "真图书馆")
        self.assertEqual(pois[0]["location"], "116.401000,39.900900")


class PlaceAroundCoercionTest(unittest.TestCase):
    def test_junk_distance_becomes_zero_and_entry_is_kept(self):
        srv = _Server(
            fetcher=_RecordingFetcher(
                _ok_body([_one_poi(distance="abc")])
            )
        )
        try:
            status, resp = _get(srv.port, PLACE)
        finally:
            srv.close()
        self.assertEqual(status, 200)
        pois = json.loads(resp)["pois"]
        self.assertEqual(len(pois), 1)
        self.assertEqual(pois[0]["distance"], 0)
        self.assertIsInstance(pois[0]["distance"], int)

    def test_distance_is_bounded(self):
        srv = _Server(
            fetcher=_RecordingFetcher(_ok_body([_one_poi(distance="999999999")]))
        )
        try:
            status, resp = _get(srv.port, PLACE)
        finally:
            srv.close()
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(resp)["pois"][0]["distance"], 50_000)

    def test_poi_with_invalid_location_is_dropped_whole(self):
        srv = _Server(
            fetcher=_RecordingFetcher(
                _ok_body(
                    [
                        _one_poi(name="坏点1", location="999,999"),
                        _one_poi(name="坏点2", location="abc"),
                        _one_poi(name="坏点3", location="116.4"),
                        _one_poi(name="坏点4", location=None),
                        _one_poi(name="好图书馆", location="116.4,39.9"),
                    ]
                )
            )
        )
        try:
            status, resp = _get(srv.port, PLACE)
        finally:
            srv.close()
        self.assertEqual(status, 200)
        pois = json.loads(resp)["pois"]
        self.assertEqual([p["name"] for p in pois], ["好图书馆"])
        # Coordinates are rebuilt at 6 decimals, not copied.
        self.assertEqual(pois[0]["location"], "116.400000,39.900000")

    def test_poi_with_non_string_name_is_dropped_whole(self):
        srv = _Server(
            fetcher=_RecordingFetcher(
                _ok_body(
                    [
                        {"name": ["图书馆"], "location": "116.4,39.9",
                         "distance": "10"},
                        {"name": None, "location": "116.4,39.9",
                         "distance": "10"},
                        {"location": "116.4,39.9", "distance": "10"},
                        _one_poi(name="好图书馆"),
                    ]
                )
            )
        )
        try:
            status, resp = _get(srv.port, PLACE)
        finally:
            srv.close()
        self.assertEqual(status, 200)
        self.assertEqual(
            [p["name"] for p in json.loads(resp)["pois"]], ["好图书馆"]
        )

    def test_pois_are_truncated_to_ten(self):
        many = [_one_poi(name="图书馆%d" % i) for i in range(12)]
        srv = _Server(fetcher=_RecordingFetcher(_ok_body(many)))
        try:
            status, resp = _get(srv.port, PLACE)
        finally:
            srv.close()
        self.assertEqual(status, 200)
        pois = json.loads(resp)["pois"]
        self.assertEqual(len(pois), 10)
        self.assertEqual(pois[0]["name"], "图书馆0")
        self.assertEqual(pois[9]["name"], "图书馆9")

    def test_non_list_pois_is_a_generic_502(self):
        for bad in ({"pois": {"name": "x"}}, {"pois": "nope"}, {"pois": 7}):
            body = json.dumps(dict(bad, status="1")).encode()
            srv = _Server(fetcher=lambda url, b=body: (200, b))
            try:
                status, resp = _get(srv.port, PLACE)
            finally:
                srv.close()
            self.assertEqual(status, 502, bad)
            self.assertEqual(json.loads(resp), {"error": "upstream failure"})


class PlaceAroundFailureTest(unittest.TestCase):
    def test_upstream_exception_is_a_generic_502(self):
        def boom(url):
            raise RuntimeError("dial failed for " + url)

        srv = _Server(fetcher=boom)
        try:
            status, resp = _get(srv.port, PLACE)
        finally:
            srv.close()
        self.assertEqual(status, 502)
        # The upstream URL (which contains the key) never leaks.
        self.assertNotIn(AMAP_KEY, resp.decode())
        self.assertEqual(json.loads(resp), {"error": "upstream failure"})

    def test_non_json_upstream_body_is_a_generic_502(self):
        srv = _Server(
            fetcher=lambda url: (200, ("error page key=" + AMAP_KEY).encode())
        )
        try:
            status, resp = _get(srv.port, PLACE)
        finally:
            srv.close()
        self.assertEqual(status, 502)
        self.assertNotIn(AMAP_KEY, resp.decode())
        self.assertEqual(json.loads(resp), {"error": "upstream failure"})

    def test_pinned_upstream_is_an_invariant(self):
        # THE pin guard: with place_upstream redirected anywhere
        # else, the keyed URL must never be built or sent.
        fetcher = _RecordingFetcher(_ok_body([_one_poi()]))
        srv = _Server(
            fetcher=fetcher, place_upstream="https://evil.invalid/v3/place/around"
        )
        try:
            status, resp = _get(srv.port, PLACE)
        finally:
            srv.close()
        self.assertEqual(status, 502)
        self.assertEqual(fetcher.urls, [])  # no upstream call at all
        self.assertNotIn(AMAP_KEY, resp.decode())
        self.assertEqual(json.loads(resp), {"error": "upstream failure"})


class PlaceAroundValidationTest(unittest.TestCase):
    def test_invalid_location_is_400_without_upstream_call(self):
        fetcher = _RecordingFetcher(_ok_body([]))
        srv = _Server(fetcher=fetcher)
        try:
            for path in (
                _place_path(location=""),
                _place_path(location="abc"),
                _place_path(location="116.4"),
                _place_path(location="999,39.9"),
                "/place/around",
            ):
                status, resp = _get(srv.port, path)
                self.assertEqual(status, 400, path)
                self.assertEqual(
                    json.loads(resp),
                    {"error": "location must be 'lon,lat'"},
                    path,
                )
        finally:
            srv.close()
        self.assertEqual(fetcher.urls, [])

    def test_invalid_keywords_is_400_without_upstream_call(self):
        fetcher = _RecordingFetcher(_ok_body([]))
        srv = _Server(fetcher=fetcher)
        try:
            for path in (
                _place_path(keywords=""),
                _place_path(keywords="图" * 33),
                _place_path(keywords="图\u0000书馆"),
                _place_path(keywords="图\u200b书馆"),
                "/place/around?location=116.4,39.9",
            ):
                status, resp = _get(srv.port, path)
                self.assertEqual(status, 400, path)
                self.assertEqual(
                    json.loads(resp), {"error": "invalid keywords"}, path
                )
        finally:
            srv.close()
        self.assertEqual(fetcher.urls, [])

    def test_keywords_are_not_an_enum(self):
        # Any landmark the user names must be accepted: the safety
        # property comes from rebuilding the response, not from
        # restricting the word.
        for word in ("图书馆", "药店", "地铁站", "公共厕所", "银行"):
            fetcher = _RecordingFetcher(_ok_body([]))
            srv = _Server(fetcher=fetcher)
            try:
                status, _body = _get(srv.port, _place_path(keywords=word))
            finally:
                srv.close()
            self.assertEqual(status, 200, word)
            self.assertEqual(len(fetcher.urls), 1, word)

    def test_unknown_get_path_is_404(self):
        fetcher = _RecordingFetcher(_ok_body([]))
        srv = _Server(fetcher=fetcher)
        try:
            for path in ("/geocode?origin=116.4,39.9", "/place", "/place/around/x"):
                status, _body = _get(srv.port, path)
                self.assertEqual(status, 404, path)
        finally:
            srv.close()
        self.assertEqual(fetcher.urls, [])

    def test_walking_route_still_works(self):
        # The new route must not shadow (or break) /walking.
        walk_body = json.dumps(
            {"status": "1", "route": {"paths": [{"distance": "186"}]}}
        ).encode()
        srv = _Server(fetcher=_RecordingFetcher(walk_body))
        try:
            status, resp = _get(
                srv.port,
                "/walking?origin=116.4,39.9&destination=116.401,39.9009",
            )
        finally:
            srv.close()
        self.assertEqual(status, 200)
        self.assertEqual(
            json.loads(resp)["route"]["paths"][0]["distance"], 186
        )


if __name__ == "__main__":
    unittest.main()
