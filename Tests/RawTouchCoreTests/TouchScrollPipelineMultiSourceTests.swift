// MIT License
// Copyright (c) 2026 RawTouch contributors

import CoreGraphics
import RawTouchTestSupport
import XCTest

@testable import RawTouchCore

/// The pipeline with more than one endpoint: two keyboards that both call
/// their pad "0", or one keyboard over USB and Bluetooth. Every source
/// (endpoint + pad) scrolls on its own geometry with its own clock,
/// sequence counter and watchdog; one gesture at a time is arbitrated
/// across all of them; and an endpoint going away takes only its own
/// sources with it. Every CGEvent is captured by an injected sink — nothing
/// is posted, so these tests can never raise an Accessibility prompt.
final class TouchScrollPipelineMultiSourceTests: XCTestCase {
    private let frameInterval: TimeInterval = 0.01
    private let usb = RawTouchEndpointID(rawValue: 1)
    private let bluetooth = RawTouchEndpointID(rawValue: 2)

    /// Two Go60-shaped endpoints by default — 1 (USB) and 2 (Bluetooth) —
    /// both with pads 0 and 1 and the same orientation, so the difference
    /// between them is purely identity. Paced only when resampling, with
    /// the latency by hand: what the estimator measures has its own suite
    /// (`TouchScrollPipelineAdaptiveLatencyTests`).
    private func makeHarness(
        endpoints: [RawTouchEndpointDescriptor]? = nil,
        configuration: RawTouchConfiguration = .init(),
        resampling: Bool = false,
        fixedLatency: TimeInterval = 0,
        now: (() -> TimeInterval)? = nil
    ) -> PipelineHarness {
        PipelineHarness(
            configuration: configuration,
            resampling: resampling,
            paced: resampling,
            fixedLatency: fixedLatency,
            endpoints: endpoints ?? [
                endpointDescriptor(id: 1, transport: .usb),
                endpointDescriptor(id: 2, transport: .bluetooth),
            ],
            now: now
        )
    }

    private func source(_ endpoint: RawTouchEndpointID, _ pad: UInt8 = 0) -> RawTouchSourceID {
        RawTouchSourceID(endpoint: endpoint, padID: pad)
    }

    // MARK: - Identity: same pad ID, different keyboards

