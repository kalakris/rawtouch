// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import IOKit.hid
import os.log

/// The blocking feature-report transfers `RawTouchDeviceManager` makes on
/// an endpoint's report queue: the capability GET that admits a device
/// (and re-reads it for a firmware version), and the 4-byte SETs — the
/// lease and the tap confirm. Every function here blocks for an IOKit round
/// trip, so none of them is ever called on the main queue.
enum RawTouchReportTransfers {
    /// The size of the capability feature-report read buffer, derived from
    /// the protocol constants rather than guessed: the longest body the wire
    /// format can describe is `payloadLength(padSlots: maximumPadSlots)`
    /// (80 bytes), and over USB macOS hands the report back with its report
    /// ID prepended, hence the +1. A buffer shorter than this would silently
    /// truncate a report from firmware built with many pad slots.
    /// `RawTouchCapabilitiesTests` pins the relationship.
    static let capabilityBufferLength =
        RawTouchCapabilities.payloadLength(padSlots: RawTouchCapabilities.maximumPadSlots) + 1

    /// How long after a capability read that found no valid report to
    /// read it again, or nil once the one retry is spent. A transfer can
    /// fail right after a device enumerates, and a device not admitted then
    /// is ignored until it enumerates again; a foreign collection squatting
    /// on the usage pair costs one more read and is then left alone.
    static func capabilityRetryDelay(afterAttempt attempt: Int) -> TimeInterval? {
        attempt == 1 ? 1 : nil
    }

    /// Reads and parses the capability feature report. Returns `nil` when the
    /// report is absent, short, or reports an unsupported protocol version.
    /// Blocking: runs on the endpoint's report queue, never the main queue.
    ///
    /// The buffer is sized from the protocol constants
    /// (`capabilityBufferLength`) rather than a round number, so firmware
    /// built with the maximum eight pad slots is read whole. `length` is an
    /// in/out parameter the driver writes, so it is range-checked before it
    /// indexes the buffer.
    static func readCapabilities(from device: IOHIDDevice) -> RawTouchCapabilities? {
        var buffer = [UInt8](repeating: 0, count: capabilityBufferLength)
        var length = CFIndex(buffer.count)
        let result = IOHIDDeviceGetReport(
            device,
            kIOHIDReportTypeFeature,
            RawTouchCapabilities.featureReportID,
            &buffer,
            &length
        )

        guard result == kIOReturnSuccess, length > 0, length <= buffer.count else {
            return nil
        }

        return RawTouchCapabilities.parse(reportBytes: Array(buffer[0..<length]))
    }

    /// The blocking acquire/renew or release write. Runs on an endpoint's
    /// report queue.
    static func writeLease(acquire: Bool, to device: IOHIDDevice, label: String) -> Bool {
        let result = writeFeatureCommand(RawTouchLease.leasePayload(acquire: acquire), to: device)

        guard result == kIOReturnSuccess else {
            os_log(
                "Lease %{public}@ failed on %{public}@ (0x%{public}x); other endpoints are unaffected",
                log: RawTouchLog.lease,
                type: .error,
                acquire ? "acquire/renew" : "release",
                label,
                result
            )
            return false
        }

        os_log(
            "Lease %{public}@ written to %{public}@",
            log: RawTouchLog.lease,
            type: .debug,
            acquire ? "acquire/renew" : "release",
            label
        )
        return true
    }

    /// The blocking write of one 4-byte feature command — the lease's or
    /// the tap confirm's, which share their framing. The body goes out
    /// bare, the report ID only in its own argument (see `ReportFraming`).
    /// Runs on an endpoint's report queue.
    static func writeFeatureCommand(_ payload: [UInt8], to device: IOHIDDevice) -> IOReturn {
        payload.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(
                device,
                kIOHIDReportTypeFeature,
                RawTouchLease.featureReportID,
                buffer.baseAddress!,
                CFIndex(buffer.count)
            )
        }
    }

    /// "Go60 Right over USB (endpoint#3)" — the log's name for an endpoint,
    /// so two keyboards' lease outcomes read apart.
    static func label(_ entry: RawTouchEndpointRegistry.Entry) -> String {
        "\(entry.productName) over \(entry.transport.displayName ?? "an unnamed transport") (\(entry.id))"
    }
}
