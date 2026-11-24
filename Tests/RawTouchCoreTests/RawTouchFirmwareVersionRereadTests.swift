// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchTestSupport
import XCTest

@testable import RawTouchCore

/// Learning a split peripheral's firmware version after the fact.
///
/// The keyboard's central half only hears its peripheral's `zmk-raw-touch`
/// version when the peripheral announces it, which it does immediately
/// before the first frame of each touch on its pad. The host reads the
/// capability report once, at discovery, so the relayed pad's slot reads 0
/// ("Pad 1 half unknown") until something makes it read again — and the
/// first frame of a touch is that something.
///
/// The IOKit half of this cannot be driven in a test (there is no way to
/// conjure an `IOHIDDevice`), so what is covered here is everything the
/// manager delegates the decision to: the probe's policy, the registry's
/// merge, and the status that comes out.
final class RawTouchFirmwareVersionRereadTests: XCTestCase {
    private let endpoint = RawTouchEndpointID(rawValue: 7)
    private lazy var pad0 = RawTouchSourceID(endpoint: endpoint, padID: 0)
    private lazy var pad1 = RawTouchSourceID(endpoint: endpoint, padID: 1)

    /// A two-pad v4 report: host lease supported, both pads Go60-shaped
    /// (rotate-90 + y-invert), with the three version bytes spelled out.
    /// 0 is the wire's "says nothing".
    private static func reportBytes(
        central: UInt8,
        pad0Version: UInt8,
        pad1Version: UInt8,
        pad1CountsPerMM: UInt8 = 38
    ) -> [UInt8] {
        featureReportBytes(
            centralVersion: central,
            deviceID: [0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xF0, 0x0D],
            slots: [
                FeatureReportSlot(version: pad0Version),
                FeatureReportSlot(countsPerMM: pad1CountsPerMM, version: pad1Version),
            ]
        )
    }

    private static func capabilities(
        central: UInt8,
        pad0Version: UInt8,
        pad1Version: UInt8,
        pad1CountsPerMM: UInt8 = 38
    ) -> RawTouchCapabilities {
        RawTouchCapabilities(
            reportBytes: reportBytes(
                central: central,
                pad0Version: pad0Version,
                pad1Version: pad1Version,
                pad1CountsPerMM: pad1CountsPerMM
            ))!
    }

    private func registry(
        with capabilities: RawTouchCapabilities
    ) -> (registry: RawTouchEndpointRegistry, id: RawTouchEndpointID) {
        var registry = RawTouchEndpointRegistry()
        let id = registry.allocateID()
        registry.admit(
            .init(
                id: id,
                productName: "Go60 Right",
                transport: .usb,
                capabilities: capabilities,
                deviceKey: "usb:test"
            ))
        return (registry, id)
    }

    // MARK: - When a re-read is worth doing at all

    /// The whole point: only a pad whose half said nothing, on a keyboard
    /// whose central *did* speak, is worth re-reading for.
    func testOnlyPadsMissingAVersionOnAVersionReportingKeyboardAreAwaited() {
        let (registry, id) = registry(with: Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0))