    /// What this whole suite guards: keyed by pad ID alone, a second
    /// keyboard's pad 0 would collide with the first one's and inherit its
    /// geometry. Each endpoint scrolls on its own: the same finger motion
    /// on a differently mounted pad 0 comes out on the other axis.
    func testTwoKeyboardsWithTheSamePadIDScrollOnTheirOwnGeometry() {
        let harness = makeHarness(endpoints: [
            // Keyboard A: rotate-90 + y-invert ⇒ vertical from raw X.
            endpointDescriptor(id: 1, rotate90: true, invertY: true),
            // Keyboard B: mounted upright, half the resolution ⇒ vertical
            // from raw Y, and twice the points per count at gain 1.0.
            endpointDescriptor(id: 2, countsPerMM: 19, rotate90: false, invertY: false),
        ])
        let a = RawTouchEndpointID(rawValue: 1)
        let b = RawTouchEndpointID(rawValue: 2)

        XCTAssertEqual(harness.pipeline.engineConfig(forPad: 0, on: a)?.axis, .x)
        XCTAssertEqual(harness.pipeline.engineConfig(forPad: 0, on: b)?.axis, .y)
        XCTAssertEqual(harness.pipeline.engineConfig(forPad: 0, on: a)?.pointsPerCount, 0.25)
        XCTAssertEqual(harness.pipeline.engineConfig(forPad: 0, on: b)?.pointsPerCount, 0.5)

        // A: +30 raw X is vertical, 7.5 pt.
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, y: 500, at: 0, endpoint: a))
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1030, y: 500, at: frameInterval, endpoint: a))
        XCTAssertEqual(harness.captured.deltas.last, 7.5)
        XCTAssertEqual(harness.captured.horizontalDeltas.last, 0)
        // Held still well past the velocity fit's window, so the lift
        // carries no momentum and the gesture really ends.
        for step in 2..<22 {
            harness.pipeline.handle(
                wireFrame: scrollFrame(x: 1030, y: 500, at: frameInterval * Double(step), endpoint: a))
        }
        harness.pipeline.handle(wireFrame: releaseFrame(at: frameInterval * 22, scrollMode: true, endpoint: a))
        XCTAssertNil(harness.pipeline.activeSource)
        harness.captured.reset()

        // B: the same +30 raw X is *horizontal* there, at 0.5 pt/count and
        // inverted (no x-invert ⇒ horizontal baseline inverted): −15 pt.
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, y: 500, at: 0.5, endpoint: b))
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1030, y: 500, at: 0.5 + frameInterval, endpoint: b))
        XCTAssertEqual(harness.captured.deltas.last, 0)
        XCTAssertEqual(harness.captured.horizontalDeltas.last, -15)
        XCTAssertEqual(harness.pipeline.activeSource, source(b))
    }

    func testTheGeometryIsTheTouchingEndpointsNotTheFirstAdmitted() {
        // Pad 1 exists only on the second keyboard; the first one has a lone
        // pad 0. A frame from the second keyboard's pad 1 must find *its*
        // configuration, not be dropped for the first keyboard lacking it.
        let harness = makeHarness(endpoints: [
            endpointDescriptor(id: 1, padsPresent: 0x01),
            endpointDescriptor(id: 2, padsPresent: 0x03),
        ])
        XCTAssertNil(harness.pipeline.engineConfig(forPad: 1, on: usb))
        XCTAssertNotNil(harness.pipeline.engineConfig(forPad: 1, on: bluetooth))

        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0, pad: 1, endpoint: bluetooth))
        XCTAssertEqual(harness.pipeline.activeSource, source(bluetooth, 1))

        // And the first keyboard's phantom pad 1 is dropped.
        harness.pipeline.interrupt()
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 1, pad: 1, endpoint: usb))
        XCTAssertNil(harness.pipeline.activeSource)
    }

    func testFramesFromAnEndpointThatWasNeverAdmittedAreDropped() {
        let harness = makeHarness()
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0, endpoint: RawTouchEndpointID(rawValue: 99)))
        harness.pipeline.handle(
            wireFrame: scrollFrame(x: 1030, at: frameInterval, endpoint: RawTouchEndpointID(rawValue: 99)))
        XCTAssertNil(harness.pipeline.activeSource)
        XCTAssertTrue(harness.captured.events.isEmpty)
    }

    // MARK: - Per-source clocks, sequence counters, watchdogs

    /// Device clocks are per source: keyboard B's timestamps, on a
    /// different timeline from A's, must not be reconstructed against A's
    /// anchor. If they were, B's first frame would land on A's timeline at
    /// a wild offset and its velocity (the delta's dt) would be nonsense;
    /// here B's two frames are 10 ms apart on B's clock and the engine must
    /// see exactly that.
    func testDeviceClocksAreIndependentPerSource() {
        let harness = makeHarness()

        // A streams with device ticks 0, 100, 200 … (10 ms apart).
        for step in 0..<3 {
            var frame = scrollFrame(x: 1000 + step * 10, at: Double(step) * frameInterval, endpoint: usb)
            frame.deviceTimestampTicks = UInt16(step * 100)
            frame.seq = UInt8(step)
            harness.pipeline.handle(wireFrame: frame)
        }
        harness.pipeline.handle(wireFrame: releaseFrame(at: 0.03, scrollMode: true, endpoint: usb))
        harness.captured.reset()

        // B's clock reads 50 000 ticks (5 s) — a different device. Its two
        // frames are 100 ticks apart. A shared clock would treat B's first
        // stamp as a 5 s jump on A's timeline (a discontinuity, re-anchored)
        // — but the *second* B frame would then be reconstructed against the
        // first correctly either way, so pin the per-source clock through a
        // stronger observation: A resumes afterwards with ticks continuing
        // from 300, and its own clock must still be continuous (no
        // discontinuity, no re-anchor to a later arrival time).
        var b0 = scrollFrame(x: 1000, at: 1.0, endpoint: bluetooth)
        b0.deviceTimestampTicks = 50_000
        var b1 = scrollFrame(x: 1040, at: 1.0 + frameInterval, endpoint: bluetooth)
        b1.deviceTimestampTicks = 50_100
        harness.pipeline.handle(wireFrame: b0)
        harness.pipeline.handle(wireFrame: b1)
        XCTAssertEqual(harness.captured.deltas.last, 10, "B scrolls on its own clock")
        harness.pipeline.handle(wireFrame: releaseFrame(at: 1.02, scrollMode: true, endpoint: bluetooth))
        harness.captured.reset()

        // A again, 1.05 s of host time later but only 100 ticks (10 ms) on
        // its own clock: with a per-source clock the reconstructed time
        // advances 10 ms from A's last frame. The engine's momentum seed
        // is what exposes the timeline: a 40-count step over a 10 ms dt is
        // a fast flick (momentum), over a 1 s dt it is a crawl (none).
        for step in 0..<12 {
            var frame = scrollFrame(x: 1020 + step * 40, at: 1.05 + Double(step) * frameInterval, endpoint: usb)
            frame.deviceTimestampTicks = UInt16(300 + step * 100)
            frame.seq = UInt8(3 + step)
            harness.pipeline.handle(wireFrame: frame)
        }
        var releaseA = releaseFrame(at: 1.05 + 12 * frameInterval, scrollMode: true, endpoint: usb)
        releaseA.deviceTimestampTicks = 1500
        harness.pipeline.handle(wireFrame: releaseA)
        XCTAssertEqual(harness.pipeline.activeSource, source(usb), "a fast flick coasts: A's timeline was continuous")
        XCTAssertTrue(harness.scheduler.liveTimers.contains(where: \.repeats), "momentum tick timer running")
    }

    /// Sequence counters are per source too: B starting at seq 0 while A is
    /// at seq 200 is not a gap on anyone's stream. Gaps are diagnostic only
    /// (logged), so the observable contract is simply that both streams
    /// scroll normally with interleaved, unrelated counters.
    func testSequenceCountersAreIndependentPerSource() {
        let harness = makeHarness()

        var a = scrollFrame(x: 1000, at: 0, endpoint: usb)
        a.seq = 200
        harness.pipeline.handle(wireFrame: a)
        var b = scrollFrame(x: 1000, at: frameInterval, endpoint: bluetooth)
        b.seq = 0
        harness.pipeline.handle(wireFrame: b)  // dropped: A owns the gesture
        // Flick-fast (15 pt in 20 ms), so the began is out at once.
        var a2 = scrollFrame(x: 1060, at: frameInterval * 2, endpoint: usb)
        a2.seq = 201
        harness.pipeline.handle(wireFrame: a2)

        XCTAssertEqual(harness.captured.scrollPhases, [.began])
        XCTAssertEqual(harness.captured.deltas.last, 15)
    }

    /// Each source has its own stale-touch watchdog. B's finger going
    /// silent (its stream stopped) ends B's touch only — and since B never
    /// owned the gesture, there is no gesture of its to end: A's is
    /// untouched.
    func testSilenceWatchdogsAreIndependentPerSource() {
        var now: TimeInterval = 10
        let harness = makeHarness(now: { now })

        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 10, endpoint: usb))
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1030, at: 10.01, endpoint: usb))
        // B touches too (dropped by arbitration) and then goes silent.
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1500, at: 10.01, endpoint: bluetooth))
        harness.captured.reset()

        // A keeps its touch fresh; B does not.
        now = 10.14
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1038, at: 10.14, endpoint: usb))
        now = 10.2
        harness.scheduler.fireOneShots()

        XCTAssertEqual(harness.pipeline.activeSource, source(usb), "B's watchdog must not close A's gesture")
        XCTAssertTrue(
            harness.captured.scrollPhases.allSatisfy { $0 == .changed },
            "only A's motion was posted: \(harness.captured.scrollPhases)"
        )

        // A's own watchdog, later, does close A.
        now = 10.5
        harness.scheduler.fireOneShots()
        XCTAssertNil(harness.pipeline.activeSource)
        XCTAssertEqual(harness.captured.scrollPhases.last, .ended)
    }

    // MARK: - Arbitration across keyboards

    func testFirstKeyboardToTouchOwnsTheGestureAndTheOtherIsIgnored() {
        let harness = makeHarness()

        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0, endpoint: bluetooth))
        XCTAssertEqual(harness.pipeline.activeSource, source(bluetooth))
        harness.captured.reset()

        // The other keyboard's pad 0 — same pad ID — touches, moves and
        // releases: all dropped while the first one owns the gesture.
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1500, at: frameInterval, endpoint: usb))
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1540, at: frameInterval * 2, endpoint: usb))
        harness.pipeline.handle(wireFrame: releaseFrame(at: frameInterval * 3, scrollMode: true, endpoint: usb))
        XCTAssertTrue(harness.captured.events.isEmpty)
        XCTAssertEqual(harness.pipeline.activeSource, source(bluetooth))

        harness.pipeline.handle(wireFrame: scrollFrame(x: 1030, at: frameInterval * 4, endpoint: bluetooth))
        XCTAssertEqual(harness.captured.scrollPhases, [.began])
        XCTAssertEqual(harness.captured.deltas, [7.5])
    }

    func testAScrollTouchOnAnotherKeyboardCatchesAMomentumTail() {
        let harness = makeHarness()

        let liftTime = harness.flickIntoMomentum(on: usb)
        XCTAssertEqual(harness.pipeline.activeSource, source(usb))
        harness.captured.reset()

        // The other keyboard's pad 0 catches the tail and takes over.
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: liftTime + 0.05, endpoint: bluetooth))
        XCTAssertEqual(harness.pipeline.activeSource, source(bluetooth))
        XCTAssertEqual(harness.captured.phases.count, 1)
        XCTAssertEqual(harness.captured.phases[0].momentum, .end)
        XCTAssertEqual(harness.captured.phases[0].deltaY, 0)
        XCTAssertTrue(harness.scheduler.liveTimers.allSatisfy { !$0.repeats })

        // And scrolls immediately, on its own terms.
        harness.pipeline.handle(
            wireFrame: scrollFrame(x: 1030, at: liftTime + 0.05 + frameInterval, endpoint: bluetooth))
        XCTAssertEqual(harness.captured.phases.last?.scroll, .began)
        XCTAssertEqual(harness.captured.deltas.last, 7.5)
    }

    func testAPointerTouchOnAnotherKeyboardDoesNotCatchTheTail() {
        let harness = makeHarness()
        let liftTime = harness.flickIntoMomentum(on: usb)
        harness.captured.reset()

        harness.pipeline.handle(wireFrame: pointerFrame(x: 1000, at: liftTime + 0.05, endpoint: bluetooth))
        XCTAssertEqual(harness.pipeline.activeSource, source(usb))
        XCTAssertTrue(harness.captured.events.isEmpty)
    }

    func testActivityNamesTheEndpointOfTheScrollingPad() {
        let harness = makeHarness()
        var activities: [RawTouchStatus.PadActivity] = []
        harness.pipeline.onActivityChange = { activities.append($0) }

        let liftTime = harness.flickIntoMomentum(on: usb)
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: liftTime + 0.05, pad: 1, endpoint: bluetooth))

        XCTAssertEqual(
            activities,
            [
                .touching(padID: 0, endpoint: usb),
                .coasting(padID: 0, endpoint: usb),
                .touching(padID: 1, endpoint: bluetooth),
            ])
    }

    /// The gesture summary reaches the owner tagged with the source that
    /// scrolled — once at lift-off, once when the coast ends — and never
    /// with another keyboard's identity.
    func testGestureSummariesAreTaggedWithTheirSource() {
        let harness = makeHarness()
        var summaries: [RawTouchGestureSummary] = []
        harness.pipeline.onGestureSummary = { summaries.append($0) }

        let liftTime = harness.flickIntoMomentum(on: usb)
        XCTAssertEqual(summaries.count, 1, "lift-off delivers the touch half")
        XCTAssertEqual(summaries.first?.padID, 0)
        XCTAssertEqual(summaries.first?.endpoint, usb)
        XCTAssertEqual(summaries.first?.complete, false)

        // The other keyboard's pad 1 catches the coast: the USB gesture is
        // closed under its own identity before Bluetooth's begins.
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: liftTime + 0.05, pad: 1, endpoint: bluetooth))
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries.last?.endpoint, usb)
        XCTAssertEqual(summaries.last?.padID, 0)
        XCTAssertEqual(summaries.last?.complete, true)
    }

    // MARK: - Lifecycle: endpoints coming and going

    /// Disconnecting a keyboard that is not scrolling must not interrupt the
    /// one that is — no phase change, no lost timing, no display-link stop.
    func testRemovingAnInactiveEndpointLeavesTheGestureAndItsTimingIntact() {
        let harness = makeHarness(resampling: true, fixedLatency: 0.003)

        // USB frames stamped by the device (ticks 0, 100 = 0 ms, 10 ms),
        // arriving promptly.
        var first = scrollFrame(x: 1000, at: 0, transport: .usb, endpoint: usb)
        first.deviceTimestampTicks = 0
        harness.pipeline.handle(wireFrame: first)
        harness.ticker.tick(at: 0.001)
        var second = scrollFrame(x: 1040, at: 0.010, transport: .usb, endpoint: usb)
        second.deviceTimestampTicks = 100
        harness.pipeline.handle(wireFrame: second)
        harness.ticker.tick(at: 0.011)
        XCTAssertEqual(harness.captured.scrollPhases, [.began])
        XCTAssertEqual(harness.pipeline.resamplerLatency, 0.003)
        XCTAssertTrue(harness.scheduler.liveTimers.contains { !$0.repeats }, "USB's watchdog is armed")
        harness.captured.reset()

        // The Bluetooth keyboard goes away (the configuration is unchanged).
        harness.pipeline.configure(
            endpoints: [endpointDescriptor(id: 1, transport: .usb)],
            systemPrefersNatural: false
        )

        XCTAssertEqual(harness.pipeline.activeSource, source(usb), "the gesture continues")
        XCTAssertTrue(harness.ticker.isTicking, "on the same display link")
        XCTAssertTrue(harness.captured.events.isEmpty, "with no phase change")
        XCTAssertEqual(harness.pipeline.resamplerLatency, 0.003, "at the same latency")
        XCTAssertTrue(harness.scheduler.liveTimers.contains { !$0.repeats }, "with its watchdog still armed")

        // The drag goes on with the next device sample (ticks 200 = 20 ms)
        // — delivered late, 50 ms after it was taken. The surviving clock
        // dates it 10 ms after the previous sample, so the tick right after
        // sees a plain continuation: +40 counts = 10 pt. Had the clock been
        // reset, the sample would re-anchor to its arrival (0.070) and the
        // tick at 0.021 would interpolate a fraction of that step instead.
        var third = scrollFrame(x: 1080, at: 0.070, transport: .usb, endpoint: usb)
        third.deviceTimestampTicks = 200
        harness.pipeline.handle(wireFrame: third)
        harness.ticker.tick(at: 0.021)
        XCTAssertEqual(harness.captured.scrollPhases, [.changed])
        XCTAssertEqual(harness.captured.deltas, [10])

        harness.pipeline.interrupt()
    }

    /// Losing the keyboard that is scrolling closes its gesture cleanly —
    /// canceled, no momentum (the same treatment as the trailing
    /// bit-2-clear release) — and the other keyboard can scroll at once.
    func testRemovingTheActiveEndpointCancelsWithoutMomentumAndTheOtherContinues() {
        let harness = makeHarness(resampling: true)

        // A fast drag on USB: a normal lift-off here would coast.
        var timestamp = 0.0
        for step in 0..<12 {
            timestamp = Double(step) * frameInterval
            harness.pipeline.handle(wireFrame: scrollFrame(x: 1000 + step * 25, at: timestamp, endpoint: usb))
            harness.ticker.tick(at: timestamp + 0.001)
        }
        harness.captured.reset()

        harness.pipeline.configure(
            endpoints: [endpointDescriptor(id: 2, transport: .bluetooth)],
            systemPrefersNatural: false
        )

        XCTAssertNil(harness.pipeline.activeSource)
        XCTAssertEqual(harness.captured.scrollPhases, [.ended], "the series is closed, not left hanging")
        XCTAssertTrue(
            harness.captured.phases.allSatisfy { $0.momentum == CGMomentumScrollPhase(rawValue: 0)! },
            "no momentum for a keyboard that is gone"
        )
        XCTAssertTrue(harness.scheduler.liveTimers.allSatisfy { !$0.repeats })
        XCTAssertFalse(harness.ticker.isTicking)

        // Frames still queued for the departed endpoint are dropped.
        harness.captured.reset()
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1300, at: timestamp + frameInterval, endpoint: usb))
        XCTAssertNil(harness.pipeline.activeSource)
        XCTAssertTrue(harness.captured.events.isEmpty)

        // The other keyboard takes a fresh gesture.
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 1, endpoint: bluetooth))
        harness.ticker.tick(at: 1.001)
        XCTAssertEqual(harness.pipeline.activeSource, source(bluetooth))
        harness.pipeline.interrupt()
    }

    /// A coasting tail belongs to its keyboard: unplugging it cuts the tail.
    func testRemovingACoastingEndpointCutsItsMomentumTail() {
        let harness = makeHarness()
        _ = harness.flickIntoMomentum(on: usb)
        harness.captured.reset()

        harness.pipeline.configure(
            endpoints: [endpointDescriptor(id: 2, transport: .bluetooth)],
            systemPrefersNatural: false
        )

        XCTAssertNil(harness.pipeline.activeSource)
        XCTAssertEqual(harness.captured.phases.count, 1)
        XCTAssertEqual(harness.captured.phases[0].momentum, .end)
        XCTAssertTrue(harness.scheduler.liveTimers.allSatisfy { !$0.repeats })
    }

    /// A re-enumerated keyboard is a new endpoint with a new ID: a frame
    /// (or a watchdog) left over from its previous appearance carries the
    /// old ID and touches nothing. The replacement starts clean — no clock
    /// anchor, no sequence, no armed watchdog — carried over.
    func testAReplacedEndpointIsANewSourceAndTheOldOnesLeftoversAreIgnored() {
        var now: TimeInterval = 0
        let harness = makeHarness(now: { now })

        // A touch on the old appearance (endpoint 1) arms its watchdog.
        var old = scrollFrame(x: 1000, at: 0, endpoint: usb)
        old.seq = 7
        old.deviceTimestampTicks = 1000
        harness.pipeline.handle(wireFrame: old)
        XCTAssertEqual(harness.pipeline.activeSource, source(usb))
        let oldWatchdog = try! XCTUnwrap(harness.scheduler.liveTimers.first { !$0.repeats })

        // It reconnects: same keyboard, new ID 3.
        let replacement = RawTouchEndpointID(rawValue: 3)
        harness.pipeline.configure(
            endpoints: [endpointDescriptor(id: 3, transport: .usb), endpointDescriptor(id: 2, transport: .bluetooth)],
            systemPrefersNatural: false
        )
        XCTAssertNil(harness.pipeline.activeSource, "the old appearance's gesture was closed")
        XCTAssertTrue(oldWatchdog.invalidated, "the old watchdog went with its source")
        harness.captured.reset()

        // Leftovers from the old appearance: a queued frame, and the old
        // watchdog's callback — already dispatched when it was invalidated,
        // so it runs anyway (`handler` bypasses the fake's invalidation
        // check, as a timer already in flight would). It finds no source
        // state and must do nothing.
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1030, at: frameInterval, endpoint: usb))
        now = 1
        oldWatchdog.handler()
        XCTAssertNil(harness.pipeline.activeSource)
        XCTAssertTrue(harness.captured.events.isEmpty)
        XCTAssertTrue(harness.scheduler.liveTimers.allSatisfy(\.repeats), "and it re-armed nothing")

        // The replacement scrolls from scratch.
        var fresh = scrollFrame(x: 2000, at: 1, endpoint: replacement)
        fresh.seq = 0
        fresh.deviceTimestampTicks = 40_000
        harness.pipeline.handle(wireFrame: fresh)
        var fresh2 = scrollFrame(x: 2030, at: 1 + frameInterval, endpoint: replacement)
        fresh2.seq = 1
        fresh2.deviceTimestampTicks = 40_100
        harness.pipeline.handle(wireFrame: fresh2)
        XCTAssertEqual(harness.pipeline.activeSource, source(replacement))
        XCTAssertEqual(harness.captured.scrollPhases, [.began])
        XCTAssertEqual(harness.captured.deltas, [7.5])
    }

    // MARK: - One keyboard, two transports

    /// The Go60 on USB and Bluetooth at once: two endpoints, each gesture
    /// measured on its own, because the two paths are not alike.
    func testEachEndpointMeasuresItsOwnLatency() {
        let harness = makeHarness(resampling: true)

        // The USB endpoint's frames arrive on time; the Bluetooth
        // endpoint's arrive 12 ms late, batch after batch.
        for step in 0..<RawTouchLatencyEstimator.windowSize {
            var frame = scrollFrame(x: 1000 + step, at: Double(step) * frameInterval, transport: .usb, endpoint: usb)
            frame.deviceTimestampTicks = UInt16(truncatingIfNeeded: step * 100)
            harness.pipeline.handle(wireFrame: frame)
        }
        harness.pipeline.handle(wireFrame: releaseFrame(at: 2.1, scrollMode: true, transport: .usb, endpoint: usb))
        XCTAssertLessThan(harness.pipeline.resamplerLatency, 0.002, "USB measured itself prompt")

        harness.pipeline.interrupt()
    }

    /// USB unplugged mid-touch: the USB endpoint goes away, its gesture is
    /// closed without momentum, and the same finger — still down — carries
    /// on over Bluetooth as a *fresh* gesture with fresh timing: nothing
    /// from the USB stream (positions, clock anchor) leaks into it.
    func testAUSBToBluetoothHandoverMidTouchClosesCleanlyAndStartsAFreshGesture() {
        // Latency at 0 so the deltas below are about identity, not
        // display-sync interpolation.
        let harness = makeHarness(resampling: true)

        var timestamp = 0.0
        for step in 0..<6 {
            timestamp = Double(step) * frameInterval
            var frame = scrollFrame(x: 1000 + step * 25, at: timestamp, transport: .usb, endpoint: usb)
            frame.deviceTimestampTicks = UInt16(step * 100)
            harness.pipeline.handle(wireFrame: frame)
            harness.ticker.tick(at: timestamp + 0.001)
        }
        XCTAssertEqual(harness.pipeline.activeSource, source(usb))
        harness.captured.reset()

        // Unplug: the USB endpoint is gone.
        harness.pipeline.configure(
            endpoints: [endpointDescriptor(id: 2, transport: .bluetooth)],
            systemPrefersNatural: false
        )
        XCTAssertEqual(harness.captured.scrollPhases, [.ended])
        XCTAssertTrue(harness.captured.phases.allSatisfy { $0.momentum == CGMomentumScrollPhase(rawValue: 0)! })
        XCTAssertNil(harness.pipeline.activeSource)
        harness.captured.reset()

        // The finger is still down; the firmware now streams over
        // Bluetooth, from a position far from where USB left off (the
        // coordinates happen to be the same pad, but the pipeline must not
        // difference against the USB history) and on its own clock.
        let handoverTime = timestamp + 0.05
        var handover = scrollFrame(x: 1125, at: handoverTime, transport: .bluetooth, endpoint: bluetooth)
        handover.deviceTimestampTicks = 700
        harness.pipeline.handle(wireFrame: handover)
        harness.ticker.tick(at: handoverTime + 0.001)
        XCTAssertEqual(harness.pipeline.activeSource, source(bluetooth))
        XCTAssertTrue(harness.captured.scrollPhases.isEmpty, "a touch-down scrolls nothing until it moves")

        var next = scrollFrame(x: 1165, at: handoverTime + frameInterval, transport: .bluetooth, endpoint: bluetooth)
        next.deviceTimestampTicks = 800
        harness.pipeline.handle(wireFrame: next)
        harness.ticker.tick(at: handoverTime + frameInterval)
        XCTAssertEqual(harness.captured.scrollPhases, [.began], "a fresh gesture, not a continuation")
        XCTAssertEqual(harness.captured.deltas, [10], "40 counts from the handover frame, nothing from USB")
        harness.pipeline.interrupt()
    }

    // MARK: - Per-keyboard configuration

    /// `devices.<key>.pads.<id>` wins over the top level, for that keyboard
    /// alone — another keyboard, or one without a key, sees only the top
    /// level.
    func testPerKeyboardOverridesApplyToTheirKeyboardOnly() {
        var configuration = RawTouchConfiguration()
        configuration.scale = 1
        configuration.devices = ["usb:one": .init(pads: ["0": .init(scale: 4)])]
        let harness = makeHarness(
            endpoints: [
                endpointDescriptor(id: 1, deviceKey: "usb:one"),
                endpointDescriptor(id: 2, deviceKey: "bt:two"),
                endpointDescriptor(id: 3, deviceKey: nil),
            ],
            configuration: configuration
        )

        XCTAssertEqual(
            harness.pipeline.engineConfig(forPad: 0, on: RawTouchEndpointID(rawValue: 1))?.pointsPerCount, 1.0)
        XCTAssertEqual(
            harness.pipeline.engineConfig(forPad: 0, on: RawTouchEndpointID(rawValue: 2))?.pointsPerCount, 0.25)
        XCTAssertEqual(
            harness.pipeline.engineConfig(forPad: 0, on: RawTouchEndpointID(rawValue: 3))?.pointsPerCount, 0.25)
        // Pad 1 has no overrides anywhere: the top level.
        XCTAssertEqual(
            harness.pipeline.engineConfig(forPad: 1, on: RawTouchEndpointID(rawValue: 1))?.pointsPerCount, 0.25)
    }

    func testDisablingOneKeyboardIgnoresOnlyThatKeyboard() {
        var configuration = RawTouchConfiguration()
        configuration.devices = ["usb:one": .init(enabled: false)]
        let harness = makeHarness(
            endpoints: [
                endpointDescriptor(id: 1, deviceKey: "usb:one"),
                endpointDescriptor(id: 2, deviceKey: "bt:two"),
            ],
            configuration: configuration
        )

        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0, endpoint: usb))
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1030, at: frameInterval, endpoint: usb))
        XCTAssertNil(harness.pipeline.activeSource)
        XCTAssertTrue(harness.captured.events.isEmpty)

        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 1, endpoint: bluetooth))
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1030, at: 1 + frameInterval, endpoint: bluetooth))
        XCTAssertEqual(harness.captured.scrollPhases, [.began])
    }

    // MARK: - Global transitions reach every source

    func testLosingPostingReadinessEndsTheGestureAndSilencesEveryKeyboard() {
        let harness = makeHarness()
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0, endpoint: usb))
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1030, at: frameInterval, endpoint: usb))
        harness.captured.reset()

        harness.pipeline.setPostingReady(false)
        XCTAssertEqual(harness.captured.scrollPhases, [.ended])
        XCTAssertNil(harness.pipeline.activeSource)

        harness.captured.reset()
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 1, endpoint: bluetooth))
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1030, at: 1 + frameInterval, endpoint: bluetooth))
        XCTAssertTrue(harness.captured.events.isEmpty, "every keyboard is silent while nothing can be posted")

        harness.pipeline.setPostingReady(true)
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 2, endpoint: bluetooth))
        XCTAssertEqual(harness.pipeline.activeSource, source(bluetooth))
    }

    func testDisablingRawTouchSilencesEveryKeyboardAndReenablingRestoresThemAll() {
        let harness = makeHarness()
        var configuration = RawTouchConfiguration()
        configuration.acceleration.enabled = false
        configuration.resampling.enabled = false

        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0, endpoint: bluetooth))
        configuration.enabled = false
        harness.pipeline.configure(
            endpoints: [endpointDescriptor(id: 1, transport: .usb), endpointDescriptor(id: 2, transport: .bluetooth)],
            configuration: configuration,
            systemPrefersNatural: false
        )
        XCTAssertFalse(harness.pipeline.isStreaming)
        XCTAssertNil(harness.pipeline.activeSource)
        harness.captured.reset()
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 1, endpoint: usb))
        XCTAssertTrue(harness.captured.events.isEmpty)

        configuration.enabled = true
        harness.pipeline.configure(
            endpoints: [endpointDescriptor(id: 1, transport: .usb), endpointDescriptor(id: 2, transport: .bluetooth)],
            configuration: configuration,
            systemPrefersNatural: false
        )
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 2, endpoint: usb))
        XCTAssertEqual(harness.pipeline.activeSource, source(usb))
        harness.pipeline.interrupt()
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 3, endpoint: bluetooth))
        XCTAssertEqual(harness.pipeline.activeSource, source(bluetooth))
    }

    /// The trailing bit-2-clear release of one keyboard's lease lapse cancels
    /// that keyboard's series only; the same frame from a keyboard that
    /// does not own the gesture is just dropped.
    func testALeaseLapseOnTheOwningKeyboardCancelsItsSeriesOnly() {
        let harness = makeHarness()
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0, endpoint: usb))
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1030, at: frameInterval, endpoint: usb))
        harness.captured.reset()

        // The other keyboard's lease lapse: nothing to cancel there.
        harness.pipeline.handle(
            wireFrame: releaseFrame(at: frameInterval * 2, scrollMode: true, leaseHeld: false, endpoint: bluetooth))
        XCTAssertEqual(harness.pipeline.activeSource, source(usb))
        XCTAssertTrue(harness.captured.events.isEmpty)

        harness.pipeline.handle(
            wireFrame: releaseFrame(at: frameInterval * 3, scrollMode: true, leaseHeld: false, endpoint: usb))
        XCTAssertEqual(harness.captured.scrollPhases, [.ended])
        XCTAssertNil(harness.pipeline.activeSource)
    }
}
