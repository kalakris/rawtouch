// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchAppCore
import RawTouchCore
import XCTest

/// A named pad is named everywhere.
///
/// What this suite guards: a Status or Firmware row printing "Pad 1"
/// directly above a heading that says "Left Pad", or disagreeing with the
/// menu. A name the user
/// typed is the name of that pad in every sentence RawTouch writes about
/// it, so this asserts on *every* formatter at once rather than on the two
/// that happened to be wrong.
final class PadNamingTests: XCTestCase {
    private let key = "id:DEADBEEFCAFEF00D"

    private var configuration: RawTouchConfiguration {
        var configuration = RawTouchConfiguration()
        // Names with no "Pad" in them, so the assertion below cannot be
        // satisfied by the word inside the name ("Right Pad 1.5 ms"
        // contains "Pad 1").
        configuration.devices = [
            key: .init(
                name: "Desk Go60",
                pads: [
                    "0": .init(name: "Righty"),
                    "1": .init(name: "Lefty"),
                ])
        ]
        return configuration
    }

    private func endpoint(
        _ id: UInt64,
        transport: RawTouchTransport = .usb,
        latencies: [UInt8: Double] = [:]
    ) -> RawTouchStatus.Endpoint {
        .init(
            id: RawTouchEndpointID(rawValue: id),
            productName: "Go60 Right",
            transport: transport,
            padIDs: [0, 1],
            firmwareVersion: RawTouchFirmwareVersion(major: 0, minor: 1),
            padFirmwareVersions: [0: RawTouchFirmwareVersion(major: 0, minor: 1)],
            deviceKey: key,
            measuredLatencyMs: latencies,
            lease: .held
        )
    }

    /// Every string the window and the menu can print about this keyboard,
    /// with both pads named.
    private func everySentence() -> [String] {
        let status = RawTouchStatus(
            activity: .touching(padID: 1, endpoint: RawTouchEndpointID(rawValue: 1)),
            endpoints: [endpoint(1, latencies: [0: 1.5, 1: 5.2]), endpoint(2, transport: .bluetooth)],
            lastGesture: RawTouchGestureSummary(
                padID: 1,
                endpoint: RawTouchEndpointID(rawValue: 1),
                peakFingerSpeed: 1000, peakGain: 2, touchDistance: 100, liftOffSpeed: 500, complete: true
            )
        )
        let configuration = configuration
        let keyboards = RawTouchKeyboard.grouped(in: status, configuration: configuration)
        let gesture = status.lastGesture!

        return [
            StatusFormatter.keyboardStatus(for: keyboards[0], in: status, configuration: configuration),
            StatusFormatter.keyboardFirmwareLine(for: keyboards[0], configuration: configuration) ?? "",
            StatusFormatter.firmwareLine(for: status.endpoints[0], configuration: configuration),
            StatusFormatter.activityLine(for: status, configuration: configuration) ?? "",
            StatusFormatter.gestureSourceLine(gesture, in: status, configuration: configuration),
        ] + StatusFormatter.keyboardLines(for: status, configuration: configuration)
            + StatusFormatter.measuredLatencyLines(for: keyboards, configuration: configuration)
    }

    func testNoFormatterFallsBackToTheFirmwareNumberingForANamedPad() {
        for sentence in everySentence() {
            XCTAssertFalse(sentence.contains("Pad 0"), "\"\(sentence)\" still calls Righty \"Pad 0\"")
            XCTAssertFalse(sentence.contains("Pad 1"), "\"\(sentence)\" still calls Lefty \"Pad 1\"")
        }
    }

    /// And the names do appear — a formatter that printed nothing at all
    /// would pass the test above.
    func testTheNamesAreWhatTheySay() {
        let sentences = everySentence()
        XCTAssertTrue(
            sentences.contains { $0.contains("Lefty scrolling") },
            "the status row says which pad is scrolling, by name"
        )
        XCTAssertTrue(
            sentences.contains { $0.contains("Lefty half: touch it to read") },
            "an unannounced half is named, and says what would answer it"
        )
        XCTAssertTrue(
            sentences.contains { $0.contains("Righty 1.5 ms") && $0.contains("Lefty 5.2 ms") },
            "the latency row names both pads"
        )
        XCTAssertTrue(sentences.contains { $0.hasPrefix("Lefty \u{00B7} Desk Go60") }, "and so does the readout")
    }

    /// Unnamed pads still read as the firmware numbers them — the default
    /// is what a name replaces, not something to be ashamed of.
    func testUnnamedPadsKeepTheFirmwaresNumbering() {
        let status = RawTouchStatus(
            activity: .touching(padID: 1, endpoint: RawTouchEndpointID(rawValue: 1)),
            endpoints: [endpoint(1)]
        )
        let keyboards = RawTouchKeyboard.grouped(in: status)
        XCTAssertEqual(
            StatusFormatter.keyboardStatus(for: keyboards[0], in: status),
            "RawTouch mode \u{00B7} USB \u{00B7} Pad 1 scrolling"
        )
    }

    // MARK: - One firmware line per keyboard

    /// The firmware row describes the keyboard, never its connections: the
    /// central answers the report on both, and the registry merges what
    /// either learns. So a keyboard on USB and Bluetooth reads as one line,
    /// and "touch it to read" appears once, not once per transport.
    func testTheFirmwareRowIsOneLineForAKeyboardOnTwoTransports() {
        var usb = endpoint(1)
        var bluetooth = endpoint(2, transport: .bluetooth)
        // A half neither connection has heard from yet.
        usb.padFirmwareVersions = [0: RawTouchFirmwareVersion(major: 0, minor: 1)]
        bluetooth.padFirmwareVersions = usb.padFirmwareVersions
        let status = RawTouchStatus(endpoints: [usb, bluetooth])
        let keyboard = RawTouchKeyboard.grouped(in: status)[0]

        let line = StatusFormatter.keyboardFirmwareLine(for: keyboard)
        XCTAssertEqual(line, "0.1 \u{00B7} protocol 4 \u{00B7} Pad 1 half: touch it to read")
        XCTAssertFalse(line?.contains("over") ?? true, "never enumerated per connection")
    }
}