        XCTAssertEqual(
            registry.padsAwaitingFirmwareVersion,
            [RawTouchSourceID(endpoint: id, padID: 1)],
            "pad 0 already answered with the central's own version"
        )
    }

    /// Firmware that does not report versions sends all three version
    /// bytes as zero. Re-reading such a keyboard would learn nothing however
    /// often it was touched, so it is never watched in the first place.
    func testAKeyboardWhoseOwnVersionIsUnknownIsNeverAwaited() {
        let (registry, _) = registry(with: Self.capabilities(central: 0, pad0Version: 0, pad1Version: 0))

        XCTAssertTrue(registry.padsAwaitingFirmwareVersion.isEmpty)
    }

    func testFirmwareWithoutRawTouchModeIsNeverAwaited() {
        var registry = RawTouchEndpointRegistry()
        let id = registry.allocateID()
        registry.addUnsupported(.init(id: id, productName: "Go60 Right", transport: .usb))

        XCTAssertTrue(registry.padsAwaitingFirmwareVersion.isEmpty, "it is not admitted, let alone read again")
    }

    func testNothingIsAwaitedOnceEveryHalfHasAnswered() {
        let (registry, _) = registry(with: Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0x01))

        XCTAssertTrue(registry.padsAwaitingFirmwareVersion.isEmpty)
    }

    // MARK: - The probe's policy

    func testTheFirstFrameOfATouchRereadsAndTheRestOfTheTouchDoesNot() {
        var probe = RawTouchFirmwareVersionProbe()

        XCTAssertEqual(probe.noteFrame(source: pad1, touched: true, now: 100), .reread)
        for tick in 1...20 {
            XCTAssertEqual(
                probe.noteFrame(source: pad1, touched: true, now: 100 + Double(tick) * 0.01),
                .none,
                "the announce came before the first frame; the rest of the touch has nothing to add"
            )
        }
        XCTAssertEqual(probe.noteFrame(source: pad1, touched: false, now: 100.3), .none, "the release frame")
    }

    /// A second touch inside the 2 s window rides on the report the first
    /// one already asked for; past it, the pad is worth asking again (the
    /// peripheral may have missed the announce, or reconnected).
    func testASecondTouchRereadsOnlyOnceTheEndpointsThrottleWindowHasPassed() {
        var probe = RawTouchFirmwareVersionProbe()

        XCTAssertEqual(probe.noteFrame(source: pad1, touched: true, now: 100), .reread)
        XCTAssertEqual(probe.noteFrame(source: pad1, touched: false, now: 100.2), .none)

        XCTAssertEqual(probe.noteFrame(source: pad1, touched: true, now: 101.5), .none, "inside 2 s")
        XCTAssertEqual(probe.noteFrame(source: pad1, touched: false, now: 101.7), .none)

        XCTAssertEqual(probe.noteFrame(source: pad1, touched: true, now: 102.5), .reread, "past 2 s")
    }

    /// The throttle is per endpoint because one report answers for every
    /// pad on it: a touch on the other pad right after does not need its
    /// own GET.
    func testTheThrottleIsSharedBetweenAKeyboardsPads() {
        var probe = RawTouchFirmwareVersionProbe()

        XCTAssertEqual(probe.noteFrame(source: pad1, touched: true, now: 100), .reread)
        XCTAssertEqual(probe.noteFrame(source: pad0, touched: true, now: 100.5), .none)
        XCTAssertEqual(probe.noteFrame(source: pad0, touched: false, now: 100.7), .none)
        XCTAssertEqual(probe.noteFrame(source: pad0, touched: true, now: 103), .reread)
    }

    /// A peripheral running firmware too old to announce anything would
    /// otherwise cost a feature-report GET per touch forever. After five
    /// fruitless re-reads the pad is written off, and the caller stops
    /// feeding its frames in at all.
    func testAPadIsGivenUpOnAfterFiveFruitlessRereads() {
        var probe = RawTouchFirmwareVersionProbe()
        var now = 100.0

        for touch in 1...RawTouchFirmwareVersionProbe.rereadsPerPad {
            XCTAssertEqual(probe.noteFrame(source: pad1, touched: true, now: now), .reread, "touch \(touch)")
            XCTAssertEqual(probe.noteFrame(source: pad1, touched: false, now: now + 0.2), .none)
            XCTAssertFalse(probe.hasGivenUp(on: pad1))
            now += 3
        }

        XCTAssertEqual(probe.noteFrame(source: pad1, touched: true, now: now), .gaveUp)
        XCTAssertTrue(probe.hasGivenUp(on: pad1))

        // And it stays given up on, quietly.
        XCTAssertEqual(probe.noteFrame(source: pad1, touched: false, now: now + 0.2), .none)
        XCTAssertEqual(probe.noteFrame(source: pad1, touched: true, now: now + 10), .none)
        XCTAssertEqual(probe.noteFrame(source: pad0, touched: true, now: now + 10), .reread, "the other pad is its own")
    }

    /// Touches suppressed by the throttle are not charged to the pad's
    /// budget — five *re-reads*, not five touches.
    func testThrottledTouchesDoNotSpendThePadsBudget() {
        var probe = RawTouchFirmwareVersionProbe()

        XCTAssertEqual(probe.noteFrame(source: pad1, touched: true, now: 100), .reread)
        for touch in 1...10 {
            let now = 100 + Double(touch) * 0.15  // ten taps inside the 2 s window
            XCTAssertEqual(probe.noteFrame(source: pad1, touched: false, now: now), .none)
            XCTAssertEqual(probe.noteFrame(source: pad1, touched: true, now: now + 0.05), .none)
        }
        XCTAssertFalse(probe.hasGivenUp(on: pad1))
    }

    func testForgettingAnEndpointDropsItsThrottleAndItsBudget() {
        var probe = RawTouchFirmwareVersionProbe()
        for _ in 1...RawTouchFirmwareVersionProbe.rereadsPerPad {
            _ = probe.noteFrame(source: pad1, touched: true, now: 100)
            _ = probe.noteFrame(source: pad1, touched: false, now: 100)
        }

        probe.forget(endpoint: endpoint)

        XCTAssertFalse(probe.hasGivenUp(on: pad1))
        XCTAssertEqual(probe.noteFrame(source: pad1, touched: true, now: 100.1), .reread)
    }

    /// What the endpoint's keyboard's report says — versions live there,
    /// shared by every connection of the keyboard, not on the endpoint.
    private func keyboardReport(_ registry: RawTouchEndpointRegistry, _ id: RawTouchEndpointID) -> RawTouchCapabilities?
    {
        registry.entry(id).map(registry.keyboardCapabilities(of:))
    }

    // MARK: - Adopting what a re-read says

    func testARereadFillsInThePadsVersionAndTheStatusRow() {
        var (registry, id) = registry(with: Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0))
        XCTAssertNil(keyboardReport(registry, id)?.padFirmwareVersions[1])

        let landed = registry.adoptFirmwareVersions(
            id,
            from: Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0x01)
        )

        XCTAssertTrue(landed, "there is new status to publish")
        XCTAssertEqual(
            keyboardReport(registry, id)?.padFirmwareVersions,
            [0: .init(major: 0, minor: 1), 1: .init(major: 0, minor: 1)]
        )
        let published = registry.statusEndpoints()
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published[0].firmwareVersion, .init(major: 0, minor: 1))
        XCTAssertEqual(published[0].padFirmwareVersions[1], .init(major: 0, minor: 1))
        XCTAssertTrue(registry.padsAwaitingFirmwareVersion.isEmpty, "nothing left to ask about")
    }

    func testARereadThatStillSaysNothingChangesNothing() {
        var (registry, id) = registry(with: Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0))
        let before = registry

        XCTAssertFalse(
            registry.adoptFirmwareVersions(
                id,
                from: Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0)
            ))
        XCTAssertEqual(registry, before, "no status change to publish")
    }

    /// A version already known is never un-learned by a report read between
    /// two announces.
    func testARereadCannotClearAVersionItDoesNotCarry() {
        var (registry, id) = registry(with: Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0x10))

        XCTAssertFalse(
            registry.adoptFirmwareVersions(
                id,
                from: Self.capabilities(central: 0, pad0Version: 0, pad1Version: 0)
            ))
        XCTAssertEqual(keyboardReport(registry, id)?.firmwareVersion, .init(major: 0, minor: 1))
        XCTAssertEqual(keyboardReport(registry, id)?.padFirmwareVersions[1], .init(major: 1, minor: 0))
    }

    /// Geometry cannot change while a keyboard stays connected, so a
    /// re-read that disagrees about it is a bug, not a reconfiguration:
    /// the versions are taken, everything else is left as admitted (and
    /// the manager logs the disagreement).
    func testARereadWhoseGeometryDiffersGivesUpOnlyItsVersions() {
        let admitted = Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0)
        var (registry, id) = registry(with: admitted)

        let impostor = Self.capabilities(
            central: 0x01,
            pad0Version: 0x01,
            pad1Version: 0x01,
            pad1CountsPerMM: 12
        )
        XCTAssertTrue(admitted.differsBeyondFirmwareVersions(from: impostor))
        XCTAssertTrue(registry.adoptFirmwareVersions(id, from: impostor))

        let kept = keyboardReport(registry, id)
        XCTAssertEqual(kept?.padFirmwareVersions[1], .init(major: 0, minor: 1), "the version is adopted")
        XCTAssertEqual(kept?.pads[1]?.countsPerMM, 38, "the geometry it was admitted with is kept")
        XCTAssertEqual(kept?.withoutFirmwareVersions, admitted.withoutFirmwareVersions)
    }

    func testARereadThatAgreesAboutEverythingButTheVersionsIsNotAWarning() {
        let admitted = Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0)
        let reread = Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0x01)

        XCTAssertFalse(admitted.differsBeyondFirmwareVersions(from: reread))
    }

    func testAdoptingIsANoOpForAnEndpointThatHasGoneAway() {
        var (registry, id) = registry(with: Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0))
        registry.remove(id)

        XCTAssertFalse(
            registry.adoptFirmwareVersions(
                id,
                from: Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0x01)
            ))
    }

    // MARK: - One record per keyboard

    /// The same keyboard on USB and Bluetooth: two endpoints, one key.
    private func keyboardOnBothTransports(
        key: String = "id:DEADBEEFCAFEF00D",
        usb usbReport: RawTouchCapabilities,
        bluetooth bluetoothReport: RawTouchCapabilities
    ) -> (registry: RawTouchEndpointRegistry, usb: RawTouchEndpointID, bluetooth: RawTouchEndpointID) {
        var registry = RawTouchEndpointRegistry()
        let usb = registry.allocateID()
        registry.admit(
            .init(id: usb, productName: "Go60 Right", transport: .usb, capabilities: usbReport, deviceKey: key))
        let bluetooth = registry.allocateID()
        registry.admit(
            .init(
                id: bluetooth,
                productName: "Go60 Right",
                transport: .bluetooth,
                capabilities: bluetoothReport,
                deviceKey: key
            ))
        return (registry, usb, bluetooth)
    }

    /// The user's screenshot: the left pad's half version learned over USB,
    /// and Bluetooth still saying "touch it to read". The report is the
    /// keyboard's — its central answers both — so learning it on one
    /// connection is learning it on both, at once.
    func testAVersionLearnedOverUSBIsKnownOverBluetoothImmediately() {
        let unannounced = Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0)
        var (registry, usb, bluetooth) = keyboardOnBothTransports(usb: unannounced, bluetooth: unannounced)

        // Learned on USB — nothing is ever read over Bluetooth here.
        XCTAssertTrue(
            registry.adoptFirmwareVersions(
                usb,
                from: Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0x01)
            ))

        let published = registry.statusEndpoints()
        XCTAssertEqual(published.map(\.id), [usb, bluetooth])
        XCTAssertEqual(
            published.map { $0.padFirmwareVersions[1] }, [.init(major: 0, minor: 1), .init(major: 0, minor: 1)])
        XCTAssertTrue(
            registry.padsAwaitingFirmwareVersion.isEmpty,
            "no connection of the keyboard is still waiting to be asked"
        )
    }

    /// Until then, every connection is on the list, so the first frame from
    /// that pad on whichever one it arrives asks.
    func testAFreshKeyboardWaitsOnEveryConnectionUntilOneLearns() {
        let unannounced = Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0)
        let (registry, usb, bluetooth) = keyboardOnBothTransports(usb: unannounced, bluetooth: unannounced)

        XCTAssertEqual(
            registry.padsAwaitingFirmwareVersion,
            [
                RawTouchSourceID(endpoint: usb, padID: 1),
                RawTouchSourceID(endpoint: bluetooth, padID: 1),
            ])
    }

    /// A connection admitted *after* the version was learned — Bluetooth
    /// reconnecting, say — reads 0 for a half that has not re-announced;
    /// that is "has not said", and the keyboard already knows.
    func testALaterReadThatDoesNotKnowAVersionKeepsTheKnownOne() {
        var registry = RawTouchEndpointRegistry()
        let usb = registry.allocateID()
        registry.admit(
            .init(
                id: usb,
                productName: "Go60 Right",
                transport: .usb,
                capabilities: Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0x01),
                deviceKey: "id:AAAA"
            ))
        let bluetooth = registry.allocateID()
        registry.admit(
            .init(
                id: bluetooth,
                productName: "Go60 Right",
                transport: .bluetooth,
                capabilities: Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0),
                deviceKey: "id:AAAA"
            ))

        XCTAssertEqual(
            registry.statusEndpoints().map { $0.padFirmwareVersions[1] },
            [.init(major: 0, minor: 1), .init(major: 0, minor: 1)])
        XCTAssertTrue(registry.padsAwaitingFirmwareVersion.isEmpty)
    }

    /// A later read that knows a *different* version replaces it — a half
    /// reflashed while its sibling stayed connected — rather than keeping
    /// the stale one (the change is logged).
    func testALaterReadWithADifferentVersionReplacesIt() {
        var (registry, usb, _) = keyboardOnBothTransports(
            usb: Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0x01),
            bluetooth: Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0x01)
        )
        XCTAssertTrue(
            registry.adoptFirmwareVersions(
                usb,
                from: Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0x02)
            ))
        XCTAssertEqual(
            registry.statusEndpoints().map { $0.padFirmwareVersions[1] },
            [.init(major: 0, minor: 2), .init(major: 0, minor: 2)])
    }

    /// Two keyboards never share what they have learned, even when they are
    /// the same model with the same versions.
    func testTwoKeyboardsNeverShareARecord() {
        var registry = RawTouchEndpointRegistry()
        let mine = registry.allocateID()
        registry.admit(
            .init(
                id: mine,
                productName: "Go60 Right",
                transport: .usb,
                capabilities: Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0),
                deviceKey: "id:AAAA"
            ))
        let other = registry.allocateID()
        registry.admit(
            .init(
                id: other,
                productName: "Go60 Right",
                transport: .usb,
                capabilities: Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0),
                deviceKey: "id:BBBB"
            ))

        registry.adoptFirmwareVersions(
            mine, from: Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0x01))

        XCTAssertEqual(registry.statusEndpoints().map { $0.padFirmwareVersions[1] }, [.init(major: 0, minor: 1), nil])
        XCTAssertEqual(registry.padsAwaitingFirmwareVersion, [RawTouchSourceID(endpoint: other, padID: 1)])
    }

    /// A keyboard whose firmware reports no hardware id is keyed per
    /// transport, so each connection is its own keyboard and its own record
    /// — exactly as it is its own group on the Keyboards tab.
    func testATransportKeyedKeyboardKeepsARecordPerConnection() {
        var registry = RawTouchEndpointRegistry()
        var ids: [RawTouchEndpointID] = []
        for (transport, key) in [(RawTouchTransport.usb, "usb:serial"), (.bluetooth, "bt:address")] {
            let id = registry.allocateID()
            ids.append(id)
            registry.admit(
                .init(
                    id: id,
                    productName: "Go60 Right",
                    transport: transport,
                    capabilities: Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0),
                    deviceKey: key
                ))
        }

        registry.adoptFirmwareVersions(
            ids[0], from: Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0x01))

        XCTAssertEqual(registry.statusEndpoints().map { $0.padFirmwareVersions[1] }, [.init(major: 0, minor: 1), nil])
    }

    /// The record goes with the keyboard's last connection, so a keyboard
    /// reflashed while unplugged is not credited with its old versions.
    func testTheRecordLeavesWithTheLastConnection() {
        var (registry, usb, bluetooth) = keyboardOnBothTransports(
            usb: Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0x01),
            bluetooth: Self.capabilities(central: 0x01, pad0Version: 0x01, pad1Version: 0x01)
        )
        registry.remove(usb)
        XCTAssertEqual(registry.firmware.count, 1, "Bluetooth still holds it")
        registry.remove(bluetooth)
        XCTAssertTrue(registry.firmware.isEmpty)
    }
}
