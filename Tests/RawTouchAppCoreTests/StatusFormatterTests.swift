// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchCore
import XCTest

@testable import RawTouchAppCore

/// The menu's status strings: short factual fragments, no drama.
final class StatusFormatterTests: XCTestCase {
    // MARK: - Keyboard lines (the menu)

    private func endpoint(
        _ id: UInt64,
        name: String = "Go60 Right",
        transport: RawTouchTransport = .usb,
        key: String? = "id:DEADBEEFCAFEF00D",
        lease: RawTouchStatus.Endpoint.Lease = .held
    ) -> RawTouchStatus.Endpoint {
        RawTouchStatus.Endpoint(
            id: RawTouchEndpointID(rawValue: id),
            productName: name,
            transport: transport,
            padIDs: [0, 1],
            deviceKey: key,
            lease: lease
        )
    }

    func testAKeyboardOnOneTransportIsOneLine() {
        let status = RawTouchStatus(endpoints: [endpoint(1)])
        XCTAssertEqual(StatusFormatter.keyboardLines(for: status), ["Go60 Right \u{00B7} USB: RawTouch mode"])
    }

    /// One keyboard plugged in *and* paired is two connections and one
    /// keyboard: as long as they agree, the menu says so once.
    func testAgreeingConnectionsAreStatedOnce() {
        let status = RawTouchStatus(endpoints: [endpoint(1), endpoint(2, transport: .bluetooth)])
        XCTAssertEqual(
            StatusFormatter.keyboardLines(for: status),
            ["Go60 Right \u{00B7} USB and Bluetooth: RawTouch mode"]
        )
    }

    /// A lease belongs to a connection and can fail on its own, so
    /// connections that disagree each say their own piece.
    func testDisagreeingConnectionsEachSayTheirOwn() {
        let status = RawTouchStatus(endpoints: [
            endpoint(1),
            endpoint(2, transport: .bluetooth, lease: .failed),
        ])
        XCTAssertEqual(
            StatusFormatter.keyboardLines(for: status),
            [
                "Go60 Right: RawTouch mode over USB, Standard mode over Bluetooth \u{2014} switch failed, reconnect to retry"
            ])
    }

    func testTwoKeyboardsAreTwoLines() {
        let status = RawTouchStatus(endpoints: [
            endpoint(1),
            endpoint(2, name: "Sofle", key: "id:0011223344556677", lease: .disabled),
        ])
        XCTAssertEqual(
            StatusFormatter.keyboardLines(for: status),
            [
                "Go60 Right \u{00B7} USB: RawTouch mode",
                "Sofle \u{00B7} USB: Standard mode \u{2014} switched off",
            ])
    }

    /// A transport macOS did not name adds nothing: the line stays factual
    /// rather than inventing a word for it.
    func testAnUnnamedTransportIsLeftOut() {
        let status = RawTouchStatus(endpoints: [endpoint(1, transport: .unknown)])
        XCTAssertEqual(StatusFormatter.keyboardLines(for: status), ["Go60 Right: RawTouch mode"])
    }

    func testWithoutAKeyboard() {
        XCTAssertEqual(StatusFormatter.keyboardLines(for: RawTouchStatus()), ["Waiting for device"])
    }

    func testLeaseLinesNameTheReason() {
        XCTAssertEqual(StatusFormatter.leaseLine(for: .held), "RawTouch mode")
        XCTAssertEqual(StatusFormatter.leaseLine(for: .notWanted), "Standard mode")
        XCTAssertEqual(StatusFormatter.leaseLine(for: .pending), "Switching to RawTouch mode\u{2026}")
        XCTAssertEqual(StatusFormatter.leaseLine(for: .disabled), "Standard mode \u{2014} switched off")
        XCTAssertEqual(
            StatusFormatter.leaseLine(for: .failed),
            "Standard mode \u{2014} switch failed, reconnect to retry"
        )
        XCTAssertEqual(StatusFormatter.leaseLine(for: .unsupportedFirmware), "Firmware without RawTouch mode")
    }

    /// The transport qualifies the mode, before the reason it is in it.
    func testLeasePhrasesNameTheirConnection() {
        XCTAssertEqual(StatusFormatter.leasePhrase(for: endpoint(1)), "RawTouch mode over USB")
        XCTAssertEqual(
            StatusFormatter.leasePhrase(for: endpoint(1, transport: .bluetooth, lease: .failed)),
            "Standard mode over Bluetooth \u{2014} switch failed, reconnect to retry"
        )
        XCTAssertEqual(StatusFormatter.leasePhrase(for: endpoint(1, transport: .unknown)), "RawTouch mode")
    }

