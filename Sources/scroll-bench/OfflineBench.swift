// MIT License
// Copyright (c) 2026 RawTouch contributors

import CoreGraphics
import Foundation
import RawTouchCore
import RawTouchTestSupport

/// The deterministic cadence bench (`scroll-bench --offline`): synthetic
/// 100 Hz touch frames through the real `TouchScrollPipeline` — device
/// clock, resampler, engine, poster — with a simulated 120 Hz vsync and a
/// capturing event sink. Nothing is posted and no display is touched, so
/// it needs no Accessibility grant and runs anywhere.
///
/// This is the real validation of display-rate resampling: a browser
/// page's `requestAnimationFrame` runs at 60 Hz in Safari and cannot see
/// what happens at 120 Hz, but the per-display-frame deltas here are
/// exactly what the display would get.
enum OfflineBench {
    /// Points per count — the engine's own unit, so the table stays
    /// comparable across releases. The configuration's `scale` is a
    /// dimensionless gain, so this is fed in as a display density instead
    /// (see `simulate`).
    static let scale = 0.25
    /// The pad resolution the simulated device reports.
    static let countsPerMM = 38.0
    static let samplePeriod = 0.010
    static let displayPeriod = 1.0 / 120.0
    /// Ticks sit off the sample grid, as they would in life.
    static let displayPhase = 0.003

    // MARK: - Input models

    /// How each sample reaches the host: its device timestamp (what the
    /// frame says) and its arrival time. The schedule is the samples' true
    /// times — the pad's nominal 10 ms grid for the synthetic models, a
    /// recording's own device timestamps for a replay.
    struct InputModel {
        let name: String
        let describe: String
        /// Every sample's true time up to `duration`, then one more: the
        /// release frame's.
        let schedule: (_ duration: TimeInterval) -> [TimeInterval]
        /// Delivery of the sample at `index` in the schedule, true time `t`.
        let deliver:
            (_ index: Int, _ t: TimeInterval, _ generator: inout SplitMix64) -> (
                timestamp: TimeInterval, arrival: TimeInterval
            )
        /// For a replay: the recorded frames behind the schedule, so the
        /// finger can be the recording's own motion (`Finger.recorded`).
        var recorded: [CaptureTrace.Frame]?

        init(
            name: String,
            describe: String,
            schedule: @escaping (_ duration: TimeInterval) -> [TimeInterval],
            deliver:
                @escaping (_ index: Int, _ t: TimeInterval, _ generator: inout SplitMix64) -> (
                    timestamp: TimeInterval, arrival: TimeInterval
                ),
            recorded: [CaptureTrace.Frame]? = nil
        ) {
            self.name = name
            self.describe = describe
            self.schedule = schedule
            self.deliver = deliver
            self.recorded = recorded
        }

        /// A synthetic model on the pad's nominal 10 ms grid.
        init(
            name: String,
            describe: String,
            deliver:
                @escaping (_ t: TimeInterval, _ generator: inout SplitMix64) -> (
                    timestamp: TimeInterval, arrival: TimeInterval
                )
        ) {
            self.init(
                name: name,
                describe: describe,
                schedule: { duration in
                    var times: [TimeInterval] = []
                    var t = 0.0
                    while t <= duration + 1e-9 {
                        times.append(t)
                        t += samplePeriod
                    }
                    times.append(t)
                    return times
                },
                deliver: { _, t, generator in deliver(t, &generator) }
            )
        }

        /// USB-like: honest timestamps, 1 ms delivery.
        static let clean = InputModel(name: "clean", describe: "10 ms cadence, 1 ms delivery") { t, _ in
            (t, t + 0.001)
        }

        /// The relayed pad over a wired split: honest timestamps (the
        /// peripheral stamps its own frames), delivery held until the
        /// central's next 5 ms poll of the link, then 1 ms.
        static let wiredRelay = InputModel(name: "wired relay", describe: "honest timestamps, 5 ms poll") { t, _ in
            let poll = ((t + 0.0005) / 0.005).rounded(.up) * 0.005
            return (t, poll + 0.001)
        }

