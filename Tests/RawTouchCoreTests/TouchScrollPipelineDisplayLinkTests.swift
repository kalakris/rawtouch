// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchTestSupport
import XCTest

@testable import RawTouchCore

/// The display link as a failure point: a link that stops ticking mid-touch
/// or mid-coast (`ManualDisplayTicker.killLiveSource()`: the display it
/// ticks for is unplugged, the lid closes, the display sleeps) must not
/// strand the gesture (or every later one), and a display that has no link
/// at all costs one attempt per gesture, not one per frame.
final class TouchScrollPipelineDisplayLinkTests: XCTestCase {
    private let frameInterval: TimeInterval = 0.01
    private let displayPeriod: TimeInterval = 1.0 / 120.0

    private func makeHarness() -> PipelineHarness {
        PipelineHarness(resampling: true)
    }

    /// Drives a drag along raw x: `count` frames `step` counts apart every
    /// 10 ms from `start`, each arriving 1 ms after it was sampled, with the
    /// display's vsyncs between them and every due timer given its chance
    /// to fire. Returns the time of the last frame.
    @discardableResult
    private func drag(
        _ harness: PipelineHarness,
        from start: TimeInterval,
        count: Int,
        step: Int,
        x0: Int = 1000
    ) -> TimeInterval {
        var t = start
        for index in 0..<count {
            t = start + Double(index) * frameInterval
            harness.now = t + 0.001
            harness.handle(scrollFrame(x: x0 + index * step, at: t))
            harness.scheduler.fireOneShots()
            var vsync = t + 0.003
            while vsync < t + frameInterval {
                harness.now = vsync
                harness.ticker.tick(at: vsync)
                vsync += displayPeriod
            }
        }
        return t
    }

    private func release(_ harness: PipelineHarness, at t: TimeInterval) {
        harness.now = t + 0.001
        harness.handle(releaseFrame(at: t, scrollMode: true))
    }

    /// The link dies mid-coast. Within ~100 ms the coast carries on on the
    /// momentum timer and runs out; the next gesture starts a fresh link and
    /// scrolls. Without the fallback the coast would never end and every
    /// later touch would be buffered for ticks that never come.
    func testALinkThatDiesMidCoastHandsTheCoastToTheTimer() {
        let harness = makeHarness()
        let last = drag(harness, from: 0, count: 12, step: 25)
        release(harness, at: last + frameInterval)
        XCTAssertNotNil(harness.pipeline.activeSource?.padID, "a flick: coasting")
        for index in 1...3 {
            harness.now = last + frameInterval + Double(index) * displayPeriod
            harness.ticker.tick(at: harness.now)
        }
        XCTAssertEqual(harness.captured.phases.last?.momentum, .continuous)

        harness.ticker.killLiveSource()
        harness.now += 0.050
        harness.scheduler.fireOneShots()
        XCTAssertFalse(
            harness.scheduler.liveTimers.contains(where: \.repeats), "50 ms of silence is not yet a dead link")

        harness.now += 0.060
        harness.scheduler.fireOneShots()
        XCTAssertTrue(
            harness.scheduler.liveTimers.contains(where: \.repeats), "the coast continues on the momentum timer")
        XCTAssertNil(harness.ticker.liveSource, "the dead link is released")

        harness.scheduler.fireRepeating(count: 2000)
        XCTAssertEqual(harness.captured.phases.last?.momentum, .end, "the coast runs out")
        XCTAssertNil(harness.pipeline.activeSource?.padID)

        let attempts = harness.ticker.startAttempts
        let posted = harness.captured.phases.count
        drag(harness, from: 5, count: 6, step: 60)
        XCTAssertEqual(harness.ticker.startAttempts, attempts + 1, "the next gesture tries the display link again")
        XCTAssertGreaterThan(harness.captured.phases.count, posted, "and scrolls")
    }

    /// The link dies mid-touch: the frames buffered for it reach the engine
    /// at once, and the rest of the touch is fed per sample — scrolled
    /// while the finger moves, not held back until it lifts.
    func testALinkThatDiesMidTouchFallsBackToPerSampleFeeding() {
        let harness = makeHarness()
        drag(harness, from: 0, count: 5, step: 4)
        let beforeDeath = harness.captured.deltas.reduce(0, +)
        XCTAssertGreaterThan(beforeDeath, 0)

        harness.ticker.killLiveSource()
        let last = drag(harness, from: 0.05, count: 20, step: 4, x0: 1020)
        XCTAssertNil(harness.ticker.liveSource)
        // 24 steps of 4 counts × 0.25 pt are 24 pt; all but the last
        // ~100 ms of them are on screen before the lift.
        XCTAssertGreaterThan(harness.captured.deltas.reduce(0, +), 20)
        release(harness, at: last + frameInterval)

        XCTAssertEqual(harness.captured.scrollPhases.last, .ended)
        // Give or take the resampler's carried offset.
        XCTAssertEqual(harness.captured.deltas.reduce(0, +), 24, accuracy: 1)
        XCTAssertNil(harness.pipeline.activeSource?.padID)
    }

    /// A display without a link is tried once per gesture — not on every
    /// frame, each attempt a CoreGraphics lookup and two log lines.
    func testNoDisplayLinkIsTriedOncePerGesture() {
        let harness = makeHarness()
        harness.ticker.refusesToStart = true

        let last = drag(harness, from: 0, count: 10, step: 4)
        XCTAssertEqual(harness.ticker.startAttempts, 1)
        XCTAssertEqual(harness.captured.deltas.reduce(0, +), 9, accuracy: 1e-9, "fed per sample: 9 steps of 1 pt")
        release(harness, at: last + frameInterval)

        drag(harness, from: 1, count: 10, step: 4)
        XCTAssertEqual(harness.ticker.startAttempts, 2, "one more attempt for the next gesture")
    }
}
