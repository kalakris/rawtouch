// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchTestSupport
import XCTest

@testable import RawTouchCore

/// The host's half of a tap on a scrolling pad (`RawTouchTapConfirm`): a
/// pad that parks scroll taps waits for the host to say the touch did not
/// stop a coast. The pipeline confirms exactly the touches that were short,
/// still, in scroll context, and landed on no running coast, on firmware
/// and pads that asked for it — and nothing else. The confirms are
/// recorded, not written; nothing is posted.
final class TouchScrollPipelineTapConfirmTests: XCTestCase {
    private let frameInterval: TimeInterval = 0.01
    private let keyboard = RawTouchEndpointID(rawValue: 1)

    /// One Go60-shaped keyboard, both pads, unpaced. By default the firmware
    /// takes confirms and both pads park their scroll taps. The harness
    /// records the confirms the way the device manager would receive them.
    private func makeHarness(
        tapConfirm: Bool = true,
        parkingPads: Set<UInt8> = [0, 1],
        now: (() -> TimeInterval)? = nil
    ) -> PipelineHarness {
        var descriptor = endpointDescriptor(id: 1)
        if tapConfirm {
            descriptor.capabilities.capabilityBits |= RawTouchCapabilities.Capability.tapConfirm
        }
        for padID in parkingPads {
            descriptor.capabilities.pads[padID]?.parksScrollTaps = true
        }
        return PipelineHarness(resampling: false, paced: false, endpoints: [descriptor], now: now)
    }

    private func source(_ pad: UInt8) -> RawTouchSourceID {
        RawTouchSourceID(endpoint: keyboard, padID: pad)
    }

    /// A tap: five frames 10 ms apart that wander a few counts, then the
    /// release. `frames` and `step` shape it into a long press or a drag.
    @discardableResult
    private func touch(
        _ harness: PipelineHarness,
        pad: UInt8 = 1,
        from start: TimeInterval = 0,
        frames: Int = 5,
        step: Int = 1,
        scrollMode: Bool = true,
        releaseLeaseHeld: Bool = true
    ) -> TimeInterval {
        var timestamp = start
        for index in 0..<frames {
            timestamp = start + Double(index) * frameInterval
            let x = 1000 + index * step
            harness.pipeline.handle(
                wireFrame: scrollMode
                    ? scrollFrame(x: x, at: timestamp, pad: pad, endpoint: keyboard)
                    : pointerFrame(x: x, at: timestamp, pad: pad, endpoint: keyboard))
        }
        timestamp += frameInterval
        harness.pipeline.handle(
            wireFrame: releaseFrame(
                at: timestamp,
                scrollMode: scrollMode,
                pad: pad,
                leaseHeld: releaseLeaseHeld,
                endpoint: keyboard
            ))
        return timestamp
    }

    /// A flick into a coasting momentum tail.
    private func flickIntoMomentum(
        _ harness: PipelineHarness,
        pad: UInt8,
        from start: TimeInterval = 0
    ) -> TimeInterval {
        let end = harness.flickIntoMomentum(pad: pad, on: keyboard, from: start)
        XCTAssertTrue(
            harness.scheduler.liveTimers.contains(where: \.repeats),
            "precondition: the flick is coasting"
        )
        return end
    }

    // MARK: - Confirmed

    func testATapIsConfirmedOnce() {
        let harness = makeHarness()
        touch(harness)
        XCTAssertEqual(harness.tapConfirms, [source(1)])
    }

