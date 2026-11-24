// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchTestSupport
import XCTest

@testable import RawTouchCore

/// The display-rate resampler as a pure function of real frames and display
/// ticks: exact interpolation, capped extrapolation, conservation of finger
/// motion, and the release flush.
final class FrameResamplerTests: XCTestCase {
    private let samplePeriod: TimeInterval = 0.01
    private let displayPeriod: TimeInterval = 1.0 / 120.0

    /// A real sample: the finger at raw `x` (the Go60's vertical axis) at
    /// device time `t`, y at rest.
    private func sample(x: Int, at t: TimeInterval, pad: UInt8 = 0) -> RawTouchFrame {
        scrollFrame(x: x, y: 700, at: t, pad: pad)
    }

    /// Everything the resampler emitted in one simulation, in engine order.
    private struct Emission {
        var frame: RawTouchFrame
        /// The tick that produced it, or nil for an ingest-time frame
        /// (flush or pass-through).
        var tick: TimeInterval?
    }

    /// Feeds frames (each tagged with its host arrival time) and display
    /// ticks in time order, returning everything emitted.
    private func simulate(
        latency: TimeInterval,
        frames: [(arrival: TimeInterval, frame: RawTouchFrame)],
        ticks: [TimeInterval]
    ) -> [Emission] {
        var resampler = FrameResampler(latency: latency)
        var emissions: [Emission] = []
        var frameIndex = 0
        var tickIndex = 0
        while frameIndex < frames.count || tickIndex < ticks.count {
            let nextFrame = frameIndex < frames.count ? frames[frameIndex].arrival : .infinity
            let nextTick = tickIndex < ticks.count ? ticks[tickIndex] : .infinity
            if nextFrame <= nextTick {
                emissions += resampler.ingest(frames[frameIndex].frame).map { Emission(frame: $0, tick: nil) }
                frameIndex += 1
            } else {
                if let frame = resampler.tick(at: nextTick) {
                    emissions.append(Emission(frame: frame, tick: nextTick))
                }
                tickIndex += 1
            }
        }
        return emissions
    }

    /// A constant-velocity drag: `count` samples every 10 ms from `start`,
    /// `step` counts apart, arriving `lag` after their sample time.
    private func drag(
        from start: TimeInterval = 0,
        count: Int,
        step: Int,
        lag: TimeInterval = 0.001,
        x0: Int = 1000
    ) -> [(arrival: TimeInterval, frame: RawTouchFrame)] {
        (0..<count).map { index in
            let t = start + Double(index) * samplePeriod
            return (arrival: t + lag, frame: sample(x: x0 + index * step, at: t))
        }
    }

    private func ticks(from start: TimeInterval, until end: TimeInterval) -> [TimeInterval] {
        vsyncTimes(from: start, until: end, period: displayPeriod)
    }

    // MARK: - Regimes

    func testBracketedTargetsAreInterpolatedExactly() {
        var resampler = FrameResampler(latency: 0.005)
        _ = resampler.ingest(sample(x: 1000, at: 0))
        _ = resampler.ingest(sample(x: 1040, at: 0.01))
        _ = resampler.ingest(sample(x: 1080, at: 0.02))

        // The first tick of a touch is the origin: the touch-down sample.
        let origin = resampler.tick(at: 0.012)
        XCTAssertEqual(origin?.x, 1000)
        XCTAssertEqual(origin?.timestamp, 0)

        // Target 0.0125 lies a quarter of the way through the second span.
        let frame = try? XCTUnwrap(resampler.tick(at: 0.0175))
        XCTAssertEqual(frame?.x, 1050)
        XCTAssertEqual(frame?.timestamp, 0.0125)
        XCTAssertEqual(frame?.y, 700, "y, constant in the samples, interpolates to itself")
        XCTAssertNil(frame?.seq, "synthetic frames never carry wire metadata")
        XCTAssertNil(frame?.deviceTimestampTicks)
        XCTAssertTrue(frame?.touched ?? false)
        XCTAssertTrue(frame?.scrollMode ?? false)
    }

