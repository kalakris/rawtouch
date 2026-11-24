// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import os.log

/// The device manager's main-queue bookkeeping of every endpoint it has
/// seen, with IOKit left out: which endpoints are admitted (validated, with
/// a host lease to hold), which validated but cannot hold one, what each
/// one's lease is doing, and the generation stamps that keep a departed
/// endpoint's leftovers from touching its replacement.
///
/// Every appearance of an `IOHIDDevice` gets a fresh `RawTouchEndpointID` from
/// `allocateID()`, and every asynchronous result about it — the capability
/// read, each lease write's completion — comes back tagged with that ID (and,
/// for leases, the `LeaseState` generation issued for the write). A result
/// whose ID is no longer registered, or whose generation a release has since
/// overtaken, is discarded. So a keyboard that disconnects and reconnects while
/// an acquire is still on the wire cannot be marked as holding the lease by the
/// old write, and a device removed mid-validation is never admitted.
///
/// Factored out of `RawTouchDeviceManager` for the same reason
/// `LeaseState` was: there is no way to conjure an `IOHIDDevice` in a
/// test, so the manager itself cannot be driven through these paths, but
/// this can.
struct RawTouchEndpointRegistry: Equatable {
    /// One admitted endpoint.
    struct Entry: Equatable {
        var id: RawTouchEndpointID
        var productName: String
        var transport: RawTouchTransport
        var capabilities: RawTouchCapabilities
        /// Persistent identity (`RawTouchDeviceKey`), or nil.
        var deviceKey: String?
        var lease = LeaseState()

        init(
            id: RawTouchEndpointID,
            productName: String,
            transport: RawTouchTransport,
            capabilities: RawTouchCapabilities,
            deviceKey: String? = nil
        ) {
            self.id = id
            self.productName = productName
            self.transport = transport
            self.capabilities = capabilities
            self.deviceKey = deviceKey
        }

        var descriptor: RawTouchEndpointDescriptor {
            RawTouchEndpointDescriptor(
                id: id,
                capabilities: capabilities,
                transport: transport,
                productName: productName,
                deviceKey: deviceKey
            )
        }
    }

    /// An endpoint that validated as protocol v4 but whose firmware has no host
    /// lease support. Reported so the user can see which keyboard needs a
    /// firmware update; never leased, never read, and never in the way of the
    /// others.
    struct Unsupported: Equatable {
        var id: RawTouchEndpointID
        var productName: String
        var transport: RawTouchTransport
    }

    /// Admitted endpoints, in connect order.
    private(set) var entries: [Entry] = []

    /// Endpoints present but unusable, in connect order.
    private(set) var unsupported: [Unsupported] = []

    /// Which keyboard an admitted endpoint's feature report describes: its
    /// device key, or — for an endpoint with none — the endpoint itself,
    /// which is then its own keyboard exactly as it is its own group in the
    /// settings window. A per-transport fallback key is its own record too,
    /// by the same construction.
    enum KeyboardID: Hashable {
        case key(String)
        case endpoint(RawTouchEndpointID)
    }

    /// What each connected keyboard's feature report says, merged across
    /// every connection it has: module version, protocol, per-pad half
    /// versions and the pad slots.
    ///
    /// Per keyboard because the report *is* per keyboard: the central half
    /// answers it on every transport, so a relayed pad's half version
    /// learned over USB is that pad's version over Bluetooth too, and the
    /// Firmware row shows one answer per keyboard rather than one per
    /// connection. Versions are read *through* this record (the status and
    /// the probe's to-do list); the pipeline keeps taking geometry from the
    /// endpoint's own copy, which cannot differ — same central, and a
    /// re-read's geometry is never adopted.
    ///
    /// Updated by whichever read of the keyboard happened last, keeping
    /// any version that read did not know; dropped with the keyboard's
    /// last connection, so a keyboard reflashed while unplugged is not
    /// credited with its old versions.
    private(set) var firmware: [KeyboardID: RawTouchCapabilities] = [:]

    private var nextID: UInt64 = 1

    /// A fresh ID for a device that just appeared. Never reused within the
    /// process, so nothing tagged with an old one can match a new one.
    mutating func allocateID() -> RawTouchEndpointID {
        defer { nextID &+= 1 }
        return RawTouchEndpointID(rawValue: nextID)
    }

    // MARK: - Membership

    mutating func admit(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        unsupported.removeAll { $0.id == entry.id }
        entries.append(entry)
        record(entry.capabilities, for: keyboardID(of: entry))
    }

