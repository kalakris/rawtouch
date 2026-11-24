// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation

/// Re-times a pad's ~100 Hz touch samples onto the display's refresh
/// cadence: one synthetic `RawTouchFrame` per display tick, positioned
/// where the finger is estimated to have been a fixed `latency` before the
/// tick.
///
/// Both raw coordinates are fitted, interpolated and reconciled — the
/// engine reads both, one for vertical scrolling and one for horizontal
/// (which is which is the pad's mounting, `TouchScrollEngine.Config.axis`,
/// and is of no concern here). The two axes share the sample timestamps
/// and are otherwise independent: each has its own carry bookkeeping, so a
/// finger that stops on one axis while still moving on the other is
/// handled per axis.
///
/// Why: the Cirque pad samples at 100 Hz and cannot go faster (the ASIC
/// clamps its sample-rate register at 100 SPS). On a 120 Hz ProMotion
/// display a 100 Hz drag is a 5:6 beat — every sixth display frame gets no
/// new delta and content holds for one frame, a ~20 Hz micro-judder — and
/// over BLE the batches make it worse. Emitting exactly one position per
/// vsync removes the beat; deriving each position from the real samples'
/// timestamps (rather than smoothing the deltas) keeps it drift-free.
///
/// Two regimes per tick, for the target time `t_out - latency`:
/// - Two real samples bracket the target: exact linear interpolation
///   between them. No filter, no lag beyond `latency`.
/// - The newest sample is older than the target: extrapolate from it with
///   the recency-weighted velocity fit (`WeightedVelocityFit`, the same
///   estimator the engine's momentum seed uses), but never further than one
///   nominal sample period (10 ms) beyond it — past that the position
///   holds, so a finger that stopped or lifted is not run on.
///
/// Emission is relative: each tick's synthetic frame moves the emitted
/// position by the estimate's own change since the last tick, and the
/// engine turns consecutive positions into deltas. Coordinates stay
/// integer counts on the wire struct; rounding the emitted position costs
/// at most half a count per frame and nothing overall.
///
/// Carry semantics: extrapolation can run the estimate past the finger
/// when it stops or slows, and the next estimate then gives that
/// extrapolation back. Content must never move in a direction the finger
/// did not, so a *retraction* — the estimate stepping back against the
/// direction of the last extrapolation while the finger has not moved
/// backwards — emits nothing and re-bases: the frozen emitted position
/// becomes the new origin and later relative deltas apply from there. The
/// overshoot becomes a carried, gesture-local offset of at most one
/// extrapolation horizon per hard stop — invisible, since scrolling is
/// relative and ballistics already break any absolute finger-to-content
/// mapping. There is no dead zone: motion resuming in the travel direction
/// scrolls on the very next tick. A genuine reversal — the estimate
/// stepping back further than the last extrapolation could account for —
/// passes through at the finger's own magnitude, the give-back carried,
/// never folded in.
///
/// Releases (and pointer-mode frames, which also end a gesture) pass
/// through at once. A final real sample the emitted position had not yet
/// reached is flushed first, so nothing the finger did is lost; a carried
/// offset is simply forgotten — there is no step back to the final sample
/// at lift-off, and the next touch-down starts with emitted == true by
/// construction. A touch-down produces nothing until the next tick, which
/// emits the touch-down sample itself as the engine's origin.
///
/// Pure value type, no I/O: the pipeline owns one instance for its active
/// pad (it arbitrates pads before frames get here) and resets it between
/// gestures.
public struct FrameResampler {
    /// The pad's nominal sample period — the extrapolation horizon cap.
    public static let nominalSamplePeriod: TimeInterval = 0.010

    /// Samples older than this relative to the newest are dropped. Matches
    /// the engine's lift-off window; the weighted fit barely sees past it.
    public static let retentionWindow: TimeInterval = 0.1

