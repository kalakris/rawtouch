// MIT License
// Copyright (c) 2026 RawTouch contributors

import CoreGraphics
import RawTouchTestSupport
import XCTest

@testable import RawTouchCore

/// The pipeline's display pacing: frames in at the pad's 100 Hz, synthetic
/// frames to the engine on the display ticks, momentum riding the same
/// ticks, the display link running only while there is something to pace,
/// and the fallbacks. Every CGEvent is captured — nothing is posted.
final class TouchScrollPipelineResamplingTests: XCTestCase {
    private let frameInterval: TimeInterval = 0.01
    private let displayPeriod: TimeInterval = 1.0 / 120.0

    // Every harness here is the Go60 (rotate-90 + y-invert ⇒ scroll axis x,
    // invert false), paced, with the latency set by hand (0 ms unless a test
    // says otherwise); what the estimator measures has its own suite
    // (`TouchScrollPipelineAdaptiveLatencyTests`).

    /// One thing that happens on the simulated timeline.
    private enum Stimulus {
        case frame(RawTouchFrame, arrival: TimeInterval)
        case tick(TimeInterval)

        var time: TimeInterval {
            switch self {
            case .frame(_, let arrival): arrival
            case .tick(let time): time
            }
        }
    }

    /// Runs the stimuli in time order (frames before ticks at equal times)
    /// and returns the deltas posted in each tick's slot — the deltas that
    /// reach the display for that frame — plus those posted at frame
    /// arrival between ticks (attributed to the following tick's slot,
    /// which is when they would be shown).
    @discardableResult
    private func run(_ stimuli: [Stimulus], on harness: PipelineHarness) -> [[Double]] {
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

        var slots: [[Double]] = []
        var pending: [Double] = []
        var seen = 0
        func drain() {
            let new = harness.captured.deltas.dropFirst(seen)
            seen = harness.captured.deltas.count
            pending += new
        }
        for stimulus in ordered {
            switch stimulus {
            case .frame(let frame, _):
                harness.pipeline.handle(wireFrame: frame)
                drain()
            case .tick(let time):
                harness.ticker.tick(at: time)
                drain()
                slots.append(pending)
                pending = []
            }
        }
        return slots
    }

    private func ticks(from start: TimeInterval, until end: TimeInterval) -> [Stimulus] {
        vsyncTimes(from: start, until: end).map { .tick($0) }
    }

    /// A constant-velocity drag on `pad`: samples every 10 ms, `step`
    /// counts apart along raw x, delivered 1 ms after sampling.
    private func drag(
        from start: TimeInterval = 0,
        count: Int,
        step: Int,
        pad: UInt8 = 0,
        x0: Int = 1000
    ) -> [Stimulus] {
        (0..<count).map { index in
            let t = start + Double(index) * frameInterval
            return .frame(scrollFrame(x: x0 + index * step, at: t, pad: pad), arrival: t + 0.001)
        }
    }

    // MARK: - Pacing

    func testScrollFramesReachTheEngineOnDisplayTicksNotOnArrival() {
        let harness = PipelineHarness()

        for step in 0..<3 {
            harness.pipeline.handle(wireFrame: scrollFrame(x: 1000 + step * 30, at: Double(step) * frameInterval))
        }
        XCTAssertTrue(harness.captured.scrollWheelViews.isEmpty, "buffered until a vsync")
        XCTAssertEqual(harness.pipeline.activeSource?.padID, 0, "the gesture is taken at arrival, as before")

        // First tick: the engine sees the touch (no scroll event yet — the
        // began waits for movement). Second tick: the began with a delta.
        harness.ticker.tick(at: 0.025)
        XCTAssertTrue(harness.captured.scrollWheelViews.isEmpty)
        harness.ticker.tick(at: 0.025 + displayPeriod)
        XCTAssertEqual(harness.captured.scrollPhases, [.began])
        XCTAssertGreaterThan(harness.captured.deltas[0], 0)
    }

