// MIT License
// Copyright (c) 2026 RawTouch contributors

import XCTest

@testable import RawTouchCore

/// The `devices.<key>` layer of the configuration: files without it parse
/// as before, the keys round-trip, and a keyboard's own pad settings win
/// over the top level for that keyboard alone.
final class RawTouchDeviceConfigurationTests: XCTestCase {
    private func decode(_ json: String) throws -> RawTouchConfiguration {
        try JSONDecoder().decode(RawTouchConfiguration.self, from: Data(json.utf8))
    }

    /// The Go60 feature report: rotate-90 + y-invert, 38 counts/mm.
    private let go60 = RawTouchCapabilities.go60()

    // MARK: - Compatibility

    func testAConfigurationWithoutDevicesDecodesExactlyAsBefore() throws {
        let json = #"""
            {"scale": 1.5, "resampling": {"enabled": true}}
            """#
        let configuration = try decode(json)
        XCTAssertTrue(configuration.devices.isEmpty)
        XCTAssertEqual(configuration.scale, 1.5)
        XCTAssertEqual(configuration.resolvedGain(forPad: 1), 1.5)
        XCTAssertEqual(configuration.resolvedAxes(forPad: 0), .both)
        XCTAssertTrue(configuration.isEnabled(forPad: 1))
        // A key nobody has, or none at all: the top level.
        XCTAssertEqual(configuration.resolvedGain(forPad: 1, deviceKey: "usb:unknown"), 1.5)
        XCTAssertEqual(RawTouchConfiguration.unknownKeys(in: Data(json.utf8)), [])
    }

    /// There is no shared per-pad layer: a top-level `pads` is reported
    /// like any unknown key and changes nothing, since pad IDs mean nothing
    /// across keyboards.
    func testATopLevelPadsKeyIsUnknownAndInert() throws {
        let json = #"{"scale": 1.5, "pads": {"1": {"scale": 0.5}}}"#
        let configuration = try decode(json)
        XCTAssertEqual(configuration.resolvedGain(forPad: 1), 1.5)
        XCTAssertEqual(configuration.resolvedGain(forPad: 1, deviceKey: "usb:a"), 1.5)
        XCTAssertEqual(RawTouchConfiguration.unknownKeys(in: Data(json.utf8)), ["pads"])
    }

    func testDevicesDecodeRoundTripAndAreKnownToTheUnknownKeyCheck() throws {
        let json = #"""
            {"devices": {"usb:moergo.com:GO60-DEADBEEFCAFEF00D": {"enabled": false, "pads": {"0": {"axes": "horizontal"}}},
                         "bt:aa-bb-cc-dd-ee-ff": {}}}
            """#
        let configuration = try decode(json)
        XCTAssertEqual(configuration.devices.count, 2)
        XCTAssertEqual(configuration.devices["usb:moergo.com:GO60-DEADBEEFCAFEF00D"]?.enabled, false)
        XCTAssertEqual(configuration.devices["usb:moergo.com:GO60-DEADBEEFCAFEF00D"]?.pads["0"]?.axes, .horizontal)
        XCTAssertEqual(configuration.devices["bt:aa-bb-cc-dd-ee-ff"], .init(), "an empty entry is legal")

        let data = try JSONEncoder().encode(configuration)
        XCTAssertEqual(try JSONDecoder().decode(RawTouchConfiguration.self, from: data), configuration)
        XCTAssertEqual(RawTouchConfiguration.unknownKeys(in: Data(json.utf8)), [])

        let typo = #"{"devices": {"usb:x": {"enabld": true, "pads": {"0": {"scal": 1}}}}}"#
        XCTAssertEqual(
            RawTouchConfiguration.unknownKeys(in: Data(typo.utf8)),
            ["devices.usb:x.enabld", "devices.usb:x.pads.0.scal"]
        )
    }

    // MARK: - Precedence

    func testPerKeyboardPadOverridesWinFieldByFieldOverTheTopLevel() throws {
        let configuration = try decode(
            #"""
            {"scale": 1.0, "axes": "both",
             "devices": {"usb:a": {"pads": {"0": {"scale": 4.0, "invert": true}}}}}
            """#)

        let own = configuration.padOverrides(forPad: 0, deviceKey: "usb:a")
        XCTAssertEqual(own.scale, 4.0, "the keyboard's own value")
        XCTAssertNil(own.axes, "unset: the top level applies")
        XCTAssertEqual(own.invert, true)
        XCTAssertEqual(configuration.resolvedGain(forPad: 0, deviceKey: "usb:a"), 4.0)
        XCTAssertEqual(configuration.resolvedAxes(forPad: 0, deviceKey: "usb:a"), .both)
        XCTAssertEqual(configuration.resolvedGain(forPad: 0, deviceKey: "bt:b"), 1.0, "another keyboard: the top level")
        XCTAssertEqual(configuration.resolvedGain(forPad: 0, deviceKey: nil), 1.0, "no key: the top level")
        XCTAssertEqual(configuration.resolvedGain(forPad: 1, deviceKey: "usb:a"), 1.0, "no pad entry: the top level")
        XCTAssertEqual(configuration.padOverrides(forPad: 0, deviceKey: nil), .init())
    }

    /// The keyboard-level switch is what the host lease follows: a keyboard
    /// switched off is not wanted at all, whatever its pads say.
    func testAKeyboardIsWantedOnlyWhileBothSwitchesAreOn() throws {
        let configuration = try decode(#"{"devices": {"usb:off": {"enabled": false}, "usb:on": {}}}"#)
        XCTAssertFalse(configuration.isEnabled(deviceKey: "usb:off"))
        XCTAssertTrue(configuration.isEnabled(deviceKey: "usb:on"))
        XCTAssertTrue(configuration.isEnabled(deviceKey: "usb:unknown"))
        XCTAssertTrue(configuration.isEnabled(deviceKey: nil))

        var disabled = configuration
        disabled.enabled = false
        XCTAssertFalse(disabled.isEnabled(deviceKey: "usb:on"))
        XCTAssertFalse(disabled.isEnabled(deviceKey: nil))
    }

    func testEnabledIsTheConjunctionOfEveryLayer() throws {
        let configuration = try decode(
            #"""
            {"devices": {"usb:off": {"enabled": false}, "usb:on": {"pads": {"1": {"enabled": false}}}}}
            """#)
        XCTAssertTrue(configuration.isEnabled(forPad: 0))
        XCTAssertTrue(configuration.isEnabled(forPad: 1), "no keyboard, no pad entry")
        XCTAssertTrue(configuration.isEnabled(forPad: 0, deviceKey: "usb:on"))
        XCTAssertFalse(configuration.isEnabled(forPad: 1, deviceKey: "usb:on"), "one keyboard's pad 1 is off")
        XCTAssertTrue(configuration.isEnabled(forPad: 1, deviceKey: "bt:other"), "and nobody else's is")
        XCTAssertFalse(configuration.isEnabled(forPad: 0, deviceKey: "usb:off"), "a keyboard switched off entirely")
        XCTAssertFalse(configuration.isEnabled(forPad: 1, deviceKey: "usb:off"))

        var disabled = configuration
        disabled.enabled = false
        XCTAssertFalse(disabled.isEnabled(forPad: 0, deviceKey: "usb:on"), "the master switch beats everything")
    }

    func testTheEngineConfigurationUsesTheKeyboardsOwnLayer() throws {
        let configuration = try decode(
            #"""
            {"devices": {"usb:a": {"pads": {"0": {"axis": "y", "invertHorizontal": false}}}}}
            """#)
        let unitPointsPerMM = RawTouchCapabilities.Pad.fallbackCountsPerMM

        let own = configuration.engineConfig(
            forPad: 0, deviceKey: "usb:a", capabilities: go60, systemPrefersNatural: false, pointsPerMM: unitPointsPerMM
        )
        XCTAssertEqual(own.axis, .y)
        XCTAssertEqual(own.invertHorizontal, false)

        let other = configuration.engineConfig(
            forPad: 0, deviceKey: "bt:b", capabilities: go60, systemPrefersNatural: false, pointsPerMM: unitPointsPerMM
        )
        XCTAssertEqual(other.axis, .x, "every other keyboard: what the firmware reports")
    }
}