    /// How far behind each display tick the emitted position is estimated
    /// for. 0 extrapolates from every tick (no added lag); one sample period
    /// interpolates from every tick (a steady stream is always bracketed);
    /// in between the regime depends on how fresh the newest sample is.
    /// Stops land within one extrapolation horizon either way (carry
    /// semantics above); latency matters for batched delivery, where it
    /// keeps the estimate within the horizon.
    public var latency: TimeInterval

    /// Display ticks answered since the current touch began (a touch-down
    /// restarts the count, `reset()` clears it).
    public private(set) var tickCount = 0

    /// Of those, the ticks that found the newest sample more than one
    /// sample period behind the target and held the position — what a
    /// latency below the delivery's need looks like on screen (see
    /// `RawTouchLatencyEstimator`).
    public private(set) var heldTickCount = 0

    /// Carry semantics for one axis (see the type comment): turns the
    /// estimate's tick-to-tick change into the emitted position's change,
    /// suppressing retractions of the last extrapolation.
    private struct AxisReconciler {
        /// The emitted position, exact (rounded only on the wire).
        private var emitted: Double?

        /// The last estimate (the base later relative deltas apply from)
        /// and how far it had been extrapolated beyond the newest real
        /// sample, signed; 0 when it was interpolated or held.
        private var previousEstimate = 0.0
        private var previousExtrapolation = 0.0

        /// Advances the emitted position for this tick's true `estimate`,
        /// extrapolated `amount` beyond the newest sample (signed, 0 when
        /// interpolated), and returns it.
        mutating func reconcile(estimate: Double, extrapolatedBy amount: Double) -> Double {
            defer {
                previousEstimate = estimate
                previousExtrapolation = amount
            }

            guard let emitted else {
                self.emitted = estimate
                return estimate
            }

            let change = estimate - previousEstimate
            let givenBack = previousExtrapolation
            var delta = change
            if givenBack != 0, change * givenBack < 0 {
                // The estimate stepped back against the last extrapolation.
                // Up to that extrapolation's worth is ours being returned,
                // not finger motion: carry it. Anything beyond is a real
                // reversal and passes through at its own magnitude.
                delta = abs(change) > abs(givenBack) ? change + givenBack : 0
            }

            self.emitted = emitted + delta
            return emitted + delta
        }
    }

    /// One value per raw axis.
    private struct PerAxis<Value> {
        var x: Value
        var y: Value

        init(_ make: (RawTouchAxis) -> Value) {
            x = make(.x)
            y = make(.y)
        }

        subscript(axis: RawTouchAxis) -> Value {
            get {
                switch axis {
                case .x: x
                case .y: y
                }
            }
            set {
                switch axis {
                case .x: x = newValue
                case .y: y = newValue
                }
            }
        }
    }

    private var reconcilers = PerAxis { _ in AxisReconciler() }

    /// One retained real sample. The frame is kept whole so a synthetic
    /// frame inherits pad, contact, z and flags from the sample it derives
    /// from.
    private struct Sample {
        var frame: RawTouchFrame
        var timestamp: TimeInterval { frame.timestamp }

        func value(on axis: RawTouchAxis) -> Double {
            Double(frame[axis])
        }
    }

    private var samples: [Sample] = []

    /// The last synthetic frame emitted for this touch: its position on
    /// both axes, to skip a redundant flush, and its timestamp, the floor
    /// for every later timestamp handed to the engine (see `monotonic(_:)`).
    private var lastEmitted: (position: PerAxis<Int>, timestamp: TimeInterval)?

    /// `latency` starts at none: with carry semantics a stop simply stops,
    /// so latency buys nothing there; it only smooths batched (BLE)
    /// delivery. It is not a setting: the pipeline sets it per gesture to
    /// what the source's delivery has measured (`RawTouchLatencyEstimator`).
    public init(latency: TimeInterval = 0) {
        self.latency = latency
    }

    /// Whether a scroll-mode touch is being tracked (samples retained since
    /// the last touch-down). The pipeline keeps display ticks flowing while
    /// this is true.
    public var isTracking: Bool {
        !samples.isEmpty
    }

    // MARK: - Input