    /// A sensor glitch must reach the engine whole, where its own step
    /// bound re-anchors it: interpolated across display ticks, a jump
    /// arrives in pieces each small enough to pass as motion.
    func testAGlitchJumpIsEmittedWholeOnOneTickAndTrackingRestartsThere() {
        var resampler = FrameResampler(latency: 0.01)
        _ = resampler.ingest(sample(x: 1000, at: 0))
        _ = resampler.ingest(sample(x: 1005, at: 0.01))
        XCTAssertEqual(resampler.tick(at: 0.012)?.x, 1000, "the origin first")

        // 700 counts in one sample period: no finger does that.
        _ = resampler.ingest(sample(x: 1705, at: 0.02))
        // Target 14.5 ms would interpolate 45% of the way into the jump.
        XCTAssertEqual(resampler.tick(at: 0.0245)?.x, 1705, "the whole jump in one step")
        XCTAssertTrue(resampler.isTracking, "the touch goes on")

        // Motion after it is tracked from the new position.
        _ = resampler.ingest(sample(x: 1715, at: 0.03))
        XCTAssertEqual(resampler.tick(at: 0.035)?.x, 1710)
    }

    /// A synthetic frame's strength is that of the real sample its position
    /// comes from — the later of the bracketing pair when interpolated — not
    /// the newest sample's: the engine judges a lift by strength, and a
    /// fade that has not been reached on screen yet is not one.
    func testAnInterpolatedFrameTakesTheStrengthOfItsBracketingSample() {
        func sample(x: Int, z: Int, at t: TimeInterval) -> RawTouchFrame {
            .init(x: x, y: 700, z: z, touched: true, scrollMode: true, timestamp: t)
        }
        var resampler = FrameResampler(latency: 0.015)
        _ = resampler.ingest(sample(x: 1000, z: 40, at: 0))
        _ = resampler.ingest(sample(x: 1040, z: 38, at: 0.01))
        _ = resampler.ingest(sample(x: 1080, z: 30, at: 0.02))
        _ = resampler.ingest(sample(x: 1120, z: 8, at: 0.03))

        XCTAssertEqual(resampler.tick(at: 0.02)?.z, 40, "the origin is the touch-down sample, strength included")
        // Target 12.5 ms: between the samples at 10 and 20 ms.
        let frame = resampler.tick(at: 0.0275)
        XCTAssertEqual(frame?.x, 1050)
        XCTAssertEqual(frame?.z, 30)
    }

    func testAStaleNewestSampleIsExtrapolatedAtMostOneSamplePeriod() {
        var resampler = FrameResampler(latency: 0)
        for index in 0..<6 {
            _ = resampler.ingest(sample(x: 1000 + index * 40, at: Double(index) * samplePeriod))
        }
        // Newest sample: x 1200 at 50 ms, moving 4000 counts/s.
        XCTAssertEqual(resampler.tick(at: 0.050)?.x, 1000, "the origin first")

        XCTAssertEqual(resampler.tick(at: 0.055)?.x, 1220, "5 ms beyond the newest sample")
        XCTAssertEqual(resampler.tick(at: 0.060)?.x, 1240, "a full period beyond")
        XCTAssertEqual(resampler.tick(at: 0.070)?.x, 1240, "capped: the position holds")
        XCTAssertEqual(resampler.tick(at: 0.200)?.x, 1240)
    }

    func testTicksBeforeTheTouchDownHoldTheFirstPositionAndItsTime() {
        var resampler = FrameResampler(latency: 0.01)
        _ = resampler.ingest(sample(x: 1000, at: 1.000))
        _ = resampler.ingest(sample(x: 1040, at: 1.010))

        // Targets 0.995 and 1.000 do not pass the touch: no motion to
        // estimate, and no frame dated before the touch itself.
        for tick in [1.005, 1.010] {
            let frame = resampler.tick(at: tick)
            XCTAssertEqual(frame?.x, 1000)
            XCTAssertEqual(frame?.timestamp, 1.000, "never dated before the touch itself")
        }
        XCTAssertEqual(resampler.tick(at: 1.015)?.x, 1020, "then motion")
    }

