#!/usr/bin/env python3
"""Record a LIVE scrolling session on page.html and measure, per touch, how
long the page took to respond to the finger.

Unlike run.py nothing is posted: the user scrolls the bench page with the
real pad through the running RawTouch app. Two logs are captured at once —
the page's per-frame scrollY (via AppleScript, as run.py does) and the raw
touch frames from the pad (via scripts/raw-touch-monitor.swift, run
passively; the app's lease keeps frames flowing) — and aligned on the host
clock. For every touch that moved, the report gives the delay from the
first finger movement to the first scrollY change, plus what preceded it
(a rubber-band stretch at an edge, momentum still running), so a felt
"lockout" can be tied to its condition.

    bench/safari-bounce/record.py --seconds 60 [--monitor PATH] [--out DIR]
    bench/safari-bounce/record.py --analyze DIR      # re-run the analysis

Clock alignment: the page log's t is ms since window.__reset(); the reset
call is bracketed with CLOCK_UPTIME_RAW readings (an AppleScript round trip,
so only ±30-60 ms), then the analysis refines the offset by cross-correlating
finger displacement with page displacement over drags away from the edges
(it also picks the pad axis and sign that drive scrollY). The residual in
the reported latencies is the real finger-to-screen lag; page frames are
60 Hz, so latencies are ±17 ms.

What to look for: a re-scroll that begins while a bounce is still
settling (residual stretch > 0) must respond within a frame, like any
other. If it vanishes whole, momentum included, suspect a began whose
integer point delta is zero — Safari reads the integer delta, and a
zero-delta began never reaches WebKit's rubber-band controller (the
poster waits for a whole point for this reason). `run.py --catch-ramp`
reproduces that failure synthetically.
"""

import argparse
import csv
import json
import os
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import run  # noqa: E402  (ensure_page / js helpers)

DEFAULT_MONITOR = os.path.normpath(os.path.join(HERE, "..", "..", "scripts", "raw-touch-monitor.swift"))


def uptime_ns():
    return time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)


def start_monitor(path, out_dir):
    csv_path = os.path.join(out_dir, "frames.csv")
    err_path = os.path.join(out_dir, "monitor.err")
    proc = subprocess.Popen(
        ["swift", path],
        stdout=open(csv_path, "w"),
        stderr=open(err_path, "w"),
    )
    # The script compiles first; wait for its "monitoring" banner.
    for _ in range(600):
        time.sleep(0.1)
        with open(err_path) as f:
            if "monitoring" in f.read():
                return proc, csv_path
        if proc.poll() is not None:
            break
    proc.kill()
    sys.exit(f"monitor did not start; see {err_path}")


def align_page_clock(tries=8, good_ns=int(24e6)):
    """Reset the page log and return (offset_ns, uncertainty_ns) such that
    host_uptime_ns = offset_ns + page_t_ms * 1e6. The reset that counts is
    the last one, so retry until its AppleScript round trip is tight."""
    for _ in range(tries):
        t0 = uptime_ns()
        run.js("window.__reset()")
        t1 = uptime_ns()
        if t1 - t0 <= good_ns:
            break
    return (t0 + t1) // 2, (t1 - t0) // 2


def record(args):
    out_dir = args.out or os.path.join(
        os.environ.get("TMPDIR", "/tmp"), time.strftime("safari-live-%Y%m%d-%H%M%S"))
    os.makedirs(out_dir, exist_ok=True)
    run.ensure_page()
    max_y = int(float(run.js(
        "document.documentElement.scrollHeight - window.innerHeight")))
    proc, csv_path = start_monitor(args.monitor, out_dir)
    offset_ns, unc_ns = align_page_clock()
    meta = dict(offset_ns=offset_ns, uncertainty_ns=unc_ns, max_y=max_y,
                seconds=args.seconds, started_uptime_ns=uptime_ns())
    print(f"recording {args.seconds} s → {out_dir}  (page clock ±{unc_ns/1e6:.0f} ms, maxY {max_y})",
          flush=True)
    try:
        time.sleep(args.seconds)
    finally:
        page_log = json.loads(run.js("window.__dump()"))
        proc.send_signal(signal.SIGINT)
        try:
            proc.wait(3)
        except subprocess.TimeoutExpired:
            proc.kill()
    with open(os.path.join(out_dir, "page.json"), "w") as f:
        json.dump(page_log, f)
    with open(os.path.join(out_dir, "meta.json"), "w") as f:
        json.dump(meta, f)
    print(f"captured {len(page_log)} page frames, "
          f"{sum(1 for _ in open(csv_path))} pad frames", flush=True)
    analyze(out_dir, args)


