# -*- coding: utf-8 -*-
"""FC package tests: build_zip.sh must produce a zip that can
be uploaded to Function Compute as-is -- handler entry at the
root, no keys, no .env, no test files -- and the handler inside
the zip must actually import and answer (guard chain first, so
no network is touched)."""
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
FC_DIR = os.path.join(HERE, "fc")


class FcPackageTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="mingtu-fc-zip-")
        cls.zip_path = os.path.join(cls.tmp, "mingtu-fc.zip")
        result = subprocess.run(
            ["bash", os.path.join(FC_DIR, "build_zip.sh"), cls.zip_path],
            capture_output=True, text=True, timeout=60,
        )
        assert result.returncode == 0, result.stderr

    def test_zip_has_handler_entry_and_impl(self):
        with zipfile.ZipFile(self.zip_path) as zf:
            names = zf.namelist()
        self.assertIn("index.py", names)
        self.assertIn("amap_proxy.py", names)
        for name in names:
            self.assertFalse(name.endswith(".env"), name)
            self.assertNotIn(".env", name)
            self.assertFalse(name.startswith("test_"), name)
            self.assertNotIn("__pycache__", name)

    def test_zip_contains_no_key_material(self):
        key_like = re.compile(r"sk-[A-Za-z0-9]{8,}")
        with zipfile.ZipFile(self.zip_path) as zf:
            for name in zf.namelist():
                text = zf.read(name).decode("utf-8")
                self.assertIsNone(key_like.search(text), name)
                self.assertNotIn("fixture", text, name)

    def test_handler_inside_zip_imports_and_guards(self):
        extract = os.path.join(self.tmp, "unzipped")
        with zipfile.ZipFile(self.zip_path) as zf:
            zf.extractall(extract)
        os.environ["MINGTU_VISION_TOKEN"] = "pkg-test-token"
        try:
            spec = importlib.util.spec_from_file_location(
                "fc_pkg_index", os.path.join(extract, "index.py"))
            module = importlib.util.module_from_spec(spec)
            sys.path.insert(0, extract)
            try:
                spec.loader.exec_module(module)
            finally:
                sys.path.remove(extract)
            self.assertTrue(callable(module.handler))
            event = {
                "headers": {},
                "rawPath": "/vision",
                "body": json.dumps({"model": "qwen3.7-flash",
                                    "messages": []}),
                "isBase64Encoded": False,
            }
            resp = module.handler(event, None)
            # No token header -> the guard chain refuses BEFORE
            # any upstream network call.
            self.assertEqual(resp["statusCode"], 401)
            self.assertEqual(json.loads(resp["body"]),
                             {"error": "unauthorized"})
        finally:
            del os.environ["MINGTU_VISION_TOKEN"]


if __name__ == "__main__":
    unittest.main()
