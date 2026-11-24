# Recorded delivery traces

Passive captures of a Go60 streaming touch frames to a Mac, 45–90 s
each, with the split stamp in the firmware (every frame carries its own
pad's sample time, so the device timestamps hold on every path) and the
input report layout of protocol 4. One CSV row per frame, the input
report's fields plus the host arrival time:

```
host_ns,dev,pad,contact,x,y,z,flags,seq,ts_ticks
```

To record one, run `swift scripts/raw-touch-monitor.swift > capture.csv`
from the repository root while RawTouch is running; add `--lease` to have
the monitor hold the stream lease itself when RawTouch is not. Its output
names the keyboard's device identifier on stderr, not in the CSV.

`host_ns` is the host arrival (system uptime, ns), `ts_ticks` the 16-bit
device timestamp (100 µs units, wraps at 6.5536 s), `flags` the input
report's flag byte (bit 0 *touched*, bit 1 *scroll mode*, bit 2 *lease
held*), `seq` the 8-bit frame counter. Pad 0 is the keyboard's local
(right) pad; pad 1 is relayed from the other half over the split link.

| File | Host link | Split link | Note |
|---|---|---|---|
| `usb-host_wired-split.csv` | USB | wire (polled, 3/5 ms) | |
| `usb-host_ble-split.csv` | USB | BLE | pad 0 has no run long enough for the bench |
| `ble-host_wired-split.csv` | BLE | wire | |
| `ble-host_ble-split.csv` | BLE | BLE | fully wireless |
| `ble-host_ble-split_3txbuf.csv` | BLE | BLE | **misconfigured firmware**: the peripheral has 3 BLE transmit buffers, so ~10 % of pad-1 stamps are late by up to 15 ms. Kept as the corrupted-stamps case, not for tuning |

What the traces are for: `scroll-bench --offline --replay <csv>` drives the
bench's finger models with a trace's real delivery — the frames' own
device timestamps as the sample times, each frame arriving as late as the
recorded one did — and `--sweep` adds the resampling-latency sweep per
trace, which is how the estimator's percentile target was chosen:

```sh
swift build -c release --product scroll-bench
.build/release/scroll-bench --offline --sweep --replay bench/captures/usb-host_wired-split.csv \
    --replay bench/captures/ble-host_ble-split.csv
```

Arrival lateness per trace (arrival − device time − the touch's minimum,
ms) and the sweep's knee — the smallest latency with no empty display
frames and the per-frame delta spread within two points of the best:

| Path | Pad | p50 | p75 | p90 | p95 | Knee |
|---|---|---|---|---|---|---|
| USB host, wired split | 0 (local) | 0.6 | 0.8 | 0.9 | 1.0 | 0 ms |
| USB host, wired split | 1 (relayed) | 2.8 | 4.2 | 4.9 | 5.3 | 3 ms |
| USB host, BLE split | 1 (relayed) | 4.9 | 6.8 | 10.0 | 11.5 | 10 ms |
| BLE host, wired split | 0 (local) | 8.1 | 11.6 | 13.9 | 14.8 | 13 ms |
| BLE host, wired split | 1 (relayed) | 9.3 | 13.2 | 15.6 | 17.1 | 14 ms |
| BLE host, BLE split | 0 (local) | 8.0 | 11.5 | 13.7 | 14.5 | 14 ms |
| BLE host, BLE split | 1 (relayed) | 8.3 | 12.1 | 14.2 | 15.3 | 15 ms |

To *see* the knee, `bench/plot-sweep.py` turns the sweep output into
[`latency-sweep.html`](latency-sweep.html): one panel per path, the two
stutter metrics against latency, the p75–p95 lateness band, the p90
hairline and the knee marked, with a hover readout and a table view:

```sh
.build/release/scroll-bench --offline --sweep --trials 8 \
    --latencies 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,22,24 \
    --replay bench/captures/usb-host_wired-split.csv --replay bench/captures/usb-host_ble-split.csv \
    --replay bench/captures/ble-host_wired-split.csv --replay bench/captures/ble-host_ble-split.csv > sweep.txt
bench/plot-sweep.py sweep.txt -o bench/captures/latency-sweep.html
```

p90 lands at or within 1 ms of the knee on every path; p85 sits about
1 ms under it on the BLE paths with a visibly wider delta spread. The
unit tests replay the same files through `RawTouchLatencyEstimator` and
check that it settles where the table says.