    mutating func addUnsupported(_ endpoint: Unsupported) {
        entries.removeAll { $0.id == endpoint.id }
        unsupported.removeAll { $0.id == endpoint.id }
        unsupported.append(endpoint)
    }

    /// Forgets an endpoint (admitted or unsupported). Returns whether it
    /// was admitted — the caller closes its gesture in that case.
    @discardableResult
    mutating func remove(_ id: RawTouchEndpointID) -> Bool {
        let departing = entry(id).map(keyboardID(of:))
        let wasAdmitted = entries.contains { $0.id == id }
        entries.removeAll { $0.id == id }
        unsupported.removeAll { $0.id == id }
        if let departing, !entries.contains(where: { keyboardID(of: $0) == departing }) {
            firmware[departing] = nil
        }
        return wasAdmitted
    }

    func entry(_ id: RawTouchEndpointID) -> Entry? {
        entries.first { $0.id == id }
    }

    /// What the pipeline is configured with.
    var descriptors: [RawTouchEndpointDescriptor] {
        entries.map(\.descriptor)
    }

    // MARK: - Leases

    /// Records an acquire (or renew) request for one endpoint and returns
    /// the generation to tag the write with; nil for an unknown endpoint.
    mutating func beginAcquire(_ id: RawTouchEndpointID) -> UInt64? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return entries[index].lease.beginAcquire()
    }

    mutating func beginRelease(_ id: RawTouchEndpointID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return
        }
        entries[index].lease.beginRelease()
    }

    mutating func beginReleaseAll() {
        for index in entries.indices {
            entries[index].lease.beginRelease()
        }
    }

    /// Records an acquire write's outcome. Ignored when the endpoint is
    /// gone or the write has been overtaken by a release or a newer acquire
    /// (see `LeaseState`).
    mutating func completeAcquire(_ id: RawTouchEndpointID, generation: UInt64, landed: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return
        }
        entries[index].lease.completeAcquire(landed: landed, generation: generation)
    }

    /// The lease writes that bring every admitted endpoint's request in
    /// line with whether its lease is wanted: an acquire where it is wanted
    /// and not requested, a release where it is requested and not wanted.
    ///
    /// Judged against the *request* (`LeaseState.desiredHeld`), not
    /// against `held`: an acquire still in flight reads as not held, and
    /// skipping its release would let it land after the release was due
    /// and stick until the firmware's lease expired. The endpoint's report
    /// queue is serial, so the release always lands behind the acquire it
    /// cancels.
    func leaseChanges(isDesired: (Entry) -> Bool) -> (acquire: [RawTouchEndpointID], release: [RawTouchEndpointID]) {
        var acquire: [RawTouchEndpointID] = []
        var release: [RawTouchEndpointID] = []
        for entry in entries where isDesired(entry) != entry.lease.desiredHeld {
            if entry.lease.desiredHeld {
                release.append(entry.id)
            } else {
                acquire.append(entry.id)
            }
        }
        return (acquire, release)
    }

    /// The endpoints whose lease is requested: what the renewal timer
    /// renews, and it runs exactly while there are any.
    var requestedLeases: [RawTouchEndpointID] {
        entries.filter(\.lease.desiredHeld).map(\.id)
    }

    /// Whether the lease has landed on at least one admitted endpoint.
    var anyLeaseHeld: Bool {
        entries.contains { $0.lease.held }
    }

    // MARK: - Firmware versions

    /// The sources whose pad has not said which firmware its half runs,
    /// while the keyboard they are on has — a split peripheral that has not
    /// announced itself to the central yet. Exactly the pads a capability
    /// re-read could still learn something from.
    ///
    /// Deliberately empty for an endpoint whose own version is unknown (old
    /// firmware: the byte is reserved-zero there, so re-reading would learn
    /// nothing, ever) and for unsupported endpoints (never admitted, so they
    /// are not in `entries` at all).
    ///
    /// Judged against the *keyboard's* record, so once any connection has
    /// learned a pad's half version, no connection of that keyboard is on
    /// the list any more; until then every connection is, and the first
    /// frame from that pad on whichever one it arrives triggers the read.
    var padsAwaitingFirmwareVersion: Set<RawTouchSourceID> {
        var sources: Set<RawTouchSourceID> = []
        for entry in entries {
            let report = keyboardCapabilities(of: entry)
            guard report.firmwareVersion != nil else {
                continue
            }
            for (padID, pad) in report.pads where pad.firmwareVersion == nil {
                sources.insert(RawTouchSourceID(endpoint: entry.id, padID: padID))
            }
        }
        return sources
    }

    /// Applies a capability re-read, taken on one endpoint, to its
    /// keyboard's record — **only** the firmware-version fields: a
    /// keyboard's geometry cannot change while it stays connected, so
    /// anything else a re-read says is dropped (the caller warns about
    /// it). Returns whether the record actually changed, i.e. whether
    /// there is new status to publish — for every connection of that
    /// keyboard at once.
    @discardableResult
    mutating func adoptFirmwareVersions(_ id: RawTouchEndpointID, from reread: RawTouchCapabilities) -> Bool {
        guard let entry = entry(id) else {
            return false
        }
        let keyboard = keyboardID(of: entry)
        let before = keyboardCapabilities(of: entry)
        // A version the re-read does not carry leaves the known one alone,
        // so a report read between two announces never un-learns anything.
        var merged = before
        merged.firmwareVersions = reread.firmwareVersions.merged(with: before.firmwareVersions)
        guard merged != before else {
            return false
        }
        logReplacedVersions(before, merged)
        firmware[keyboard] = merged
        return true
    }

    /// Which keyboard record an endpoint reads and writes.
    func keyboardID(of entry: Entry) -> KeyboardID {
        entry.deviceKey.map(KeyboardID.key) ?? .endpoint(entry.id)
    }

    /// What the endpoint's keyboard's feature report says, as far as any
    /// of its connections has learned.
    func keyboardCapabilities(of entry: Entry) -> RawTouchCapabilities {
        firmware[keyboardID(of: entry)] ?? entry.capabilities
    }

    /// A discovery read joins the keyboard's record: it is the latest word
    /// on everything, except a version it does not know that an earlier
    /// read of the same keyboard did.
    private mutating func record(_ read: RawTouchCapabilities, for keyboard: KeyboardID) {
        guard let earlier = firmware[keyboard] else {
            firmware[keyboard] = read
            return
        }
        var merged = read
        merged.firmwareVersions = read.firmwareVersions.merged(with: earlier.firmwareVersions)
        logReplacedVersions(earlier, merged)
        firmware[keyboard] = merged
    }

    /// A known version replaced by a different one is worth a line: a
    /// half's firmware does not change while it stays connected, unless
    /// someone reflashed it.
    private func logReplacedVersions(_ before: RawTouchCapabilities, _ after: RawTouchCapabilities) {
        for change in before.firmwareVersions.replaced(in: after.firmwareVersions) {
            let what = change.pad.map { "Pad \($0)'s half" } ?? "The keyboard"
            os_log(
                "%{public}@ now reports firmware module version %{public}@ (was %{public}@)",
                log: RawTouchLog.device,
                type: .info,
                what,
                String(describing: change.to),
                String(describing: change.from)
            )
        }
    }

    // MARK: - Status

    /// The per-endpoint status lines, admitted first (connect order), then
    /// the unsupported ones. `isDisabled` names the endpoints switched off
    /// on their own (`devices.<key>.enabled: false`), which read as
    /// `.disabled` rather than merely unwanted.
    func statusEndpoints(
        isDisabled: (Entry) -> Bool = { _ in false },
        measuredLatencyMs: [RawTouchSourceID: Double] = [:]
    ) -> [RawTouchStatus.Endpoint] {
        let admitted = entries.map { entry -> RawTouchStatus.Endpoint in
            // A keyboard switched off on its own says so, whatever its
            // lease is doing.
            let lease = isDisabled(entry) ? .disabled : entry.lease.phase
            return RawTouchStatus.Endpoint(
                id: entry.id,
                productName: entry.productName,
                transport: entry.transport,
                padIDs: entry.capabilities.pads.keys.sorted(),
                // The keyboard's, not this connection's: one central
                // answers every transport.
                firmwareVersion: keyboardCapabilities(of: entry).firmwareVersion,
                padFirmwareVersions: keyboardCapabilities(of: entry).padFirmwareVersions,
                deviceID: entry.capabilities.deviceIDHex,
                deviceKey: entry.deviceKey,
                measuredLatencyMs: measuredLatencyMs.reduce(into: [UInt8: Double]()) { pads, entryPair in
                    guard entryPair.key.endpoint == entry.id else {
                        return
                    }
                    pads[entryPair.key.padID] = entryPair.value
                },
                lease: lease
            )
        }
        let rest = unsupported.map {
            RawTouchStatus.Endpoint(
                id: $0.id,
                productName: $0.productName,
                transport: $0.transport,
                padIDs: [],
                lease: .unsupportedFirmware
            )
        }
        return admitted + rest
    }
}
