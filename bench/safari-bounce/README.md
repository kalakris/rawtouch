# Safari rubber-band bench

Checks how Safari reacts to RawTouch's scroll stream at a page edge:
after a flick coasts into the edge and rubber-bands, how soon does a
fresh scroll register?

## Synthetic runs: `run.py`

`scroll-bench` (`Sources/scroll-bench`) posts a synthetic sequence
through the real pipeline and poster (flick, momentum, catch, re-scroll,
lift), so the page receives the stream RawTouch would post. `run.py`
drives it against `page.html` in Safari and reads the page's per-frame
`scrollY` log back through AppleScript (enable Develop → **Allow
JavaScript from Apple Events** in Safari). Each row reports when the
edge was hit, how much of the re-scroll the page applied, and how long
after the edge the page first responded. A 60-frame (600 ms) re-scroll
makes that onset visible even when the catch lands inside Safari's
lockout:

```sh
swift build -c release --product scroll-bench
bench/safari-bounce/run.py --delays 250 --rescroll-frames 60 --repeat 3 [--decay 0.5] [--flick 80 --start 400]
bench/safari-bounce/run.py --flick 10 --flick-frames 30 --flick-settle 60 --start 50   # no-momentum drag
bench/safari-bounce/run.py --catch-ramp --catch-rest 40 --rescroll-frames 60          # re-scroll starting from rest
```

Every run goes through the display-sync path, as the app runs
(`--latency` states the latency). Safari's page-side `requestAnimationFrame` runs at 60 Hz even on a
120 Hz display, so this bench cannot see display-rate cadence; use
`scroll-bench --offline` for that.

## Live sessions: `record.py`

`record.py` records a real session: you scroll `page.html` with the pad
through the running app while it captures the page's `scrollY` log and
the pad's raw frames, aligns them, and reports for every touch the delay
from the first finger movement to the first page movement, with what
preceded it (a stretched edge, momentum still running). Use it for
problems that are felt but do not show up in `run.py`.

```sh
bench/safari-bounce/record.py --seconds 60 [--monitor PATH] [--out DIR]
bench/safari-bounce/record.py --analyze DIR
```

`--monitor` names the passive HID monitor that captures the pad's
frames.

## What Safari expects

- **A `began` event must carry at least one whole point.** Safari reads
  the integer point delta. A zero-delta `began` never reaches WebKit's
  rubber-band controller, so a scroll that starts while a bounce is
  still settling is ignored, momentum included. RawTouch sends
  `mayBegin` at touch-down and defers `began` until a whole point has
  accumulated, then carries all of it; a touch that never moves ends as
  `cancelled`, as a Mac trackpad's does.
- **Momentum arriving at an edge locks out new scrolling briefly.** On a
  120 Hz built-in display, Safari ignored a re-scroll for roughly 400 to
  520 ms after momentum reached the edge, depending on speed; a plain
  drag into the edge caused none, and neither did a 60 Hz external
  display or Chrome. A Mac trackpad shows the same lockout for a very fast re-scroll.
  A catch that sends a proper `began` ends it.
- **Synthetic events carry no IOHIDEvent.** WebKit's momentum smoothing
  needs the hardware event behind a scroll event, so it does not run on
  events created with `CGEvent`. Safari applies RawTouch's momentum
  deltas as posted, like every other app.