    /// Ingests a real frame. Scroll-mode touched frames are buffered and
    /// return nothing — their motion reaches the engine through `tick(at:)`.
    /// Anything else (a release, or a touched pointer-mode frame, which
    /// ends a gesture in the engine) goes through `passThrough(_:)`.
    public mutating func ingest(_ frame: RawTouchFrame) -> [RawTouchFrame] {
        guard frame.touched, frame.scrollMode else {
            return passThrough(frame)
        }

        if samples.isEmpty {
            tickCount = 0
            heldTickCount = 0
        }
        // A jump no finger makes (`TouchScrollEngine.maxPlausibleStepCounts`,
        // on either axis) restarts tracking from this sample, as a
        // touch-down would but within the touch: interpolated across, the
        // jump would reach the engine in display-tick pieces each small
        // enough to pass for motion; restarted, it arrives whole on the next
        // tick and the engine re-anchors on it.
        if let newest = samples.last,
            RawTouchAxis.allCases.contains(where: {
                Double(abs(frame[$0] - newest.frame[$0])) > TouchScrollEngine.maxPlausibleStepCounts
            })
        {
            samples.removeAll(keepingCapacity: true)
            reconcilers = PerAxis { _ in AxisReconciler() }
        }
        samples.append(Sample(frame: frame))
        let cutoff = frame.timestamp - Self.retentionWindow
        samples.removeAll { $0.timestamp < cutoff }
        return []
    }

    /// Flushes the tracked touch (see `flush()`), then passes `frame`
    /// through with a monotonic timestamp. Frames are returned in engine
    /// order. The pipeline uses this directly for frames it will not
    /// resample — when resampling is off mid-gesture, or no display ticks
    /// could be started — so the engine never sees a position gap.
    public mutating func passThrough(_ frame: RawTouchFrame) -> [RawTouchFrame] {
        var output = flush()
        output.append(monotonic(frame))
        lastEmitted = nil
        return output
    }

    /// Ends tracking, returning a final frame if the final real sample
    /// moves the emitted position on either axis — either nothing was
    /// emitted yet (touch-down and release within one display period: the
    /// engine still sees the touch) or the last estimate sat behind the
    /// sample. The same carry rule as a tick applies: extrapolation the
    /// final sample gives back is carried, not paid back, so the release
    /// carries no step back and the momentum seed sees the history as
    /// posted. The emitted-timestamp floor survives so a frame passed
    /// through right after stays monotonic.
    public mutating func flush() -> [RawTouchFrame] {
        defer {
            samples.removeAll(keepingCapacity: true)
            reconcilers = PerAxis { _ in AxisReconciler() }
        }
        guard let newest = samples.last else {
            return []
        }
        guard let lastEmitted else {
            let frame = monotonic(newest.frame)
            self.lastEmitted = (PerAxis { frame[$0] }, frame.timestamp)
            return [frame]
        }

        var frame = newest.frame
        for axis in RawTouchAxis.allCases {
            frame[axis] = Int(
                reconcilers[axis].reconcile(estimate: newest.value(on: axis), extrapolatedBy: 0).rounded())
        }
        guard RawTouchAxis.allCases.contains(where: { frame[$0] != lastEmitted.position[$0] }) else {
            return []
        }
        frame = monotonic(frame)
        self.lastEmitted = (PerAxis { frame[$0] }, frame.timestamp)
        return [frame]
    }

