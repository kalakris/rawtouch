#!/usr/bin/env python3
"""Validate the lift-off strength floor (momentum.liftStrengthFloor) for a
pad from a raw-touch-monitor capture, so the floor can be checked on any
pad, overlay or sensitivity rather than trusted from the one it was
tuned on.

    bench/lift-strength.py capture.csv [more.csv ...] [--pad N]

Per pad, three views of the last 100 ms before every release:

1. The strength profile: how strength (z) relative to the touch's
   reference (its 75th percentile) behaves in the body of a touch versus
   its last 100 ms. A floor is safe where the body's low percentiles sit
   above the floor and the tail's do not.
2. Motion versus strength: the final frames binned by relative strength,
   each frame's velocity compared with the finger's velocity 50-150 ms
   earlier. The floor belongs where the along-track ratio starts falling
   and the cross-track error starts rising.
3. Per candidate floor: how often a full-contact frame is dropped (a
   dropped frame followed by a kept one), how often the floor finds too
   few frames and falls back, and how the seed moves relative to the
   default floor.

On a Go60's Cirque pads (61 recorded touches): body strength ≥ 0.63
for 95% of frames, motion trustworthy down to ~0.5-0.6, seed flat for
floors 0.5-0.7, so 0.6. A pad that looks different here wants a
different floor - or, if its strength does not track contact area at
all, the floor off (0).
"""
import argparse
import csv
import math
import statistics as st

FLOORS = [0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
DEFAULT_FLOOR = 0.6
FIT_WINDOW = 0.1
REACH_WINDOW = 0.2
WEIGHT_TAU = 0.03


def pct(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, int(p * len(values)))] if values else float("nan")


def touches(path, pads):
    """Touched runs per pad: lists of (device time, x, y, z)."""
    rows = list(csv.DictReader(open(path)))
    out = {}
    for pad in sorted({r["pad"] for r in rows}):
        if pads and int(pad) not in pads:
            continue
        current, last, unwrapped = [], None, 0
        for r in (r for r in rows if r["pad"] == pad):
            ticks = int(r["ts_ticks"])
            unwrapped = ticks if last is None else unwrapped + (ticks - last) % 65536
            last = ticks
            if int(r["flags"]) & 1:
                current.append((unwrapped * 1e-4, int(r["x"]), int(r["y"]), int(r["z"])))
            else:
                if len(current) >= 30:
                    out.setdefault(int(pad), []).append(current)
                current = []
    return out


def weighted_slope(points):
    if len(points) < 2:
        return None
    t_end = points[-1][0]
    weights = [math.exp(-(t_end - t) / WEIGHT_TAU) for t, _ in points]
    total = sum(weights)
    mean_t = sum(w * t for (t, _), w in zip(points, weights)) / total
    mean_v = sum(w * v for (_, v), w in zip(points, weights)) / total
    variance = sum(w * (t - mean_t) ** 2 for (t, _), w in zip(points, weights))
    if variance < 1e-9:
        return None
    return sum(w * (t - mean_t) * (v - mean_v) for (t, v), w in zip(points, weights)) / variance


def seed(run, floor):
    """The lift-off speed the engine would fit at this floor (counts/s)."""
    z = [p[3] for p in run]
    reference = pct(z, 0.75)
    t_end = run[-1][0]
    recent = [p for p in run if t_end - p[0] <= FIT_WINDOW]

    def fits(candidates):
        return len(candidates) >= 2 and candidates[-1][0] - candidates[0][0] >= 0.005

    chosen = recent
    if floor > 0:
        strong = [p for p in recent if p[3] >= floor * reference]
        if fits(strong):
            chosen = strong
        else:
            reached = [p for p in run if t_end - p[0] <= REACH_WINDOW and p[3] >= floor * reference]
            chosen = reached if fits(reached) else recent
    vx = weighted_slope([(p[0], p[1]) for p in chosen])
    vy = weighted_slope([(p[0], p[2]) for p in chosen])
    return None if vx is None or vy is None else math.hypot(vx, vy)


