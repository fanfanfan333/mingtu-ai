#!/usr/bin/env python3
"""Contract tests for amap_proxy.py.

Everything runs on localhost with a fake upstream fetcher: NO real
API is ever called, and the "key" used here is a fixture string,
not a credential. Run: python3 -m unittest test_amap_proxy -v
(from this directory) or python3 -m unittest discover -s server.
"""

import io
import json
import os
import sys
import threading
import unittest
import unittest.mock
import urllib.error
import urllib.request
from contextlib import redirect_stderr

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import amap_proxy

FIXTURE_KEY = "fixture-key-not-a-real-credential"
AMAP_OK = json.dumps(
    {"status": "1", "info": "OK", "route": {"paths": [{"distance": "186"}]}}
).encode()


class CapturingFetcher:
    def __init__(self):
        self.urls = []

    def __call__(self, url):
        self.urls.append(url)
        return 200, AMAP_OK


def _get(port, path):
    try:
        with urllib.request.urlopen(
            "http://127.0.0.1:%d%s" % (port, path), timeout=5
        ) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


class ProxyContractTest(unittest.TestCase):
    def setUp(self):
        self.fetcher = CapturingFetcher()
        self.logs = io.StringIO()
        self._stderr_cm = redirect_stderr(self.logs)
        self._stderr_cm.__enter__()
        self.server = amap_proxy.make_server(
            0, FIXTURE_KEY, fetcher=self.fetcher
        )
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.daemon = True
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self._stderr_cm.__exit__(None, None, None)

    def test_walking_passthrough_and_key_added_server_side(self):
        status, body = _get(
            self.port,
            "/walking?origin=116.400000,39.900000&destination=116.401000,39.900900",
        )
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["status"], "1")
        # The upstream request carried the key; the client never sent one.
        self.assertEqual(len(self.fetcher.urls), 1)
        upstream = self.fetcher.urls[0]
        self.assertIn("key=" + FIXTURE_KEY, upstream)
        self.assertIn("origin=116.400000%2C39.900000", upstream)
        # The key never comes back to the client...
        self.assertNotIn(FIXTURE_KEY, body.decode())
        # ...and never reaches the proxy's own log (paths only).
        self.assertNotIn(FIXTURE_KEY, self.logs.getvalue())

    def test_client_needs_no_key_parameter(self):
        # A client request WITH a stray key parameter is not how the
        # contract works; the proxy ignores client-supplied params
        # beyond origin/destination and always uses its own key.
        status, _body = _get(
            self.port,
            "/walking?origin=116.4,39.9&destination=116.401,39.9009&key=client-junk",
        )
        self.assertEqual(status, 200)
        self.assertIn("key=" + FIXTURE_KEY, self.fetcher.urls[0])
        self.assertNotIn("client-junk", self.fetcher.urls[0])

    def test_invalid_coordinates_rejected_without_upstream_call(self):
        for path in (
            "/walking",
            "/walking?origin=abc&destination=116.4,39.9",
            "/walking?origin=116.4,39.9",
            "/walking?origin=999,39.9&destination=116.4,39.9",
        ):
            status, _ = _get(self.port, path)
            self.assertEqual(status, 400, path)
        self.assertEqual(self.fetcher.urls, [])

    def test_unknown_path_404(self):
        status, _ = _get(self.port, "/geocode?origin=116.4,39.9")
        self.assertEqual(status, 404)
        self.assertEqual(self.fetcher.urls, [])

    def test_upstream_failure_is_generic_502(self):
        def boom(url):
            raise RuntimeError("dial failed for " + url)

        server = amap_proxy.make_server(0, FIXTURE_KEY, fetcher=boom)
        port = server.server_address[1]
        t = threading.Thread(target=server.serve_forever)
        t.daemon = True
        t.start()
        try:
            status, body = _get(
                port, "/walking?origin=116.4,39.9&destination=116.401,39.9009"
            )
        finally:
            server.shutdown()
            server.server_close()
        self.assertEqual(status, 502)
        # The upstream URL (which contains the key) must not leak
        # into the client-facing error.
        self.assertNotIn(FIXTURE_KEY, body.decode())


class StartupContractTest(unittest.TestCase):
    def test_missing_env_key_fails_fast(self):
        env = dict(os.environ)
        env.pop("AMAP_WEB_KEY", None)
        logs = io.StringIO()
        with unittest.mock.patch.dict(os.environ, env, clear=True):
            with redirect_stderr(logs):
                rc = amap_proxy.main()
        self.assertEqual(rc, 1)
        self.assertIn("AMAP_WEB_KEY", logs.getvalue())


if __name__ == "__main__":
    unittest.main()
