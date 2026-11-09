# -*- coding: utf-8 -*-
"""Alibaba Cloud Function Compute entry point (self-contained
package: this directory is the whole deployment).

Configure the function's handler as ``index.handler`` (see
../DEPLOY_FC.md). The implementation lives in amap_proxy.py in
this same directory -- Python standard library only, no
third-party dependencies -- so this folder can be zipped as-is
(or via build_zip.sh) and uploaded to FC directly.
"""
from amap_proxy import handler  # noqa: F401

__all__ = ["handler"]
