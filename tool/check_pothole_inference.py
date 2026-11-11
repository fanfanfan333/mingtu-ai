#!/usr/bin/env python3
"""Run the pothole model once on a generated fixture image, on
this machine (NAVHAZ M3, COMMIT23 evidence item E1).

Purpose: prove the fetched weight (assets/models/pothole/
pothole2v.tflite, SHA256-verified by tool/fetch_pothole_model.sh)
actually loads and invokes in a stock TFLite runtime, and pin
its real I/O contract (tensor shapes / dtypes as the interpreter
reports them -- not as any document claims). This says NOTHING
about detection accuracy: the input is a synthetic fixture
(grey field, one dark ellipse), and the numbers reported are
shapes, value ranges and wall-clock time only.

Out-of-repo dependencies (install into a scratch venv, they are
NOT project dependencies):
    pip install ai-edge-litert        # preferred, Apache-2.0
    # or: pip install tflite-runtime  # fallback, Apache-2.0
plus numpy (pulled in by either runtime).

Usage:
    python3 tool/check_pothole_inference.py [model-path]
Exit code 0 = the model loaded and invoked cleanly.
"""

import importlib.metadata
import statistics
import sys
import time

import numpy as np


def load_interpreter(path):
    """Return (Interpreter class, runtime description)."""
    try:
        from ai_edge_litert.interpreter import Interpreter

        try:
            ver = importlib.metadata.version("ai-edge-litert")
        except importlib.metadata.PackageNotFoundError:
            ver = "unknown"
        return Interpreter, f"ai-edge-litert {ver}"
    except ImportError:
        pass
    try:
        from tflite_runtime.interpreter import Interpreter

        try:
            ver = importlib.metadata.version("tflite-runtime")
        except importlib.metadata.PackageNotFoundError:
            ver = "unknown"
        return Interpreter, f"tflite-runtime {ver}"
    except ImportError:
        pass
    raise SystemExit(
        "ERROR: no TFLite runtime available. Install one of:\n"
        "  pip install ai-edge-litert\n"
        "  pip install tflite-runtime"
    )


def fixture_image(height, width):
    """A 320x320 RGB fixture: mid-grey road, one dark ellipse
    low-centre (a pothole-shaped shadow). Pure numpy -- the
    point is exercising the model, not recognising anything."""
    img = np.full((height, width, 3), 170, dtype=np.uint8)
    yy, xx = np.mgrid[0:height, 0:width]
    ellipse = ((xx - width * 0.5) / (width * 0.22)) ** 2 + (
        (yy - height * 0.72) / (height * 0.10)
    ) ** 2 <= 1.0
    img[ellipse] = 55
    return img


def main():
    model_path = (
        sys.argv[1]
        if len(sys.argv) > 1
        else "assets/models/pothole/pothole2v.tflite"
    )
    interpreter_cls, runtime_name = load_interpreter(model_path)
    interp = interpreter_cls(model_path=model_path)
    interp.allocate_tensors()

    in_detail = interp.get_input_details()[0]
    out_details = interp.get_output_details()
    in_shape = [int(d) for d in in_detail["shape"]]
    print(f"runtime        : {runtime_name}")
    print(f"model          : {model_path}")
    print(f"input tensor   : shape={in_shape} dtype={in_detail['dtype']}")
    for od in out_details:
        print(
            f"output tensor  : shape={[int(d) for d in od['shape']]} "
            f"dtype={od['dtype']}"
        )

    # Build the input in the layout the interpreter asks for.
    if len(in_shape) == 4 and in_shape[1] == 3:
        height, width = in_shape[2], in_shape[3]
        img = fixture_image(height, width).transpose(2, 0, 1)[None]
    elif len(in_shape) == 4 and in_shape[3] == 3:
        height, width = in_shape[1], in_shape[2]
        img = fixture_image(height, width)[None]
    else:
        raise SystemExit(f"ERROR: unexpected input shape {in_shape}")

    dtype = in_detail["dtype"]
    if dtype == np.float32:
        data = img.astype(np.float32) / 255.0
    elif dtype == np.uint8:
        data = img.astype(np.uint8)
    elif dtype == np.int8:
        data = (img.astype(np.int16) - 128).astype(np.int8)
    else:
        raise SystemExit(f"ERROR: unhandled input dtype {dtype}")
    interp.set_tensor(in_detail["index"], data)

    for _ in range(3):  # warm-up, untimed
        interp.invoke()
    times_ms = []
    for _ in range(25):
        start = time.perf_counter()
        interp.invoke()
        times_ms.append((time.perf_counter() - start) * 1000.0)

    out = interp.get_tensor(out_details[0]["index"])
    finite = bool(np.isfinite(out).all())
    print(f"invoke median  : {statistics.median(times_ms):.1f} ms "
          f"(25 runs, min {min(times_ms):.1f}, max {max(times_ms):.1f})")
    print(f"output[0]      : shape={list(out.shape)} finite={finite} "
          f"min={float(out.min()):.4f} max={float(out.max()):.4f}")
    if out.ndim == 3 and out.shape[1] >= 6:
        # YOLO head layout [1, 4 box + N class, anchors]: report
        # the best class score as a sanity value ONLY.
        scores = out[0, 4:, :]
        print(f"best class score (sanity only): {float(scores.max()):.4f}")
    if not finite:
        raise SystemExit("ERROR: output contains non-finite values")
    print("OK: model loaded and invoked; output tensor is finite.")


if __name__ == "__main__":
    main()