    func testNothingIsEmittedBeforeTheFirstSampleOrAfterReset() {
        var resampler = FrameResampler()
        XCTAssertNil(resampler.tick(at: 0))
        XCTAssertFalse(resampler.isTracking)

        _ = resampler.ingest(sample(x: 1000, at: 0))
        XCTAssertTrue(resampler.isTracking)
        resampler.reset()
        XCTAssertFalse(resampler.isTracking)
        XCTAssertNil(resampler.tick(at: 0.01))
    }

    // MARK: - Conservation

    /// The property everything rests on: the engine differences consecutive
    /// positions, so the sum of synthetic deltas telescopes to the finger's
    /// motion plus the carried offset — the extrapolation the finger never
    /// gave back — whatever the timing of the input.
    func testCumulativeMotionMatchesTheFingerPlusTheCarriedOffsetUnderJitterAndBatching() {
        let count = 200  // 2 s of drag
        let step = 23
        let velocity = Double(step) / samplePeriod
        var generator = SplitMix64(seed: 7)
        var frames: [(arrival: TimeInterval, frame: RawTouchFrame)] = []
        for index in 0..<count {
            // Sample time carries ±2 ms relay jitter; arrival batches every
            // 15 ms like a BLE connection interval.
            let t = Double(index) * samplePeriod + (generator.nextUnit() - 0.5) * 0.004
            let arrival = (t / 0.015).rounded(.up) * 0.015 + 0.001
            frames.append((arrival: arrival, frame: sample(x: 1000 + index * step, at: t)))
        }
        frames.sort { $0.frame.timestamp < $1.frame.timestamp }
        let releaseTime = Double(count) * samplePeriod
        frames.append((arrival: releaseTime + 0.016, frame: releaseFrame(at: releaseTime, scrollMode: true)))

        for latency in [0.0, 0.005, 0.01] {
            let emissions = simulate(
                latency: latency, frames: frames, ticks: ticks(from: 0.003, until: releaseTime + 0.02))
            let touched = emissions.map(\.frame).filter(\.touched)
            let release = emissions.last?.frame

            XCTAssertEqual(release?.touched, false)
            XCTAssertEqual(touched.first?.x, 1000, "the first synthetic frame is at the touch-down position")

            // The finger was still moving at lift, so the last estimates
            // ran ahead of the final sample by up to one horizon and that
            // is carried, never paid back: total = truth + carried.
            let carried = (touched.last!.x - touched.first!.x) - (count - 1) * step
            XCTAssertGreaterThanOrEqual(carried, -1, "latency \(latency): nothing the finger did is lost")
            XCTAssertLessThanOrEqual(
                Double(carried),
                velocity * FrameResampler.nominalSamplePeriod + 1,
                "latency \(latency): the carried offset is at most one extrapolation horizon"
            )

            // No drift along the way either. Against the ideal trajectory
            // at its own timestamp, a tick's estimate may lead the finger
            // only by what the jittered timestamps carry (2 ms × 2300
            // counts/s ≈ 5 counts), plus rounding, plus any carried
            // give-back (one horizon at most); and may lag it by no more
            // than the stream's own worst-case staleness — a 15 ms batch,
            // 1 ms delivery, a jitter-stretched gap — less the latency: the
            // resampler adds no lag of its own.
            let worstStaleness = 0.015 + 0.001 + 0.004
            for emission in emissions where emission.tick != nil && emission.frame.timestamp > 0.1 {
                let truth = 1000 + emission.frame.timestamp / samplePeriod * Double(step)
                let error = Double(emission.frame.x) - truth
                XCTAssertLessThanOrEqual(
                    error, velocity * 0.012 + 1, "latency \(latency): ran ahead at t=\(emission.frame.timestamp)")
                XCTAssertLessThanOrEqual(
                    -error, velocity * (worstStaleness - latency) + 1,
                    "latency \(latency): fell behind at t=\(emission.frame.timestamp)")
            }
            // Timestamps handed to the engine never step backwards.
            for (earlier, later) in zip(emissions, emissions.dropFirst()) {
                XCTAssertLessThanOrEqual(earlier.frame.timestamp, later.frame.timestamp)
            }
        }
    }

