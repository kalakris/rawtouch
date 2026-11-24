// MIT License
// Copyright (c) 2026 RawTouch contributors
// Derived from LinearMouse — Copyright (c) 2021-2026 LinearMouse (MIT).

import Foundation

/// Unwraps the raw touch frames' 16-bit device-side sample timestamps (100 µs
/// units, wrapping at 6.5536 s — the HID Scan Time convention) onto a
/// continuous timeline comparable with host system uptime.
///
/// Why: over BLE, frames sampled 10 ms apart arrive batched at the
/// connection interval, so arrival-time deltas oscillate between ~0 and a
/// multiple of the real sample interval — which distorts every velocity
/// derived from them (acceleration gain, momentum seed). The device
/// timestamp restores the true sample cadence; protocol v4's spec requires
/// hosts to derive finger velocity from it.
///
/// The reconstructed timeline is *anchored* to the host arrival time of the
/// first frame (and re-anchored after any discontinuity), then advanced by
/// exact device-side deltas. It therefore never leads host time by more than
/// clock drift, and lags it by at most the anchor frame's delivery latency —
/// close enough for the momentum machinery, whose per-tick dt is clamped
/// anyway. It is monotonic by construction.
///
/// The lag is trimmed as the stream runs: a sample
/// cannot post-date its own arrival, so a frame that arrives *before* the
/// timeline says it was sampled proves the anchor frame was delivered
/// slower than this one, and the timeline snaps back to this arrival —
/// once per new minimum, never forwards, still monotonic (arrivals are).
/// Over BLE the first frame of a gesture may have waited a whole
/// connection interval (~15 ms) and every later timestamp would inherit
/// that lag; display-rate resampling estimates positions *at* host times,
/// so that lag would be added scroll latency.
public struct RawTouchDeviceClock {
    /// One device timestamp tick (100 µs), per the wire spec.
    public static let tickDuration: TimeInterval = 100e-6

    /// Device- or arrival-time gaps larger than this are treated as a stream
    /// discontinuity and re-anchor the timeline instead of trusting the
    /// wrapped 16-bit delta. ~2 s: comfortably above any genuine
    /// intra-gesture gap (the stream runs at ~100 Hz while touched, and the
    /// stale-touch timeout fires at 150 ms), and well below the 6.5536 s
    /// wrap period, so a delta this large is ambiguous rather than
    /// informative. The arrival-time check catches silence longer than a
    /// full wrap period, which the 16-bit delta alone cannot see.
    public static let discontinuityThreshold: TimeInterval = 2.0

    private var lastTicks: UInt16?
    private var lastArrival: TimeInterval = 0
    private var lastReconstructed: TimeInterval = 0

    public init() {}

    /// Maps a device timestamp to the continuous timeline. `arrival` is the
    /// host receive time (system uptime) of the same frame, used to anchor
    /// the timeline and to detect discontinuities.
    public mutating func reconstruct(ticks: UInt16, arrival: TimeInterval) -> TimeInterval {
        defer {
            lastTicks = ticks
            lastArrival = arrival
        }

        guard let lastTicks else {
            lastReconstructed = arrival
            return lastReconstructed
        }

        // Wrapping 16-bit delta: correct across the 6.5536 s wrap as long as
        // consecutive frames are less than one wrap period apart. A genuinely
        // out-of-order timestamp shows up as a huge delta and lands in the
        // discontinuity path below.
        let deltaTicks = ticks &- lastTicks
        let delta = TimeInterval(deltaTicks) * Self.tickDuration

        if delta > Self.discontinuityThreshold || arrival - lastArrival > Self.discontinuityThreshold {
            // Discontinuity/reset: re-anchor to arrival time, clamped to keep
            // the timeline monotonic.
            lastReconstructed = max(arrival, lastReconstructed)
        } else {
            lastReconstructed += delta
            if lastReconstructed > arrival {
                // Delivered faster than the anchor frame: the timeline was
                // running late by at least the difference. `arrival` is at
                // or after the previous frame's (clamped) time, so this
                // never steps backwards.
                lastReconstructed = arrival
            }
        }

        return lastReconstructed
    }
}
