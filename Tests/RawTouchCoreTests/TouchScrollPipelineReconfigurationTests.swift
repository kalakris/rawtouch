// MIT License
// Copyright (c) 2026 RawTouch contributors

import CoreGraphics
import RawTouchTestSupport
import XCTest

@testable import RawTouchCore

/// What a live configuration edit does to a gesture already in flight.
///
/// `configure` runs on the event thread while frames are flowing — a slider
/// drag in Settings, a config-file save, a pad switched off — and most of it
/// applies seamlessly (gain, direction, ballistics, momentum, latency). Two
/// edits cannot be applied to a gesture at all, and this suite pins them:
/// the active pad leaving the enabled set, and the active pad's axis
/// mapping changing under it — which raw axis is vertical, or which
/// directions are on. Both must end the gesture *without* momentum — a pad
/// the user just turned off has no business coasting.
///
/// Every CGEvent is captured by an injected sink; nothing is posted, so these
/// tests can never raise an Accessibility prompt.
final class TouchScrollPipelineReconfigurationTests: XCTestCase {
    /// The Go60 feature report: both pads, host lease supported,
    /// rotate-90 + y-invert (⇒ the engine reads x).
    private func capabilities() -> RawTouchCapabilities {
        .go60()
    }

    /// A paced Go60 under `testDeviceKey` at `testPointsPerMM` (gain 1.0 is
    /// 0.25 points per count), with the latency by hand (0 ms): the
    /// assertions count deltas per tick; what the estimator measures has its
    /// own suite.
    private func makePipeline(
        configuration: RawTouchConfiguration,
        now: (() -> TimeInterval)? = nil
    ) -> (TouchScrollPipeline, CapturedScrollEvents, FakeTimerScheduler, ManualDisplayTicker) {
        let harness = PipelineHarness(
            configuration: configuration,
            capabilities: capabilities(),
            deviceKey: testDeviceKey,
            now: now
        )
        return (harness.pipeline, harness.captured, harness.scheduler, harness.ticker)
    }

    // MARK: - The active pad leaving the set

