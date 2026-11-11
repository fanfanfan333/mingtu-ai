# -*- coding: utf-8 -*-
"""Compatibility shim: the proxy implementation moved to
fc/amap_proxy.py (2026-11-09) so the Function Compute package
is a self-contained directory. This module loads that file and
re-exports its names, so the standalone server
(``python3 amap_proxy.py``) and the existing tests keep
working unchanged. Edit fc/amap_proxy.py, not this file.
"""
import importlib.util
import os
import sys

CORE_FILE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "fc", "amap_proxy.py"
)

_spec = importlib.util.spec_from_file_location("mingtu_proxy_core", CORE_FILE)
_core = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_core)

for _name, _value in list(vars(_core).items()):
    if not _name.startswith("__"):
        globals()[_name] = _value

__all__ = [n for n in globals() if not n.startswith("_")]

if __name__ == "__main__":
    sys.exit(_core.main())