    /// Forgets the tracked touch. The pipeline calls this on interrupts and
    /// lease changes; a release does it on its own.
    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        lastEmitted = nil
        reconcilers = PerAxis { _ in AxisReconciler() }
        tickCount = 0
        heldTickCount = 0
    }

    // MARK: - Output

    /// One display tick at `outputTime` (host uptime, the vsync this tick
    /// belongs to). Returns the synthetic frame for `outputTime - latency`,
    /// or nil while no touch is tracked.
    public mutating func tick(at outputTime: TimeInterval) -> RawTouchFrame? {
        guard let first = samples.first, let newest = samples.last else {
            return nil
        }

        let target = outputTime - latency
        tickCount += 1
        // Held: the extrapolation below is capped at the horizon, so the
        // position no longer follows the finger (a microsecond of slack
        // keeps an exact period from counting through rounding).
        if target - newest.timestamp > Self.nominalSamplePeriod + 1e-6 {
            heldTickCount += 1
        }
        var position = PerAxis { _ in 0.0 }
        var extrapolated = PerAxis { _ in 0.0 }
        let timestamp: TimeInterval
        // The real sample the estimate is anchored to, which the synthetic
        // frame takes its strength (and pad, contact and flags) from.
        let anchor: Sample
        if lastEmitted == nil || target <= first.timestamp {
            // The first frame of a touch is the touch-down sample itself:
            // the engine takes its first frame as the origin and emits no
            // delta for it, so anything short of the real touch-down
            // position would drop the finger's first milliseconds of
            // motion. Likewise a target before the touch-down (a tick
            // within `latency` of it) has no motion to estimate — hold the
            // origin, and never date a frame before the touch itself.
            position = PerAxis { first.value(on: $0) }
            timestamp = first.timestamp
            anchor = first
        } else if target <= newest.timestamp {
            position = PerAxis { interpolate(at: target, on: $0) }
            timestamp = target
            anchor = samples[bracketingIndex(for: target)]
        } else {
            let horizon = min(target - newest.timestamp, Self.nominalSamplePeriod)
            for axis in RawTouchAxis.allCases {
                let points = samples.map { ($0.value(on: axis), $0.timestamp) }
                let displacement = (WeightedVelocityFit.slope(through: points) ?? 0) * horizon
                extrapolated[axis] = displacement
                position[axis] = newest.value(on: axis) + displacement
            }
            timestamp = target
            anchor = newest
        }

        // Carry semantics (see the type comment), per axis: the estimate is
        // what the finger did; the emitted position follows its changes,
        // never giving an extrapolation back.
        var frame = anchor.frame
        for axis in RawTouchAxis.allCases {
            let reconciled = reconcilers[axis].reconcile(estimate: position[axis], extrapolatedBy: extrapolated[axis])
            frame[axis] = Int(reconciled.rounded())
        }
        frame.timestamp = timestamp
        // Synthetic: never crossed the wire with these values.
        frame.seq = nil
        frame.deviceTimestampTicks = nil
        frame = monotonic(frame)
        lastEmitted = (PerAxis { frame[$0] }, frame.timestamp)
        return frame
    }

    /// The index of the later of the two retained samples that bracket
    /// `target` (the caller guarantees one exists).
    private func bracketingIndex(for target: TimeInterval) -> Int {
        var index = samples.count - 1
        while index > 0, samples[index - 1].timestamp > target {
            index -= 1
        }
        return index
    }

    /// Exact linear interpolation on one axis, between the two retained
    /// samples that bracket `target`.
    private func interpolate(at target: TimeInterval, on axis: RawTouchAxis) -> Double {
        let index = bracketingIndex(for: target)
        let after = samples[index]
        let before = samples[max(index - 1, 0)]

        let span = after.timestamp - before.timestamp
        guard span > 0 else {
            return after.value(on: axis)
        }
        let fraction = (target - before.timestamp) / span
        return before.value(on: axis)
            + (after.value(on: axis) - before.value(on: axis)) * fraction
    }

    /// Keeps the engine's timeline monotonic: an extrapolated estimate is
    /// dated ahead of the newest real sample, so a release (or the flush of
    /// that sample) arriving right after would otherwise step backwards.
    /// The engine only uses these timestamps for velocity spacing and
    /// momentum dt, so pinning them to the last emitted time is harmless.
    private func monotonic(_ frame: RawTouchFrame) -> RawTouchFrame {
        guard let lastEmitted, frame.timestamp < lastEmitted.timestamp else {
            return frame
        }
        var frame = frame
        frame.timestamp = lastEmitted.timestamp
        return frame
    }
}
