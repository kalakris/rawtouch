// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation

/// The one place that knows whether a HID report buffer carries its report
/// ID as a leading byte.
///
/// The rule, as macOS behaves:
///
/// - **Feature-report GETs**: macOS hands back the report **ID-prefixed over
///   USB and bare over Bluetooth**, for the same device and the same
///   `IOHIDDeviceGetReport` call. Neither spelling is wrong — the ID is
///   redundant with the argument that asked for it — so a reader has to
///   accept both.
/// - **Input reports**: the callback gets the report ID as an argument, and
///   the payload that follows may or may not repeat it, again per transport.
/// - **Feature-report SETs**: written bare — the 4-byte body, with the ID
///   only in `IOHIDDeviceSetReport`'s own argument. That spelling lands over
///   both USB and Bluetooth. The firmware's USB path also accepts the body
///   with the ID repeated as a leading byte (its Bluetooth path does not),
///   but nothing here writes that spelling.
///
/// Every report read and write goes through here, so the rule can be
/// reasoned about — and tested — once.
public enum ReportFraming {
    /// Where the payload of a **fixed-length** report starts inside a buffer
    /// the transport handed us: 1 when the report ID was prefixed, 0 when the
    /// payload is bare, `nil` when the buffer is too short to be this report
    /// either way.
    ///
    /// A buffer of exactly `payloadLength` bytes is bare by definition —
    /// checked first, so a bare payload whose first byte happens to equal the
    /// report ID (a frame from pad 4, say) is never mistaken for a prefixed
    /// one. Only a *longer* buffer that actually starts with the report ID is
    /// read as prefixed; a longer buffer that does not is a bare payload with
    /// trailing padding.
    public static func payloadOffset(
        bufferLength: Int,
        firstByte: UInt8?,
        reportID: UInt8,
        payloadLength: Int
    ) -> Int? {
        if bufferLength == payloadLength {
            return 0
        }
        if firstByte == reportID, bufferLength - 1 >= payloadLength {
            return 1
        }
        if bufferLength > payloadLength {
            return 0
        }
        return nil
    }

    /// Both readings of a **variable-length** report buffer, for a caller
    /// that can tell a valid payload from an invalid one itself (the
    /// capability parser validates the magic, the protocol version and the
    /// body length): the buffer as it came first — Bluetooth delivers the
    /// body bare — then, only if it really starts with the report ID, the
    /// buffer without that byte, which is how USB delivers it.
    ///
    /// Bare first, so a body that legitimately begins with the report-ID
    /// value is never truncated by guesswork; the ID-prefixed reading is
    /// tried only when the bare one fails to validate. That case is now the
    /// ordinary one rather than a corner: the feature body's first byte is
    /// the protocol version, which is 4 — the same value as the report ID —
    /// so every bare feature GET looks ID-prefixed. It parses as bare
    /// because bare is tried first, and the prefixed reading of the same
    /// buffer would fail the length and magic checks anyway.
    public static func payloadCandidates(_ bytes: [UInt8], reportID: UInt8) -> [[UInt8]] {
        guard bytes.first == reportID else {
            return [bytes]
        }
        return [bytes, Array(bytes.dropFirst())]
    }

}