        /// BLE: honest timestamps, frames held until the next 15 ms
        /// connection event, so they land in ones and twos.
        static let bleBatch = InputModel(name: "BLE batch", describe: "honest timestamps, 15 ms batches") { t, _ in
            let event = ((t + 0.0005) / 0.015).rounded(.up) * 0.015
            return (t, event + 0.0005)
        }

        static let all: [InputModel] = [.clean, .wiredRelay, .bleBatch]

        /// The device time a replayed run must cover: the longest finger
        /// model plus room for the release.
        static let replaySpan: TimeInterval = 1.2

        /// Delivery replayed from one recorded run of `trace`: the samples'
        /// true times are the run's own device timestamps and each frame
        /// arrives as late as the recorded one did. Successive trials take
        /// successive runs long enough to cover a gesture, then start at
        /// spread offsets within them — deterministic, so a row is
        /// reproducible. Nil when no run is long enough.
        static func replay(_ trace: CaptureTrace, trial: Int) -> InputModel? {
            let eligible = trace.runs.filter { $0.span >= replaySpan }
            guard !eligible.isEmpty else {
                return nil
            }
            let run = eligible[trial % eligible.count]
            let round = trial / eligible.count
            let latestStart = run.frames.lastIndex { $0.deviceTime + replaySpan <= run.span } ?? 0
            var generator = SplitMix64(seed: UInt64(round))
            let offset = round == 0 ? 0 : Int(generator.nextUnit() * Double(latestStart + 1))
            let frames = Array(run.frames[offset...])
            let base = frames[0].deviceTime
            return InputModel(
                name: "\(trace.name.replacingOccurrences(of: ".csv", with: "")) p\(trace.pad)",
                describe: "recorded delivery, a \(run.frames.count)-frame run from frame \(offset)",
                schedule: { duration in
                    var times: [TimeInterval] = []
                    for frame in frames {
                        times.append(frame.deviceTime - base)
                        if frame.deviceTime - base > duration {
                            break
                        }
                    }
                    return times
                },
                deliver: { index, t, _ in
                    (t, t + frames[min(index, frames.count - 1)].lateness)
                },
                recorded: frames
            )
        }
    }

    // MARK: - Finger models

    /// The finger's raw position (counts) as a function of true time, plus
    /// the phase boundaries the metrics need.
    struct Finger {
        let name: String
        /// Raw position at `t` (counts), for `t` in `0 ... duration`.
        let position: (TimeInterval) -> Double
        /// Samples in this window count as the steady drag for the
        /// cadence metrics.
        let steady: ClosedRange<TimeInterval>
        /// When the finger comes to rest for good (nil: it never stops).
        let stopTime: TimeInterval?
        /// When it moves again after an earlier dead stop, if it does.
        let resumeTime: TimeInterval?
        /// The finger lifts here (still, so the lift carries no momentum
        /// and the bench needs no momentum timer).
        let duration: TimeInterval

        /// 2400 counts/s for 1 s, then a dead stop held 150 ms.
        static let steadyDrag = Finger(
            name: "steady drag 2400 counts/s, dead stop",
            position: { t in min(t, 1.0) * 2400 },
            steady: 0.1...0.95,
            stopTime: 1.0,
            resumeTime: nil,
            duration: 1.15
        )

        /// 2400 counts/s for 0.5 s, a dead stop for 0.2 s, 2400 counts/s
        /// again for 0.3 s, a dead stop.
        static let stopAndResume = Finger(
            name: "stop and resume: 2400 counts/s, 200 ms dead stop, 2400 counts/s, dead stop",
            position: { t in (min(t, 0.5) + max(min(t, 1.0) - 0.7, 0)) * 2400 },
            steady: 0.1...0.45,
            stopTime: 1.0,
            resumeTime: 0.7,
            duration: 1.15
        )

