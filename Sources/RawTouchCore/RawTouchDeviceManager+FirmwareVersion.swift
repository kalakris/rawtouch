// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import os.log

// MARK: - Firmware-version re-reads

extension RawTouchDeviceManager {
    /// The pads still worth a capability re-read (see
    /// `RawTouchFirmwareVersionProbe`) and the policy that decides when to
    /// issue one. Both are consulted from the frame path, so both live under
    /// `verifiedDevicesLock` — read there only for endpoints whose
    /// `awaitsFirmwareVersion` is set, which is a brief window after a
    /// keyboard connects and nothing at all afterwards.
    struct FirmwareVersionWatch {
        var padsAwaiting: Set<RawTouchSourceID> = []
        var probe = RawTouchFirmwareVersionProbe()
    }

    /// Feeds one frame from a pad that has not said which firmware its half
    /// runs into the probe, on the HID callback thread. The probe's own
    /// state lives under `verifiedDevicesLock`; the main queue is only
    /// woken when there is something to do, which is at most once per touch
    /// and at most `RawTouchFirmwareVersionProbe.rereadsPerPad` times per
    /// pad.
    func noteFrameForFirmwareVersion(source: RawTouchSourceID, touched: Bool, now: TimeInterval) {
        verifiedDevicesLock.lock()
        // The endpoint has *a* pad awaiting; this may not be that pad.
        guard lockedFirmwareVersionWatch.padsAwaiting.contains(source) else {
            verifiedDevicesLock.unlock()
            return
        }
        let decision = lockedFirmwareVersionWatch.probe.noteFrame(source: source, touched: touched, now: now)
        verifiedDevicesLock.unlock()

        switch decision {
        case .none:
            return
        case .reread:
            DispatchQueue.main.async { [weak self] in
                self?.rereadCapabilitiesForFirmwareVersion(of: source)
            }
        case .gaveUp:
            os_log(
                """
                Pad %{public}d on %{public}@ has not reported its half's firmware version after %{public}d \
                capability re-reads; assuming firmware that does not report one and giving up on it
                """,
                log: RawTouchLog.device,
                type: .info,
                Int(source.padID),
                String(describing: source.endpoint),
                RawTouchFirmwareVersionProbe.rereadsPerPad
            )
            // Takes this endpoint's frames off the probe path (its last
            // awaiting pad is now written off).
            DispatchQueue.main.async { [weak self] in
                self?.updateVerifiedDevices()
            }
        }
    }

    /// Re-reads one endpoint's capability feature report to pick up a
    /// firmware version announced since it was admitted (main queue). The
    /// GET is the same blocking transfer as the one at connect, so it runs
    /// on the endpoint's own report queue — behind whatever lease write is
    /// already in flight there — and lands back on the main queue.
    func rereadCapabilitiesForFirmwareVersion(of source: RawTouchSourceID) {
        let id = source.endpoint
        guard started,
            let open = openDevices.first(where: { $0.id == id }),
            let entry = registry.entry(id)
        else {
            return  // gone, or never admitted
        }
        let device = open.device
        let label = RawTouchReportTransfers.label(entry)

        open.reportQueue.async { [weak self] in
            let capabilities = RawTouchReportTransfers.readCapabilities(from: device)
            DispatchQueue.main.async { [weak self] in
                self?.firmwareVersionRereadDidLand(capabilities, for: id, label: label)
            }
        }
    }

    /// A re-read landed (main queue). Only the firmware-version fields are
    /// taken from it: the pads' geometry and orientation were settled when
    /// the device was admitted, and a keyboard that changes them mid-session
    /// is a bug worth seeing in the log, not a reconfiguration to follow.
    ///
    /// The pipeline is deliberately **not** reconfigured from here. Its
    /// endpoint descriptors carry the capabilities, but nothing downstream
    /// reads the version fields, and this lands in the middle of a touch —
    /// where a reconfigure would end the gesture in flight.
    func firmwareVersionRereadDidLand(
        _ reread: RawTouchCapabilities?,
        for id: RawTouchEndpointID,
        label: String
    ) {
        guard started, let reread, let entry = registry.entry(id) else {
            return
        }

        if entry.capabilities.differsBeyondFirmwareVersions(from: reread) {
            os_log(
                """
                Capability re-read of %{public}@ disagrees with the report it was admitted with beyond the \
                firmware versions (pads 0x%{public}x vs 0x%{public}x, capabilities 0x%{public}x vs \
                0x%{public}x); keeping the original and taking only the versions
                """,
                log: RawTouchLog.device,
                type: .error,
                label,
                entry.capabilities.padsPresent,
                reread.padsPresent,
                entry.capabilities.capabilityBits,
                reread.capabilityBits
            )
        }

        // Read through the keyboard's record: what this read teaches is
        // the keyboard's to know, on every connection it has.
        let before = registry.keyboardCapabilities(of: entry).padFirmwareVersions
        guard registry.adoptFirmwareVersions(id, from: reread) else {
            return
        }
        let after = registry.entry(id).map { registry.keyboardCapabilities(of: $0).padFirmwareVersions } ?? [:]
        for (padID, version) in after where before[padID] != version {
            os_log(
                "Pad %{public}d on %{public}@ reports firmware module version %{public}@ (learned on its first touch)",
                log: RawTouchLog.device,
                type: .info,
                Int(padID),
                label,
                String(describing: version)
            )
        }

        updateVerifiedDevices()
        publishStatus()
    }
}