    // MARK: - Keyboard status (settings window)

    private func keyboard(_ status: RawTouchStatus) -> RawTouchKeyboard {
        RawTouchKeyboard.grouped(in: status)[0]
    }

    func testKeyboardStatusStatesTheModeOnceWhenConnectionsAgree() {
        let status = RawTouchStatus(endpoints: [endpoint(1), endpoint(2, transport: .bluetooth)])
        XCTAssertEqual(
            StatusFormatter.keyboardStatus(for: keyboard(status), in: status),
            "RawTouch mode \u{00B7} USB and Bluetooth"
        )
    }

    func testKeyboardStatusEnumeratesOnlyOnDisagreement() {
        let status = RawTouchStatus(endpoints: [
            endpoint(1),
            endpoint(2, transport: .bluetooth, lease: .failed),
        ])
        XCTAssertEqual(
            StatusFormatter.keyboardStatus(for: keyboard(status), in: status),
            "RawTouch mode over USB \u{00B7} Standard mode over Bluetooth \u{2014} switch failed, reconnect to retry"
        )
    }

    /// Activity is named on the keyboard it is on, and on no other: two
    /// keyboards can both have a pad 0.
    func testKeyboardStatusNamesActivityOnItsOwnKeyboardOnly() {
        let mine = endpoint(1)
        let other = endpoint(2, name: "Sofle", key: "id:0011223344556677")
        let status = RawTouchStatus(
            activity: .touching(padID: 0, endpoint: mine.id),
            endpoints: [mine, other]
        )
        let keyboards = RawTouchKeyboard.grouped(in: status)
        XCTAssertEqual(
            StatusFormatter.keyboardStatus(for: keyboards[0], in: status),
            "RawTouch mode \u{00B7} USB \u{00B7} Pad 0 scrolling"
        )
        XCTAssertEqual(StatusFormatter.keyboardStatus(for: keyboards[1], in: status), "RawTouch mode \u{00B7} USB")
    }

    /// The pad is the keyboard's, whichever of its connections it came in
    /// over.
    func testKeyboardStatusNamesActivityOnEitherConnection() {
        let usb = endpoint(1)
        let bluetooth = endpoint(2, transport: .bluetooth)
        let status = RawTouchStatus(
            activity: .coasting(padID: 1, endpoint: bluetooth.id),
            endpoints: [usb, bluetooth]
        )
        XCTAssertEqual(
            StatusFormatter.keyboardStatus(for: keyboard(status), in: status),
            "RawTouch mode \u{00B7} USB and Bluetooth \u{00B7} Pad 1 coasting"
        )
    }

    // MARK: - Firmware line (settings window)

    private static let v01 = RawTouchFirmwareVersion(major: 0, minor: 1)
    private static let v00 = RawTouchFirmwareVersion(major: 0, minor: 0)

    private func firmwareEndpoint(
        _ central: RawTouchFirmwareVersion?,
        pads: [UInt8: RawTouchFirmwareVersion] = [:],
        padIDs: [UInt8] = [0, 1],
        deviceID: String? = nil
    ) -> RawTouchStatus.Endpoint {
        RawTouchStatus.Endpoint(
            id: RawTouchEndpointID(rawValue: 1),
            productName: "Go60 Right",
            transport: .usb,
            padIDs: padIDs,
            firmwareVersion: central,
            padFirmwareVersions: pads,
            deviceID: deviceID,
            deviceKey: "usb:1",
            lease: .held
        )
    }

    // The keyboard's hardware id has no row of its own: the settings it
    // keys are what the page is for, and the key itself reads in every
    // row's tooltip, in the removal confirmation, and in the "Saved as"
    // row of an entry whose keyboard is gone — where it is the only
    // identity left. `RawTouchKeyboard` still carries `deviceID`, which
    // is what tells two of the same model apart.

    /// Both halves on the build the app is talking to: one version, one
    /// protocol, nothing to single out.
    func testFirmwareLineWhenEveryHalfAgrees() {
        let endpoint = firmwareEndpoint(Self.v01, pads: [0: Self.v01, 1: Self.v01])
        XCTAssertEqual(StatusFormatter.firmwareLine(for: endpoint), "0.1 \u{00B7} protocol 4")
    }