def report(pad, runs):
    print(f"\n== pad {pad}: {len(runs)} touches of 30+ frames")

    body, tail = [], []
    for run in runs:
        reference = pct([p[3] for p in run], 0.75)
        t_end = run[-1][0]
        for p in run:
            if p[0] - run[0][0] < 0.05:
                continue
            (tail if t_end - p[0] <= 0.1 else body).append(p[3] / reference)
    print("strength / reference (the touch's 75th percentile):")
    print(f"  body (after the first 50 ms, before the last 100 ms), n={len(body)}: "
          f"p1 {pct(body, 0.01):.2f}  p5 {pct(body, 0.05):.2f}  p10 {pct(body, 0.1):.2f}  p50 {pct(body, 0.5):.2f}")
    print(f"  last 100 ms, n={len(tail)}: p10 {pct(tail, 0.1):.2f}  p25 {pct(tail, 0.25):.2f}  "
          f"p50 {pct(tail, 0.5):.2f}  p75 {pct(tail, 0.75):.2f}")

    bins = [(0, 0.2), (0.2, 0.3), (0.3, 0.4), (0.4, 0.5), (0.5, 0.6), (0.6, 0.7), (0.7, 0.8), (0.8, 0.9), (0.9, 1.1), (1.1, 9)]
    along = {b: [] for b in bins}
    across = {b: [] for b in bins}
    for run in runs:
        reference = pct([p[3] for p in run], 0.75)
        t_end = run[-1][0]
        earlier = [p for p in run if 0.05 <= t_end - p[0] <= 0.15]
        if len(earlier) < 4:
            continue
        span = earlier[-1][0] - earlier[0][0]
        vx = (earlier[-1][1] - earlier[0][1]) / span
        vy = (earlier[-1][2] - earlier[0][2]) / span
        v_ref = math.hypot(vx, vy)
        if v_ref < 300:
            continue
        for i in range(1, len(run)):
            p, q = run[i - 1], run[i]
            dt = q[0] - p[0]
            if t_end - q[0] > 0.1 or dt <= 0:
                continue
            ux, uy = (q[1] - p[1]) / dt, (q[2] - p[2]) / dt
            ratio = q[3] / reference
            for b in bins:
                if b[0] <= ratio < b[1]:
                    along[b].append((ux * vx + uy * vy) / v_ref / v_ref)
                    across[b].append(abs(ux * vy - uy * vx) / v_ref / v_ref)
    print("motion in the last 100 ms vs the finger's motion 50-150 ms earlier (moving touches):")
    print(f"  {'z/ref':>9} {'n':>5}   along-track ratio p25/p50/p75   cross-track p50/p90")
    for b in bins:
        v, d = along[b], across[b]
        if len(v) < 8:
            continue
        print(f"  {b[0]:3.1f}-{b[1]:<3.1f} {len(v):5d}     {pct(v, .25):5.2f} / {pct(v, .5):5.2f} / {pct(v, .75):5.2f}        "
              f"{pct(d, .5):5.2f} / {pct(d, .9):5.2f}")

    print("per floor: false drops (a dropped frame followed by a kept one), fallbacks (too few frames even reaching back 200 ms),")
    print(f"           and the seed relative to the {DEFAULT_FLOOR} floor on fast lifts")
    for floor in FLOORS:
        false_drops = fallbacks = 0
        ratios = []
        for run in runs:
            reference = pct([p[3] for p in run], 0.75)
            t_end = run[-1][0]
            window = [p for p in run if t_end - p[0] <= FIT_WINDOW]
            kept = [p[3] >= floor * reference for p in window]
            if any(not k and any(kept[i + 1:]) for i, k in enumerate(kept)):
                false_drops += 1
            reached = [p for p in run if t_end - p[0] <= REACH_WINDOW and p[3] >= floor * reference]
            if len(reached) < 2 or reached[-1][0] - reached[0][0] < 0.005:
                fallbacks += 1
            base = seed(run, DEFAULT_FLOOR)
            this = seed(run, floor)
            if base and this and base >= 300:
                ratios.append(this / base)
        spread = (f"median {st.median(ratios):.2f}  p10 {pct(ratios, .1):.2f}  p90 {pct(ratios, .9):.2f}"
                  if ratios else "n/a")
        print(f"  floor {floor:.1f}: false drops {false_drops:3d}/{len(runs)}   fallbacks {fallbacks:3d}/{len(runs)}   seed {spread}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("captures", nargs="+")
    parser.add_argument("--pad", type=int, action="append", help="pad(s) to analyse (default: all)")
    args = parser.parse_args()
    merged = {}
    for path in args.captures:
        for pad, runs in touches(path, args.pad or []).items():
            merged.setdefault(pad, []).extend(runs)
    if not merged:
        raise SystemExit("no touches of 30+ frames found")
    for pad in sorted(merged):
        report(pad, merged[pad])


if __name__ == "__main__":
    main()