    /// Arbitration ignores a pad while another one owns the gesture; a tap
    /// there is still a tap, and was no catch.
    func testATapOnAPadTheArbitrationIgnoresIsStillConfirmed() {
        let harness = makeHarness()
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0, pad: 0, endpoint: keyboard))
        XCTAssertEqual(harness.pipeline.activeSource, source(0))

        touch(harness, pad: 1, from: 0.01)
        XCTAssertEqual(harness.tapConfirms, [source(1)])
    }

    // MARK: - Not a tap

    func testADragIsNotConfirmed() {
        let harness = makeHarness()
        touch(harness, frames: 5, step: 20)  // 80 counts of travel in 50 ms
        XCTAssertEqual(harness.tapConfirms, [])
    }

    func testALongPressIsNotConfirmed() {
        let harness = makeHarness()
        touch(harness, frames: 35, step: 0)  // 350 ms, perfectly still
        XCTAssertEqual(harness.tapConfirms, [])
    }

    func testAPointerContextTapIsNotConfirmed() {
        let harness = makeHarness()
        touch(harness, scrollMode: false)
        XCTAssertEqual(harness.tapConfirms, [])
    }

    // MARK: - Caught a coast

    func testATapCatchingItsOwnPadsCoastIsNotConfirmed() {
        let harness = makeHarness()
        let end = flickIntoMomentum(harness, pad: 1)

        touch(harness, pad: 1, from: end + 0.05)
        XCTAssertEqual(harness.tapConfirms, [], "the finger stopped a coast; that is no click")

        // The catch ended the coast, so the next tap lands on nothing.
        touch(harness, pad: 1, from: end + 0.5)
        XCTAssertEqual(harness.tapConfirms, [source(1)])
    }

    func testATapCatchingAnotherPadsCoastIsNotConfirmed() {
        let harness = makeHarness()
        let end = flickIntoMomentum(harness, pad: 0)

        touch(harness, pad: 1, from: end + 0.05)
        XCTAssertEqual(harness.tapConfirms, [])
        XCTAssertEqual(harness.pipeline.activeSource, nil, "the catching tap took the gesture over and ended it")

        touch(harness, pad: 1, from: end + 0.5)
        XCTAssertEqual(harness.tapConfirms, [source(1)])
    }

    // MARK: - Nobody asked

    func testFirmwareWithoutTapConfirmIsNeverSentOne() {
        let harness = makeHarness(tapConfirm: false)
        touch(harness)
        XCTAssertEqual(harness.tapConfirms, [])
    }

    func testAPadThatDoesNotParkTapsIsNeverSentOne() {
        let harness = makeHarness(parkingPads: [1])
        touch(harness, pad: 0)
        XCTAssertEqual(harness.tapConfirms, [])
        touch(harness, pad: 1, from: 0.5)
        XCTAssertEqual(harness.tapConfirms, [source(1)])
    }

    // MARK: - The touch ended without its release

    /// The firmware's trailing bit-2-clear release after a lease lapse: the
    /// lease is gone, so there is nobody to confirm to — and the next touch
    /// after the lease returns starts a record of its own.
    func testALeaseLapseMidTapIsNeverConfirmed() {
        let harness = makeHarness()
        touch(harness, releaseLeaseHeld: false)
        XCTAssertEqual(harness.tapConfirms, [])

        touch(harness, from: 0.5)
        XCTAssertEqual(harness.tapConfirms, [source(1)])
    }

    /// The same on a pad the arbitration is ignoring, whose state the lapse
    /// does not otherwise reset: its record must not run on into the next
    /// touch, which would then read as one long press.
    func testALeaseLapseMidTapOnAnIgnoredPadIsNeverConfirmed() {
        let harness = makeHarness()
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0, pad: 0, endpoint: keyboard))
        touch(harness, pad: 1, from: 0.01, releaseLeaseHeld: false)
        XCTAssertEqual(harness.tapConfirms, [])

        touch(harness, pad: 1, from: 0.5)
        XCTAssertEqual(harness.tapConfirms, [source(1)])
    }

    /// A stream that went silent mid-touch: the watchdog ending the touch
    /// is not the finger lifting, so it confirms nothing.
    func testAWatchdogLiftOffIsNeverConfirmed() {
        var clock: TimeInterval = 0
        let harness = makeHarness(now: { clock })
        harness.pipeline.handle(wireFrame: scrollFrame(x: 1000, at: 0, pad: 1, endpoint: keyboard))
        clock = 0.2
        harness.scheduler.fireOneShots()
        XCTAssertEqual(harness.pipeline.activeSource, nil, "precondition: the watchdog closed the touch")
        XCTAssertEqual(harness.tapConfirms, [])
    }
}
