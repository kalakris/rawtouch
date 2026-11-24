// MIT License
// Copyright (c) 2026 RawTouch contributors

import CoreGraphics
import RawTouchTestSupport
import XCTest

@testable import RawTouchCore

/// The pipeline: lease filtering, pad arbitration, per-pad configuration and
/// the stale-touch watchdog. Every CGEvent is captured by an injected sink —
/// nothing is posted, so these tests can never raise an Accessibility prompt.
final class TouchScrollPipelineTests: XCTestCase {
    private let frameInterval: TimeInterval = 0.01

    /// An unpaced Go60 under `testDeviceKey`, latency measured.
    private func makePipeline(
        configuration: RawTouchConfiguration = .init(),
        capabilities: RawTouchCapabilities = .go60(),
        now: (() -> TimeInterval)? = nil,
        pointsPerMM: @escaping () -> Double = { testPointsPerMM }
    ) -> (TouchScrollPipeline, CapturedScrollEvents, FakeTimerScheduler) {
        let harness = PipelineHarness(
            configuration: configuration,
            paced: false,
            fixedLatency: nil,
            capabilities: capabilities,
            deviceKey: testDeviceKey,
            now: now,
            pointsPerMM: pointsPerMM
        )
        return (harness.pipeline, harness.captured, harness.scheduler)
    }

    // MARK: - Lease filtering

    func testFramesWithTheLeaseBitClearAreDroppedSilently() {
        let (pipeline, captured, _) = makePipeline()

        for step in 0..<5 {
            pipeline.handle(
                wireFrame: scrollFrame(
                    x: 1000 + step * 25,
                    at: Double(step) * frameInterval,
                    leaseHeld: false
                ))
        }
        pipeline.handle(wireFrame: releaseFrame(at: 0.05, scrollMode: true, leaseHeld: false))

        XCTAssertTrue(captured.events.isEmpty, "no scroll may be synthesized while the firmware wheel is live")
        XCTAssertNil(pipeline.activeSource?.padID)
    }

