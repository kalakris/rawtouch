// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation

/// How a streaming keyboard is attached to this Mac.
///
/// The two transports deliver frames differently — USB hands over each
/// ~100 Hz sample as it is taken, Bluetooth holds frames until the next
/// connection event (~15 ms) — but the resampling latency that smooths
/// that out is measured per source (`RawTouchLatencyEstimator`), not
/// looked up by transport. The transport is for people and bookkeeping:
/// the menu and the log name it, and the fallback device key of a
/// keyboard that reports no hardware id is built from it.
///
/// The same keyboard can be present over both at once, as two IOHIDDevices;
/// frames carry the transport of the endpoint they arrived on.
public enum RawTouchTransport: String, Codable, Equatable {
    case usb
    case bluetooth
    /// Anything macOS names differently, or does not name at all.
    case unknown

    /// Maps the `kIOHIDTransportKey` string macOS puts on a HID device.
    /// Matched case-insensitively — the constant is a display-ish string
    /// ("USB", "Bluetooth", "Bluetooth Low Energy"), not an identifier.
    public init(hidTransport: String?) {
        switch hidTransport?.lowercased() {
        case "usb":
            self = .usb
        case "bluetooth", "bluetooth low energy":
            self = .bluetooth
        default:
            self = .unknown
        }
    }

    /// The transport's name for humans — the menu and the log. Nil for
    /// `.unknown`: there is nothing truthful to say about a transport macOS
    /// did not name.
    public var displayName: String? {
        switch self {
        case .usb:
            return "USB"
        case .bluetooth:
            return "Bluetooth"
        case .unknown:
            return nil
        }
    }
}
