# -*- coding: utf-8 -*-
"""Alibaba Cloud Function Compute entry point.

Configure the function's handler as ``index.handler`` (see
DEPLOY_FC.md). The implementation lives in amap_proxy.py so the
standalone server and the FC function share one code path:
token guard, rate caps, structured enum-only vision output.
"""
from amap_proxy import handler  # noqa: F401

__all__ = ["handler"]
