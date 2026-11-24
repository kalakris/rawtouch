// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation

/// The version of the `zmk-raw-touch` firmware module a keyboard half is
/// running, as the feature report packs it: one byte, `(major << 4) | minor`
/// — `0x01` is 0.1, `0x10` is 1.0.
///
/// Reported per keyboard (the central half) and per pad (the half that owns
/// that pad), so a split flashed on one side only is visible: the halves can
/// disagree, and a pad's frames come from its own half.
///
/// Not a compatibility contract — that is the protocol version, which the
/// parser checks exactly. This is a human-readable fact for the
/// Keyboards tab and for bug reports.
public struct RawTouchFirmwareVersion: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// Unpacks the wire byte. Zero is "unknown" — firmware that does not
    /// report its version, or a split peripheral that has not reported it
    /// to the central yet — and yields nil rather than a 0.0 that would
    /// read as a real answer.
    public init?(packed: UInt8) {
        guard packed != 0 else {
            return nil
        }
        self.init(major: Int(packed >> 4), minor: Int(packed & 0x0F))
    }

    public var description: String {
        "\(major).\(minor)"
    }
}

/// What one feature report says about the firmware of a keyboard's halves:
/// the central's module version and each pad's half's, every one nil (or
/// absent) where that half has not said.
struct RawTouchFirmwareVersions: Equatable {
    var central: RawTouchFirmwareVersion?
    var pads: [UInt8: RawTouchFirmwareVersion] = [:]

    /// These versions, with `fallback`'s wherever these say nothing. Once a
    /// half has said which firmware it runs it stays known: a report read
    /// before that half announced itself again reads 0 there, and 0 means
    /// "has not said", not "changed".
    func merged(with fallback: RawTouchFirmwareVersions) -> RawTouchFirmwareVersions {
        RawTouchFirmwareVersions(
            central: central ?? fallback.central,
            pads: fallback.pads.merging(pads) { _, known in known }
        )
    }

    /// Every version that was known here and is known as something else in
    /// `newer` — worth a log line, since a half's firmware does not change
    /// while it stays connected unless someone reflashed it. Pad nil is the
    /// central.
    func replaced(in newer: RawTouchFirmwareVersions) -> [(
        pad: UInt8?, from: RawTouchFirmwareVersion, to: RawTouchFirmwareVersion
    )] {
        var replaced: [(pad: UInt8?, from: RawTouchFirmwareVersion, to: RawTouchFirmwareVersion)] = []
        if let old = central, let new = newer.central, old != new {
            replaced.append((nil, old, new))
        }
        for (padID, old) in pads.sorted(by: { $0.key < $1.key }) {
            if let new = newer.pads[padID], old != new {
                replaced.append((padID, old, new))
            }
        }
        return replaced
    }
}
