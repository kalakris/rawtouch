// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchTestSupport
import XCTest

@testable import RawTouchCore

/// The host-lease wire contract. These assertions ARE the contract: the
/// firmware rejects any other command byte, length, or non-zero reserved
/// byte, so a change here without a matching firmware change silently turns
/// RawTouch into a no-op that lets the wheel fallback double-scroll.
final class RawTouchLeaseTests: XCTestCase {
    // MARK: - Lease payload encoding

    func testLeasePayloadMatchesTheWireContract() {
        let payload = RawTouchLease.leasePayload(acquire: true)

        XCTAssertEqual(payload.count, 4)
        XCTAssertEqual(payload[0], 0x01, "byte 0 is the host-lease command")
        XCTAssertEqual(payload[1], 0x01, "byte 1 is acquire/renew")
        XCTAssertEqual(payload[2], 30, "byte 2 is the requested timeout in seconds")
        XCTAssertEqual(payload[3], 0, "byte 3 is reserved and MUST be zero")
    }

    func testTapConfirmPayloadMatchesTheWireContract() {
        let payload = RawTouchTapConfirm.payload(pad: 1)

        XCTAssertEqual(payload, [0x02, 0x01, 0x00, 0x00])
        XCTAssertEqual(payload.count, 4, "framed like the lease command")
        XCTAssertNotEqual(RawTouchTapConfirm.command, RawTouchLease.leaseCommand)
    }

    func testReleasePayloadOnlyDiffersInTheActionByte() {
        let acquire = RawTouchLease.leasePayload(acquire: true)
        let release = RawTouchLease.leasePayload(acquire: false)

        XCTAssertEqual(release[0], acquire[0])
        XCTAssertEqual(release[1], 0x00)
        XCTAssertEqual(release[3], 0)
        // The timeout field stays in range on a release too: the firmware
        // rejects a zero timeout regardless of the action byte.
        XCTAssertTrue(RawTouchLease.timeoutRange.contains(release[2]))
    }

    func testRequestedTimeoutIsClampedIntoTheFirmwareAcceptedRange() {
        // 0 is rejected by the firmware, so it can never be emitted.
        XCTAssertEqual(RawTouchLease.leasePayload(acquire: true, timeoutSeconds: 0)[2], 5)
        XCTAssertEqual(RawTouchLease.leasePayload(acquire: true, timeoutSeconds: 1)[2], 5)
        XCTAssertEqual(RawTouchLease.leasePayload(acquire: true, timeoutSeconds: 200)[2], 120)
        XCTAssertEqual(RawTouchLease.leasePayload(acquire: true, timeoutSeconds: 60)[2], 60)
    }

    func testRenewalIntervalNeverExceedsHalfTheRequestedTimeout() {
        XCTAssertLessThanOrEqual(
            RawTouchLease.renewalInterval,
            TimeInterval(RawTouchLease.defaultTimeoutSeconds) / 2
        )
    }

    func testFeatureReportIDIsSharedWithTheInputAndCapabilityReports() {
        XCTAssertEqual(RawTouchLease.featureReportID, 0x04)
        XCTAssertEqual(RawTouchLease.featureReportID, RawTouchCapabilities.featureReportID)
        XCTAssertEqual(CFIndex(RawTouchFrame.reportID), RawTouchLease.featureReportID)
    }

    // MARK: - Capability bit

    func testCapabilityBitZeroAdvertisesTheLease() {
        var report = featureReportBytes(
            padsPresent: 0x01,  // pad 0 present
            capabilityBits: 0x00,  // capabilities: no lease support
            slots: [.empty, .empty]
        )

        guard let unsupported = RawTouchCapabilities.parse(reportBytes: report) else {
            XCTFail("Expected the report to parse")
            return
        }
        XCTAssertFalse(unsupported.supportsHostLease)

        report[2] = 0x01
        XCTAssertEqual(RawTouchCapabilities.parse(reportBytes: report)?.supportsHostLease, true)

        // Other capability bits do not imply lease support.
        report[2] = 0xFE
        XCTAssertEqual(RawTouchCapabilities.parse(reportBytes: report)?.supportsHostLease, false)

        report[2] = 0xFF
        XCTAssertEqual(RawTouchCapabilities.parse(reportBytes: report)?.supportsHostLease, true)
    }

    // MARK: - Frame filtering decision

    /// The pipeline synthesizes only from frames with `leaseHeld` set; the
    /// fixtures must agree with the flag.
    func testFixturesCarryTheLeaseHeldFlag() {
        XCTAssertTrue(scrollFrame(at: 0, leaseHeld: true).leaseHeld)
        XCTAssertFalse(scrollFrame(at: 0, leaseHeld: false).leaseHeld)

        // The decision is on bit 2 alone; bit 1 is the engine's business
        // (a leased pointer-mode frame must still reach it, to close out a
        // gesture when the scroll layer is released mid-touch).
        XCTAssertTrue(pointerFrame(at: 0, leaseHeld: true).leaseHeld)
        XCTAssertFalse(pointerFrame(at: 0, leaseHeld: false).leaseHeld)
        XCTAssertTrue(releaseFrame(at: 0, scrollMode: true).leaseHeld)
    }