    /// Firmware from before the feature report carried a version says so
    /// rather than the app inventing one — the protocol is still known, and
    /// it is the part that has to match.
    func testFirmwareLineWhenTheKeyboardReportsNoVersion() {
        XCTAssertEqual(
            StatusFormatter.firmwareLine(for: firmwareEndpoint(nil)),
            "protocol 4 \u{00B7} version unknown"
        )
    }

    /// A split peripheral that has not reported its version — one half
    /// flashed and the other not awake yet — is named, not hidden.
    func testFirmwareLineNamesAPadWhoseHalfIsUnknown() {
        let endpoint = firmwareEndpoint(Self.v01, pads: [0: Self.v01])
        XCTAssertEqual(
            StatusFormatter.firmwareLine(for: endpoint),
            "0.1 \u{00B7} protocol 4 \u{00B7} Pad 1 half: touch it to read"
        )
    }

    /// The case the row exists for: a right half flashed without the left.
    /// Every differing pad is listed, in pad order whatever order the
    /// endpoint names them in.
    func testFirmwareLineNamesEveryDifferingHalfInPadOrder() {
        let endpoint = firmwareEndpoint(
            Self.v01,
            pads: [0: Self.v01, 1: Self.v00, 2: Self.v00],
            padIDs: [2, 0, 1]
        )
        XCTAssertEqual(
            StatusFormatter.firmwareLine(for: endpoint),
            "0.1 \u{00B7} protocol 4 \u{00B7} Pad 1 half 0.0 \u{00B7} Pad 2 half 0.0"
        )
    }

    // MARK: - Activity line

    func testIdleActivityHasNoLine() {
        XCTAssertNil(StatusFormatter.activityLine(for: RawTouchStatus()))
    }

    func testTouchingPad() {
        let status = RawTouchStatus(activity: .touching(padID: 0))
        XCTAssertEqual(StatusFormatter.activityLine(for: status), "Pad 0 scrolling")
    }

    func testCoastingPad() {
        let status = RawTouchStatus(activity: .coasting(padID: 1))
        XCTAssertEqual(StatusFormatter.activityLine(for: status), "Pad 1 coasting")
    }

    func testPadNamesStayLiteral() {
        // Pad IDs carry no side information; guessing "left" or "right"
        // would be wrong on unknown hardware.
        let status = RawTouchStatus(activity: .touching(padID: 5))
        XCTAssertEqual(StatusFormatter.activityLine(for: status), "Pad 5 scrolling")
    }

    // MARK: - Measured latency (the Advanced tab's read-only row)

    private func measured(
        _ id: UInt64,
        transport: RawTouchTransport = .usb,
        key: String? = "id:DEADBEEFCAFEF00D",
        name: String = "Go60 Right",
        latencies: [UInt8: Double]
    ) -> RawTouchStatus.Endpoint {
        var endpoint = self.endpoint(id, name: name, transport: transport, key: key)
        endpoint.measuredLatencyMs = latencies
        return endpoint
    }

    private func keyboards(_ endpoints: [RawTouchStatus.Endpoint]) -> [RawTouchKeyboard] {
        RawTouchKeyboard.grouped(in: RawTouchStatus(endpoints: endpoints))
    }

    /// The estimator is per pad *and* connection — a relayed pad's frames
    /// travel further than the one wired to the half the Mac talks to —
    /// so the row says both rather than flipping between them.
    func testEachConnectionNamesItsPads() {
        let lines = StatusFormatter.measuredLatencyLines(
            for: keyboards([
                measured(1, latencies: [0: 1.52, 1: 5.21]),
                measured(2, transport: .bluetooth, latencies: [0: 14.4, 1: 16.08]),
            ]))
        XCTAssertEqual(
            lines,
            [
                "USB: Pad 0 1.5 ms \u{00B7} Pad 1 5.2 ms",
                "Bluetooth: Pad 0 14.4 ms \u{00B7} Pad 1 16.1 ms",
            ])
    }

    /// Before anything has been measured the row says so once. Saying
    /// "not yet measured" per connection filled the row with nothing,
    /// three times, in the state it spends its first minutes in.
    func testNothingMeasuredAnywhereIsOneLine() {
        let lines = StatusFormatter.measuredLatencyLines(
            for: keyboards([
                measured(1, latencies: [:]),
                measured(2, transport: .bluetooth, latencies: [:]),
            ]))
        XCTAssertEqual(lines, ["Not yet measured"])
    }

