// MIT License
// Copyright (c) 2026 RawTouch contributors

import XCTest

@testable import RawTouchCore

/// The event thread's own contract: work lands on it, in order, and a
/// stopped thread refuses work instead of losing it silently — whichever
/// thread asks.
final class EventThreadTests: XCTestCase {
    func testWorkRunsOnTheThreadInOrder() {
        let thread = EventThread()
        thread.start()
        defer { thread.stop() }

        var order: [Int] = []
        for index in 0..<3 {
            XCTAssertTrue(
                thread.perform {
                    XCTAssertTrue(thread.isCurrent)
                    order.append(index)
                })
        }
        let onThread = thread.performAndWait { thread.isCurrent }

        XCTAssertEqual(onThread, true)
        XCTAssertFalse(thread.isCurrent, "the test's own thread is not the event thread")
        XCTAssertEqual(thread.performAndWait { order }, [0, 1, 2])
    }

    func testAStoppedThreadRefusesWork() {
        let thread = EventThread()
        thread.start()
        thread.stop()

        XCTAssertFalse(thread.perform {})
        XCTAssertNil(thread.performAndWait { 1 })
        XCTAssertNil(thread.runLoop)
    }

    /// Other threads — the display link's, a report queue's — hand work
    /// over while the owner stops the thread. Every call must see the
    /// thread either running or stopped, never half of each: run under the
    /// thread sanitizer, this is the race the lock closes.
    func testWorkHandedOverFromOtherThreadsWhileStoppingIsSafe() {
        for _ in 0..<20 {
            let thread = EventThread()
            thread.start()
            let handedOver = DispatchGroup()
            for _ in 0..<4 {
                DispatchQueue.global().async(group: handedOver) {
                    for _ in 0..<200 {
                        _ = thread.perform {}
                        _ = thread.isCurrent
                    }
                }
            }
            thread.stop()
            handedOver.wait()
            XCTAssertFalse(thread.perform {})
        }
    }
}
