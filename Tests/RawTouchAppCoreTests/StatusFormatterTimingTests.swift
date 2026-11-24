// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchAppCore
import RawTouchCore
import XCTest

/// The gesture readout's timing line and lift-floor fragment.
final class StatusFormatterTimingTests: XCTestCase {
    /// The latency is a measurement of the connection the frames came in
    /// over, so the line names it: that is what explains the number.
    func testTimingLineNamesTheConnectionAndTheStalledFrames() {
        let endpoint = RawTouchStatus.Endpoint(
            id: RawTouchEndpointID(rawValue: 1),
            productName: "Go60 Right",
            transport: .usb,
            padIDs: [0],
            lease: .held
        )
        let status = RawTouchStatus(endpoints: [endpoint])
        var gesture = RawTouchGestureSummary(
            endpoint: endpoint.id,
            peakFingerSpeed: 1240, peakGain: 3.2, touchDistance: 400, liftOffSpeed: 1850, complete: true,
            latencyMs: 1.5, displayFrames: 138, heldFrames: 0
        )
        XCTAssertEqual(
            StatusFormatter.gestureTimingLine(gesture, in: status),
            "Latency 1.5 ms over USB \u{00B7} stalled 0 of 138 frames"
        )

        gesture.heldFrames = 7
        XCTAssertEqual(
            StatusFormatter.gestureTimingLine(gesture, in: RawTouchStatus()),
            "Latency 1.5 ms \u{00B7} stalled 7 of 138 frames",
            "a gesture from a keyboard that has since gone still reads"
        )
    }

    /// A pad relayed from the other half of a split keyboard says which
    /// split link it crossed, right after the connection; a local pad (or
    /// firmware that does not say) adds nothing.
    func testTimingLineNamesTheSplitLinkOfARelayedPad() {
        let usb = RawTouchStatus.Endpoint(
            id: RawTouchEndpointID(rawValue: 1), productName: "Go60", transport: .usb, padIDs: [1], lease: .held)
        let bluetooth = RawTouchStatus.Endpoint(
            id: RawTouchEndpointID(rawValue: 2), productName: "Go60", transport: .bluetooth, padIDs: [1],
            lease: .held)
        let status = RawTouchStatus(endpoints: [usb, bluetooth])
        var gesture = RawTouchGestureSummary(
            endpoint: usb.id,
            peakFingerSpeed: 1240, peakGain: 3.2, touchDistance: 400, liftOffSpeed: 1850, complete: true,
            latencyMs: 5.2, displayFrames: 138, heldFrames: 2, splitLink: .wired
        )
        XCTAssertEqual(
            StatusFormatter.gestureTimingLine(gesture, in: status),
            "Latency 5.2 ms over USB \u{00B7} wired split \u{00B7} stalled 2 of 138 frames"
        )

        gesture.endpoint = bluetooth.id
        gesture.latencyMs = 15.3
        gesture.splitLink = .wireless
        XCTAssertEqual(
            StatusFormatter.gestureTimingLine(gesture, in: status),
            "Latency 15.3 ms over Bluetooth \u{00B7} wireless split \u{00B7} stalled 2 of 138 frames"
        )

        gesture.splitLink = nil
        XCTAssertEqual(
            StatusFormatter.gestureTimingLine(gesture, in: status),
            "Latency 15.3 ms over Bluetooth \u{00B7} stalled 2 of 138 frames"
        )
    }

    /// The peak is the finger's own speed, in the unit the acceleration
    /// row is set in — not the pad's counts, which mean nothing to a user.
    func testFingerLineIsInMillimetresPerSecond() {
        let gesture = RawTouchGestureSummary(
            padCountsPerMM: 38,
            peakFingerSpeed: 6726, peakGain: 4.8, touchDistance: 400, liftOffSpeed: 1850, complete: true
        )
        XCTAssertEqual(
            StatusFormatter.gestureFingerLine(gesture),
            "Peak finger 177 mm/s \u{00B7} acceleration up to 4.8\u{00D7}"
        )
    }

    /// A reading from before lunch is still true of its gesture and no
    /// longer of the sliders: the strip dims it rather than dropping it.
    func testAReadingGoesStaleAfterHalfAMinute() {
        let liftOff = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertFalse(StatusFormatter.gestureIsStale(since: liftOff, now: liftOff.addingTimeInterval(29)))
        XCTAssertTrue(StatusFormatter.gestureIsStale(since: liftOff, now: liftOff.addingTimeInterval(30)))
        XCTAssertTrue(StatusFormatter.gestureIsStale(since: liftOff, now: liftOff.addingTimeInterval(600)))
    }

    func testLiftFloorFragmentIsAbsentUnlessFramesWereCarried() {
        var gesture = RawTouchGestureSummary(
            displayPointsPerMM: 4.3,
            peakFingerSpeed: 1, peakGain: 1, touchDistance: 1, liftOffSpeed: 1850, complete: false
        )
        XCTAssertNil(StatusFormatter.gestureLiftFloorFragment(gesture))
        XCTAssertEqual(
            StatusFormatter.gestureLiftOffLine(gesture, minimumFlickSpeed: 23),
            "Lift-off 430 mm/s on screen \u{00B7} coasting\u{2026}",
            "a followed lift says nothing about the floor"
        )
        gesture.liftFramesCarried = 1
        XCTAssertEqual(StatusFormatter.gestureLiftFloorFragment(gesture), "carried 1 frame")
        gesture.liftFramesCarried = 4
        XCTAssertEqual(StatusFormatter.gestureLiftFloorFragment(gesture), "carried 4 frames")
        XCTAssertEqual(
            StatusFormatter.gestureLiftOffLine(gesture, minimumFlickSpeed: 23),
            "Lift-off 430 mm/s on screen, carried 4 frames \u{00B7} coasting\u{2026}"
        )

        let slow = RawTouchGestureSummary(
            displayPointsPerMM: 4.3,
            peakFingerSpeed: 300, peakGain: 1, touchDistance: 40, liftOffSpeed: 99, complete: true, liftFramesCarried: 2
        )
        XCTAssertEqual(
            StatusFormatter.gestureLiftOffLine(slow, minimumFlickSpeed: 23),
            "Lift-off 23 mm/s on screen, carried 2 frames \u{00B7} no coast, under 23"
        )
    }
}
