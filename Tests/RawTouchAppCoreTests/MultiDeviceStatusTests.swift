// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchCore
import RawTouchTestSupport
import XCTest

@testable import RawTouchAppCore

/// The menu and settings strings with more than one endpoint — and the
/// model's per-keyboard configuration helpers.
final class MultiDeviceStatusTests: XCTestCase {
    private func endpoint(
        _ id: UInt64,
        name: String = "Go60 Right",
        transport: RawTouchTransport = .usb,
        key: String? = nil,
        lease: RawTouchStatus.Endpoint.Lease = .held,
        pads: [UInt8] = [0, 1]
    ) -> RawTouchStatus.Endpoint {
        .init(
            id: RawTouchEndpointID(rawValue: id),
            productName: name,
            transport: transport,
            padIDs: pads,
            deviceKey: key,
            lease: lease
        )
    }

    // MARK: - Names

    /// Two identical keyboards must never read as one: the tail of the
    /// device key tells them apart, or the endpoint number when there is
    /// no key at all.
    func testKeylessTwinsAreToldApartByEndpointNumber() {
        let unkeyed = RawTouchStatus(endpoints: [endpoint(1), endpoint(2)])
        XCTAssertEqual(
            RawTouchKeyboard.grouped(in: unkeyed).map(\.name),
            [
                "Go60 Right (#1)",
                "Go60 Right (#2)",
            ])
    }

    func testAnUnnamedTransportAddsNothingToTheName() {
        let status = RawTouchStatus(endpoints: [endpoint(1, transport: .unknown, key: "usb:serial")])
        XCTAssertEqual(RawTouchKeyboard.grouped(in: status)[0].name, "Go60 Right")
    }

    // MARK: - Per-endpoint lines

    func testEachKeyboardReportsItsOwnLeaseOutcome() {
        let status = RawTouchStatus(endpoints: [
            endpoint(1, transport: .usb, key: "id:AAAA", lease: .held),
            endpoint(2, transport: .bluetooth, key: "id:AAAA", lease: .failed),
            endpoint(3, name: "Other", transport: .usb, key: "id:BBBB", lease: .pending),
            endpoint(4, name: "Old board", transport: .usb, lease: .unsupportedFirmware, pads: []),
            endpoint(5, name: "Spare", transport: .usb, key: "id:CCCC", lease: .disabled),
        ])
        XCTAssertEqual(
            StatusFormatter.keyboardLines(for: status),
            [
                "Go60 Right: RawTouch mode over USB, Standard mode over Bluetooth \u{2014} switch failed, reconnect to retry",
                "Other \u{00B7} USB: Switching to RawTouch mode\u{2026}",
                "Old board \u{00B7} USB: Firmware without RawTouch mode",
                "Spare \u{00B7} USB: Standard mode \u{2014} switched off",
            ])
    }

    /// "Nothing here can serve": only when every present endpoint is
    /// unsupported *and* nothing is still being validated — at login two
    /// keyboards enumerate together, and the supported one may still be
    /// mid-read when the unsupported one reports.
    func testNoEndpointCouldServeWaitsForValidationToFinish() {
        let old = endpoint(1, name: "Old board", lease: .unsupportedFirmware, pads: [])
        XCTAssertTrue(RawTouchStatus(endpoints: [old]).noEndpointCouldServe)
        XCTAssertFalse(RawTouchStatus(endpoints: [old], validatingEndpointCount: 1).noEndpointCouldServe)
        XCTAssertFalse(RawTouchStatus(endpoints: [old, endpoint(2, lease: .pending)]).noEndpointCouldServe)
        XCTAssertFalse(RawTouchStatus(endpoints: [old, endpoint(2, lease: .disabled)]).noEndpointCouldServe)
        XCTAssertTrue(
            RawTouchStatus().noEndpointCouldServe, "vacuously \u{2014} it is only asked on an unsupported report")
    }