    func testCleanCadenceYieldsOneEvenDeltaPerTick() {
        // 100 Hz in, 120 Hz out at every latency: with a steady drag the
        // interpolated and extrapolated estimates agree, so consecutive
        // deltas are all the finger's per-tick motion (±1 count rounding).
        let step = 24  // 2400 counts/s → 20 counts per 120 Hz tick
        let frames = drag(count: 60, step: step)
        for latency in [0.0, 0.005, 0.01] {
            let emissions = simulate(latency: latency, frames: frames, ticks: ticks(from: 0.02, until: 0.58))
            let xs = emissions.map(\.frame.x)
            // The first delta runs from the touch-down origin to the first
            // estimate, a partial tick's worth; every later one is a full
            // tick of motion.
            let deltas = zip(xs, xs.dropFirst()).map { $1 - $0 }.dropFirst()
            XCTAssertFalse(deltas.isEmpty)
            for delta in deltas {
                XCTAssertEqual(Double(delta), 20, accuracy: 1.01, "latency \(latency): \(deltas)")
            }
        }
    }

    // MARK: - Stops, resumes, reversals (carry semantics)

    /// A 2400 counts/s drag into an abrupt stop (the finger stays down and
    /// still for 150 ms): the emitted x per tick, from the stop on.
    private func stopTrace(latency: TimeInterval, restFrames: Int = 15) -> (stopX: Int, emitted: [Int]) {
        let step = 24
        let moving = drag(count: 30, step: step)
        let stopX = moving.last!.frame.x
        let stopTime = moving.last!.frame.timestamp
        let resting = (1...restFrames).map { index -> (arrival: TimeInterval, frame: RawTouchFrame) in
            let t = stopTime + Double(index) * samplePeriod
            return (arrival: t + 0.001, frame: sample(x: stopX, at: t))
        }
        let emissions = simulate(
            latency: latency,
            frames: moving + resting,
            ticks: ticks(from: 0.003, until: stopTime + Double(restFrames) * samplePeriod)
        )
        return (stopX, emissions.map(\.frame.x))
    }

    func testAStopLandsAheadAndNeverStepsBack() {
        // Whatever the latency: no delta ever runs against the travel
        // direction after the stop, so the peak is where it lands. The
        // landing offset is the extrapolation the finger gave back —
        // about one horizon (24 counts at 2400 counts/s) at latency 0, a
        // little more because the velocity fit decays over a few resting
        // samples and each re-growth of the horizon is emitted; none at a
        // full sample period, where every estimate is bracketed.
        for latency in [0.0, 0.005, 0.01] {
            let (stopX, emitted) = stopTrace(latency: latency)
            let deltas = zip(emitted, emitted.dropFirst()).map { $1 - $0 }
            XCTAssertTrue(deltas.allSatisfy { $0 >= 0 }, "latency \(latency): a retraction was emitted: \(deltas)")
            let landing = emitted.last! - stopX
            XCTAssertEqual(landing, emitted.max()! - stopX, "latency \(latency): the peak is the landing")
            XCTAssertLessThanOrEqual(Double(landing), 1.3 * 2400 * (0.010 - latency) + 1, "latency \(latency)")
        }
        XCTAssertEqual(stopTrace(latency: 0.01).emitted.last!, stopTrace(latency: 0.01).stopX, "bracketed: exact")
        XCTAssertGreaterThan(stopTrace(latency: 0).emitted.last!, stopTrace(latency: 0).stopX, "extrapolated: carried")
    }