    /// Once one connection has numbers, the others are simply left out:
    /// the row lists what is known, not what is not.
    func testOnlyMeasuredConnectionsAreListed() {
        let lines = StatusFormatter.measuredLatencyLines(
            for: keyboards([
                measured(1, latencies: [0: 1.52]),
                measured(2, transport: .bluetooth, latencies: [:]),
            ]))
        XCTAssertEqual(lines, ["USB: Pad 0 1.5 ms"])
    }

    /// With no keyboard, the reason there is no measurement.
    func testNoKeyboardSaysSo() {
        XCTAssertEqual(StatusFormatter.measuredLatencyLines(for: []), ["No keyboard connected"])
    }

    /// Pads go by the names the user gave them, here as everywhere else.
    func testPadNamesAreUsedWhenSet() {
        var configuration = RawTouchConfiguration()
        configuration.devices = [
            "id:DEADBEEFCAFEF00D": .init(pads: [
                "0": .init(name: "Right Pad"),
                "1": .init(name: "Left Pad"),
            ])
        ]
        let lines = StatusFormatter.measuredLatencyLines(
            for: keyboards([measured(1, latencies: [0: 1.5, 1: 5.2])]),
            configuration: configuration
        )
        XCTAssertEqual(lines, ["USB: Right Pad 1.5 ms \u{00B7} Left Pad 5.2 ms"])
    }

    /// Two keyboards: "USB" alone would stand for two different paths, so
    /// each line names its keyboard too.
    func testTwoKeyboardsNameTheirConnectionsInFull() {
        let lines = StatusFormatter.measuredLatencyLines(
            for: keyboards([
                measured(1, latencies: [0: 1.5]),
                measured(2, key: "id:BBBB", name: "Sofle", latencies: [0: 2.0]),
            ]))
        XCTAssertEqual(
            lines,
            [
                "Go60 Right \u{00B7} USB: Pad 0 1.5 ms",
                "Sofle \u{00B7} USB: Pad 0 2.0 ms",
            ])
    }

    // MARK: - Gesture readout

    func testGestureLinesReadInTheSlidersUnits() {
        let usb = endpoint(1)
        let status = RawTouchStatus(endpoints: [usb])
        var gesture = RawTouchGestureSummary(
            padID: 0,
            endpoint: usb.id,
            padCountsPerMM: 38,
            // A panel that measures 4.3 pt/mm, so 1,850 pt/s reads as the
            // 430 mm/s of content the finger actually pushed.
            displayPointsPerMM: 4.3,
            peakFingerSpeed: 1240.4,
            peakGain: 3.21,
            touchDistance: 640,
            liftOffSpeed: 1850.2,
            complete: false
        )
        XCTAssertEqual(
            StatusFormatter.gestureFingerLine(gesture), "Peak finger 33 mm/s \u{00B7} acceleration up to 3.2\u{00D7}")
        XCTAssertEqual(
            StatusFormatter.gestureLiftOffLine(gesture, minimumFlickSpeed: 23),
            "Lift-off 430 mm/s on screen \u{00B7} coasting\u{2026}"
        )
        // The keyboard, not the connection: a pad is the same pad however
        // its frames got here.
        XCTAssertEqual(StatusFormatter.gestureSourceLine(gesture, in: status), "Pad 0 \u{00B7} Go60 Right")
        var named = RawTouchConfiguration()
        named.devices = ["id:DEADBEEFCAFEF00D": .init(pads: ["0": .init(name: "Scroll pad")])]
        XCTAssertEqual(
            StatusFormatter.gestureSourceLine(gesture, in: status, configuration: named),
            "Scroll pad \u{00B7} Go60 Right"
        )

        gesture.coastDistance = 1900
        gesture.coastDuration = 0.83
        gesture.complete = true
        XCTAssertEqual(
            StatusFormatter.gestureLiftOffLine(gesture, minimumFlickSpeed: 23),
            "Lift-off 430 mm/s on screen \u{00B7} coasted 442 mm"
        )

        let slow = RawTouchGestureSummary(
            displayPointsPerMM: 4.3,
            peakFingerSpeed: 300, peakGain: 1, touchDistance: 40, liftOffSpeed: 60, complete: true
        )
        XCTAssertEqual(
            StatusFormatter.gestureLiftOffLine(slow, minimumFlickSpeed: 23),
            "Lift-off 14 mm/s on screen \u{00B7} no coast, under 23"
        )
        XCTAssertEqual(
            StatusFormatter.gestureSourceLine(slow, in: RawTouchStatus()), "Pad 0",
            "a gone keyboard leaves the pad alone")
    }