def load_frames(path):
    rows = []
    with open(path) as f:
        for r in csv.reader(f):
            if len(r) >= 10 and r[0].isdigit():
                rows.append(dict(t=int(r[0]), dev=r[1], pad=int(r[2]), x=int(r[4]),
                                 y=int(r[5]), z=int(r[6]), flags=int(r[7]), seq=int(r[8])))
    rows.sort(key=lambda r: r["t"])
    return rows


def touches(frames, move_counts):
    """Split frames into touches per pad. Each: pad, t_down, t_move (first
    frame displaced >= move_counts from touch-down), t_up, path length."""
    out, cur = [], {}
    for fr in frames:
        pad = fr["pad"]
        touched = fr["flags"] & 1
        if touched:
            t = cur.get(pad)
            if t is None:
                t = cur[pad] = dict(pad=pad, t_down=fr["t"], x0=fr["x"], y0=fr["y"],
                                    t_move=None, t_up=None, path=0, last=(fr["x"], fr["y"]),
                                    n=1)
            else:
                t["path"] += abs(fr["x"] - t["last"][0]) + abs(fr["y"] - t["last"][1])
                t["last"] = (fr["x"], fr["y"])
                t["n"] += 1
                if t["t_move"] is None and (abs(fr["x"] - t["x0"]) + abs(fr["y"] - t["y0"])) >= move_counts:
                    t["t_move"] = fr["t"]
        else:
            t = cur.pop(pad, None)
            if t is not None:
                t["t_up"] = fr["t"]
                out.append(t)
    for t in cur.values():
        t["t_up"] = None
        out.append(t)
    out.sort(key=lambda t: t["t_down"])
    return out


def scroll_axis_and_alignment(frames, ps, max_y, meta):
    """Pick the pad axis/sign that drives scrollY and the clock offset that
    best aligns finger motion with page motion, by cross-correlating finger
    displacement with page displacement over drags away from the edges.
    Returns (axis, sign, extra_offset_ns, corr)."""
    import bisect
    ft = [f["t"] for f in frames]
    best = None
    inner = [(t, y) for t, y in ps if 5 < y < max_y - 5]
    for axis in ("x", "y"):
        for sign in (1, -1):
            for d_ms in range(-200, 201, 2):
                d = int(d_ms * 1e6)
                xs, ys = [], []
                for i in range(1, len(inner)):
                    t1, y1 = inner[i]
                    t0, y0 = inner[i - 1]
                    if t1 - t0 > int(40e6):
                        continue
                    a = bisect.bisect_left(ft, t0 - d)
                    b = bisect.bisect_left(ft, t1 - d)
                    if a == 0 or b >= len(frames) or b <= a:
                        disp = 0
                    else:
                        fa, fb = frames[a - 1], frames[b - 1]
                        if not (fa["flags"] & 1 and fb["flags"] & 1) or fa["pad"] != fb["pad"]:
                            disp = 0
                        else:
                            disp = sign * (fb[axis] - fa[axis])
                    xs.append(disp)
                    ys.append(y1 - y0)
                n = len(xs)
                if n < 20:
                    continue
                mx, my = sum(xs) / n, sum(ys) / n
                sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
                sxx = sum((x - mx) ** 2 for x in xs)
                syy = sum((y - my) ** 2 for y in ys)
                if sxx == 0 or syy == 0:
                    continue
                c = sxy / (sxx * syy) ** 0.5
                if best is None or c > best[3]:
                    best = (axis, sign, d, c)
    return best