    func testResumingAfterAStopScrollsOnTheFirstMovingTick() {
        // Drag, dead stop for 100 ms, drag again: the first tick whose
        // target sees the resumed motion must move the emitted position —
        // no dead zone, whatever offset is being carried.
        let step = 24
        let moving = drag(count: 20, step: step)
        let stopX = moving.last!.frame.x
        let stopTime = moving.last!.frame.timestamp
        var frames = moving
        for index in 1...10 {
            let t = stopTime + Double(index) * samplePeriod
            frames.append((arrival: t + 0.001, frame: sample(x: stopX, at: t)))
        }
        let resumeTime = stopTime + 11 * samplePeriod
        for index in 0..<20 {
            let t = resumeTime + Double(index) * samplePeriod
            frames.append((arrival: t + 0.001, frame: sample(x: stopX + (index + 1) * step, at: t)))
        }

        for latency in [0.0, 0.005, 0.01] {
            let emissions = simulate(
                latency: latency, frames: frames, ticks: ticks(from: 0.003, until: resumeTime + 0.19))
            // The first tick at or after the first moving sample's arrival
            // whose target reaches that sample's time.
            let firstOpportunity = emissions.firstIndex {
                $0.tick.map { $0 >= resumeTime + 0.001 && $0 - latency >= resumeTime } ?? false
            }!
            let before = emissions[firstOpportunity - 1].frame.x
            XCTAssertGreaterThan(
                emissions[firstOpportunity].frame.x,
                before,
                "latency \(latency): the emitted position must move on the first tick that can see the motion"
            )
            // And the drag then proceeds without a single hold: the
            // velocity fit ramps back up over a few samples (deltas briefly
            // above one tick of motion, by at most a horizon), then settles
            // at the finger's own pace of 20 counts per tick.
            let xs = emissions[firstOpportunity...].map(\.frame.x)
            let deltas = zip(xs, xs.dropFirst()).map { $1 - $0 }
            XCTAssertTrue(deltas.allSatisfy { $0 > 0 && $0 <= 20 + 24 + 1 }, "latency \(latency): \(deltas)")
            for delta in deltas.suffix(8) {
                XCTAssertEqual(Double(delta), 20, accuracy: 1.01, "latency \(latency): \(deltas)")
            }
        }
    }

    func testAGenuineReversalPassesThroughAtItsOwnMagnitude() {
        // 2400 counts/s up for 300 ms, then 2400 counts/s down: after the
        // turn the emitted motion tracks the finger's reversal tick for
        // tick, and the extrapolation given back at the turn (up to one
        // horizon) is carried rather than folded into the first reversed
        // delta.
        let step = 24
        let up = drag(count: 30, step: step)
        let turnX = up.last!.frame.x
        let turnTime = up.last!.frame.timestamp
        var frames = up
        for index in 1...30 {
            let t = turnTime + Double(index) * samplePeriod
            frames.append((arrival: t + 0.001, frame: sample(x: turnX - index * step, at: t)))
        }
        let emissions = simulate(latency: 0, frames: frames, ticks: ticks(from: 0.003, until: turnTime + 0.30))
        let xs = emissions.map(\.frame.x)
        let deltas = zip(xs, xs.dropFirst()).map { $1 - $0 }

        // No single delta larger than the finger's own per-tick motion
        // plus the prediction turning around (one horizon at most) — the
        // carried give-back never lands in a delta.
        XCTAssertLessThanOrEqual(deltas.map { abs($0) }.max()!, 20 + 24 + 1)
        // Once the fit has turned (a few samples), the reversal runs at
        // the finger's pace.
        let settled = deltas.suffix(20)
        for delta in settled {
            XCTAssertEqual(Double(delta), -20, accuracy: 1.01, "\(Array(settled))")
        }
        // Peak = the turn plus what was extrapolated past it (≤ one
        // horizon); the whole reversal is then delivered.
        XCTAssertLessThanOrEqual(xs.max()! - turnX, 25)
        XCTAssertLessThanOrEqual(xs.last! - (turnX - 30 * step), 25 + 24)
    }

