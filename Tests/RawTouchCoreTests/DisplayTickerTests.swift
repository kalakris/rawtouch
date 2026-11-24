// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchTestSupport
import XCTest

@testable import RawTouchCore

/// The manual ticker's bookkeeping (the pipeline tests lean on it) and the
/// host-clock conversion the real display link relies on. No display link
/// is ever created here.
final class DisplayTickerTests: XCTestCase {
    func testManualTickerDeliversToTheLiveSourceOnly() {
        let ticker = ManualDisplayTicker()
        var received: [TimeInterval] = []
        XCTAssertFalse(ticker.tick(at: 1), "nothing running")

        let source = ticker.startTicks { received.append($0) }
        XCTAssertNotNil(source)
        XCTAssertTrue(ticker.isTicking)
        XCTAssertTrue(ticker.tick(at: 2))
        XCTAssertEqual(received, [2])

        source?.invalidate()
        XCTAssertFalse(ticker.isTicking)
        XCTAssertFalse(ticker.tick(at: 3))
        XCTAssertEqual(received, [2])
        XCTAssertEqual(ticker.startCount, 1)
    }

    func testManualTickerCanRefuseToStart() {
        let ticker = ManualDisplayTicker()
        ticker.refusesToStart = true
        XCTAssertNil(ticker.startTicks { _ in })
        XCTAssertEqual(ticker.startCount, 0)
    }

    /// The display link's `hostTime` is Mach absolute time; the pipeline's
    /// clock is `ProcessInfo.systemUptime`. They must be the same axis, or
    /// every resampling target would be offset by the boot-time difference.
    func testHostClockSharesTheSystemUptimeAxis() {
        let before = ProcessInfo.processInfo.systemUptime
        let host = HostClock.now()
        let after = ProcessInfo.processInfo.systemUptime

        XCTAssertGreaterThanOrEqual(host, before - 0.001)
        XCTAssertLessThanOrEqual(host, after + 0.001)
    }

    func testHostClockConvertsRawHostTimeConsistently() {
        let raw = mach_absolute_time()
        XCTAssertEqual(HostClock.seconds(fromHostTime: raw), HostClock.now(), accuracy: 0.01)
        XCTAssertEqual(HostClock.seconds(fromHostTime: 0), 0)
    }
}