    /// Once `configure` rebuilds `padConfigs` without the active pad, every
    /// frame for it — its release and the synthesized stale-touch lift-off
    /// included — is dropped by the `padConfigs` guard. So the reconfigure
    /// itself must close the gesture, or nothing would clear the active
    /// source, the display link would stay live and the other pad would be
    /// locked out for good.
    func testDisablingActivePadClosesGestureAndAllowsOtherPad() {
        var now = 0.0
        var config = RawTouchConfiguration()
        config.acceleration.enabled = false
        let caps = capabilities()
        let (pipeline, _, scheduler, ticker) = makePipeline(configuration: config, now: { now })

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0))
        ticker.tick(at: 0.001)
        pipeline.handle(wireFrame: scrollFrame(x: 1040, at: 0.010))
        ticker.tick(at: 0.011)
        XCTAssertEqual(pipeline.activeSource?.padID, 0)

        config[pad: "0"] = .init(enabled: false)
        pipeline.configure(
            capabilities: caps, configuration: config, deviceKey: testDeviceKey, systemPrefersNatural: false)

        pipeline.handle(wireFrame: releaseFrame(at: 0.02, scrollMode: true))
        now = 1
        scheduler.fireOneShots()

        XCTAssertNil(
            pipeline.activeSource?.padID,
            "disabled pad must relinquish the gesture even after its release/watchdog"
        )
        XCTAssertFalse(ticker.isTicking, "disabled pad must not retain a display link")

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 1, pad: 1))
        ticker.tick(at: 1.001)
        XCTAssertEqual(pipeline.activeSource?.padID, 1, "other pad must be able to scroll")

        pipeline.interrupt()
    }

    /// The same, with the finger already lifted: the gesture is only coasting.
    /// Momentum for a pad the user just switched off is motion they did not
    /// ask for, so the tail is cut rather than allowed to decay away.
    func testDisablingAPadThatIsCoastingCutsTheMomentumTail() {
        var config = RawTouchConfiguration()
        config.acceleration.enabled = false
        let caps = capabilities()
        let (pipeline, capture, scheduler, ticker) = makePipeline(configuration: config)

        // A flick: twelve frames of steady motion, then lift-off.
        var timestamp = 0.0
        for step in 0..<12 {
            timestamp = Double(step) * 0.01
            pipeline.handle(wireFrame: scrollFrame(x: 1000 + step * 25, at: timestamp))
            ticker.tick(at: timestamp + 0.001)
        }
        timestamp += 0.01
        pipeline.handle(wireFrame: releaseFrame(at: timestamp, scrollMode: true))
        ticker.tick(at: timestamp + 0.001)
        XCTAssertEqual(pipeline.activeSource?.padID, 0, "the flick is coasting on pad 0")
        capture.reset()

        config[pad: "0"] = .init(enabled: false)
        pipeline.configure(
            capabilities: caps, configuration: config, deviceKey: testDeviceKey, systemPrefersNatural: false)

        XCTAssertNil(pipeline.activeSource?.padID, "the tail must not outlive the pad it belongs to")
        XCTAssertFalse(ticker.isTicking, "and must not keep the display link alive")
        XCTAssertTrue(
            capture.phases.allSatisfy { $0.deltaY == 0 },
            "cutting a tail must not post motion of its own"
        )
        XCTAssertTrue(
            scheduler.liveTimers.allSatisfy { !$0.repeats },
            "no momentum tick timer may survive"
        )

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: timestamp + 0.5, pad: 1))
        XCTAssertEqual(pipeline.activeSource?.padID, 1, "the other pad must be able to take over")

        pipeline.interrupt()
    }

    // MARK: - The active pad's axis changing

    /// If `configure` swapped in the new axis on the engine and the
    /// resampler while the engine's `lastPosition` — a scalar on the *old*
    /// axis — stayed, the next delta would difference a Y coordinate
    /// against an X one: tens of points for a finger that never moved.
    func testChangingAxisAtRestDoesNotGenerateMotion() {
        var config = RawTouchConfiguration()
        config.acceleration.enabled = false
        let caps = capabilities()
        let (pipeline, capture, _, ticker) = makePipeline(configuration: config)

        pipeline.handle(wireFrame: scrollFrame(x: 1000, y: 800, at: 0))
        ticker.tick(at: 0.001)
        pipeline.handle(wireFrame: scrollFrame(x: 1040, y: 800, at: 0.010))
        ticker.tick(at: 0.010)
        capture.reset()

        config[pad: "0"] = .init(axis: .y)
        pipeline.configure(
            capabilities: caps, configuration: config, deviceKey: testDeviceKey, systemPrefersNatural: false)
        ticker.tick(at: 0.02)

        XCTAssertEqual(
            capture.deltas.reduce(0, +),
            0,
            accuracy: 0.001,
            "stationary Y must not be differenced against the previous X"
        )
        XCTAssertNil(pipeline.activeSource?.padID, "the gesture ends; the next touch starts on the new axis")

        pipeline.interrupt()
    }

    /// The enabled directions are part of the mapping too, and end a
    /// gesture the same way, without motion.
    func testChangingTheScrollAxesAtRestEndsTheGestureWithoutMotion() {
        let edits: [(String, (inout RawTouchConfiguration) -> Void)] = [
            ("pad axes vertical", { $0[pad: "0"] = .init(axes: .vertical) }),
            ("pad axes horizontal", { $0[pad: "0"] = .init(axes: .horizontal) }),
        ]
        for (name, edit) in edits {
            var config = RawTouchConfiguration()
            config.acceleration.enabled = false
            let caps = capabilities()
            let (pipeline, capture, _, ticker) = makePipeline(configuration: config)

            // A diagonal drag, then rest.
            // Two axial steps first release the began (the poster holds a
            // diagonal first step until the direction is clear, and a
            // zero minor axis needs a second frame); the diagonal step
            // that follows is a plain changed event.
            pipeline.handle(wireFrame: scrollFrame(x: 1000, y: 800, at: 0))
            ticker.tick(at: 0.001)
            pipeline.handle(wireFrame: scrollFrame(x: 1040, y: 800, at: 0.003))
            ticker.tick(at: 0.003)
            pipeline.handle(wireFrame: scrollFrame(x: 1080, y: 800, at: 0.006))
            ticker.tick(at: 0.006)
            pipeline.handle(wireFrame: scrollFrame(x: 1120, y: 760, at: 0.010))
            ticker.tick(at: 0.010)
            XCTAssertEqual(pipeline.activeSource?.padID, 0, name)
            capture.reset()

            edit(&config)
            pipeline.configure(
                capabilities: caps, configuration: config, deviceKey: testDeviceKey, systemPrefersNatural: false)
            ticker.tick(at: 0.02)

            XCTAssertEqual(capture.scrollPhases, [.ended], "\(name): the gesture ends")
            XCTAssertEqual(capture.deltas.reduce(0, +), 0, accuracy: 0.001, "\(name): without vertical motion")
            XCTAssertEqual(capture.horizontalDeltas.reduce(0, +), 0, accuracy: 0.001, "\(name): or horizontal")
            XCTAssertNil(pipeline.activeSource?.padID, "\(name): the next touch starts on the new mapping")
            XCTAssertFalse(ticker.isTicking, name)

            // The next touch works, on the new mapping.
            pipeline.handle(wireFrame: scrollFrame(x: 1000, y: 800, at: 1))
            ticker.tick(at: 1.001)
            XCTAssertEqual(pipeline.activeSource?.padID, 0, name)
            pipeline.interrupt()
        }
    }

    /// A direction change is not an axis change: the engine's history is
    /// sign-free, so a flipped `invert`/`invertHorizontal`, the reverse
    /// toggle, or the macOS Natural Scrolling preference simply applies
    /// from the next delta on, with the gesture (and its display link)
    /// intact — as `invert` always did.
    func testChangingADirectionMidGestureAppliesTheNewSignLive() {
        // On the Go60 mapping (vertical from x, horizontal from y inverted)
        // a +40 x / −40 y step is +10 deltaY / +10 deltaX before any edit.
        let edits: [(String, (inout RawTouchConfiguration) -> Void, natural: Bool, expected: (x: Double, y: Double))] =
            [
                ("pad invert", { $0[pad: "0"] = .init(invert: true) }, false, (10, -10)),
                ("pad invertHorizontal", { $0[pad: "0"] = .init(invertHorizontal: false) }, false, (-10, 10)),
                ("reverseScrolling", { $0.reverseScrolling = true }, false, (-10, -10)),
                ("system natural scrolling", { _ in }, true, (-10, -10)),
            ]
        for (name, edit, natural, expected) in edits {
            var config = RawTouchConfiguration()
            config.acceleration.enabled = false
            let caps = capabilities()
            let (pipeline, capture, _, ticker) = makePipeline(configuration: config)

            // Two axial steps first release the began (the poster holds a
            // diagonal first step until the direction is clear, and a
            // zero minor axis needs a second frame); the diagonal step
            // that follows is a plain changed event.
            pipeline.handle(wireFrame: scrollFrame(x: 1000, y: 800, at: 0))
            ticker.tick(at: 0.001)
            pipeline.handle(wireFrame: scrollFrame(x: 1040, y: 800, at: 0.003))
            ticker.tick(at: 0.003)
            pipeline.handle(wireFrame: scrollFrame(x: 1080, y: 800, at: 0.006))
            ticker.tick(at: 0.006)
            pipeline.handle(wireFrame: scrollFrame(x: 1120, y: 760, at: 0.010))
            ticker.tick(at: 0.010)
            XCTAssertEqual(capture.phases.last.map { ($0.deltaX, $0.deltaY) } ?? (0, 0) == (10, 10), true, name)

            edit(&config)
            pipeline.configure(
                capabilities: caps, configuration: config, deviceKey: testDeviceKey, systemPrefersNatural: natural)

            XCTAssertEqual(pipeline.activeSource?.padID, 0, "\(name): the gesture survives")
            XCTAssertTrue(ticker.isTicking, name)
            capture.reset()

            // The drag continues: the same step now carries the new sign.
            pipeline.handle(wireFrame: scrollFrame(x: 1160, y: 720, at: 0.020))
            ticker.tick(at: 0.020)
            XCTAssertEqual(capture.scrollPhases, [.changed], "\(name): no new began, no end")
            XCTAssertEqual(capture.horizontalDeltas, [expected.x], name)
            XCTAssertEqual(capture.deltas, [expected.y], name)

            pipeline.interrupt()
        }
    }

    func testChangingTheScrollAxesOfACoastingPadCutsTheMomentumTail() {
        var config = RawTouchConfiguration()
        config.acceleration.enabled = false
        let caps = capabilities()
        let (pipeline, capture, _, ticker) = makePipeline(configuration: config)

        var timestamp = 0.0
        for step in 0..<12 {
            timestamp = Double(step) * 0.01
            pipeline.handle(wireFrame: scrollFrame(x: 1000 + step * 25, y: 800 - step * 25, at: timestamp))
            ticker.tick(at: timestamp + 0.001)
        }
        timestamp += 0.01
        pipeline.handle(wireFrame: releaseFrame(at: timestamp, scrollMode: true))
        ticker.tick(at: timestamp + 0.001)
        XCTAssertEqual(pipeline.activeSource?.padID, 0, "coasting")
        capture.reset()

        config[pad: "0"] = .init(axes: .vertical)
        pipeline.configure(
            capabilities: caps, configuration: config, deviceKey: testDeviceKey, systemPrefersNatural: false)

        XCTAssertNil(pipeline.activeSource?.padID, "the tail is cut")
        XCTAssertFalse(ticker.isTicking)
        XCTAssertTrue(capture.phases.allSatisfy { $0.deltaX == 0 && $0.deltaY == 0 }, "without motion of its own")

        pipeline.interrupt()
    }

    /// The edits that *do* apply live must go on doing so: only the axis
    /// mapping and the pad leaving the set end a gesture.
    func testChangingGainMidGestureKeepsTheGestureAlive() {
        var config = RawTouchConfiguration()
        config.acceleration.enabled = false
        let caps = capabilities()
        let (pipeline, _, _, ticker) = makePipeline(configuration: config)

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0))
        ticker.tick(at: 0.001)
        pipeline.handle(wireFrame: scrollFrame(x: 1040, at: 0.010))
        ticker.tick(at: 0.011)

        config[pad: "0"] = .init(scale: 2)
        pipeline.configure(
            capabilities: caps, configuration: config, deviceKey: testDeviceKey, systemPrefersNatural: false)

        XCTAssertEqual(pipeline.activeSource?.padID, 0, "a gain edit applies to the gesture in flight")
        XCTAssertTrue(ticker.isTicking)

        pipeline.interrupt()
    }

    // MARK: - Posting readiness

    /// Readiness drops when Accessibility is revoked. The lease is being
    /// released at the same moment and the firmware is about to resume its
    /// own wheel scrolling, so an open scroll phase must be closed out and
    /// the frames that follow dropped — synthesizing on top of the
    /// firmware's own events would double-scroll.
    func testLosingPostingReadinessEndsTheGestureAndDropsFrames() {
        var config = RawTouchConfiguration()
        config.acceleration.enabled = false
        let (pipeline, capture, _, ticker) = makePipeline(configuration: config)

        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0))
        ticker.tick(at: 0.001)
        pipeline.handle(wireFrame: scrollFrame(x: 1040, at: 0.010))
        ticker.tick(at: 0.011)
        XCTAssertEqual(pipeline.activeSource?.padID, 0)
        capture.reset()

        pipeline.setPostingReady(false)

        XCTAssertFalse(pipeline.isStreaming)
        XCTAssertNil(pipeline.activeSource?.padID)
        XCTAssertFalse(ticker.isTicking)
        XCTAssertEqual(capture.scrollPhases, [.ended], "the series is closed, not left hanging")

        capture.reset()
        pipeline.handle(wireFrame: scrollFrame(x: 1080, at: 0.020))
        XCTAssertTrue(capture.events.isEmpty, "frames arriving while nothing can be posted are dropped")
        XCTAssertNil(pipeline.activeSource?.padID)

        pipeline.setPostingReady(true)
        pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0.030))
        XCTAssertEqual(pipeline.activeSource?.padID, 0, "the pad works again once posting is possible")

        pipeline.interrupt()
    }
}
