#!/usr/bin/env python3
"""Generate the NAVHAZ M1 replay fixtures (10 FPS, t_ms step 100).

Fixtures are synthetic geometry only -- no real sensor data.
Run: python3 test/fixtures/navhaz/gen_fixtures.py
"""
import json
import math
import os
import random

OUT = os.path.dirname(os.path.abspath(__file__))


def frame(t_ms, dets, pitch_deg=10.0, ego="still", gps_speed=0.0, expect=None):
    row = {
        "t_ms": t_ms,
        "dets": dets,
        "pitch_deg": pitch_deg,
        "ego": ego,
        "gps_speed": gps_speed,
    }
    if expect is not None:
        row["expect"] = expect
    return row


def det(label, conf, cx, cy, w, h):
    return {"label": label, "conf": conf, "cx": cx, "cy": cy, "w": w, "h": h}


def write(name, rows):
    with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(name, len(rows), "frames")


CAM_H = 1.3          # m, matches NavHazConfig.cameraHeightM
PITCH_DEG = 10.0
FY = 0.5 / math.tan(math.radians(30.0))  # VFOV 60 deg, normalised


def bottom_for_range(z_m):
    """Image-space bottom of a ground-contact object at range
    z_m, from the same ground-plane geometry the estimator
    inverts: depression = atan(H/Z); the optical axis sits
    PITCH_DEG below horizontal."""
    depression = math.degrees(math.atan(CAM_H / z_m))
    return 0.5 + FY * math.tan(math.radians(depression - PITCH_DEG))


def approaching(name, jitter=False, drop_at_ms=None, end_i=45):
    """Car dead ahead (cx=0.5) closing at a constant 2 m/s:
    Z(t) = Z0*(T-t)/T with Z0 = 12 m, T = 6 s, so the true
    TTC at time t is exactly 6 - t and the box scale follows
    s(t) = s0*T/(T-t). The box bottom is placed by the
    ground-plane law so scale TTC and range TTC agree.
    Runs t = 0 .. 4.5 s: TTC crosses [3,5] (W), [2.5,3.0]
    (U) and goes below 2 s."""
    s0, T, z0 = 0.08, 6.0, 12.0
    rng = random.Random(42)
    rows = []
    for i in range(0, end_i + 1):
        t = i / 10.0
        t_ms = i * 100
        if drop_at_ms is not None and t_ms == drop_at_ms:
            continue  # dropped frame: no line at all
        s = s0 * T / (T - t)
        if jitter:
            s *= 1.0 + (rng.random() * 2.0 - 1.0) * 0.08
        z = z0 * (T - t) / T
        bottom = bottom_for_range(z)
        cy = bottom - s / 2.0
        rows.append(frame(t_ms, [det("car", 0.9, 0.5, cy, s, s)],
                          expect="W first in TTC[3,5]; U first in TTC[2.5,3.0]"))
    write(name, rows)


def crossing():
    """Pedestrian crossing left->right in 2 s, constant size:
    extrapolated path crosses the corridor but the target is
    not closing and not in the corridor NOW -> 0 alerts."""
    rows = []
    for i in range(0, 21):
        t = i / 10.0
        cx = 0.1 + 0.4 * t
        rows.append(frame(i * 100,
                          [det("person", 0.9, cx, 0.5, 0.15, 0.3)],
                          expect="0 alerts"))
    write("crossing_pedestrian.jsonl", rows)


def side_pass():
    """Car closing like the approaching case but pinned at
    cx=0.9: box and extrapolated centre stay right of the
    corridor -> 0 alerts (in particular 0 urgent)."""
    s0, T, z0 = 0.08, 6.0, 12.0
    rows = []
    for i in range(0, 46):
        t = i / 10.0
        s = s0 * T / (T - t)
        z = z0 * (T - t) / T
        cy = bottom_for_range(z) - s / 2.0
        rows.append(frame(i * 100, [det("car", 0.9, 0.9, cy, s, s)],
                          expect="0 alerts"))
    write("side_pass_car.jsonl", rows)


def flicker():
    """Person ahead, static (ground range ~2.8 m at pitch
    10 deg): 1-frame / alternating / 2-frame appearances
    must produce nothing; once 3 CONSECUTIVE frames land
    (frames 10,11,12) exactly one W fires, then cooldown."""
    present = {0, 3, 5, 7, 8} | set(range(10, 30))
    rows = []
    for i in range(0, 30):
        dets = [det("person", 0.9, 0.5, 0.55, 0.2, 0.4)] if i in present else []
        rows.append(frame(i * 100, dets,
                          expect="0 alerts before t=1200; exactly 1 W at t=1200"))
    write("flicker_person.jsonl", rows)


if __name__ == "__main__":
    approaching("approaching_car.jsonl")
    # The jitter run stops at t = 4.0 s (true TTC 2.0): with
    # the 40%-TTC-drop re-alert rule, a longer tail would
    # legitimately re-alert in BOTH the clean and jitter
    # runs; the acceptance item for jitter pins exactly one
    # U, so its window ends where the drop from the first
    # U's TTC (~2.9) to the final TTC (2.0) is ~31% < 40%.
    approaching("jitter_car.jsonl", jitter=True, drop_at_ms=2000, end_i=40)
    crossing()
    side_pass()
    flicker()