    func testTheActivityLineNamesTheKeyboardOnlyWhenThereIsMoreThanOne() {
        let one = RawTouchStatus(
            activity: .touching(padID: 0, endpoint: RawTouchEndpointID(rawValue: 1)), endpoints: [endpoint(1)])
        XCTAssertEqual(StatusFormatter.activityLine(for: one), "Pad 0 scrolling")

        // One keyboard's two connections are still one keyboard: naming it
        // would add nothing.
        let bothTransports = RawTouchStatus(
            activity: .coasting(padID: 1, endpoint: RawTouchEndpointID(rawValue: 2)),
            endpoints: [endpoint(1, key: "id:AAAA"), endpoint(2, transport: .bluetooth, key: "id:AAAA")]
        )
        XCTAssertEqual(StatusFormatter.activityLine(for: bothTransports), "Pad 1 coasting")

        let two = RawTouchStatus(
            activity: .coasting(padID: 1, endpoint: RawTouchEndpointID(rawValue: 2)),
            endpoints: [endpoint(1, key: "id:AAAA"), endpoint(2, name: "Sofle", key: "id:BBBB")]
        )
        XCTAssertEqual(StatusFormatter.activityLine(for: two), "Sofle: Pad 1 coasting")
    }

    // MARK: - The model's per-keyboard helpers

    private var directory: URL!
    private var model: AppModel?

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rawtouch-multidevice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        model?.shutdownForQuit()
        model = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel(_ fake: FakeRawTouchDeviceManager) -> AppModel {
        let model = AppModel(
            configPath: directory.appendingPathComponent("config.json"),
            lockPath: directory.appendingPathComponent("rawtouch.pid"),
            saveDebounceInterval: 10,
            trustCheck: { true },
            loginItems: FakeLoginItems(),
            makeManager: { _ in fake },
            releaseSource: FakeReleaseSource(),
            updateScheduler: FakeTimerScheduler()
        )
        self.model = model
        model.start()
        return model
    }

    func testSettingsListEveryConnectedKeyboardWithItsPads() {
        let fake = FakeRawTouchDeviceManager()
        let model = makeModel(fake)
        var status = RawTouchStatus()
        status.endpoints = [
            endpoint(1, key: "id:AAAA", pads: [0]),
            endpoint(2, name: "Other", transport: .bluetooth, key: "id:BBBB", pads: [0, 2]),
        ]
        fake.push(status)

        XCTAssertEqual(model.settingsKeyboards.map(\.key), ["id:AAAA", "id:BBBB"])
        XCTAssertEqual(model.settingsKeyboards.map(\.padIDs), [[0], [0, 2]], "each keyboard's own pads")
        XCTAssertEqual(model.settingsKeyboards[1].name, "Other")
    }

    /// One keyboard on two transports is one entry with both connections
    /// and every pad either of them reports — a relayed pad can be missing
    /// from one report and present in the other.
    func testOneKeyboardOnTwoTransportsIsOneKeyboard() {
        let status = RawTouchStatus(endpoints: [
            endpoint(1, key: "id:AAAA", pads: [0]),
            endpoint(2, transport: .bluetooth, key: "id:AAAA", pads: [0, 1]),
        ])
        let keyboards = RawTouchKeyboard.grouped(in: status)
        XCTAssertEqual(keyboards.count, 1)
        XCTAssertEqual(keyboards[0].name, "Go60 Right")
        XCTAssertEqual(keyboards[0].padIDs, [0, 1])
        XCTAssertEqual(keyboards[0].transports, [.usb, .bluetooth])
        XCTAssertEqual(keyboards[0].key, "id:AAAA")
    }

    /// An endpoint with no key is nobody else's: nothing says it is the
    /// same keyboard as any other.
    func testAKeylessEndpointIsItsOwnKeyboard() {
        let status = RawTouchStatus(endpoints: [
            endpoint(1, key: "id:AAAA"),
            endpoint(2, transport: .bluetooth, key: nil),
            endpoint(3, transport: .bluetooth, key: nil),
        ])
        let keyboards = RawTouchKeyboard.grouped(in: status)
        XCTAssertEqual(keyboards.count, 3)
        XCTAssertNil(keyboards[1].key)
        XCTAssertNil(keyboards[1].editableKey)
    }