        /// 2400 counts/s, then a gentle stop: velocity ramps to 0 over
        /// 200 ms — the case where the velocity fit lags the finger for a
        /// while.
        static let gentleStop = Finger(
            name: "gentle stop: 2400 counts/s, decelerating to rest over 200 ms",
            position: { t in
                let cruise = min(t, 0.5) * 2400
                let ramp = max(min(t, 0.7) - 0.5, 0)
                return cruise + 2400 * ramp - 0.5 * (2400 / 0.2) * ramp * ramp
            },
            steady: 0.1...0.45,
            stopTime: 0.7,
            resumeTime: nil,
            duration: 0.85
        )

        /// The recording's own motion: its raw x (the Go60's scroll axis),
        /// interpolated between frames and taken from its first frame, so
        /// the truth is defined at every instant and starts at 0. The last
        /// recorded frame becomes the release; the finger is wherever it
        /// was, so the bench runs it with momentum disabled. There is no
        /// steady window in a real touch — the whole run counts, minus its
        /// first and last 50 ms.
        static func recorded(_ frames: [CaptureTrace.Frame]) -> Finger {
            let base = frames[0].deviceTime
            let x0 = Double(frames[0].x)
            let times = frames.map { $0.deviceTime - base }
            let duration = times[frames.count - 2]
            return Finger(
                name: "recorded touch, \(frames.count - 1) frames",
                position: { t in
                    guard let after = times.firstIndex(where: { $0 >= t }) else {
                        return Double(frames[frames.count - 1].x) - x0
                    }
                    guard after > 0 else {
                        return 0
                    }
                    let span = times[after] - times[after - 1]
                    let fraction = span > 0 ? (t - times[after - 1]) / span : 1
                    let a = Double(frames[after - 1].x)
                    let b = Double(frames[after].x)
                    return a + (b - a) * fraction - x0
                },
                steady: 0.05...max(0.05, duration - 0.05),
                stopTime: nil,
                resumeTime: nil,
                duration: duration
            )
        }

        /// Velocity ramping 0 → 4000 counts/s over 600 ms, held 300 ms,
        /// then a dead stop.
        static let acceleratingDrag = Finger(
            name: "accelerating 0 → 4000 counts/s over 0.6 s, dead stop at 0.9 s",
            position: { t in
                let ramp = min(t, 0.6)
                return 0.5 * (4000 / 0.6) * ramp * ramp + (min(t, 0.9) - ramp) * 4000
            },
            steady: 0.7...0.85,
            stopTime: 0.9,
            resumeTime: nil,
            duration: 1.05
        )
    }

    // MARK: - Simulation

    struct Metrics {
        var displayFrames = 0
        var zeroFraction = 0.0
        var multiFraction = 0.0
        var deltaCV = 0.0
        var emitted = 0.0
        var truth = 0.0
        /// How far past the true stop the emitted position froze (px).
        var landingOffset = 0.0
        /// Final emitted minus true displacement at lift (px): what the
        /// gesture carried.
        var carriedOffset = 0.0
        /// Finger motion (px) before the emitted position moved again
        /// after a stop-and-resume; nil when the finger never resumed.
        var deadZone: Double?
        /// A retraction — a delta against the travel direction while the
        /// finger did not reverse — was posted. Must never happen.
        var retracted = false
        /// A non-zero horizontal delta was posted. The finger models move
        /// on one raw axis only, so the other axis must stay silent.
        var crossAxisLeak = false
        var meanLatencyMs = 0.0
        var maxPositionErrorPx = 0.0
        /// RMS of the per-display-frame delta error (px) against the ideal
        /// output — the finger interpolated non-causally `latency` before
        /// each tick — over the steady window: the jitter the estimator
        /// adds on top of what the finger did.
        var deltaErrorRMSPx = 0.0
    }

    /// A `TimerScheduling` that records and never fires: the bench's
    /// gestures end at rest, so neither momentum nor the stale-touch
    /// watchdog ever needs to run.
    private final class InertScheduler: TimerScheduling {
        final class Timer: ScheduledTimer {
            func invalidate() {}
        }

