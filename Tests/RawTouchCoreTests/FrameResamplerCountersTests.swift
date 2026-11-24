// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchTestSupport
import XCTest

@testable import RawTouchCore

/// The resampler's per-touch tick counts: every answered tick, and the
/// ones that found the newest sample beyond the extrapolation horizon and
/// held the position — the stutter a too-small latency shows as.
final class FrameResamplerCountersTests: XCTestCase {
    func testHeldTicksAreThoseBeyondTheExtrapolationHorizon() {
        var resampler = FrameResampler(latency: 0)
        _ = resampler.ingest(scrollFrame(x: 1000, y: 700, at: 0))
        _ = resampler.ingest(scrollFrame(x: 1030, y: 700, at: 0.010))

        _ = resampler.tick(at: 0.015)  // 5 ms past the newest: extrapolated
        XCTAssertEqual(resampler.tickCount, 1)
        XCTAssertEqual(resampler.heldTickCount, 0)

        _ = resampler.tick(at: 0.025)  // 15 ms past: capped, held
        XCTAssertEqual(resampler.tickCount, 2)
        XCTAssertEqual(resampler.heldTickCount, 1)

        _ = resampler.ingest(scrollFrame(x: 1060, y: 700, at: 0.020))
        _ = resampler.tick(at: 0.030)  // exactly one period past: not held
        XCTAssertEqual(resampler.tickCount, 3)
        XCTAssertEqual(resampler.heldTickCount, 1)

        // Latency covers the gap: the same tick, 5 ms of latency, targets
        // 0.025 — within the horizon.
        resampler.latency = 0.005
        _ = resampler.tick(at: 0.035)
        XCTAssertEqual(resampler.heldTickCount, 1)
    }

    func testTheCountsSurviveTheReleaseAndRestartWithTheNextTouch() {
        var resampler = FrameResampler(latency: 0)
        _ = resampler.ingest(scrollFrame(x: 1000, y: 700, at: 0))
        _ = resampler.tick(at: 0.005)
        _ = resampler.tick(at: 0.020)
        XCTAssertEqual(resampler.tickCount, 2)
        XCTAssertEqual(resampler.heldTickCount, 1)

        _ = resampler.passThrough(releaseFrame(at: 0.030, scrollMode: true))
        XCTAssertEqual(resampler.tickCount, 2, "the lift-off summary reads the counts after the release")
        XCTAssertEqual(resampler.heldTickCount, 1)

        _ = resampler.ingest(scrollFrame(x: 1000, y: 700, at: 1))
        XCTAssertEqual(resampler.tickCount, 0)
        XCTAssertEqual(resampler.heldTickCount, 0)

        _ = resampler.tick(at: 1.005)
        resampler.reset()
        XCTAssertEqual(resampler.tickCount, 0)
    }
}
