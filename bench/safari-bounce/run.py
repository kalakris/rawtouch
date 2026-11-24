#!/usr/bin/env python3
"""Safari rubber-band bench: how soon after a flick hits the page edge does a
re-scroll register again?

Drives scroll-bench (the real RawTouch pipeline + poster, synthetic frames)
against page.html in Safari and reads the page's per-frame scrollY log back
through AppleScript. One row per re-scroll delay: when the edge was hit, how
much of the re-scroll the page actually applied, and how long after the edge
it started responding.

Setup (once): Safari → Develop → Developer Settings → "Allow JavaScript from
Apple Events"; approve the Automation prompt on first run; keep the Safari
window on the display under test; hands off the pads while it runs.

    swift build -c release --product scroll-bench
    bench/safari-bounce/run.py                     # default sweep
    bench/safari-bounce/run.py --delays 200,400,800 --repeat 3
    bench/safari-bounce/run.py --latency 8               # a stated display-sync latency
"""
import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PAGE_URL = "file://" + os.path.join(HERE, "page.html")


def osa(*lines):
    args = ["osascript"]
    for line in lines:
        args += ["-e", line]
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout.strip()


def js(code):
    return subprocess.run(
        ["osascript", "-e", "on run argv",
         "-e", 'tell application "Safari" to do JavaScript (item 1 of argv) in document 1',
         "-e", "end run", code],
        capture_output=True, text=True, check=True,
    ).stdout.strip()


def ensure_page():
    osa('tell application "Safari" to activate')
    try:
        url = osa('tell application "Safari" to get URL of document 1')
    except subprocess.CalledProcessError:
        url = ""
    if "page.html" not in url:
        osa(f'tell application "Safari" to make new document with properties {{URL:"{PAGE_URL}"}}')
        time.sleep(1.5)
    probe = js("typeof window.__dump")
    if probe != "function":
        sys.exit("page.html is not instrumented — is 'Allow JavaScript from Apple Events' on?")


def window_center():
    bounds = osa('tell application "Safari" to get bounds of window 1')
    x1, y1, x2, y2 = [int(v) for v in bounds.split(", ")]
    return (x1 + x2) / 2, (y1 + y2) / 2


SYNC_ARGS = []


def run_bench(binary, center, extra):
    cmd = [binary, "--cursor", f"{center[0]:.0f},{center[1]:.0f}"] + SYNC_ARGS + extra
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"scroll-bench failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout.strip()


def read_log():
    return json.loads(js("window.__dump()"))


def flick_direction(binary, center, flick, scale):
    """Which way does a positive flick move the page? Returns +1 if it scrolls
    toward the top edge (scrollY decreases), else -1."""
    js("window.__reset(5000)")
    time.sleep(0.2)
    # A moderate probe: a very fast flick can bounce off the far edge and
    # invert the answer.
    flick = max(10, min(abs(flick), 40))
    run_bench(binary, center, ["--flick", str(flick), "--flick-frames", "6",
                               "--scale", str(scale), "--no-catch", "--decay", "0.2"])
    time.sleep(0.3)
    log = read_log()
    return 1 if log[-1][1] < 5000 else -1