    func testEveryDisplayFrameGetsOneDeltaWhereRawFramesWouldBeat() {
        // 100 Hz in, 120 Hz out. Without resampling one display frame in
        // six has nothing new; with it, every slot after the began carries
        // one delta of the finger's per-frame motion: 24 counts / 10 ms →
        // 20 counts per tick × 0.25 pt = 5 pt, ±0.25 pt of count rounding.
        let stimuli = drag(count: 60, step: 24) + ticks(from: 0.003, until: 0.58)

        let resampled = PipelineHarness()
        let slots = run(stimuli, on: resampled)
        let active = slots.dropFirst(3).dropLast(2)
        XCTAssertFalse(active.isEmpty)
        for slot in active {
            XCTAssertEqual(slot.count, 1, "exactly one delta per display frame: \(slot)")
            XCTAssertEqual(slot[0], 5, accuracy: 0.26)
        }

        var off = RawTouchConfiguration()
        off.resampling.enabled = false
        off.acceleration.enabled = false  // linear deltas, as the harness builds them
        let unresampled = PipelineHarness(configuration: off)
        let rawSlots = run(stimuli, on: unresampled)
        let empty = rawSlots.dropFirst(3).dropLast(2).filter(\.isEmpty).count
        XCTAssertGreaterThan(empty, 5, "the 5:6 beat: some display frames get no delta at all")
        XCTAssertEqual(unresampled.ticker.startCount, 0, "resampling off never touches the display link")
    }

    func testTotalScrollIsTheFingersMotionPlusTheCarriedOffset() {
        // Jittered sample times, batched delivery, then a dead stop and a
        // release: the posted deltas sum to the finger's motion plus the
        // extrapolation the stop gave back — carried, never retracted.
        var generator = SplitMix64(seed: 3)
        var stimuli: [Stimulus] = []
        let count = 80
        let step = 17
        for index in 0..<count {
            let t = Double(index) * frameInterval + (generator.nextUnit() - 0.5) * 0.004
            let arrival = (t / 0.015).rounded(.up) * 0.015 + 0.001
            stimuli.append(.frame(scrollFrame(x: 1000 + index * step, at: t), arrival: arrival))
        }
        let stopX = 1000 + (count - 1) * step
        for index in 1...12 {
            let t = Double(count - 1 + index) * frameInterval
            stimuli.append(.frame(scrollFrame(x: stopX, at: t), arrival: t + 0.001))
        }
        let release = Double(count + 12) * frameInterval
        stimuli.append(.frame(releaseFrame(at: release, scrollMode: true), arrival: release + 0.001))
        stimuli += ticks(from: 0.004, until: release + 0.03)

        let harness = PipelineHarness()
        run(stimuli, on: harness)

        XCTAssertEqual(harness.captured.scrollPhases.last, .ended)
        let truth = Double((count - 1) * step) * 0.25
        let carried = harness.captured.deltas.reduce(0, +) - truth
        XCTAssertGreaterThanOrEqual(carried, -1e-9)
        XCTAssertLessThanOrEqual(carried, 1.3 * Double(step) / frameInterval * 0.010 * 0.25, "at most ~one horizon")
        XCTAssertTrue(harness.captured.deltas.allSatisfy { $0 >= 0 }, "no retraction is ever posted")
        XCTAssertNil(harness.pipeline.activeSource?.padID)
    }

    func testStopsLandWithoutSteppingBackAtEveryLatency() {
        // A 2400 counts/s drag into a dead stop at each latency: never a
        // negative delta; at 0 ms the stop lands ahead by the carried
        // extrapolation, at 10 ms (always bracketed) exactly on the finger.
        func landing(latencyMs: Double) -> (deltas: [Double], offset: Double) {
            let harness = PipelineHarness(fixedLatency: latencyMs / 1000)

            var stimuli = drag(count: 30, step: 24)
            for index in 1...15 {
                let t = Double(29 + index) * frameInterval
                stimuli.append(.frame(scrollFrame(x: 1000 + 29 * 24, at: t), arrival: t + 0.001))
            }
            stimuli += ticks(from: 0.003, until: 0.45)
            run(stimuli, on: harness)
            let total = harness.captured.deltas.reduce(0, +)
            return (harness.captured.deltas, total - Double(29 * 24) * 0.25)
        }

        for latencyMs in [0.0, 5.0, 10.0] {
            let result = landing(latencyMs: latencyMs)
            XCTAssertTrue(result.deltas.allSatisfy { $0 >= 0 }, "latency \(latencyMs): retraction posted")
            XCTAssertLessThanOrEqual(result.offset, 1.3 * 2400 * (0.010 - latencyMs / 1000) * 0.25 + 0.25)
        }
        XCTAssertGreaterThan(landing(latencyMs: 0).offset, 0)
        XCTAssertEqual(landing(latencyMs: 10).offset, 0, accuracy: 1e-9)
    }