        func scheduleTimer(interval: TimeInterval, repeats: Bool, handler: @escaping () -> Void) -> ScheduledTimer? {
            Timer()
        }
    }

    /// Display sync as the bench varies it: on or off, and at a stated
    /// latency. The latency is not a configuration key — the app measures
    /// it per connection — so the bench states it through the pipeline's
    /// `fixedLatency` seam instead.
    struct Sync: Equatable {
        var enabled: Bool
        var latencyMs: Double = 0

        var latency: TimeInterval {
            latencyMs.clamped(
                to: RawTouchLatencyEstimator.range.lowerBound * 1000...RawTouchLatencyEstimator.range.upperBound * 1000)
                / 1000
        }

        /// The latency the resampler actually estimates at: none at all
        /// with display sync off.
        var effectiveLatency: TimeInterval {
            enabled ? latency : 0
        }
    }

    /// The `--latency` default, milliseconds.
    static let defaultLatencyMs = 5.0

    static func simulate(
        finger: Finger,
        input: InputModel,
        resampling: Sync,
        seed: UInt64 = 11
    ) -> Metrics {
        var configuration = RawTouchConfiguration()
        configuration.resampling = .init(enabled: resampling.enabled)
        // Ballistics off: this bench measures the resampler's cadence, and
        // a velocity-dependent gain would fold the finger model's speed
        // into every delta.
        configuration.acceleration.enabled = false
        // A recorded touch lifts mid-motion; its coast would be counted as
        // scrolling. The synthetic fingers lift still and never coast.
        if finger.stopTime == nil {
            configuration.momentum.minimumFlickSpeed = RawTouchConfiguration.Momentum.minimumFlickSpeedRange.upperBound
        }

        var simNow: TimeInterval = 0
        var posted: [(time: TimeInterval, delta: Double)] = []
        var horizontalPosted: [Double] = []
        let poster = RawTouchScrollPoster(
            eventSink: { event in
                guard event.type == .scrollWheel else {
                    return
                }
                let view = ScrollWheelEventView(event)
                posted.append((simNow, view.deltaYFixedPt))
                horizontalPosted.append(view.deltaXFixedPt)
            },
            modifierFlags: { [] },
            now: { simNow }
        )
        let ticker = ManualDisplayTicker()
        let pipeline = TouchScrollPipeline(
            configuration: configuration,
            poster: poster,
            scheduler: InertScheduler(),
            displayTicker: ticker,
            now: { simNow },
            // The engine's points per count is `gain × points/mm ÷
            // counts/mm`. Gain stays at its default 1.0, so pinning the
            // display at `scale × counts/mm` points per millimetre makes
            // that exactly `scale` points per count — and never touches
            // CoreGraphics.
            pointsPerMM: { scale * countsPerMM }
        )
        pipeline.fixedLatency = resampling.latency
        // The Go60's orientation: scroll along raw x, uninverted.
        pipeline.configure(
            capabilities: RawTouchCapabilities(
                padsPresent: 0x03,
                capabilityBits: RawTouchCapabilities.Capability.hostLease,
                countsPerMM: Int(countsPerMM),
                rotate90: true,
                invertY: true
            ),
            systemPrefersNatural: false
        )

        // Samples: true time, raw position, device timestamp, arrival.
        var generator = SplitMix64(seed: seed)
        struct Sample {
            var t: TimeInterval
            var x: Int
            var frame: RawTouchFrame
        }
        var samples: [Sample] = []
        let x0 = 1000
        let times = input.schedule(finger.duration)
        precondition(times.count >= 2 && times.last! > finger.duration, "the schedule must run past the gesture")
        for (index, t) in times.dropLast().enumerated() {
            let (stamped, arrival) = input.deliver(index, t, &generator)
            let x = x0 + Int(finger.position(t).rounded())
            let ticks = deviceTicks(at: stamped)
            // A recorded finger carries its recorded strength too, so the
            // engine's lift-strength floor sees the real collapse before a
            // lift.
            let strength =
                finger.stopTime == nil ? (input.recorded?[min(index, (input.recorded?.count ?? 1) - 1)].z ?? 40) : 40
            samples.append(
                Sample(
                    t: t, x: x,
                    frame: RawTouchFrame(
                        padID: 0, x: x, y: 700, z: strength, touched: true, scrollMode: true, leaseHeld: true,
                        seq: UInt8(truncatingIfNeeded: index), deviceTimestampTicks: ticks, timestamp: arrival
                    )))
        }
        let releaseIndex = times.count - 1
        let (releaseStamp, releaseArrival) = input.deliver(releaseIndex, times[releaseIndex], &generator)
        let release = RawTouchFrame(
            padID: 0, touched: false, scrollMode: true, leaseHeld: true,
            seq: UInt8(truncatingIfNeeded: releaseIndex),
            deviceTimestampTicks: deviceTicks(at: releaseStamp),
            timestamp: releaseArrival
        )

        // Merge arrivals and vsyncs in time order, frames first on ties.
        enum Stimulus {
            case frame(RawTouchFrame, TimeInterval)
            case tick(TimeInterval)
            var time: TimeInterval {
                switch self {
                case .frame(_, let at): at
                case .tick(let at): at
                }
            }
        }
        var stimuli: [Stimulus] = samples.map { .frame($0.frame, $0.frame.timestamp) }
        stimuli.append(.frame(release, releaseArrival))
        var tick = displayPhase
        while tick <= releaseArrival + 0.05 {
            stimuli.append(.tick(tick))
            tick += displayPeriod
        }
        let ordered = stimuli.enumerated().sorted { lhs, rhs in
            if lhs.element.time != rhs.element.time {
                return lhs.element.time < rhs.element.time
            }
            if case .frame = lhs.element, case .tick = rhs.element {
                return true
            }
            if case .tick = lhs.element, case .frame = rhs.element {
                return false
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        // Per display frame: the deltas shown at that vsync — everything
        // posted since the previous one (per-sample posts included) plus
        // what the vsync itself produced.
        var slots: [(time: TimeInterval, deltas: [Double])] = []
        var seen = 0
        for stimulus in ordered {
            simNow = stimulus.time
            switch stimulus {
            case .frame(let frame, _):
                pipeline.handle(wireFrame: frame)
            case .tick(let at):
                ticker.tick(at: at)
                slots.append((at, posted[seen...].map(\.delta)))
                seen = posted.count
            }
        }

        // MARK: Metrics

        var metrics = Metrics()
        metrics.displayFrames = slots.count
        metrics.emitted = posted.map(\.delta).reduce(0, +)
        metrics.truth = Double(samples.last!.x - samples.first!.x) * scale

        let steadySlots = slots.filter { finger.steady.contains($0.time) }
        let sums = steadySlots.map { $0.deltas.reduce(0, +) }
        if !sums.isEmpty {
            metrics.zeroFraction = Double(sums.filter { $0 == 0 }.count) / Double(sums.count)
            metrics.multiFraction = Double(steadySlots.filter { $0.deltas.count > 1 }.count) / Double(sums.count)
            let mean = sums.reduce(0, +) / Double(sums.count)
            let variance = sums.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(sums.count)
            metrics.deltaCV = mean != 0 ? variance.squareRoot() / abs(mean) : 0
        }

        // Cumulative shown position per display frame, in raw counts from
        // the origin.
        var cumulative: [(time: TimeInterval, counts: Double)] = []
        var running = 0.0
        for slot in slots {
            running += slot.deltas.reduce(0, +) / scale
            cumulative.append((slot.time, running))
        }

        metrics.carriedOffset = metrics.emitted - metrics.truth
        if let stopTime = finger.stopTime {
            let stopCounts = finger.position(stopTime)
            metrics.landingOffset = ((cumulative.last?.counts ?? 0) - stopCounts) * scale
        }
        // The finger only ever moves forward in these models, so any
        // negative delta is a retraction.
        metrics.retracted = posted.contains { $0.delta < 0 }
        // And only along raw x (the Go60's vertical axis): raw y is
        // constant, so the horizontal axis must post nothing.
        metrics.crossAxisLeak = horizontalPosted.contains { $0 != 0 }
        if let resumeTime = finger.resumeTime {
            // Finger motion between the first vsync that could see the
            // resumed motion (its target at or past the first moving
            // sample, that sample delivered) and the vsync where the shown
            // position first moved: the dead zone.
            let latency = resampling.effectiveLatency
            let firstMoving = samples.first { $0.t >= resumeTime + samplePeriod - 1e-9 }!
            if let opportunity = slots.firstIndex(where: {
                $0.time - latency >= firstMoving.t && $0.time >= firstMoving.frame.timestamp
            }), let moved = slots[opportunity...].firstIndex(where: { $0.deltas.reduce(0, +) > 0 }) {
                let fingerAtOpportunity = finger.position(slots[opportunity].time - latency)
                let fingerWhenMoved = finger.position(slots[moved].time - latency)
                metrics.deadZone = (fingerWhenMoved - fingerAtOpportunity) * scale
            }
        }

        // Latency: from a sample's true time to the vsync at which the
        // shown position first reaches it.
        var latencies: [TimeInterval] = []
        for sample in samples where finger.steady.contains(sample.t) {
            let target = Double(sample.x - x0)
            if let reached = cumulative.first(where: { $0.counts >= target - 0.5 && $0.time >= sample.t }) {
                latencies.append(reached.time - sample.t)
            }
        }
        if !latencies.isEmpty {
            metrics.meanLatencyMs = latencies.reduce(0, +) / Double(latencies.count) * 1000
        }

        // Position error: the shown position at a vsync against the finger
        // at that vsync's target time (a resampled frame estimates for
        // `latency` earlier; per-sample delivery estimates nothing, so its
        // error is simply its lag). Reported over the moving part.
        let latency = resampling.effectiveLatency
        var worst = 0.0
        for point in cumulative where point.time > 0.05 && point.time < (finger.stopTime ?? finger.duration) {
            let truth = finger.position(point.time - latency)
            worst = max(worst, abs(point.counts - truth))
        }
        metrics.maxPositionErrorPx = worst * scale

        // Jitter: how the per-frame error against the ideal output changes
        // from one display frame to the next, over the steady window.
        var previousError: Double?
        var squares = 0.0
        var count = 0
        for point in cumulative where finger.steady.contains(point.time) {
            let error = point.counts - finger.position(point.time - latency)
            if let previousError {
                squares += (error - previousError) * (error - previousError)
                count += 1
            }
            previousError = error
        }
        metrics.deltaErrorRMSPx = count > 0 ? (squares / Double(count)).squareRoot() * scale : 0

        return metrics
    }

    // MARK: - Report

    /// The standard table: every finger model against the synthetic input
    /// models plus any `extraInputs` (recorded replays), at OFF / 0 / 5 ms.
    static func run(extraInputs: [InputModel] = []) {
        print("scroll-bench --offline: 100 Hz frames through the real pipeline, simulated 120 Hz vsync")
        print(
            "scale \(scale) pt/count; ON = resampling at the given latency, OFF = one delta per sample as it arrives\n")

        let variants: [(label: String, resampling: Sync)] = [
            ("OFF", .init(enabled: false)),
            ("ON 0 ms", .init(enabled: true, latencyMs: 0)),
            ("ON 5 ms", .init(enabled: true, latencyMs: 5)),
        ]
        let inputs = InputModel.all + extraInputs
        let nameWidth = max(10, inputs.map(\.name.count).max() ?? 0)

        var violations: [String] = []
        for finger in [Finger.steadyDrag, Finger.stopAndResume, Finger.gentleStop, Finger.acceleratingDrag] {
            print("== \(finger.name)")
            print(
                String(
                    format: "%-\(nameWidth)@ %-8@ %8@ %7@ %7@ %10@ %9@ %8@ %8@ %8@ %9@",
                    "input", "mode", "0-delta", "2+", "CV", "total", "truth", "landing", "carried", "deadzone",
                    "latency"
                ) + "  max err")
            for input in inputs {
                for variant in variants {
                    let m = simulate(finger: finger, input: input, resampling: variant.resampling)
                    print(
                        String(
                            format:
                                "%-\(nameWidth)@ %-8@ %7.1f%% %6.1f%% %6.1f%% %8.2f px %6.2f px %5.2f px %5.2f px %8@ %6.1f ms  %.2f px",
                            input.name, variant.label,
                            m.zeroFraction * 100, m.multiFraction * 100, m.deltaCV * 100,
                            m.emitted, m.truth, m.landingOffset, m.carriedOffset,
                            m.deadZone.map { String(format: "%.2f px", $0) } ?? "-",
                            m.meanLatencyMs, m.maxPositionErrorPx
                        ))
                    if m.retracted, variant.resampling.enabled {
                        violations.append("\(finger.name) / \(input.name) / \(variant.label): a retraction was posted")
                    }
                    if m.crossAxisLeak {
                        violations.append(
                            "\(finger.name) / \(input.name) / \(variant.label): a horizontal delta was posted")
                    }
                    if let deadZone = m.deadZone, deadZone > 0, variant.resampling.enabled {
                        violations.append("\(finger.name) / \(input.name) / \(variant.label): dead zone \(deadZone) px")
                    }
                }
            }
            print("")
        }
        print(
            """
            columns: 0-delta = display frames in the steady window with no motion; 2+ = frames that got more than \
            one delta; CV = coefficient of variation of the per-frame delta; total/truth = scrolled vs finger \
            motion; landing = how far past the true stop the shown position froze; carried = total − truth, the \
            gesture-local offset forgotten at lift; deadzone = finger motion before the shown position moved \
            again after the stop-and-resume (0 by construction); latency = mean true-sample-time → \
            vsync-at-which-it-is-shown; max err = worst shown-vs-finger position error while moving (ON: \
            against the finger `latency` earlier; OFF: plain lag).
            inputs: \(inputs.map { "\($0.name) = \($0.describe)" }.joined(separator: "; ")).
            """)
        if violations.isEmpty {
            print(
                "assertions: no retraction posted in any ON run; dead zone on resume 0 in every ON run; no horizontal delta in any run."
            )
        } else {
            print("ASSERTION FAILURES:\n  " + violations.joined(separator: "\n  "))
            exit(1)
        }
    }

    // MARK: - Latency sweep

    /// One row of a sweep: the steady drag's cadence metrics at a latency,
    /// averaged over the trials (worst case for the position error).
    struct SweepRow {
        let latencyMs: Double
        var zeroFraction = 0.0
        var multiFraction = 0.0
        var deltaCV = 0.0
        var meanLatencyMs = 0.0
        var maxPositionErrorPx = 0.0
        var landingOffset = 0.0
        var carriedOffset = 0.0
        var deltaErrorRMSPx = 0.0
        var retracted = false
    }

    /// The knee of a sweep: the smallest latency at which the steady drag
    /// has (nearly) no empty display frames and its per-frame delta spread
    /// is within two points of the best any latency achieves. Below it,
    /// more latency buys smoother scrolling; above it, only lag.
    static func knee(of rows: [SweepRow]) -> SweepRow? {
        guard let floor = rows.map(\.deltaCV).min() else {
            return nil
        }
        return rows.first { $0.zeroFraction <= 0.005 && $0.deltaCV <= floor + 0.02 }
    }

    /// The stutter-versus-latency curve per recorded path: the steady drag
    /// replayed from each trace at each resampling latency, averaged over
    /// `trials` starts, with the trace's lateness percentiles alongside —
    /// what a live estimator of that path would settle on.
    static func sweep(traces: [CaptureTrace], latencies: [Double], trials: Int, recordedFinger: Bool = false) {
        let fingerName = recordedFinger ? "the recording's own finger motion" : Finger.steadyDrag.name
        print(
            "scroll-bench --offline --sweep: \(fingerName), replayed from recorded delivery, \(trials) start(s) per row"
        )
        print(
            "scale \(scale) pt/count; lateness = arrival − device time − the run's minimum (ms): what the resampling latency has to cover"
        )
        print(
            "jitter = RMS change of the per-frame error against the ideal output (the finger `latency` before each tick, known non-causally); carried = shown − true displacement at lift\n"
        )

        var summary: [String] = []
        for trace in traces {
            let p = { (q: Double) in trace.latenessPercentile(q) * 1000 }
            print(
                String(
                    format:
                        "== %@ pad %d: %d runs, %d frames; lateness p50 %.1f  p75 %.1f  p90 %.1f  p95 %.1f  max %.1f ms",
                    trace.name, trace.pad, trace.runs.count, trace.frameCount, p(0.5), p(0.75), p(0.9), p(0.95), p(1.0)
                ))
            let models = (0..<trials).compactMap { InputModel.replay(trace, trial: $0) }
            guard !models.isEmpty else {
                print("   no run covers \(InputModel.replaySpan) s of touch — skipped\n")
                continue
            }
            print(
                String(
                    format: "  %8@ %8@ %7@ %7@ %9@ %9@ %9@ %9@ %9@",
                    "latency", "0-delta", "2+", "CV", "shown", "max err", "landing", "carried", "jitter"
                ))
            var rows: [SweepRow] = []
            for latencyMs in latencies {
                var row = SweepRow(latencyMs: latencyMs)
                for model in models {
                    let finger: Finger =
                        recordedFinger && model.recorded != nil ? .recorded(model.recorded!) : .steadyDrag
                    let m = simulate(
                        finger: finger, input: model, resampling: .init(enabled: true, latencyMs: latencyMs))
                    row.zeroFraction += m.zeroFraction / Double(models.count)
                    row.multiFraction += m.multiFraction / Double(models.count)
                    row.deltaCV += m.deltaCV / Double(models.count)
                    row.meanLatencyMs += m.meanLatencyMs / Double(models.count)
                    row.landingOffset += m.landingOffset / Double(models.count)
                    row.carriedOffset += m.carriedOffset / Double(models.count)
                    row.deltaErrorRMSPx += m.deltaErrorRMSPx / Double(models.count)
                    row.maxPositionErrorPx = max(row.maxPositionErrorPx, m.maxPositionErrorPx)
                    row.retracted = row.retracted || (m.retracted && !recordedFinger)
                }
                rows.append(row)
                print(
                    String(
                        format: "  %5.0f ms %7.1f%% %6.1f%% %6.1f%% %6.1f ms %6.2f px %6.2f px %6.2f px %6.2f px%@",
                        row.latencyMs, row.zeroFraction * 100, row.multiFraction * 100, row.deltaCV * 100,
                        row.meanLatencyMs, row.maxPositionErrorPx, row.landingOffset, row.carriedOffset,
                        row.deltaErrorRMSPx,
                        row.retracted ? "  RETRACTION" : ""
                    ))
            }
            let kneeText = knee(of: rows).map { String(format: "%.0f ms", $0.latencyMs) } ?? "beyond the sweep"
            let line = String(
                format: "%@ pad %d: knee %@ (lateness p50 %.1f / p75 %.1f / p90 %.1f / p95 %.1f ms)",
                trace.name, trace.pad, kneeText, p(0.5), p(0.75), p(0.9), p(0.95)
            )
            print("  knee: \(kneeText)\n")
            summary.append(line)
        }
        print(
            """
            columns: 0-delta = display frames in the steady window with no motion; 2+ = frames that got more \
            than one delta; CV = coefficient of variation of the per-frame delta; shown = mean true-sample-time → \
            vsync-at-which-it-is-shown; max err = worst shown-vs-finger position error while moving, against the \
            finger `latency` earlier; landing = how far past the true stop the shown position froze.
            knee = smallest latency with ≤ 0.5% empty frames and CV within 2 points of the sweep's best.

            summary:
              \(summary.joined(separator: "\n  "))
            """)
    }
}