    // MARK: - Release

    func testReleaseFlushesTheExactFinalPositionThenPassesTheReleaseThrough() {
        var resampler = FrameResampler(latency: 0.005)
        for index in 0..<4 {
            _ = resampler.ingest(sample(x: 1000 + index * 40, at: Double(index) * samplePeriod))
        }
        XCTAssertEqual(resampler.tick(at: 0.022)?.x, 1000, "the origin")
        // Tick with target 0.025 — bracketed, x 1100 — so the final real
        // sample (1120 at 30 ms) has not been emitted.
        XCTAssertEqual(resampler.tick(at: 0.030)?.x, 1100)

        let release = releaseFrame(at: 0.04, scrollMode: true)
        let output = resampler.ingest(release)

        XCTAssertEqual(output.count, 2)
        XCTAssertEqual(output[0].x, 1120, "the exact final real position")
        XCTAssertEqual(output[0].timestamp, 0.03, "at its real time")
        XCTAssertTrue(output[0].touched)
        XCTAssertEqual(output[1], release, "the release itself, untouched")
        XCTAssertFalse(resampler.isTracking)
    }

    func testReleaseAfterAnExtrapolatedFrameCarriesTheOvershootAndStaysMonotonic() {
        var resampler = FrameResampler(latency: 0)
        for index in 0..<4 {
            _ = resampler.ingest(sample(x: 1000 + index * 40, at: Double(index) * samplePeriod))
        }
        XCTAssertEqual(resampler.tick(at: 0.030)?.x, 1000, "the origin")
        // Extrapolated 6 ms past the newest sample (dated 0.036).
        let extrapolated = resampler.tick(at: 0.036)
        XCTAssertEqual(extrapolated?.x, 1144)
        XCTAssertEqual(extrapolated?.timestamp, 0.036)

        // The release is timestamped before that estimate (it was sampled
        // 2 ms after the last touched sample). The extrapolation past the
        // final sample is carried, not flushed back — no step back to 1120
        // — and the release is pinned to the last emitted time rather than
        // stepping back.
        let output = resampler.ingest(releaseFrame(at: 0.032, scrollMode: true))
        XCTAssertEqual(output.map(\.x), [0])
        XCTAssertEqual(output.map(\.timestamp), [0.036])
        XCTAssertFalse(output[0].touched)
    }

    func testANewTouchStartsWithNoCarriedOffset() {
        var resampler = FrameResampler(latency: 0)
        for index in 0..<4 {
            _ = resampler.ingest(sample(x: 1000 + index * 40, at: Double(index) * samplePeriod))
        }
        _ = resampler.tick(at: 0.030)
        XCTAssertEqual(resampler.tick(at: 0.036)?.x, 1144, "24 counts of extrapolation in flight")
        _ = resampler.ingest(releaseFrame(at: 0.04, scrollMode: true))

        // The next touch-down is the origin again: emitted == true.
        _ = resampler.ingest(sample(x: 500, at: 1.0))
        _ = resampler.ingest(sample(x: 540, at: 1.01))
        XCTAssertEqual(resampler.tick(at: 1.012)?.x, 500)
        XCTAssertEqual(resampler.tick(at: 1.020)?.x, 580, "relative motion from the new origin, nothing carried over")
    }

    func testNoFlushWhenTheFinalPositionWasAlreadyEmitted() {
        var resampler = FrameResampler(latency: 0)
        _ = resampler.ingest(sample(x: 1000, at: 0))
        _ = resampler.ingest(sample(x: 1040, at: 0.01))
        XCTAssertEqual(resampler.tick(at: 0.005)?.x, 1000, "the origin")
        // Target exactly on the newest sample.
        XCTAssertEqual(resampler.tick(at: 0.01)?.x, 1040)

        let release = releaseFrame(at: 0.02, scrollMode: true)
        XCTAssertEqual(resampler.ingest(release), [release])
    }

