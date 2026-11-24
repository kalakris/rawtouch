// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation

/// One appearance of one HID endpoint — an `IOHIDDevice` instance as seen by
/// `RawTouchDeviceManager`, stamped with a generation so that a keyboard
/// which re-enumerates (replug, wake, re-pair, a USB → Bluetooth handover)
/// is a *new* endpoint every time. Everything queued for the old one —
/// frames still on the event thread, a capability read or a lease write in
/// flight, a stale-touch watchdog — carries the old ID and is dropped on
/// arrival, so it can never touch the replacement.
///
/// This is runtime identity only. It says nothing about which physical
/// keyboard is behind the endpoint; that is `RawTouchDeviceKey`'s job, and
/// the two are deliberately separate: the same keyboard on USB and on
/// Bluetooth is two endpoints (two leases, two transports, two device
/// clocks), and two identical keyboards on USB are two endpoints too.
public struct RawTouchEndpointID: Hashable, Comparable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// The implicit endpoint of single-endpoint callers: frames built by
    /// the test fixtures and the bench, and `TouchScrollPipeline`'s
    /// single-`capabilities` `configure`. The device manager never issues
    /// it — its IDs start at 1.
    public static let `default` = RawTouchEndpointID(rawValue: 0)

    public static func < (lhs: RawTouchEndpointID, rhs: RawTouchEndpointID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        "endpoint#\(rawValue)"
    }
}

/// One live input source: a pad on an endpoint. The unit every piece of
/// per-stream state in `TouchScrollPipeline` is keyed by — device clock,
/// sequence tracking, stale-touch watchdog, gesture ownership — so that two
/// keyboards which both call their pad "0" never share any of it.
public struct RawTouchSourceID: Hashable, CustomStringConvertible {
    public var endpoint: RawTouchEndpointID
    public var padID: UInt8

    public init(endpoint: RawTouchEndpointID, padID: UInt8) {
        self.endpoint = endpoint
        self.padID = padID
    }

    public var description: String {
        "\(endpoint)/pad\(padID)"
    }
}

/// What the pipeline needs to know about one admitted endpoint: its
/// validated capabilities (geometry and orientation per pad), the transport
/// its frames arrive on, and the persistent key its configuration overrides
/// live under (nil when macOS exposes nothing stable for it).
public struct RawTouchEndpointDescriptor: Equatable {
    public var id: RawTouchEndpointID
    public var capabilities: RawTouchCapabilities
    public var transport: RawTouchTransport
    public var productName: String
    public var deviceKey: String?

    public init(
        id: RawTouchEndpointID = .default,
        capabilities: RawTouchCapabilities,
        transport: RawTouchTransport = .unknown,
        productName: String = "",
        deviceKey: String? = nil
    ) {
        self.id = id
        self.capabilities = capabilities
        self.transport = transport
        self.productName = productName
        self.deviceKey = deviceKey
    }
}

/// The persistent identity of a physical **keyboard** — the string
/// `devices.<key>` in the configuration is keyed by, and what the settings
/// window groups pads under.
///
/// Protocol 4 firmware reports the SoC's own hardware id in its feature
/// report, and answers with the same one over every transport, so the key
/// is that id: `id:<16 uppercase hex>`. One keyboard is one entry, whether
/// it is plugged in, paired, or both at once, and a keyboard that moves
/// between transports keeps its settings.
///
/// A keyboard whose firmware reports no id (an all-zero field) falls back
/// to a per-transport key (`transportKey`): `usb:<serial>` when the serial
/// is not a known placeholder (`RawTouchDeviceKey.placeholderSerialNumbers`),
/// `bt:<address>` (lower-cased, as macOS spells it), and no key at all
/// when neither is usable — `LocationID` is deliberately unused, it
/// changes with the USB port. Nothing macOS exposes on an `IOHIDDevice` is
/// common to both transports, so such a keyboard has one entry per
/// transport. An endpoint without a key gets no per-keyboard settings
/// rather than a key that would silently stop applying.
public enum RawTouchDeviceKey {
    /// USB serial strings that identify a *firmware default*, not a device:
    /// Zephyr's `USB_DEVICE_SN` Kconfig placeholders as far as they are
    /// known here, and the Go60 template returned when the hardware ID
    /// cannot be read. A keyboard whose serial is not on this list is taken
    /// at its word; `ioreg -r -c IOHIDDevice -l | grep SerialNumber` shows
    /// what a keyboard reports.
    public static let placeholderSerialNumbers: Set<String> = [
        "0123456789AB",
        "0.01",
        "moergo.com:GO60-0123456789ABCDEF",
    ]

    public static let hardwareIDPrefix = "id:"

    /// `id:<hex>` from a hardware id, or nil when the firmware reported none.
    public static func hardwareID(_ deviceID: String?) -> String? {
        guard let deviceID, !deviceID.isEmpty else {
            return nil
        }
        return "\(hardwareIDPrefix)\(deviceID.uppercased())"
    }

    /// Whether a key names a keyboard (its hardware id) rather than one
    /// connection of one (`usb:` / `bt:`).
    public static func isHardwareID(_ key: String) -> Bool {
        key.hasPrefix(hardwareIDPrefix)
    }

    /// The fallback key for firmware that reports no hardware id, built
    /// from what macOS says about this one connection: `usb:<serial>` from
    /// a non-placeholder serial, `bt:<address>` from the device address (a
    /// usable serial when macOS gave no address), nil when neither is
    /// stable.
    public static func transportKey(
        transport: RawTouchTransport,
        serialNumber: String?,
        bluetoothAddress: String?
    ) -> String? {
        let serial = serialNumber?.trimmingCharacters(in: .whitespaces) ?? ""
        let usableSerial = !serial.isEmpty && !placeholderSerialNumbers.contains(serial)

        switch transport {
        case .bluetooth:
            if let address = bluetoothAddress?.trimmingCharacters(in: .whitespaces), !address.isEmpty {
                return "bt:\(address.lowercased())"
            }
            return usableSerial ? "bt:\(serial)" : nil
        case .usb, .unknown:
            return usableSerial ? "usb:\(serial)" : nil
        }
    }

    /// A short, human-readable tail of a key, for telling two keyboards
    /// with the same name apart in a heading ("Go60 Right (…F00D)").
    public static func shortSuffix(of key: String) -> String {
        let tail = key.suffix(4)
        return "\u{2026}\(tail)"
    }

    /// A key as the log may show it: its kind (`id:`, `usb:`, `bt:`) and
    /// `shortSuffix`, never the whole hardware id, serial or Bluetooth
    /// address — users attach these logs to public bug reports. Enough to
    /// tell two keyboards apart in one log, not to identify one.
    public static func redacted(_ key: String) -> String {
        let kind = key.firstIndex(of: ":").map { key[...$0] } ?? ""
        return "\(kind)\(shortSuffix(of: key))"
    }
}
