// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import XCTest

@testable import RawTouchAppCore

/// The handler is driven directly: installing it would set the test
/// runner's own SIGINT/SIGTERM/SIGHUP to ignored.
final class TerminationSignalsTests: XCTestCase {
    func testHandlesTheSignalsThatEndAProcessByDefault() {
        XCTAssertEqual(Set(TerminationSignals.handled), [SIGTERM, SIGINT, SIGHUP])
    }

    func testFirstSignalTerminates() {
        var calls = 0
        let signals = TerminationSignals { calls += 1 }
        signals.handle(SIGTERM)
        XCTAssertEqual(calls, 1)
    }

    func testLaterSignalsDoNothing() {
        var calls = 0
        let signals = TerminationSignals { calls += 1 }
        signals.handle(SIGTERM)
        signals.handle(SIGTERM)
        signals.handle(SIGINT)
        signals.handle(SIGHUP)
        XCTAssertEqual(calls, 1)
    }
}