    func testFramesWithTheLeaseBitSetDriveScrolling() {
        let (pipeline, captured, _) = makePipeline()

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0))
        pipeline.handle(wireFrame: scrollFrame(x: 1030, at: frameInterval))

        // The touch-down posts no scroll event; the first movement is the
        // began and carries its delta.
        XCTAssertEqual(captured.scrollPhases, [.began])
        // rotate-90 + y-invert ⇒ axis x, invert false; 30 counts * 0.25.
        XCTAssertEqual(captured.deltas.last, 7.5)
    }

    /// The window this bit exists to close: the lease lapses mid-gesture
    /// (sleep, reboot, profile switch), the firmware resumes its own wheel
    /// events, and the host must stop synthesizing at once rather than
    /// double-scrolling. The firmware announces the lapse with a single
    /// trailing bit-2-clear release frame; any bit-2-clear frame for the
    /// owning pad cancels the series immediately.
    func testUnleasedFrameDuringAnActiveTouchCancelsTheSeries() {
        let (pipeline, captured, _) = makePipeline(now: { 1.0 })

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0))
        pipeline.handle(wireFrame: scrollFrame(x: 1030, at: frameInterval))
        captured.reset()

        // The firmware's trailing synthetic release: touched clear, bit 2
        // clear.
        pipeline.handle(
            wireFrame: releaseFrame(
                at: frameInterval * 2,
                scrollMode: true,
                leaseHeld: false
            ))

        XCTAssertEqual(captured.scrollPhases, [.ended], "the series is closed at once, not left to the watchdog")
        XCTAssertNil(pipeline.activeSource?.padID)

        // Further bit-2-clear frames (Standard-mode wheel is live) synthesize
        // nothing.
        captured.reset()
        pipeline.handle(wireFrame: scrollFrame(x: 1100, at: frameInterval * 3, leaseHeld: false))
        XCTAssertTrue(captured.events.isEmpty)
    }

    /// The no-momentum property: a lease lapse after a fast drag must NOT seed
    /// lift-off momentum — the finger may still be down, scrolling through
    /// the firmware's resumed wheel events, and momentum on top would
    /// double-scroll.
    func testLeaseLapseCancelAddsNoLiftOffMomentum() {
        let (pipeline, captured, scheduler) = makePipeline(now: { 1.0 })

        // A fast drag: a normal lift-off here would enter momentum (the
        // same input `flickIntoMomentum` uses).
        for step in 0..<12 {
            pipeline.handle(wireFrame: scrollFrame(x: 1000 + step * 25, at: Double(step) * frameInterval))
        }
        captured.reset()

        pipeline.handle(
            wireFrame: scrollFrame(
                x: 1300,
                at: 12 * frameInterval,
                leaseHeld: false
            ))

        XCTAssertEqual(captured.scrollPhases, [.ended])
        XCTAssertTrue(
            captured.phases.allSatisfy { $0.momentum == CGMomentumScrollPhase(rawValue: 0)! },
            "a lease-lapse cancel must never post momentum events"
        )
        XCTAssertTrue(
            scheduler.liveTimers.allSatisfy { !$0.repeats },
            "no momentum tick timer may be running after a lease-lapse cancel"
        )
        XCTAssertNil(pipeline.activeSource?.padID)
    }

    func testUnleasedFrameDuringCoastingCancelsTheMomentumTail() {
        let (pipeline, captured, scheduler) = makePipeline()

        let liftTime = flickIntoMomentum(pipeline, scheduler, pad: 0)
        XCTAssertEqual(pipeline.activeSource?.padID, 0)
        captured.reset()

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: liftTime + 0.05, leaseHeld: false))

        // The momentum series is closed out (momentum .end, zero delta) with
        // no further coasting.
        XCTAssertEqual(captured.phases.count, 1)
        XCTAssertEqual(captured.phases[0].momentum, .end)
        XCTAssertEqual(captured.phases[0].deltaY, 0)
        XCTAssertNil(pipeline.activeSource?.padID)
        XCTAssertTrue(scheduler.liveTimers.allSatisfy { !$0.repeats })
    }

    func testUnleasedFrameForTheOtherPadLeavesTheSeriesAlone() {
        let (pipeline, captured, _) = makePipeline()

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0, pad: 0))
        captured.reset()

        // Pad 1 has no active series: its bit-2-clear frames stay silently
        // dropped, and pad 0's gesture is untouched.
        pipeline.handle(wireFrame: scrollFrame(x: 1500, at: frameInterval, pad: 1, leaseHeld: false))
        XCTAssertTrue(captured.events.isEmpty)
        XCTAssertEqual(pipeline.activeSource?.padID, 0)

        // A flick-fast step (15 pt in 20 ms), so the began is out at once.
        pipeline.handle(wireFrame: scrollFrame(x: 1060, at: frameInterval * 2, pad: 0))
        XCTAssertEqual(captured.scrollPhases, [.began])
    }

    func testLeaseReacquiredResumesSynthesis() {
        let (pipeline, captured, _) = makePipeline()

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0, leaseHeld: false))
        XCTAssertTrue(captured.events.isEmpty)

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: frameInterval))
        pipeline.handle(wireFrame: scrollFrame(x: 1030, at: frameInterval * 2))
        XCTAssertEqual(captured.scrollPhases, [.began])
    }

    /// A leased frame that is *not* in scroll mode still reaches the engine:
    /// it is how a gesture ends when the user releases the scroll layer while
    /// still touching. It synthesizes no scroll delta of its own.
    func testLeasedPointerModeFrameEndsTheGestureWithoutScrolling() {
        let (pipeline, captured, _) = makePipeline()

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0))
        pipeline.handle(wireFrame: scrollFrame(x: 1030, at: frameInterval))
        captured.reset()

        pipeline.handle(wireFrame: pointerFrame(x: 1060, at: frameInterval * 2))

        XCTAssertEqual(captured.scrollPhases, [.ended])
        XCTAssertEqual(captured.deltas, [0])
    }

    // MARK: - Streaming switch

    func testNoDeviceMeansNoSynthesis() {
        let captured = CapturedScrollEvents()
        let pipeline = TouchScrollPipeline(
            poster: captured.makePoster(),
            scheduler: FakeTimerScheduler()
        )

        pipeline.handle(wireFrame: scrollFrame(at: 0))
        XCTAssertFalse(pipeline.isStreaming)
        XCTAssertTrue(captured.events.isEmpty)
    }

    func testDisabledConfigurationSilencesThePipeline() {
        let (pipeline, captured, _) = makePipeline(configuration: .init(enabled: false))

        pipeline.handle(wireFrame: scrollFrame(at: 0))
        pipeline.handle(wireFrame: scrollFrame(x: 1030, at: frameInterval))

        XCTAssertFalse(pipeline.isStreaming)
        XCTAssertTrue(captured.events.isEmpty)
    }

    func testPerPadDisableIgnoresThatPadOnly() {
        var configuration = RawTouchConfiguration()
        configuration[pad: "1"] = .init(enabled: false)
        let (pipeline, captured, _) = makePipeline(configuration: configuration)

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0, pad: 1))
        pipeline.handle(wireFrame: scrollFrame(x: 1030, at: frameInterval, pad: 1))
        XCTAssertTrue(captured.events.isEmpty)

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: frameInterval * 2, pad: 0))
        pipeline.handle(wireFrame: scrollFrame(x: 1030, at: frameInterval * 3, pad: 0))
        XCTAssertEqual(captured.scrollPhases, [.began])
    }

    // MARK: - Pad arbitration (first touch wins)

    func testFirstPadToTouchOwnsTheGestureAndTheOtherPadIsIgnored() {
        let (pipeline, captured, _) = makePipeline()

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0, pad: 1))
        XCTAssertEqual(pipeline.activeSource?.padID, 1)
        captured.reset()

        // The right pad touches too: its frames, including its release, are
        // dropped while the left pad owns the gesture.
        pipeline.handle(wireFrame: scrollFrame(x: 1500, at: frameInterval, pad: 0))
        pipeline.handle(wireFrame: releaseFrame(at: frameInterval * 2, scrollMode: true, pad: 0))
        XCTAssertTrue(captured.events.isEmpty)

        // The owning pad keeps scrolling (its first movement is the began).
        pipeline.handle(wireFrame: scrollFrame(x: 1030, at: frameInterval * 3, pad: 1))
        XCTAssertEqual(captured.scrollPhases, [.began])
        XCTAssertEqual(captured.deltas, [7.5])
    }

    func testTheOwnershipClearsWhenTheGestureEnds() {
        let (pipeline, captured, _) = makePipeline()

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0, pad: 1))
        // Slow drag: no momentum after lift-off.
        pipeline.handle(wireFrame: scrollFrame(x: 1002, at: frameInterval, pad: 1))
        pipeline.handle(wireFrame: releaseFrame(at: frameInterval * 2, scrollMode: true, pad: 1))
        XCTAssertNil(pipeline.activeSource?.padID)

        captured.reset()
        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0.1, pad: 0))
        XCTAssertEqual(pipeline.activeSource?.padID, 0)
        pipeline.handle(wireFrame: scrollFrame(x: 1030, at: 0.1 + frameInterval, pad: 0))
        XCTAssertEqual(captured.scrollPhases, [.began])
    }

    // MARK: - Pad arbitration (cross-pad catch of a momentum tail)

    /// Puts pad 0 into a coasting momentum tail: a fast flick, then a few
    /// momentum ticks so `.momentumBegan`/`.momentumChanged` are on the wire.
    private func flickIntoMomentum(
        _ pipeline: TouchScrollPipeline,
        _ scheduler: FakeTimerScheduler,
        pad: UInt8 = 0
    ) -> TimeInterval {
        PipelineHarness.flickIntoMomentum(pipeline, scheduler, pad: pad)
    }

    /// The observed defect: after a flick on one pad, the momentum tail's
    /// imperceptibly small deltas held the gesture for 5-10 s and the other
    /// pad was locked out. A scroll touch-down on the other pad must catch
    /// the tail instead: momentum ends (same series-closing event a
    /// same-pad catch posts) and the gesture transfers.
    func testScrollTouchOnTheOtherPadCatchesAMomentumTailAndTakesTheGesture() {
        let (pipeline, captured, scheduler) = makePipeline()

        let liftTime = flickIntoMomentum(pipeline, scheduler, pad: 0)
        XCTAssertEqual(pipeline.activeSource?.padID, 0)
        captured.reset()

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: liftTime + 0.05, pad: 1))

        XCTAssertEqual(pipeline.activeSource?.padID, 1)
        // Pad 0's series is closed out (momentum .end, zero delta) — no
        // half-open series left behind. Pad 1's began waits for its first
        // movement.
        XCTAssertEqual(captured.phases.count, 1)
        XCTAssertEqual(captured.phases[0].momentum, .end)
        XCTAssertEqual(captured.phases[0].deltaY, 0)
        // The decay tick timer is gone along with the momentum.
        XCTAssertTrue(scheduler.liveTimers.allSatisfy { !$0.repeats })
    }

    func testScrollTouchOnTheOtherPadDoesNotStealFromAnActiveTouch() {
        let (pipeline, captured, _) = makePipeline()

        // Pad 0's finger is physically down (engine touching, not coasting).
        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0, pad: 0))
        pipeline.handle(wireFrame: scrollFrame(x: 1030, at: frameInterval, pad: 0))
        captured.reset()

        pipeline.handle(wireFrame: scrollFrame(x: 1500, at: frameInterval * 2, pad: 1))

        XCTAssertEqual(pipeline.activeSource?.padID, 0, "first touch wins while the owning finger is down")
        XCTAssertTrue(captured.events.isEmpty)

        // Pad 0 keeps scrolling undisturbed.
        pipeline.handle(wireFrame: scrollFrame(x: 1060, at: frameInterval * 3, pad: 0))
        XCTAssertEqual(captured.scrollPhases, [.changed])
    }

    func testPointerContextTouchOnTheOtherPadDoesNotCatchTheMomentumTail() {
        let (pipeline, captured, scheduler) = makePipeline()

        let liftTime = flickIntoMomentum(pipeline, scheduler, pad: 0)
        captured.reset()

        pipeline.handle(wireFrame: pointerFrame(x: 1000, at: liftTime + 0.05, pad: 1))

        XCTAssertEqual(pipeline.activeSource?.padID, 0, "a pointer-context touch must not take over the gesture")
        XCTAssertTrue(captured.events.isEmpty)

        // Pad 0's momentum keeps coasting.
        scheduler.fireRepeating(count: 1)
        XCTAssertEqual(captured.phases.count, 1)
        XCTAssertEqual(captured.phases[0].momentum, .continuous)
    }

    /// Pointer-context frames on an idle pad are the pointer, not a
    /// gesture: they never take ownership, so they never pay for a
    /// gesture's start (the display lookup, the latency percentiles).
    func testPointerFramesNeverTakeOwnership() {
        var lookups = 0
        var activities: [RawTouchStatus.PadActivity] = []
        let (pipeline, captured, _) = makePipeline(pointsPerMM: {
            lookups += 1
            return testPointsPerMM
        })
        pipeline.onActivityChange = { activities.append($0) }
        let lookupsAfterConfigure = lookups

        for step in 0..<5 {
            pipeline.handle(wireFrame: pointerFrame(x: 1000 + step * 30, at: Double(step) * frameInterval))
            XCTAssertNil(pipeline.activeSource?.padID)
        }
        pipeline.handle(wireFrame: releaseFrame(at: 5 * frameInterval, scrollMode: false))

        XCTAssertEqual(lookups, lookupsAfterConfigure, "no gesture was started")
        XCTAssertTrue(activities.isEmpty)
        XCTAssertTrue(captured.events.isEmpty)
    }

    func testTheStolenToPadScrollsImmediately() {
        let (pipeline, captured, scheduler) = makePipeline()

        let liftTime = flickIntoMomentum(pipeline, scheduler, pad: 0)
        captured.reset()

        // Pad 1 catches the tail and drags: its first movement begins the
        // gesture and already moves content.
        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: liftTime + 0.05, pad: 1))
        pipeline.handle(wireFrame: scrollFrame(x: 1030, at: liftTime + 0.05 + frameInterval, pad: 1))

        XCTAssertEqual(pipeline.activeSource?.padID, 1)
        XCTAssertEqual(captured.phases.count, 2)
        XCTAssertEqual(captured.phases[0].momentum, .end)
        XCTAssertEqual(captured.phases[1].scroll, .began)
        XCTAssertEqual(captured.deltas[1], 7.5, "30 counts * 0.25 points per count")
    }

    // MARK: - Per-pad configuration

    func testPerPadGainOverrideAppliesWhenThatPadOwnsTheGesture() {
        var configuration = RawTouchConfiguration()
        configuration.scale = 1.0
        configuration[pad: "1"] = .init(scale: 4.0)
        let (pipeline, captured, _) = makePipeline(configuration: configuration)

        XCTAssertEqual(pipeline.engineConfig(forPad: 0)?.pointsPerCount, 0.25)
        XCTAssertEqual(pipeline.engineConfig(forPad: 1)?.pointsPerCount, 1.0)

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0, pad: 1))
        pipeline.handle(wireFrame: scrollFrame(x: 1030, at: frameInterval, pad: 1))
        XCTAssertEqual(captured.deltas.last, 30.0)
    }

    func testPerPadAxisAndInvertOverridesComposeWithReverseScrolling() {
        var configuration = RawTouchConfiguration()
        configuration.reverseScrolling = true
        configuration[pad: "0"] = .init(axis: .y, invert: true, invertHorizontal: false)
        let (pipeline, _, _) = makePipeline(configuration: configuration)

        let config = pipeline.engineConfig(forPad: 0)
        XCTAssertEqual(config?.axis, .y)
        XCTAssertEqual(config?.horizontalAxis, .x)
        // orientation override true, system natural off, reverse on ⇒ false.
        XCTAssertEqual(config?.invert, false)
        // horizontal override false, reverse on ⇒ true.
        XCTAssertEqual(config?.invertHorizontal, true)
    }

    /// End to end on the Go60 mapping: raw X moves content vertically, raw
    /// Y horizontally (inverted, per the derivation), both at once — and a
    /// pad limited to one direction posts zero on the other.
    func testADiagonalDragPostsBothAxesAndASingleAxisPadPostsOne() {
        let (pipeline, captured, _) = makePipeline()

        // A diagonal start is ambiguous to the poster's began rule, so it
        // is released at the eighth frame — vertical, the prior, since
        // horizontal (10 pt a frame against 7.5) does not clearly lead —
        // the other axis riding on the changed event after it: over the
        // drag both axes arrive in full.
        pipeline.handle(wireFrame: scrollFrame(x: 1000, y: 700, at: 0))
        for step in 1...9 {
            pipeline.handle(
                wireFrame: scrollFrame(x: 1000 + 30 * step, y: 700 - 40 * step, at: Double(step) * frameInterval))
        }
        XCTAssertEqual(captured.scrollPhases, [.began, .changed])
        XCTAssertEqual(captured.deltas.reduce(0, +), 67.5, accuracy: 1e-6, "9 × +30 raw X × 0.25")
        XCTAssertEqual(captured.horizontalDeltas.reduce(0, +), 90, accuracy: 1e-6, "9 × −40 raw Y × 0.25, inverted")
        XCTAssertEqual(captured.deltas.first, 60, "the began names one axis only")
        XCTAssertEqual(captured.horizontalDeltas.first, 0)

        var configuration = RawTouchConfiguration()
        configuration[pad: "0"] = .init(axes: .vertical)
        let (verticalOnly, verticalCaptured, _) = makePipeline(configuration: configuration)
        verticalOnly.handle(wireFrame: scrollFrame(x: 1000, y: 700, at: 0))
        verticalOnly.handle(wireFrame: scrollFrame(x: 1030, y: 660, at: frameInterval))
        XCTAssertEqual(verticalCaptured.deltas.last, 7.5)
        XCTAssertEqual(verticalCaptured.horizontalDeltas.last, 0)
    }

    // MARK: - Physical gain resolution

    /// Drags one gesture on `pad` from `x` in 30-count steps, settles (so
    /// the lift carries no momentum and the series really ends), and lifts.
    /// Returns the time just after the release.
    @discardableResult
    private func dragAndLift(
        _ pipeline: TouchScrollPipeline,
        from start: TimeInterval,
        x: Int = 1000,
        steps: Int = 4,
        pad: UInt8 = 0
    ) -> TimeInterval {
        var time = start
        for step in 0...steps {
            pipeline.handle(wireFrame: scrollFrame(x: x + step * 30, at: time, pad: pad))
            time += frameInterval
        }
        // Held still well past the velocity fit's 30 ms weighting window:
        // the lift-off speed reads as zero, so no momentum keeps the series
        // (and the pad's ownership) alive.
        for _ in 0..<20 {
            pipeline.handle(wireFrame: scrollFrame(x: x + steps * 30, at: time, pad: pad))
            time += frameInterval
        }
        pipeline.handle(wireFrame: releaseFrame(at: time, scrollMode: true, pad: pad))
        return time + frameInterval
    }

    /// Resolving the display's density costs a CoreGraphics round trip, so
    /// it happens once per gesture — at touch-down, where the display link
    /// is picked too — and never per frame.
    func testTheDisplayDensityIsResolvedOncePerGestureNotPerFrame() {
        var lookups = 0
        let (pipeline, _, _) = makePipeline(pointsPerMM: {
            lookups += 1
            return testPointsPerMM
        })
        XCTAssertEqual(lookups, 1, "configure resolves once so diagnostics have a value before any gesture")

        let afterFirst = dragAndLift(pipeline, from: 0)
        XCTAssertNil(pipeline.activeSource?.padID, "the settled lift ends the series")
        XCTAssertEqual(lookups, 2, "ten frames, one lookup")

        dragAndLift(pipeline, from: afterFirst)
        XCTAssertEqual(lookups, 3, "the next gesture resolves again")
    }

    /// The cursor can move to a display of a different density between
    /// gestures — that is the whole reason the lookup is per gesture — so
    /// the next gesture must scroll by the new display's measure.
    func testAGestureUsesTheDensityResolvedAtItsOwnTouchDown() {
        var pointsPerMM = testPointsPerMM
        let (pipeline, captured, _) = makePipeline(pointsPerMM: { pointsPerMM })

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0))
        pipeline.handle(wireFrame: scrollFrame(x: 1030, at: frameInterval))
        XCTAssertEqual(captured.deltas.last, 7.5, "30 counts at 0.25 points per count")

        let afterFirst = dragAndLift(pipeline, from: frameInterval * 2, x: 1030)

        // The cursor lands on a display with twice the point density: the
        // same finger millimetres now buy twice the points.
        pointsPerMM *= 2
        captured.reset()
        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: afterFirst))
        pipeline.handle(wireFrame: scrollFrame(x: 1030, at: afterFirst + frameInterval))
        XCTAssertEqual(captured.deltas.last, 15.0)
        XCTAssertEqual(pipeline.engineConfig(forPad: 0)?.pointsPerCount, 0.5)
    }

    /// A live `configure` (a Natural Scrolling change, an endpoint joining,
    /// a config edit) re-derives the gesture in flight's settings, but not
    /// its density: the gesture keeps the display it started on even if
    /// the cursor has moved to another since.
    func testALiveConfigureKeepsTheGesturesOwnDensity() {
        var pointsPerMM = testPointsPerMM
        let (pipeline, captured, _) = makePipeline(pointsPerMM: { pointsPerMM })

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0))
        pipeline.handle(wireFrame: scrollFrame(x: 1030, at: frameInterval))
        XCTAssertEqual(captured.deltas.last, 7.5)

        // Mid-gesture, the cursor is over a denser display and something
        // triggers a configure.
        pointsPerMM *= 2
        pipeline.configure(capabilities: .go60(), deviceKey: testDeviceKey, systemPrefersNatural: false)
        pipeline.handle(wireFrame: scrollFrame(x: 1060, at: frameInterval * 2))
        XCTAssertEqual(captured.deltas.last, 7.5, "still 0.25 points per count")
        XCTAssertEqual(pipeline.engineConfig(forPad: 0)?.pointsPerCount, 0.25)
        XCTAssertEqual(
            pipeline.engineConfig(forPad: 1)?.pointsPerCount, 0.5, "an idle pad takes the display under the cursor")
    }

    // MARK: - Stale-touch watchdog

    func testSilenceMidTouchEndsTheTouch() {
        var now: TimeInterval = 10
        // A flick-fast step (15 pt in 20 ms, so the began is out at once)
        // that must not coast: the momentum threshold is out of reach.
        var configuration = RawTouchConfiguration()
        configuration.momentum.minimumFlickSpeed = 100_000
        let (pipeline, captured, scheduler) = makePipeline(configuration: configuration, now: { now })

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 10))
        pipeline.handle(wireFrame: scrollFrame(x: 1060, at: 10.02))
        captured.reset()

        // The watchdog fires early (a frame kept the touch fresh): it re-arms
        // instead of closing the gesture.
        now = 10.1
        scheduler.fireOneShots()
        XCTAssertTrue(captured.events.isEmpty)
        XCTAssertEqual(pipeline.activeSource?.padID, 0)

        // Now the stream really is silent past the timeout.
        now = 10.3
        scheduler.fireOneShots()
        XCTAssertEqual(captured.scrollPhases, [.ended])
        XCTAssertNil(pipeline.activeSource?.padID)
    }

    /// The watchdog ends a touch whose lift-off was never seen, so it
    /// never starts a coast: a stream that goes silent mid-flick (a BLE
    /// profile switch to another host, a disconnect) must not leave this
    /// host scrolling on its own — the same rule as a lease lapse.
    func testSilenceMidFlickEndsTheTouchWithoutMomentum() {
        var now: TimeInterval = 10
        let (pipeline, captured, scheduler) = makePipeline(now: { now })

        // A fast drag: a real release here would coast (the input
        // `flickIntoMomentum` uses).
        for step in 0..<12 {
            pipeline.handle(wireFrame: scrollFrame(x: 1000 + step * 25, at: 10 + Double(step) * frameInterval))
        }
        captured.reset()

        now = 10.11 + TouchScrollPipeline.staleTouchTimeout + 0.01
        scheduler.fireOneShots()
        XCTAssertEqual(captured.scrollPhases, [.ended])
        XCTAssertTrue(
            captured.phases.allSatisfy { $0.momentum == CGMomentumScrollPhase(rawValue: 0)! },
            "a silent stream must never start a coast"
        )
        XCTAssertTrue(scheduler.liveTimers.allSatisfy { !$0.repeats }, "no momentum tick timer")
        XCTAssertNil(pipeline.activeSource?.padID)
    }

    func testARealReleaseDisarmsTheWatchdog() {
        var now: TimeInterval = 10
        let (pipeline, captured, scheduler) = makePipeline(now: { now })

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 10))
        pipeline.handle(wireFrame: scrollFrame(x: 1002, at: 10.01))
        pipeline.handle(wireFrame: releaseFrame(at: 10.02, scrollMode: true))
        captured.reset()

        now = 11
        scheduler.fireOneShots()
        XCTAssertTrue(captured.events.isEmpty, "a real release must leave no armed watchdog behind")
    }

    // MARK: - Frames that must be ignored

    func testSecondaryContactsAreIgnored() {
        let (pipeline, captured, _) = makePipeline()

        var frame = scrollFrame(x: 1000, at: 0)
        frame.contactID = 1
        pipeline.handle(wireFrame: frame)

        XCTAssertTrue(captured.events.isEmpty)
        XCTAssertNil(pipeline.activeSource?.padID)
    }

    // MARK: - Interrupt

    func testInterruptClosesAnOpenGesture() {
        let (pipeline, captured, _) = makePipeline()

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0))
        pipeline.handle(wireFrame: scrollFrame(x: 1030, at: frameInterval))
        captured.reset()

        pipeline.interrupt()
        XCTAssertEqual(captured.scrollPhases, [.ended])
        XCTAssertNil(pipeline.activeSource?.padID)
    }

    func testLosingTheDeviceClosesAnOpenGesture() {
        let (pipeline, captured, _) = makePipeline()

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0))
        pipeline.handle(wireFrame: scrollFrame(x: 1030, at: frameInterval))
        captured.reset()

        pipeline.configure(capabilities: nil, systemPrefersNatural: false)
        XCTAssertFalse(pipeline.isStreaming)
        XCTAssertEqual(captured.scrollPhases, [.ended])
    }

    // MARK: - Activity reporting

    func testActivityRunsIdleTouchingCoastingIdle() {
        let (pipeline, _, scheduler) = makePipeline()
        var activities: [RawTouchStatus.PadActivity] = []
        pipeline.onActivityChange = { activities.append($0) }

        _ = flickIntoMomentum(pipeline, scheduler, pad: 0)
        XCTAssertEqual(activities, [.touching(padID: 0), .coasting(padID: 0)])

        // Let the momentum decay away completely.
        scheduler.fireRepeating(count: 2000)
        XCTAssertEqual(activities, [.touching(padID: 0), .coasting(padID: 0), .idle])
    }

    func testActivityIsReportedPerTransitionNotPerFrame() {
        let (pipeline, _, _) = makePipeline()
        var activities: [RawTouchStatus.PadActivity] = []
        pipeline.onActivityChange = { activities.append($0) }

        for step in 0..<10 {
            pipeline.handle(wireFrame: scrollFrame(x: 1000 + step * 25, at: Double(step) * frameInterval))
        }

        XCTAssertEqual(activities, [.touching(padID: 0)], "ten frames, one transition")
    }

    func testASlowReleaseGoesStraightBackToIdle() {
        let (pipeline, _, _) = makePipeline()
        var activities: [RawTouchStatus.PadActivity] = []
        pipeline.onActivityChange = { activities.append($0) }

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0))
        pipeline.handle(wireFrame: scrollFrame(x: 1002, at: frameInterval))
        pipeline.handle(wireFrame: releaseFrame(at: frameInterval * 2, scrollMode: true))

        XCTAssertEqual(activities, [.touching(padID: 0), .idle], "no momentum, no coasting state")
    }

    func testInterruptReportsIdle() {
        let (pipeline, _, _) = makePipeline()
        var activities: [RawTouchStatus.PadActivity] = []
        pipeline.onActivityChange = { activities.append($0) }

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0))
        pipeline.interrupt()

        XCTAssertEqual(activities, [.touching(padID: 0), .idle])
    }

    func testACrossPadCatchReportsTheStealingPad() {
        let (pipeline, _, scheduler) = makePipeline()
        var activities: [RawTouchStatus.PadActivity] = []
        pipeline.onActivityChange = { activities.append($0) }

        let liftTime = flickIntoMomentum(pipeline, scheduler, pad: 0)
        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: liftTime + 0.05, pad: 1))

        XCTAssertEqual(
            activities,
            [
                .touching(padID: 0),
                .coasting(padID: 0),
                .touching(padID: 1),
            ])
    }

    // MARK: - Gesture summaries

    /// Two taps that measure exactly alike are still two gestures: each
    /// delivers its own summary, and a coast's closing half is delivered
    /// under the touch that started it.
    func testIdenticalGesturesEachDeliverTheirOwnSummary() {
        let (pipeline, _, scheduler) = makePipeline()
        var summaries: [RawTouchGestureSummary] = []
        pipeline.onGestureSummary = { summaries.append($0) }

        for tap in 0..<2 {
            let start = Double(tap) * 1.0
            pipeline.handle(wireFrame: scrollFrame(x: 1000, at: start))
            pipeline.handle(wireFrame: releaseFrame(at: start + frameInterval, scrollMode: true))
        }
        XCTAssertEqual(summaries.count, 2, "one summary per tap")
        XCTAssertNotEqual(summaries[0].gestureID, summaries[1].gestureID)
        XCTAssertFalse(summaries[1].isSameTouch(as: summaries[0]))

        _ = flickIntoMomentum(pipeline, scheduler, pad: 0)
        scheduler.fireRepeating(count: 2000)
        XCTAssertEqual(summaries.count, 4, "the flick: lift-off, then the coast's end")
        XCTAssertTrue(summaries[3].isSameTouch(as: summaries[2]))
        XCTAssertEqual(summaries[2].complete, false)
        XCTAssertEqual(summaries[3].complete, true)
    }

    /// The summary carries the split link of the gesture's latest touched
    /// frame — the latest if it changed mid-gesture — and none for a
    /// local pad. The coast half keeps its touch half's.
    func testTheSummaryCarriesTheLatestSplitLinkOfTheGesture() {
        let (pipeline, _, scheduler) = makePipeline()
        var summaries: [RawTouchGestureSummary] = []
        pipeline.onGestureSummary = { summaries.append($0) }

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0, splitLink: .wired))
        pipeline.handle(wireFrame: scrollFrame(x: 1010, at: frameInterval, splitLink: .wireless))
        pipeline.handle(wireFrame: releaseFrame(at: 2 * frameInterval, scrollMode: true))
        XCTAssertEqual(summaries.last?.splitLink, .wireless)

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 1))
        pipeline.handle(wireFrame: releaseFrame(at: 1 + frameInterval, scrollMode: true, splitLink: .wired))
        XCTAssertNil(summaries.last?.splitLink, "a local pad; a release frame's bits are not a touched frame's")

        let coasting = summaries.count
        var time = 2.0
        for step in 0..<6 {
            pipeline.handle(wireFrame: scrollFrame(x: 1000 + step * 40, at: time, splitLink: .wired))
            time += frameInterval
        }
        pipeline.handle(wireFrame: releaseFrame(at: time, scrollMode: true))
        scheduler.fireRepeating(count: 2000)
        XCTAssertEqual(summaries.count, coasting + 2, "lift-off, then the coast's end")
        XCTAssertEqual(summaries.map(\.splitLink).suffix(2), [.wired, .wired])
    }
}