def measure(log, start, expected):
    """From the per-frame log: edge hit time, how far above the edge the
    page ended (the re-scroll moves away from the edge, so this is what the
    re-scroll actually applied), and how long after the edge it started
    responding. Safari reports the rubber-band stretch as negative scrollY;
    it is ignored here — the page returns to 0 on its own."""
    t_move = next((t for t, y in log if y != start), None)
    t_edge = next((t for t, y in log if y <= 0), None)
    if t_edge is None:
        return dict(t_move=t_move, t_edge=None, response=0, latency=None, final=log[-1][1])
    after = [(t, y) for t, y in log if t >= t_edge]
    final = log[-1][1]
    stretch = -min(y for _, y in after)
    t_respond = next((t for t, y in after if y > 2), None)
    # Residual stretch when the catch's first movement lands (the page is
    # still snapping back if this is nonzero): the trajectory's y just
    # before t_catch, if the caller knows it.
    return dict(
        t_move=t_move, t_edge=t_edge, response=max(final, 0), final=final, stretch=stretch,
        latency=(t_respond - t_edge) if t_respond is not None else None, log=log,
    )


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--bin", default=os.path.join(HERE, "..", "..", ".build", "release", "scroll-bench"))
    p.add_argument("--delays", default="100,200,300,500,750,1000,1500,2000,3000",
                   help="release→catch delays in ms")
    p.add_argument("--start", type=int, default=250, help="starting scrollY (px); the flick must reach 0")
    p.add_argument("--flick", type=int, default=40, help="flick speed, counts/frame")
    p.add_argument("--flick-frames", type=int, default=12)
    p.add_argument("--flick-settle", type=int, default=0,
                   help="hold this long (ms) before the flick's lift so it carries no momentum: a plain drag into the edge")
    p.add_argument("--catch-rest", type=int, default=0,
                   help="hold still this long (ms) after the catch's touch-down before the re-scroll moves, like a landing finger")
    p.add_argument("--catch-ramp", action="store_true",
                   help="ramp the re-scroll up from 1 count/frame, doubling, like a finger starting from rest (sub-pixel first deltas)")
    p.add_argument("--rescroll", type=int, default=30, help="re-scroll speed, counts/frame (away from the edge)")
    p.add_argument("--rescroll-frames", type=int, default=20)
    p.add_argument("--scale", type=float, default=0.25)
    p.add_argument("--decay", type=float, default=0.83)
    p.add_argument("--repeat", type=int, default=1)
    p.add_argument("--warmup", type=int, default=2,
                   help="throwaway runs before measuring: the operator is often still moving the mouse when a sweep starts")
    p.add_argument("--latency", type=float, default=None,
                   help="display-sync latency in ms (default: scroll-bench's own)")
    args = p.parse_args()

    if args.latency is not None:
        SYNC_ARGS.extend(["--latency", str(args.latency)])

    if not os.path.exists(args.bin):
        sys.exit(f"missing {args.bin}: swift build -c release --product scroll-bench")

    ensure_page()
    center = window_center()
    for _ in range(args.warmup):
        js("window.__reset(3000)")
        time.sleep(0.25)
        run_bench(args.bin, center, ["--flick", "20", "--flick-frames", "6", "--no-catch", "--decay", "0.2"])
        time.sleep(0.5)
    if args.warmup:
        print(f"({args.warmup} warm-up runs discarded)")
    sign = flick_direction(args.bin, center, args.flick, args.scale)
    expected = args.rescroll_frames * args.rescroll * args.scale
    flick = sign * args.flick
    rescroll = -sign * args.rescroll
    release_offset = (args.flick_frames - 1) * 10 + args.flick_settle  # ms from first movement to release

    print(f"flick {flick} counts/frame (seed ≈ {abs(flick) / 0.01 * args.scale:.0f} pt/s), "
          f"re-scroll {rescroll} counts/frame × {args.rescroll_frames} = {expected:.0f} px expected, "
          f"decay {args.decay} s, start scrollY {args.start}"
          + (f", NO momentum (settle {args.flick_settle} ms before lift)" if args.flick_settle else "")
          + (f", display sync {args.latency if args.latency is not None else 0} ms" if args.resample else ""))
    print(f"{'delay':>6} {'edge@':>7} {'edge→catch':>10} {'applied':>8} {'resp%':>6} {'latency':>8}  note")

    for delay in [int(d) for d in args.delays.split(",")]:
        for _ in range(args.repeat):
            js(f"window.__reset({args.start})")
            time.sleep(0.25)
            summary = run_bench(args.bin, center, [
                "--flick", str(flick), "--flick-frames", str(args.flick_frames),
                "--flick-settle", str(args.flick_settle), "--catch-rest", str(args.catch_rest),
            ] + (["--catch-ramp"] if args.catch_ramp else []) + [
                "--rescroll", str(rescroll), "--rescroll-frames", str(args.rescroll_frames),
                "--scale", str(args.scale), "--decay", str(args.decay),
                "--delay", str(delay),
            ])
            time.sleep(0.4)
            m = measure(read_log(), args.start, expected)
            if m["t_edge"] is None:
                print(f"{delay:>6} {'-':>7} {'-':>10} {m['response']:>8} {'-':>6} {'-':>8}  never reached the edge (final {m['final']})")
                continue
            edge_to_catch = delay - (m["t_edge"] - (m["t_move"] + release_offset))
            t_catch = m["t_move"] + release_offset + delay + args.catch_rest
            y_catch = next((y for t, y in reversed(m["log"]) if t <= t_catch), None)
            residual = f"residual {-y_catch if y_catch is not None and y_catch < 0 else 0} px at catch"
            pct = 100 * m["response"] / expected
            latency = f"{m['latency']:.0f} ms" if m["latency"] is not None else "none"
            note = "dead" if pct < 10 else ("partial" if pct < 80 else "ok")
            print(f"{delay:>6} {m['t_edge']:>5} ms {edge_to_catch:>7.0f} ms {m['response']:>6} px {pct:>5.0f}% {latency:>8}  {note} (stretch {m['stretch']} px, {residual})   [{summary.split('|')[1].strip()}]")


if __name__ == "__main__":
    main()
