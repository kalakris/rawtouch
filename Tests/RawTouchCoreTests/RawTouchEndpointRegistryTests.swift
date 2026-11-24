// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchTestSupport
import XCTest

@testable import RawTouchCore

/// The device manager's IOKit-free bookkeeping: endpoint generations,
/// per-endpoint leases, and the status they add up to. Nothing here opens
/// a device or writes a report.
final class RawTouchEndpointRegistryTests: XCTestCase {
    private func entry(
        _ id: RawTouchEndpointID,
        name: String = "Go60 Right",
        transport: RawTouchTransport = .usb,
        key: String? = nil
    ) -> RawTouchEndpointRegistry.Entry {
        .init(
            id: id,
            productName: name,
            transport: transport,
            capabilities: endpointDescriptor(id: id.rawValue).capabilities,
            deviceKey: key
        )
    }

    // MARK: - Generations

    func testEveryAppearanceGetsAFreshIDNeverReused() {
        var registry = RawTouchEndpointRegistry()
        let first = registry.allocateID()
        let second = registry.allocateID()
        registry.admit(entry(first))
        registry.remove(first)
        let third = registry.allocateID()

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, third)
        XCTAssertNotEqual(second, third)
        XCTAssertNotEqual(first, .default, "the manager never issues the fixtures' default endpoint")
    }

    /// The race this exists for: an acquire written to a keyboard that then
    /// disconnects and reconnects. The completion carries the *old* ID and
    /// must not mark the replacement as holding the lease.
    func testAnAcquireCompletionForARemovedEndpointIsIgnoredEvenAfterItReappears() {
        var registry = RawTouchEndpointRegistry()
        let old = registry.allocateID()
        registry.admit(entry(old))
        let generation = try! XCTUnwrap(registry.beginAcquire(old))

        registry.remove(old)
        let replacement = registry.allocateID()
        registry.admit(entry(replacement))
        _ = registry.beginAcquire(replacement)

        registry.completeAcquire(old, generation: generation, landed: true)
        XCTAssertFalse(registry.anyLeaseHeld, "the replacement's own acquire is still in flight")
        XCTAssertEqual(registry.statusEndpoints().map(\.lease), [.pending])
    }

    func testAStaleGenerationOnALiveEndpointIsIgnored() {
        var registry = RawTouchEndpointRegistry()
        let id = registry.allocateID()
        registry.admit(entry(id))
        let first = registry.beginAcquire(id)!
        registry.beginRelease(id)

        // The user disabled RawTouch while the acquire was on the wire.
        registry.completeAcquire(id, generation: first, landed: true)
        XCTAssertFalse(registry.anyLeaseHeld)
        XCTAssertEqual(registry.statusEndpoints().map(\.lease), [.notWanted])
    }

    // MARK: - Per-endpoint leases

    func testOneEndpointsFailedLeaseLeavesTheOthersHeld() {
        var registry = RawTouchEndpointRegistry()
        let a = registry.allocateID()
        let b = registry.allocateID()
        registry.admit(entry(a, transport: .usb))
        registry.admit(entry(b, name: "Other", transport: .bluetooth))
        let ga = registry.beginAcquire(a)!
        let gb = registry.beginAcquire(b)!

        registry.completeAcquire(a, generation: ga, landed: true)
        registry.completeAcquire(b, generation: gb, landed: false)

        XCTAssertTrue(registry.anyLeaseHeld, "RawTouch mode is live on A")
        XCTAssertEqual(registry.statusEndpoints().map(\.lease), [.held, .failed])

        // A refresh that then succeeds on B clears its failure — not the
        // refresh being issued, which has not answered yet.
        let gb2 = registry.beginAcquire(b)!
        XCTAssertEqual(registry.statusEndpoints().map(\.lease), [.held, .failed])
        registry.completeAcquire(b, generation: gb2, landed: true)
        XCTAssertEqual(registry.statusEndpoints().map(\.lease), [.held, .held])
    }

    /// A keyboard switched off on its own (`devices.<key>.enabled: false`)
    /// is released and reads as switched off — not as a pad set without a lease
    /// whose firmware is silently kept in RawTouch mode.
    func testASwitchedOffKeyboardReadsAsDisabledWhileTheOtherKeepsItsLease() {
        var registry = RawTouchEndpointRegistry()
        let a = registry.allocateID()
        let b = registry.allocateID()
        registry.admit(entry(a, key: "usb:a"))
        registry.admit(entry(b, transport: .bluetooth, key: "bt:b"))
        registry.completeAcquire(a, generation: registry.beginAcquire(a)!, landed: true)
        registry.completeAcquire(b, generation: registry.beginAcquire(b)!, landed: true)

        // The manager's reconciliation for `devices.bt:b.enabled = false`.
        var configuration = RawTouchConfiguration()
        configuration.devices = ["bt:b": .init(enabled: false)]
        registry.beginRelease(b)

        let endpoints = registry.statusEndpoints(isDisabled: { !configuration.isEnabled(deviceKey: $0.deviceKey) })
        XCTAssertEqual(endpoints.map(\.lease), [.held, .disabled])
        XCTAssertTrue(registry.anyLeaseHeld, "RawTouch mode stays live on the keyboard that is on")
    }

    func testReleasingAllDropsEveryLeaseAtOnce() {
        var registry = RawTouchEndpointRegistry()
        let a = registry.allocateID()
        let b = registry.allocateID()
        registry.admit(entry(a))
        registry.admit(entry(b, transport: .bluetooth))
        registry.completeAcquire(a, generation: registry.beginAcquire(a)!, landed: true)
        registry.completeAcquire(b, generation: registry.beginAcquire(b)!, landed: true)
        XCTAssertEqual(registry.statusEndpoints().map(\.lease), [.held, .held])

        registry.beginReleaseAll()
        XCTAssertFalse(registry.anyLeaseHeld)
        XCTAssertEqual(registry.statusEndpoints().map(\.lease), [.notWanted, .notWanted])
    }

    // MARK: - Lease reconciliation

    /// The manager's one reconcile, as its decision: acquire what is wanted
    /// and not requested, release what is requested and not wanted, leave
    /// every endpoint that already agrees alone.
    func testLeaseChangesTouchOnlyTheEndpointsThatDisagree() {
        var registry = RawTouchEndpointRegistry()
        let wantedIdle = registry.allocateID()
        let wantedHeld = registry.allocateID()
        let unwantedHeld = registry.allocateID()
        let unwantedIdle = registry.allocateID()
        for id in [wantedIdle, wantedHeld, unwantedHeld, unwantedIdle] {
            registry.admit(entry(id, key: "id:\(id.rawValue)"))
        }
        registry.completeAcquire(wantedHeld, generation: registry.beginAcquire(wantedHeld)!, landed: true)
        registry.completeAcquire(unwantedHeld, generation: registry.beginAcquire(unwantedHeld)!, landed: true)

        let wanted: Set = [wantedIdle, wantedHeld]
        let changes = registry.leaseChanges { wanted.contains($0.id) }
        XCTAssertEqual(changes.acquire, [wantedIdle])
        XCTAssertEqual(changes.release, [unwantedHeld])
    }

    /// An acquire still in flight is requested but not held, and a desire
    /// that drops meanwhile must release it — or it lands after the
    /// release was due and sticks until the firmware's lease expires.
    func testAnAcquireInFlightIsReleasedWhenTheDesireDrops() {
        var registry = RawTouchEndpointRegistry()
        let id = registry.allocateID()
        registry.admit(entry(id))
        _ = registry.beginAcquire(id)
        XCTAssertFalse(registry.anyLeaseHeld)

        XCTAssertEqual(registry.leaseChanges { _ in false }.release, [id])
    }

    /// A failed acquire stays requested: the renewal retries it, and the
    /// reconcile does not write it again on every unrelated change.
    func testAFailedAcquireIsLeftToTheRenewal() {
        var registry = RawTouchEndpointRegistry()
        let id = registry.allocateID()
        registry.admit(entry(id))
        registry.completeAcquire(id, generation: registry.beginAcquire(id)!, landed: false)

        let changes = registry.leaseChanges { _ in true }
        XCTAssertEqual(changes.acquire, [])
        XCTAssertEqual(changes.release, [])
        XCTAssertEqual(registry.requestedLeases, [id], "and the renewal timer keeps running for it")
    }

    /// Applying the changes makes the registry agree with the desire, so a
    /// second reconcile is a no-op and the renewal set is exactly the
    /// wanted endpoints — nothing to renew once nothing is wanted.
    func testApplyingTheChangesConvergesAndTheRenewalSetFollows() {
        var registry = RawTouchEndpointRegistry()
        let a = registry.allocateID()
        let b = registry.allocateID()
        registry.admit(entry(a))
        registry.admit(entry(b, transport: .bluetooth))

        func reconcile(_ wanted: Set<RawTouchEndpointID>) {
            let changes = registry.leaseChanges { wanted.contains($0.id) }
            for id in changes.acquire { _ = registry.beginAcquire(id) }
            for id in changes.release { registry.beginRelease(id) }
        }

        reconcile([a, b])
        XCTAssertEqual(registry.requestedLeases, [a, b])
        reconcile([b])
        XCTAssertEqual(registry.requestedLeases, [b])
        let again = registry.leaseChanges { $0.id == b }
        XCTAssertTrue(again.acquire.isEmpty && again.release.isEmpty)
        reconcile([])
        XCTAssertEqual(registry.requestedLeases, [])
        XCTAssertEqual(registry.statusEndpoints().map(\.lease), [.notWanted, .notWanted])
    }

    // MARK: - Unsupported firmware

    func testUnsupportedFirmwareIsReportedButNeverAdmitted() {
        var registry = RawTouchEndpointRegistry()
        let good = registry.allocateID()
        let old = registry.allocateID()
        registry.admit(entry(good))
        registry.addUnsupported(.init(id: old, productName: "Old board", transport: .usb))
        _ = registry.beginAcquire(good)

        XCTAssertEqual(registry.descriptors.map(\.id), [good], "the pipeline never hears about it")
        XCTAssertNil(registry.beginAcquire(old), "and it is never leased")
        XCTAssertEqual(registry.statusEndpoints().map(\.lease), [.pending, .unsupportedFirmware])
        XCTAssertEqual(registry.statusEndpoints().last?.productName, "Old board")

        XCTAssertFalse(registry.remove(old), "removing it closes no gesture")
        XCTAssertEqual(registry.statusEndpoints().count, 1)
    }

    // MARK: - Status

    func testStatusCarriesEveryEndpointWithItsOwnIdentity() {
        var registry = RawTouchEndpointRegistry()
        let a = registry.allocateID()
        let b = registry.allocateID()
        registry.admit(entry(a, transport: .usb, key: "usb:serial-a"))
        registry.admit(entry(b, transport: .bluetooth, key: "bt:aa-bb"))

        let endpoints = registry.statusEndpoints()
        XCTAssertEqual(endpoints.map(\.id), [a, b])
        XCTAssertEqual(endpoints.map(\.deviceKey), ["usb:serial-a", "bt:aa-bb"])
        XCTAssertEqual(endpoints.map(\.padIDs), [[0, 1], [0, 1]])
        XCTAssertEqual(endpoints.map(\.transport), [.usb, .bluetooth])
    }

    /// The firmware versions the feature report carried reach the status
    /// snapshot, central and per pad, so the Keyboards tab can show them
    /// without reaching back into the capabilities.
    func testStatusCarriesTheFirmwareVersionsFromTheFeatureReport() {
        var registry = RawTouchEndpointRegistry()
        let id = registry.allocateID()
        var capabilities = endpointDescriptor(id: id.rawValue).capabilities
        capabilities.firmwareVersion = RawTouchFirmwareVersion(major: 0, minor: 1)
        capabilities.pads[0]?.firmwareVersion = RawTouchFirmwareVersion(major: 0, minor: 1)
        // Pad 1's half says nothing: a peripheral on older firmware.
        capabilities.pads[1]?.firmwareVersion = nil
        registry.admit(
            .init(
                id: id,
                productName: "Go60 Right",
                transport: .usb,
                capabilities: capabilities,
                deviceKey: "usb:serial-a"
            ))

        let endpoint = registry.statusEndpoints().first
        XCTAssertEqual(endpoint?.firmwareVersion, RawTouchFirmwareVersion(major: 0, minor: 1))
        XCTAssertEqual(endpoint?.padFirmwareVersions, [0: RawTouchFirmwareVersion(major: 0, minor: 1)])
        XCTAssertEqual(endpoint?.padIDs, [0, 1])
    }

    /// Firmware without RawTouch mode is reported without a version: it is
    /// never read past its capabilities, and the tab hides the row for it.
    func testUnsupportedEndpointsCarryNoFirmwareVersion() {
        var registry = RawTouchEndpointRegistry()
        let id = registry.allocateID()
        registry.addUnsupported(.init(id: id, productName: "Old board", transport: .usb))

        XCTAssertNil(registry.statusEndpoints().first?.firmwareVersion)
        XCTAssertEqual(registry.statusEndpoints().first?.padFirmwareVersions, [:])
    }

    // MARK: - Device keys

    /// Protocol 4 firmware reports its own hardware id, the same over every
    /// transport, so one keyboard is one key however it is connected.
    func testTheHardwareIDIsTheKeyOnEveryTransport() {
        // Nothing about the transport goes into it: the id alone is the key.
        let usb = RawTouchDeviceKey.hardwareID("DEADBEEFCAFEF00D")
        let bluetooth = RawTouchDeviceKey.hardwareID("deadbeefcafef00d")
        XCTAssertEqual(usb, "id:DEADBEEFCAFEF00D")
        XCTAssertEqual(usb, bluetooth)
        XCTAssertNil(RawTouchDeviceKey.hardwareID(nil), "no id, no id key")
        XCTAssertNil(RawTouchDeviceKey.hardwareID(""))
        XCTAssertTrue(RawTouchDeviceKey.isHardwareID(usb!))
    }

    /// Two identical keyboards report different ids, so they never merge.
    func testIdenticalKeyboardsAreNeverMergedIntoOneKey() {
        let one = RawTouchDeviceKey.hardwareID("1111")
        let two = RawTouchDeviceKey.hardwareID("2222")
        XCTAssertNotEqual(one, two)
    }

    /// Without an id — firmware that reports none — the per-transport keys
    /// still apply, built only from identifiers that survive a reconnect.
    func testTransportKeysComeOnlyFromIdentifiersThatSurviveAReconnect() {
        // The Go60 over USB: MoErgo's board file puts the hardware ID in
        // the serial string.
        XCTAssertEqual(
            RawTouchDeviceKey.transportKey(
                transport: .usb,
                serialNumber: "moergo.com:GO60-DEADBEEFCAFEF00D",
                bluetoothAddress: nil
            ),
            "usb:moergo.com:GO60-DEADBEEFCAFEF00D"
        )
        // Over Bluetooth Low Energy: the identity address.
        XCTAssertEqual(
            RawTouchDeviceKey.transportKey(
                transport: .bluetooth, serialNumber: nil, bluetoothAddress: "AA-BB-CC-DD-EE-FF"),
            "bt:aa-bb-cc-dd-ee-ff"
        )
        // Stock ZMK leaves Zephyr's placeholder serial: no key, rather than
        // a key every such keyboard would share.
        XCTAssertNil(
            RawTouchDeviceKey.transportKey(transport: .usb, serialNumber: "0123456789AB", bluetoothAddress: nil))
        XCTAssertNil(RawTouchDeviceKey.transportKey(transport: .usb, serialNumber: "", bluetoothAddress: nil))
        XCTAssertNil(RawTouchDeviceKey.transportKey(transport: .usb, serialNumber: nil, bluetoothAddress: nil))
        // A Bluetooth address is never used for a USB endpoint (there is
        // none), and a serial stands in over Bluetooth only without one.
        XCTAssertNil(
            RawTouchDeviceKey.transportKey(transport: .usb, serialNumber: nil, bluetoothAddress: "aa-bb-cc-dd-ee-ff"))
        XCTAssertEqual(
            RawTouchDeviceKey.transportKey(transport: .bluetooth, serialNumber: "ABC123", bluetoothAddress: nil),
            "bt:ABC123"
        )
        XCTAssertNil(RawTouchDeviceKey.transportKey(transport: .bluetooth, serialNumber: nil, bluetoothAddress: nil))
        XCTAssertFalse(RawTouchDeviceKey.isHardwareID("usb:moergo.com:GO60-DEADBEEFCAFEF00D"))
    }

    /// The log names a key by its kind and its last four characters only.
    func testARedactedKeyKeepsItsKindAndTail() {
        XCTAssertEqual(RawTouchDeviceKey.redacted("id:DEADBEEFCAFEF00D"), "id:\u{2026}F00D")
        XCTAssertEqual(RawTouchDeviceKey.redacted("usb:moergo.com:GO60-DEADBEEFCAFEF00D"), "usb:\u{2026}F00D")
        XCTAssertEqual(RawTouchDeviceKey.redacted("bt:aa-bb-cc-dd-ee-ff"), "bt:\u{2026}e-ff")
    }
}