    // MARK: - Display link lifetime

    func testTheDisplayLinkStartsAtTouchDownAndStopsWhenTheGestureEnds() {
        // A flick-sized step (so the began is out at once) that must not
        // coast: the momentum threshold is out of reach.
        var configuration = RawTouchConfiguration()
        configuration.momentum.minimumFlickSpeed = 100_000
        let harness = PipelineHarness(configuration: configuration)
        XCTAssertFalse(harness.ticker.isTicking)

        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0))
        XCTAssertEqual(harness.ticker.startCount, 1)
        XCTAssertTrue(harness.ticker.isTicking)

        harness.ticker.tick(at: 0.005)
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1030, at: 0.01))
        harness.ticker.tick(at: 0.005 + displayPeriod)
        XCTAssertTrue(harness.ticker.isTicking, "still touching")

        // A slow release: no momentum, so nothing is left to pace.
        harness.pipeline.handle(wireFrame: releaseFrame(at: 0.02, scrollMode: true))
        XCTAssertFalse(harness.ticker.isTicking)
        XCTAssertEqual(harness.captured.scrollPhases.last, .ended)
        XCTAssertNil(harness.pipeline.activeSource?.padID)

        // The next gesture starts a new subscription.
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 1))
        XCTAssertEqual(harness.ticker.startCount, 2)
    }

    func testMomentumRidesTheDisplayTicksAndStopsThemWhenItEnds() {
        let harness = PipelineHarness()
        var activities: [RawTouchStatus.PadActivity] = []
        harness.pipeline.onActivityChange = { activities.append($0) }

        // A flick: 12 frames at 2500 counts/s, ticks along the way, then
        // the release.
        var stimuli = drag(count: 12, step: 25)
        stimuli.append(.frame(releaseFrame(at: 0.12, scrollMode: true), arrival: 0.121))
        stimuli += ticks(from: 0.003, until: 0.121)
        run(stimuli, on: harness)

        XCTAssertEqual(harness.captured.scrollPhases.last, .ended)
        XCTAssertTrue(harness.ticker.isTicking, "coasting keeps the display link alive")
        XCTAssertTrue(
            harness.scheduler.liveTimers.allSatisfy { !$0.repeats },
            "no free-running momentum timer while display ticks drive momentum"
        )
        XCTAssertEqual(activities.last, .coasting(padID: 0))

        // Each tick is one momentum step.
        let before = harness.captured.phases.count
        harness.ticker.tick(at: 0.14)
        XCTAssertEqual(harness.captured.phases.count, before + 1)
        XCTAssertEqual(harness.captured.phases.last?.momentum, .begin)
        harness.ticker.tick(at: 0.14 + displayPeriod)
        XCTAssertEqual(harness.captured.phases.last?.momentum, .continuous)

        // Coast to the end.
        var t = 0.14 + displayPeriod
        var steps = 0
        while harness.ticker.isTicking, steps < 5000 {
            t += displayPeriod
            harness.ticker.tick(at: t)
            steps += 1
        }
        XCTAssertFalse(harness.ticker.isTicking, "idle: the display link is released")
        XCTAssertEqual(harness.captured.phases.last?.momentum, .end)
        XCTAssertEqual(activities.last, .idle)
        XCTAssertNil(harness.pipeline.activeSource?.padID)
    }

    func testMomentumSeedMatchesTheUnresampledSeedClosely() {
        // The release flush can step back from an extrapolated estimate;
        // the lift-off fit must shrug that off. Compare the first momentum
        // delta (same tick spacing, so the same decay and dt) between the
        // resampled and per-sample paths for the same flick.
        func firstMomentumDelta(resampling: Bool) -> Double {
            var configuration = RawTouchConfiguration()
            configuration.resampling.enabled = resampling
            let harness = PipelineHarness(configuration: configuration, now: { 0.13 })
            var stimuli = drag(count: 12, step: 25)
            stimuli.append(.frame(releaseFrame(at: 0.12, scrollMode: true), arrival: 0.121))
            stimuli += ticks(from: 0.003, until: 0.125)
            run(stimuli, on: harness)

            if resampling {
                harness.ticker.tick(at: 0.13)
            } else {
                harness.scheduler.fireRepeating(count: 1)
            }
            let momentum = harness.captured.phases.last
            XCTAssertEqual(momentum?.momentum, .begin)
            return momentum?.deltaY ?? 0
        }

        let reference = firstMomentumDelta(resampling: false)
        let resampled = firstMomentumDelta(resampling: true)
        XCTAssertGreaterThan(reference, 0)
        XCTAssertEqual(resampled, reference, accuracy: reference * 0.12)
    }

    func testStopThenLiftYieldsNoMomentumWithResampling() {
        let harness = PipelineHarness()
        var stimuli = drag(count: 12, step: 25)
        for index in 1...10 {
            let t = Double(11 + index) * frameInterval
            stimuli.append(.frame(scrollFrame(x: 1000 + 11 * 25, at: t), arrival: t + 0.001))
        }
        stimuli.append(.frame(releaseFrame(at: 0.22, scrollMode: true), arrival: 0.221))
        stimuli += ticks(from: 0.003, until: 0.25)
        run(stimuli, on: harness)

        XCTAssertEqual(harness.captured.scrollPhases.last, .ended)
        XCTAssertTrue(harness.captured.phases.allSatisfy { $0.momentum == CGMomentumScrollPhase(rawValue: 0)! })
        XCTAssertFalse(harness.ticker.isTicking)
        XCTAssertNil(harness.pipeline.activeSource?.padID)
    }

    /// A sensor glitch mid-drag, through the resampler: the jump reaches
    /// the engine whole, so nothing of it is scrolled, and a lift right
    /// after it does not coast from it.
    func testAGlitchJumpIsNeitherScrolledNorCoastedWithResampling() {
        let harness = PipelineHarness()
        var stimuli = drag(count: 10, step: 2)
        for index in 0..<3 {
            let t = Double(10 + index) * frameInterval
            stimuli.append(.frame(scrollFrame(x: 1000 + 1500 + (9 + index) * 2, at: t), arrival: t + 0.001))
        }
        stimuli.append(.frame(releaseFrame(at: 0.13, scrollMode: true), arrival: 0.131))
        stimuli += ticks(from: 0.003, until: 0.16)
        run(stimuli, on: harness)

        // 22 counts of finger motion either side of the jump, at 0.25 pt,
        // plus what the extrapolation carried (a few counts at most).
        XCTAssertEqual(harness.captured.deltas.reduce(0, +), 5.5, accuracy: 1, "no piece of the jump is scrolled")
        XCTAssertEqual(harness.captured.scrollPhases.last, .ended)
        XCTAssertTrue(harness.captured.phases.allSatisfy { $0.momentum == CGMomentumScrollPhase(rawValue: 0)! })
        XCTAssertNil(harness.pipeline.activeSource?.padID)
    }

    // MARK: - Fallbacks

    func testWithoutADisplayLinkFramesDriveTheEngineDirectlyAndMomentumUsesTheTimer() {
        let harness = PipelineHarness()
        harness.ticker.refusesToStart = true

        var stimuli = drag(count: 12, step: 25)
        stimuli.append(.frame(releaseFrame(at: 0.12, scrollMode: true), arrival: 0.121))
        run(stimuli, on: harness)

        // One delta per raw frame after the touch-down, as before.
        XCTAssertEqual(harness.captured.scrollPhases.filter { $0 == .began || $0 == .changed }.count, 11)
        XCTAssertEqual(harness.captured.scrollPhases.last, .ended)
        XCTAssertFalse(harness.ticker.isTicking)
        XCTAssertTrue(harness.scheduler.liveTimers.contains { $0.repeats }, "momentum on the timer")

        harness.scheduler.fireRepeating(count: 1)
        XCTAssertEqual(harness.captured.phases.last?.momentum, .begin)
    }

    func testResamplingOffLeavesTheOldPathIntact() {
        var configuration = RawTouchConfiguration()
        configuration.resampling.enabled = false
        let harness = PipelineHarness(configuration: configuration)

        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0))
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1030, at: frameInterval))
        XCTAssertEqual(harness.captured.scrollPhases, [.began])
        XCTAssertEqual(harness.captured.deltas, [7.5])
        XCTAssertEqual(harness.ticker.startCount, 0)
    }

    func testTurningResamplingOffMidGestureKeepsTheGestureAndTotal() {
        let harness = PipelineHarness()
        var stimuli = drag(count: 10, step: 30)
        stimuli += ticks(from: 0.003, until: 0.095)
        run(stimuli, on: harness)

        var off = RawTouchConfiguration()
        off.resampling.enabled = false
        off.acceleration.enabled = false  // linear deltas, as the harness builds them
        harness.pipeline.configure(
            capabilities: RawTouchCapabilities(
                padsPresent: 0x03,
                capabilityBits: RawTouchCapabilities.Capability.hostLease,
                rotate90: true,
                invertY: true
            ),
            configuration: off,
            systemPrefersNatural: false
        )
        XCTAssertEqual(harness.pipeline.activeSource?.padID, 0, "the gesture survives a live reconfigure")

        // Frames now go straight to the engine; the total still telescopes.
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000 + 10 * 30, at: 0.10))
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000 + 11 * 30, at: 0.11))
        harness.pipeline.handle(wireFrame: releaseFrame(at: 0.30, scrollMode: true))
        XCTAssertEqual(harness.captured.scrollPhases.last, .ended)
        XCTAssertEqual(harness.captured.deltas.reduce(0, +), Double(11 * 30) * 0.25, accuracy: 1e-9)
    }

    // MARK: - The latency in force

    /// The latency a gesture runs at is adopted at touch-down and held for
    /// the whole gesture: raising it mid-gesture would ask the resampler
    /// for a time before its last estimate, and lowering it would move
    /// content under a moving finger.
    func testTheLatencyIsAdoptedAtTouchDownAndHeldForTheGesture() {
        let harness = PipelineHarness(fixedLatency: 0.005)
        XCTAssertEqual(harness.pipeline.resamplerLatency, 0.005, "before any frame")

        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0))
        XCTAssertEqual(harness.pipeline.resamplerLatency, 0.005)

        harness.pipeline.fixedLatency = 0.001
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1024, at: frameInterval))
        XCTAssertEqual(harness.pipeline.resamplerLatency, 0.001, "the next touch-down takes the new value")
    }

    // MARK: - Interactions with the rest of the pipeline

    func testACrossPadCatchStartsFromTheNewPadsOwnPosition() {
        let harness = PipelineHarness()
        var stimuli = drag(count: 12, step: 25, pad: 0)
        stimuli.append(.frame(releaseFrame(at: 0.12, scrollMode: true, pad: 0), arrival: 0.121))
        stimuli += ticks(from: 0.003, until: 0.16)
        run(stimuli, on: harness)
        XCTAssertEqual(harness.pipeline.activeSource?.padID, 0)
        XCTAssertEqual(harness.captured.phases.last?.momentum, .continuous)

        // Pad 1 catches at a completely different raw position (300 vs
        // pad 0's ~1300), then moves 30 counts at 3000 counts/s: the deltas
        // after the catch must be pad 1's own motion — at most 30 counts
        // plus one horizon of prediction — never a jump from pad 0's
        // coordinates (~250 pt).
        let before = harness.captured.phases.count
        harness.pipeline.handle(wireFrame: scrollFrame(x: 300, at: 0.17, pad: 1))
        XCTAssertEqual(harness.pipeline.activeSource?.padID, 1)
        harness.ticker.tick(at: 0.175)
        XCTAssertEqual(harness.captured.phases[before].momentum, .end, "the catch lands on the tick")
        XCTAssertEqual(harness.captured.phases.count, before + 1, "the origin frame posts nothing")
        harness.pipeline.handle(wireFrame: scrollFrame(x: 330, at: 0.18, pad: 1))
        harness.ticker.tick(at: 0.175 + displayPeriod)
        harness.ticker.tick(at: 0.175 + 2 * displayPeriod)
        let afterCatch = harness.captured.phases.dropFirst(before + 1)
        XCTAssertEqual(afterCatch.first?.scroll, .began)
        XCTAssertEqual(afterCatch.count, 2)
        for phase in afterCatch {
            XCTAssertGreaterThan(phase.deltaY, 0)
            XCTAssertLessThanOrEqual(phase.deltaY, (30 + 30) * 0.25 + 0.25)
        }
    }

    func testTheStaleTouchWatchdogFlushesThroughTheResampler() {
        var now: TimeInterval = 10
        var configuration = RawTouchConfiguration()
        configuration.momentum.minimumFlickSpeed = 100_000
        let harness = PipelineHarness(configuration: configuration, now: { now })

        // A slow drag (no momentum on lift-off) whose last sample the
        // engine has not seen when the stream goes silent. The first step
        // is flick-sized so the began is out before the silence.
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 10))
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1030, at: 10.01))
        harness.ticker.tick(at: 10.012)
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1034, at: 10.02))
        XCTAssertTrue(harness.ticker.isTicking)

        now = 10.3
        harness.scheduler.fireOneShots()
        XCTAssertEqual(harness.captured.scrollPhases.last, .ended)
        XCTAssertEqual(
            harness.captured.deltas.reduce(0, +), 8.5, "the flush delivered the final 4 counts on top of the first 30")
        XCTAssertFalse(harness.ticker.isTicking)
        XCTAssertNil(harness.pipeline.activeSource?.padID)
    }

    func testInterruptStopsTheDisplayLink() {
        let harness = PipelineHarness()
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0))
        XCTAssertTrue(harness.ticker.isTicking)
        harness.ticker.tick(at: 0.005)

        harness.pipeline.interrupt()
        XCTAssertFalse(harness.ticker.isTicking)
        XCTAssertEqual(harness.captured.scrollPhases, [.cancelled], "a touch the engine saw only at its origin")
        XCTAssertNil(harness.pipeline.activeSource?.padID)
    }

    func testInterruptBeforeTheFirstTickDropsTheBufferedTouchSilently() {
        let harness = PipelineHarness()
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0))

        // The engine never saw the touch, so there is no series to close.
        harness.pipeline.interrupt()
        XCTAssertFalse(harness.ticker.isTicking)
        XCTAssertTrue(harness.captured.events.isEmpty)
        XCTAssertNil(harness.pipeline.activeSource?.padID)
    }

    func testATickFromAnInvalidatedSubscriptionIsIgnored() {
        let harness = PipelineHarness()
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0))
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1040, at: 0.01))
        let stale = harness.ticker.sources[0]
        harness.pipeline.handle(wireFrame: releaseFrame(at: 0.02, scrollMode: true))
        XCTAssertTrue(stale.isInvalidated)
        let count = harness.captured.events.count

        // A vsync that was already queued for the event thread when the
        // subscription was invalidated must do nothing.
        harness.pipeline.handle(wireFrame: scrollFrame(x: 2000, at: 1))
        stale.fire(at: 1.005)
        XCTAssertEqual(harness.captured.events.count, count, "no frame for the new touch from the old ticks")
    }

    func testAnUnleasedFrameMidGestureCancelsAndStopsTheDisplayLink() {
        let harness = PipelineHarness()
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0))
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1040, at: 0.01))
        harness.ticker.tick(at: 0.012)
        harness.ticker.tick(at: 0.012 + displayPeriod)
        XCTAssertEqual(harness.captured.scrollPhases, [.began])

        harness.pipeline.handle(wireFrame: releaseFrame(at: 0.03, scrollMode: true, leaseHeld: false))
        XCTAssertEqual(harness.captured.scrollPhases.last, .ended)
        XCTAssertFalse(harness.ticker.isTicking)
        XCTAssertTrue(harness.scheduler.liveTimers.allSatisfy { !$0.repeats })
    }
}