    // MARK: - Connection names and gesture age

    /// A connection is named plainly wherever it is named at all (the
    /// latency row): telling twins apart is the keyboard list's job.
    func testConnectionNameCarriesNoTwinSuffix() {
        let usb = endpoint(1, key: "id:AAAA")
        let status = RawTouchStatus(endpoints: [usb, endpoint(2, key: "id:BBBB")])
        XCTAssertTrue(RawTouchKeyboard.grouped(in: status)[0].name.contains("("), "twins are suffixed in the list")
        XCTAssertEqual(StatusFormatter.connectionName(usb), "Go60 Right \u{00B7} USB")
    }

    func testGestureAgeReadsInTheUnitThatFits() {
        let t = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertEqual(StatusFormatter.gestureAge(since: t, now: t.addingTimeInterval(0.5)), "just now")
        XCTAssertEqual(StatusFormatter.gestureAge(since: t, now: t.addingTimeInterval(12.9)), "12 s ago")
        XCTAssertEqual(StatusFormatter.gestureAge(since: t, now: t.addingTimeInterval(200)), "3 min ago")
        XCTAssertEqual(StatusFormatter.gestureAge(since: t, now: t.addingTimeInterval(7300)), "2 h ago")
    }

    func testLoginItemFailureIsTheLowestAttention() {
        XCTAssertEqual(
            StatusFormatter.attentionLine(
                axTrusted: true, leaseUnsupportedProductName: nil, configError: nil, loginItemError: "refused"),
            "Start at Login couldn\u{2019}t be changed \u{2014} see Login Items in System Settings"
        )
        XCTAssertEqual(
            StatusFormatter.attentionLine(
                axTrusted: true, leaseUnsupportedProductName: nil, configError: .unreadable("bad"),
                loginItemError: "refused"),
            "config.json couldn\u{2019}t be read \u{2014} changes aren\u{2019}t saved"
        )
    }

    // MARK: - Attention line

    func testHealthyHasNoAttentionLine() {
        XCTAssertNil(
            StatusFormatter.attentionLine(
                axTrusted: true,
                leaseUnsupportedProductName: nil,
                configError: nil
            ))
    }

    func testMissingAccessibilityOutranksEverything() {
        XCTAssertEqual(
            StatusFormatter.attentionLine(
                axTrusted: false,
                leaseUnsupportedProductName: "Go60",
                configError: .unreadable("bad JSON")
            ),
            "Accessibility permission needed"
        )
    }

    func testFirmwareWithoutLeaseSupportOutranksConfigError() {
        XCTAssertEqual(
            StatusFormatter.attentionLine(
                axTrusted: true,
                leaseUnsupportedProductName: "Go60",
                configError: .unreadable("bad JSON")
            ),
            "Firmware doesn\u{2019}t support RawTouch mode \u{2014} update needed"
        )
    }

    /// A decoder's message belongs in the log (where it already is); the
    /// menu names the problem and what it means for edits made meanwhile.
    func testConfigErrorIsNamedNotQuoted() {
        XCTAssertEqual(
            StatusFormatter.attentionLine(
                axTrusted: true,
                leaseUnsupportedProductName: nil,
                configError: .unreadable("dataCorrupted at line 3")
            ),
            "config.json couldn\u{2019}t be read \u{2014} changes aren\u{2019}t saved"
        )
    }

    /// A save that failed left a readable file behind: the line must not
    /// send the user looking for a syntax error in it.
    func testAFailedSaveIsNamedAsOneNotAsAnUnreadableFile() {
        XCTAssertEqual(
            StatusFormatter.attentionLine(
                axTrusted: true,
                leaseUnsupportedProductName: nil,
                configError: .unsaved("You don\u{2019}t have permission to save the file")
            ),
            "config.json couldn\u{2019}t be saved \u{2014} changes apply but aren\u{2019}t kept"
        )
    }
}