    func testLeaseHeldReadsBitTwoOfTheWireFlagsByte() {
        func frame(flags: UInt8) -> RawTouchFrame {
            RawTouchFrame(reportBytes: v3FrameBytes(flags: flags), timestamp: 0)!
        }

        XCTAssertFalse(frame(flags: 0b000).leaseHeld)
        XCTAssertFalse(frame(flags: 0b011).leaseHeld)
        XCTAssertTrue(frame(flags: 0b100).leaseHeld)
        XCTAssertTrue(frame(flags: 0b111).leaseHeld)
    }

    /// Bit 3 says the pad is relayed from a split peripheral, bit 4 over
    /// which link. Bit 4 alone means nothing, and both clear (what older
    /// firmware sends) is no link to show. Neither touches the other flags.
    func testSplitLinkReadsBitsThreeAndFourOfTheWireFlagsByte() {
        func frame(flags: UInt8) -> RawTouchFrame {
            RawTouchFrame(reportBytes: v3FrameBytes(flags: flags), timestamp: 0)!
        }

        XCTAssertNil(frame(flags: 0b0_0111).splitLink, "older firmware: not relayed, or unknown")
        XCTAssertNil(frame(flags: 0b1_0111).splitLink, "bit 4 without bit 3 is not a relay")
        XCTAssertEqual(frame(flags: 0b0_1111).splitLink, .wired)
        XCTAssertEqual(frame(flags: 0b1_1111).splitLink, .wireless)

        let relayed = frame(flags: 0b1_1111)
        XCTAssertTrue(relayed.touched)
        XCTAssertTrue(relayed.scrollMode)
        XCTAssertTrue(relayed.leaseHeld)
        XCTAssertFalse(frame(flags: 0b1_1000).leaseHeld)
    }

    // MARK: - Lease bookkeeping across the asynchronous write

    /// The race this guards against: the user disables RawTouch while an
    /// acquire write is still in flight on the report queue. The release is
    /// queued behind it, but the *acquire's completion* lands afterwards —
    /// and must not mark the lease held again, or the firmware would keep
    /// suppressing its own wheel scrolling with nobody synthesizing, until
    /// the 30 s lease expired.
    func testAnAcquireCompletingAfterAReleaseIsIgnored() {
        var state = LeaseState()
        let stamp = state.beginAcquire()

        state.beginRelease()
        XCTAssertFalse(state.held, "the status reads Standard mode from the moment we ask to release")

        // ...and only now does the acquire write report success.
        state.completeAcquire(landed: true, generation: stamp)

        XCTAssertFalse(state.held, "a stale completion must never resurrect the lease")
        XCTAssertFalse(state.desiredHeld)
    }

    func testAnAcquireThatLandsWhileStillWantedIsRecorded() {
        var state = LeaseState()
        let stamp = state.beginAcquire()
        state.completeAcquire(landed: true, generation: stamp)
        XCTAssertTrue(state.held)
        XCTAssertTrue(state.desiredHeld)
    }

    /// A failed write is recorded as failed, so `status.leaseHeld` (the
    /// menu's RawTouch-mode line) describes the device rather than our
    /// intent.
    func testAFailedAcquireLeavesTheDeviceWithoutALease() {
        var state = LeaseState()
        let stamp = state.beginAcquire()
        state.completeAcquire(landed: false, generation: stamp)
        XCTAssertFalse(state.held)
    }

    /// A renewal in flight has not answered yet, so it must not wipe the
    /// last answer: an endpoint that keeps failing reads failed from one
    /// renewal to the next rather than flickering through pending (and
    /// republishing the status) every 10 s. Only a landed acquire or a
    /// release clears it.
    func testAFailureStandsThroughTheNextRenewalUntilOneLands() {
        var state = LeaseState()
        state.completeAcquire(landed: false, generation: state.beginAcquire())
        XCTAssertTrue(state.failed)

        let renewal = state.beginAcquire()
        XCTAssertTrue(state.failed, "the renewal has not answered yet")

        state.completeAcquire(landed: true, generation: renewal)
        XCTAssertFalse(state.failed)
        XCTAssertTrue(state.held)

        state.completeAcquire(landed: false, generation: state.beginAcquire())
        state.beginRelease()
        XCTAssertFalse(state.failed, "a lease we no longer want has nothing left to fail")
    }

    /// Renewals overtake each other too — the timer fires every 10 s and a
    /// BLE write can take a while. Only the newest answer counts.
    func testAnOlderAcquireCompletionLosesToANewerOne() {
        var state = LeaseState()
        let first = state.beginAcquire()
        let second = state.beginAcquire()

        state.completeAcquire(landed: true, generation: second)
        state.completeAcquire(landed: false, generation: first)

        XCTAssertTrue(state.held, "the superseded write cannot drop the lease")
    }

    /// Re-enabling after a release is a fresh generation and lands normally.
    func testReacquiringAfterAReleaseWorks() {
        var state = LeaseState()
        state.beginRelease()
        let stamp = state.beginAcquire()
        state.completeAcquire(landed: true, generation: stamp)
        XCTAssertTrue(state.held)
        XCTAssertTrue(state.desiredHeld)
    }
}