def analyze(out_dir, args):
    meta = json.load(open(os.path.join(out_dir, "meta.json")))
    page = json.load(open(os.path.join(out_dir, "page.json")))
    frames = load_frames(os.path.join(out_dir, "frames.csv"))
    off, max_y = meta["offset_ns"], meta["max_y"]
    ps = [(off + int(t * 1e6), y) for t, y in page]
    if not ps or not frames:
        print("nothing to analyze (page frames %d, pad frames %d)" % (len(ps), len(frames)))
        return
    axis, sign, extra, corr = scroll_axis_and_alignment(frames, ps, max_y, meta)
    # Shift the page clock so that finger motion and page motion line up;
    # the residual in the latencies below is the real finger->screen lag.
    ps = [(t + extra, y) for t, y in ps]
    t_start = ps[0][0]
    ms = lambda ns: (ns - t_start) / 1e6

    def page_index_at(t_ns):
        lo, hi = 0, len(ps)
        while lo < hi:
            mid = (lo + hi) // 2
            if ps[mid][0] < t_ns:
                lo = mid + 1
            else:
                hi = mid
        return lo

    def stretch_at(t_ns):
        i = page_index_at(t_ns)
        y = ps[max(i - 1, 0)][1]
        return -y if y < 0 else (y - max_y if y > max_y else 0)

    def last_edge_before(t_ns, lookback_ns):
        i = page_index_at(t_ns)
        j = page_index_at(t_ns - lookback_ns)
        best = None
        for k in range(i - 1, j - 1, -1):
            t, y = ps[k]
            if y < 0 or y > max_y:
                if best is None:
                    best = dict(t_end=t, stretch=0, t_hit=t)
                best["t_hit"] = t
                best["stretch"] = max(best["stretch"], -y if y < 0 else y - max_y)
            elif best is not None:
                break
        return best

    tl = touches(frames, args.move_counts)
    # Signed finger travel along the scroll axis, in the page's direction.
    by_touch = {}
    for fr in frames:
        if fr["flags"] & 1:
            by_touch.setdefault(fr["pad"], []).append(fr)
    print(f"\npage frames {len(ps)} over {ms(ps[-1][0])/1e3:.1f} s, pad frames {len(frames)}, "
          f"touches {len(tl)}, maxY {max_y}")
    print(f"scroll axis = pad {axis} (sign {sign:+d}); clock aligned by cross-correlation "
          f"(r={corr:.2f}, shift {extra/1e6:+.0f} ms vs the AppleScript bracket, which was ±{meta['uncertainty_ns']/1e6:.0f} ms)")
    print(f"{'#':>3} {'down@':>7} {'dur':>5} {'travel':>7} {'dir':>4} {'y@move':>7} {'stretch@move':>12} {'edge→move':>9} "
          f"{'move→resp':>9} {'applied':>8}  note")
    rows = []
    for n, t in enumerate(tl, 1):
        # frames of this touch
        fr = [f for f in frames if f["pad"] == t["pad"] and t["t_down"] <= f["t"] <= (t["t_up"] or f["t"]) and f["flags"] & 1]
        travel = sign * (fr[-1][axis] - fr[0][axis]) if len(fr) > 1 else 0
        scroll_mode = sum(1 for f in fr if f["flags"] & 2) / max(len(fr), 1)
        dur = (t["t_up"] - t["t_down"]) / 1e6 if t["t_up"] else float("nan")
        if t["t_move"] is None or abs(travel) < args.move_counts:
            print(f"{n:>3} {ms(t['t_down']):>7.0f} {dur:>5.0f} {travel:>7} {'-':>4} {'-':>7} {'-':>12} {'-':>9} {'-':>9} {'-':>8}  no movement")
            continue
        direction = 1 if travel > 0 else -1   # +1 = scrollY increases (away from the top edge)
        i = page_index_at(t["t_move"])
        y_move = ps[max(i - 1, 0)][1]
        st = stretch_at(t["t_move"])
        edge = last_edge_before(t["t_move"], int(2.5e9))
        edge_to_move = (t["t_move"] - edge["t_hit"]) / 1e6 if edge else None
        # Response: the page moves in the finger's direction *beyond* any
        # stretch unwinding — i.e. it leaves the edge band (y in [0, maxY])
        # heading the finger's way, or, off the edge, simply moves that way.
        t_limit = (t["t_up"] or t["t_move"]) + int(400e6)
        resp = None
        y_prev = y_move
        for k in range(i, len(ps)):
            tk, yk = ps[k]
            if tk > t_limit:
                break
            dy = yk - y_prev
            in_band = 0 <= yk <= max_y
            if dy * direction > 0 and in_band and (0 <= y_prev <= max_y or (yk - (0 if direction > 0 else max_y)) * direction >= 1):
                resp = tk
                break
            y_prev = yk
        # applied: page travel in the finger's direction until 400 ms after lift
        seg = [y for tk, y in ps if t["t_move"] <= tk <= t_limit]
        applied = (max(seg) - y_move) if direction > 0 else (y_move - min(seg)) if seg else 0
        resp_ms = (resp - t["t_move"]) / 1e6 if resp else None
        note = ""
        into_edge = (direction < 0 and y_move <= 0) or (direction > 0 and y_move >= max_y)
        if into_edge:
            note = "pushes INTO the edge (no response expected)"
        elif resp_ms is None:
            note = "NO RESPONSE"
        elif resp_ms > args.slow_ms:
            note = f"SLOW"
        if scroll_mode < 0.9:
            note += f" (scroll-mode only {scroll_mode:.0%} of frames)"
        rows.append(dict(n=n, into=into_edge, resp=resp_ms, stretch=st, edge_to_move=edge_to_move, applied=applied))
        print(f"{n:>3} {ms(t['t_down']):>7.0f} {dur:>5.0f} {travel:>+7} {('down' if direction > 0 else 'up'):>4} {y_move:>7} "
              f"{st:>12} {(f'{edge_to_move:.0f} ms' if edge_to_move is not None else '-'):>9} "
              f"{(f'{resp_ms:.0f} ms' if resp_ms is not None else 'none'):>9} {applied:>6} px  {note}")
    catches = [r for r in rows if not r["into"] and r["edge_to_move"] is not None and r["edge_to_move"] < 1500]
    if catches:
        print("\nre-scrolls after a bounce (catch within 1.5 s of the edge hit):")
        print(f"{'#':>3} {'edge→move':>9} {'stretch@move':>12} {'move→resp':>9} {'applied':>8}")
        for r in sorted(catches, key=lambda r: r["edge_to_move"]):
            print(f"{r['n']:>3} {r['edge_to_move']:>7.0f} ms {r['stretch']:>9} px {(f'{r['resp']:.0f} ms' if r['resp'] is not None else 'none'):>9} {r['applied']:>5} px")
    if args.dump:
        for t, y in ps:
            print(f"{ms(t):9.1f} {y}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--seconds", type=int, default=60)
    p.add_argument("--monitor", default=DEFAULT_MONITOR)
    p.add_argument("--out", help="capture directory (default: $TMPDIR/safari-live-<stamp>)")
    p.add_argument("--analyze", metavar="DIR", help="re-analyze an existing capture")
    p.add_argument("--move-counts", type=int, default=4,
                   help="pad displacement from touch-down that counts as 'the finger moved'")
    p.add_argument("--slow-ms", type=float, default=100,
                   help="flag a touch whose move→response exceeds this")
    p.add_argument("--dump", action="store_true", help="also print the aligned page log")
    args = p.parse_args()
    if args.analyze:
        analyze(args.analyze, args)
    else:
        record(args)


if __name__ == "__main__":
    main()