    /// A keyboard whose firmware reports no hardware id is keyed per
    /// transport, and its name says so — two entries that would otherwise
    /// read alike.
    func testATransportKeyedKeyboardIsNamedWithItsTransport() {
        let status = RawTouchStatus(endpoints: [
            endpoint(1, key: "usb:serial"),
            endpoint(2, transport: .bluetooth, key: "bt:address"),
        ])
        XCTAssertEqual(
            RawTouchKeyboard.grouped(in: status).map(\.name),
            [
                "Go60 Right \u{00B7} USB",
                "Go60 Right \u{00B7} Bluetooth",
            ])
    }

    /// Two of the same model are told apart by the tail of their key.
    func testTwoIdenticalKeyboardsAreToldApart() {
        let status = RawTouchStatus(endpoints: [
            endpoint(1, key: "id:DEADBEEFCAFEF00D"),
            endpoint(2, key: "id:C0FFEE00C0FFEE11"),
        ])
        XCTAssertEqual(
            RawTouchKeyboard.grouped(in: status).map(\.name),
            [
                "Go60 Right (\u{2026}F00D)",
                "Go60 Right (\u{2026}EE11)",
            ])
    }

    func testPerKeyboardOverridesAreEditedUnderTheirOwnKey() {
        let fake = FakeRawTouchDeviceManager()
        let model = makeModel(fake)

        model.updateDevicePad("usb:a", "0") { $0.scale = 4 }
        XCTAssertEqual(model.config.devices["usb:a"]?.pads["0"]?.scale, 4)
        XCTAssertEqual(model.config.resolvedGain(forPad: 0, deviceKey: "usb:a"), 4)
        XCTAssertEqual(
            model.config.resolvedGain(forPad: 0, deviceKey: "bt:b"), model.config.scale,
            "another keyboard: the top level")
        XCTAssertEqual(
            model.config.resolvedGain(forPad: 1, deviceKey: "usb:a"), model.config.scale, "another pad: the top level")

        model.resetDevicePad("usb:a", "0")
        XCTAssertNil(model.config.devices["usb:a"], "a pad back at its inherited values leaves nothing to persist")
        XCTAssertEqual(fake.appliedConfigurations.last, model.config, "every edit reached the manager")
    }

    /// The app never names an entry behind the user's back: a name in the
    /// file is theirs. An entry with none goes by what its keyboard
    /// reports while it is connected, and by its key once it is not —
    /// which is the moment to rename it, if that matters.
    func testTheAppNeverWritesANameOfItsOwn() {
        let fake = FakeRawTouchDeviceManager()
        let model = makeModel(fake)
        var status = RawTouchStatus()
        status.endpoints = [endpoint(2, name: "Other", transport: .bluetooth, key: "id:BBBB", pads: [0])]
        fake.push(status)

        model.setDeviceEnabled("id:BBBB", false)
        XCTAssertEqual(model.config.devices["id:BBBB"], .init(enabled: false))
        XCTAssertEqual(model.settingsKeyboards.map(\.name), ["Other"], "the firmware's name, while it is here")

        status.endpoints = []
        fake.push(status)
        XCTAssertEqual(
            model.savedEntryName("id:BBBB"),
            "Saved keyboard",
            "a line of hex is an identifier, not a name; the \u{201C}Saved as\u{201D} row says the key"
        )

        model.setKeyboardName("id:BBBB", "Spare")
        XCTAssertEqual(model.savedEntryName("id:BBBB"), "Spare")

        model.setDeviceEnabled("id:BBBB", true)
        XCTAssertEqual(
            model.config.devices["id:BBBB"],
            .init(name: "Spare"),
            "a name is worth keeping on its own"
        )
        model.setKeyboardName("id:BBBB", "")
        XCTAssertNil(model.config.devices["id:BBBB"], "and once that goes, so does the entry")
    }

    func testDisconnectedKeyboardsWithOverridesAreListedForRemoval() {
        let fake = FakeRawTouchDeviceManager()
        let model = makeModel(fake)
        model.updateDevicePad("usb:gone", "0") { $0.scale = 3 }
        model.setDeviceEnabled("bt:here", false)
        var status = RawTouchStatus()
        status.endpoints = [endpoint(1, transport: .bluetooth, key: "bt:here")]
        fake.push(status)

        XCTAssertEqual(model.disconnectedDeviceKeys, ["usb:gone"])
    }
}