    func testTouchAndReleaseWithinOneTickStillReachTheEngine() {
        var resampler = FrameResampler()
        let touch = sample(x: 1000, at: 0)
        let release = releaseFrame(at: 0.005, scrollMode: true)

        _ = resampler.ingest(touch)
        XCTAssertEqual(resampler.ingest(release), [touch, release])
    }

    func testAPointerModeFrameFlushesAndPassesThroughLikeARelease() {
        var resampler = FrameResampler(latency: 0.005)
        _ = resampler.ingest(sample(x: 1000, at: 0))
        _ = resampler.ingest(sample(x: 1040, at: 0.01))
        XCTAssertEqual(resampler.tick(at: 0.005)?.x, 1000, "the origin")
        XCTAssertEqual(resampler.tick(at: 0.01)?.x, 1020)

        // The scroll layer released mid-touch: the engine ends the gesture
        // on this frame, so it must not wait for a tick.
        let pointer = pointerFrame(x: 1060, at: 0.02)
        let output = resampler.ingest(pointer)
        XCTAssertEqual(output.map(\.x), [1040, 1060])
        XCTAssertEqual(output[1], pointer)
        XCTAssertFalse(resampler.isTracking)
        XCTAssertNil(resampler.tick(at: 0.03))
    }

    // MARK: - Latency extremes

    func testZeroLatencyAlwaysExtrapolatesAndFullLatencyAlwaysInterpolates() {
        // Samples arrive 1 ms after their sample time; ticks at 3 ms phase.
        let frames = drag(count: 20, step: 30)
        let tickTimes = ticks(from: 0.023, until: 0.18)

        // Latency 0: the target is the tick itself, always past the newest
        // sample, so every estimate is dated after it — extrapolation.
        var zero = FrameResampler(latency: 0)
        var lastSample: TimeInterval = 0
        var frameIndex = 0
        for (index, tick) in tickTimes.enumerated() {
            while frameIndex < frames.count, frames[frameIndex].arrival <= tick {
                _ = zero.ingest(frames[frameIndex].frame)
                lastSample = frames[frameIndex].frame.timestamp
                frameIndex += 1
            }
            let frame = zero.tick(at: tick)
            guard index > 0 else {
                XCTAssertEqual(frame?.x, 1000, "the origin")
                continue
            }
            XCTAssertGreaterThan(frame!.timestamp, lastSample)
            // 3000 counts/s: the estimate is exactly on the line.
            XCTAssertEqual(Double(frame!.x), 1000 + tick * 3000, accuracy: 0.51)
        }

        // Latency 10 ms: the target trails the newest sample by at least
        // the sample period minus the delivery lag, so it is bracketed.
        var full = FrameResampler(latency: 0.01)
        frameIndex = 0
        for (index, tick) in tickTimes.enumerated() {
            while frameIndex < frames.count, frames[frameIndex].arrival <= tick {
                _ = full.ingest(frames[frameIndex].frame)
                lastSample = frames[frameIndex].frame.timestamp
                frameIndex += 1
            }
            let frame = full.tick(at: tick)
            guard index > 0 else {
                XCTAssertEqual(frame?.x, 1000, "the origin")
                continue
            }
            XCTAssertLessThanOrEqual(frame!.timestamp, lastSample)
            XCTAssertEqual(Double(frame!.x), 1000 + (tick - 0.01) * 3000, accuracy: 0.51)
        }
    }

    // MARK: - Axes

    /// Both raw coordinates are fitted: the engine reads one for vertical
    /// and the other for horizontal scrolling, so each is estimated with
    /// the same fit/interpolate/carry machinery over the shared timestamps.
    func testBothAxesAreResampled() {
        var resampler = FrameResampler(latency: 0)
        for index in 0..<4 {
            var frame = sample(x: 1000 + index * 40, at: Double(index) * samplePeriod)
            frame.y = 700 + index * 40  // the other axis moves just as fast
            _ = resampler.ingest(frame)
        }
        let origin = resampler.tick(at: 0.030)
        XCTAssertEqual(origin?.x, 1000, "the origin")
        XCTAssertEqual(origin?.y, 700, "on both axes")

        let extrapolated = resampler.tick(at: 0.036)
        XCTAssertEqual(extrapolated?.x, 1144, "x is fitted and extrapolated")
        XCTAssertEqual(extrapolated?.y, 844, "and so is y")
    }

    /// The same estimates on both axes: identical trajectories on x and y
    /// (from different origins) yield identical relative motion tick for
    /// tick, so neither axis is second-class.
    func testIdenticalTrajectoriesOnBothAxesResampleIdentically() {
        var resampler = FrameResampler(latency: 0.005)
        var relative: [(x: Int, y: Int)] = []
        for index in 0..<8 {
            var frame = sample(x: 1000 + index * 24, at: Double(index) * samplePeriod)
            frame.y = 300 + index * 24
            _ = resampler.ingest(frame)
            if let tick = resampler.tick(at: Double(index) * samplePeriod + 0.003) {
                relative.append((tick.x - 1000, tick.y - 300))
            }
        }

        XCTAssertFalse(relative.isEmpty)
        for (x, y) in relative {
            XCTAssertEqual(x, y)
        }
        XCTAssertGreaterThan(relative.last!.x, 0)
    }

    /// Carry semantics are per axis: a finger that stops on one axis while
    /// still moving on the other has its overshoot carried on the stopped
    /// axis only — no retraction there, and no disturbance to the moving
    /// one.
    func testCarrySemanticsAreIndependentPerAxis() {
        let step = 24
        var frames: [(arrival: TimeInterval, frame: RawTouchFrame)] = []
        for index in 0..<30 {
            let t = Double(index) * samplePeriod
            var frame = sample(x: 1000 + index * step, at: t)
            frame.y = 300 + index * step
            frames.append((arrival: t + 0.001, frame: frame))
        }
        let stopX = frames.last!.frame.x
        let stopTime = frames.last!.frame.timestamp
        for index in 1...20 {
            let t = stopTime + Double(index) * samplePeriod
            var frame = sample(x: stopX, at: t)  // x stops dead
            frame.y = 300 + (29 + index) * step  // y carries on
            frames.append((arrival: t + 0.001, frame: frame))
        }

        let emissions = simulate(latency: 0, frames: frames, ticks: ticks(from: 0.003, until: stopTime + 0.2))
        let xs = emissions.map(\.frame.x)
        let ys = emissions.map(\.frame.y)
        let xDeltas = zip(xs, xs.dropFirst()).map { $1 - $0 }
        let yDeltas = zip(ys, ys.dropFirst()).map { $1 - $0 }

        XCTAssertTrue(xDeltas.allSatisfy { $0 >= 0 }, "x never steps back after its stop: \(xDeltas)")
        XCTAssertLessThanOrEqual(Double(xs.last! - stopX), 1.3 * 24 + 1, "x lands within one horizon of its stop")
        XCTAssertTrue(yDeltas.allSatisfy { $0 > 0 }, "y never holds: \(yDeltas)")
        for delta in yDeltas.suffix(8) {
            XCTAssertEqual(Double(delta), 20, accuracy: 1.01, "y keeps the finger's pace: \(yDeltas)")
        }
    }

    func testLatencyCanBeChangedMidTouch() {
        var resampler = FrameResampler(latency: 0)
        _ = resampler.ingest(sample(x: 1000, at: 0))
        _ = resampler.ingest(sample(x: 1040, at: 0.01))

        XCTAssertEqual(resampler.tick(at: 0.005)?.x, 1000, "the origin")
        XCTAssertEqual(resampler.tick(at: 0.01)?.x, 1040)
        resampler.latency = 0.01
        XCTAssertEqual(resampler.tick(at: 0.015)?.x, 1020, "now interpolating for 5 ms")
    }
}
