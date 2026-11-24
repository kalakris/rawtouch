// MIT License
// Copyright (c) 2026 RawTouch contributors
// Derived from LinearMouse — Copyright (c) 2021-2026 LinearMouse (MIT).

import Foundation

/// One of the two raw Cirque coordinates. The engine reads both: one
/// drives vertical scrolling, the other horizontal (which is which is a
/// property of the pad's mounting — see `RawTouchCapabilities.Pad.scrollAxis`).
public enum RawTouchAxis: String, Codable, Equatable, CaseIterable {
    case x
    case y

    /// The other raw coordinate: with vertical scrolling reading one, this
    /// is what horizontal scrolling reads.
    public var other: RawTouchAxis {
        switch self {
        case .x: .y
        case .y: .x
        }
    }
}

/// Which scroll directions a pad produces. `both` is an Apple trackpad;
/// the other two zero one component and leave it out of the acceleration
/// speed estimate and the momentum seed, so a pad meant for one direction
/// never drifts sideways.
public enum RawTouchScrollAxes: String, Codable, Equatable, CaseIterable {
    case both
    case vertical
    case horizontal

    public var includesVertical: Bool {
        self != .horizontal
    }

    public var includesHorizontal: Bool {
        self != .vertical
    }
}

/// Capabilities self-reported by a streaming device through the feature
/// report (`featureReportID`, the same report ID as the input report, read
/// with `IOHIDDeviceGetReport(kIOHIDReportTypeFeature)`). This is the
/// parser; the firmware module's docs/protocol.md is the normative layout.
/// In brief: a `headerLength`-byte header — protocol version, pads-present
/// bitmask, `Capability` bits, the central half's module version, the
/// `magic`, the device id — then one `padSlotLength`-byte slot per present
/// pad in ascending pad_id order — resolution, orientation bits, x/y
/// maximum, maximum contacts, the owning half's module version. That is
/// `payloadLength(padSlots:)` bytes, one more over USB, where macOS
/// prefixes the report ID.
///
/// A clear capability bit or slot flag means "not supported" and changes
/// nothing else; the tap-confirm command they describe is in
/// `RawTouchTapConfirm`. Module versions are diagnostic: zero means "says
/// nothing", and no value is ever a reason to reject a report. The device
/// id is read but never judged either: no value of it, all-zero included,
/// admits or rejects a keyboard.
///
/// **Validation is all three of** the `magic`, a protocol version of
/// exactly `protocolVersion`, and a body length of exactly
/// `payloadLength(padSlots:)` for some slot count (at most
/// `maximumPadSlots` are read; a longer body's extra slots are ignored, as
/// the pads-present bitmask cannot name more). A body that fails any of
/// them is not this protocol, and the caller must not so much as write a
/// lease command to the device it came from. This is the squatter defense:
/// 0xFF00/0x01 is a generic vendor usage pair that any unrelated device may
/// sit on, so a matching collection is only trusted once this report
/// validates. Identification, not authentication.
///
/// Trailing padding is *not* tolerated — a body of 30 bytes is rejected
/// rather than read as one slot — because the exact length is part of that
/// check.
///
/// A pad advertised in the bitmask beyond the slots the body carries is
/// taken as present with default (Pinnacle) geometry rather than dropped.
public struct RawTouchCapabilities: Equatable {
    public static let featureReportID: CFIndex = 0x04

    /// Version, pads-present, capabilities, the central's module version,
    /// the four magic bytes, then the eight-byte device id. Also where
    /// slot 0 starts.
    public static let headerLength = 16

    /// Where the magic sits in the body.
    public static let magicOffset = 4

    /// Where the device id sits in the body, and how long it is.
    public static let deviceIDOffset = 8
    public static let deviceIDLength = 8

    /// The ASCII bytes "RAWT". Fixed for the life of the protocol; what
    /// tells a raw touch keyboard apart from anything else squatting on the
    /// generic 0xFF00/0x01 vendor usage pair.
    public static let magic: [UInt8] = [0x52, 0x41, 0x57, 0x54]

    /// One pad slot: resolution, orientation, x-max, y-max, max contacts,
    /// the owning half's module version.
    public static let padSlotLength = 8

    /// The pads-present bitmask is one byte, so no report can describe more.
    public static let maximumPadSlots = 8

    /// The shortest body that can describe anything: header + one slot.
    public static let minimumPayloadLength = headerLength + padSlotLength

    /// The body length of a report carrying `padSlots` slots — the 16 + 8N
    /// formula.
    public static func payloadLength(padSlots: Int) -> Int {
        headerLength + padSlotLength * padSlots
    }

    /// The one protocol version this build consumes. Anything else is
    /// treated as non-streaming rather than guessed at.
    public static let protocolVersion = 4

    /// Capability bit masks in feature-report byte 2.
    public enum Capability {
        /// Bit 0: the firmware implements the host lease (lease SET
        /// feature report + frame flags bit 2). RawTouch requires it.
        public static let hostLease: UInt8 = 0x1
        /// Bit 1: the firmware accepts the tap-confirm command
        /// (`RawTouchTapConfirm`). A host must see it before writing one.
        public static let tapConfirm: UInt8 = 0x2
    }

    /// Orientation-byte (slot +1) bit masks.
    public enum PadFlag {
        public static let rotate90: UInt8 = 0x1
        public static let invertX: UInt8 = 0x2
        public static let invertY: UInt8 = 0x4
        /// Bit 3: see `Pad.parksScrollTaps`.
        public static let parksScrollTaps: UInt8 = 0x8
    }

    /// Per-pad geometry and orientation (one pad slot).
    public struct Pad: Equatable {
        /// Resolution assumed for a pad that reports none (0). Every Cirque
        /// Pinnacle this firmware drives is ≈38 counts/mm, so a zero here
        /// means an old or hand-rolled feature report rather than genuinely
        /// different hardware.
        public static let fallbackCountsPerMM = 38.0

        /// Pad resolution in counts/mm; 0 = unknown.
        public var countsPerMM: Int
        public var rotate90: Bool
        public var invertX: Bool
        public var invertY: Bool
        public var xMax: Int
        public var yMax: Int
        /// Maximum simultaneous contacts (1 on a Pinnacle).
        public var maxContacts: Int
        /// Whether this pad, while a host lease is held, holds back a
        /// scroll-context tap at lift-off instead of emitting it, and emits
        /// it only if the host confirms it within ~250 ms. Only the host
        /// knows whether that touch was a tap or a finger stopping a
        /// coast, because only the host runs the coast — see
        /// `TouchScrollPipeline.onTapConfirm`. False for a pad whose
        /// firmware does not say.
        public var parksScrollTaps: Bool
        /// The firmware module version of the half this pad belongs to — a
        /// relayed split-peripheral pad carries the peripheral's, a local
        /// pad repeats the central's. Nil when the half has not said (its
        /// firmware does not report one, or it is a peripheral that has not
        /// reported yet — it
        /// announces itself just before the first frame of each touch, so
        /// see `padFirmwareVersions` for when this becomes known).
        public var firmwareVersion: RawTouchFirmwareVersion?

        public init(
            countsPerMM: Int = 38,
            rotate90: Bool = false,
            invertX: Bool = false,
            invertY: Bool = false,
            xMax: Int = 2047,
            yMax: Int = 1535,
            maxContacts: Int = 1,
            firmwareVersion: RawTouchFirmwareVersion? = nil,
            parksScrollTaps: Bool = false
        ) {
            self.countsPerMM = countsPerMM
            self.rotate90 = rotate90
            self.invertX = invertX
            self.invertY = invertY
            self.xMax = xMax
            self.yMax = yMax
            self.maxContacts = maxContacts
            self.firmwareVersion = firmwareVersion
            self.parksScrollTaps = parksScrollTaps
        }

        /// Parses an 8-byte pad slot.
        public init(slotBytes: ArraySlice<UInt8>) {
            let bytes = Array(slotBytes)
            countsPerMM = Int(bytes[0])
            rotate90 = bytes[1] & PadFlag.rotate90 != 0
            invertX = bytes[1] & PadFlag.invertX != 0
            invertY = bytes[1] & PadFlag.invertY != 0
            parksScrollTaps = bytes[1] & PadFlag.parksScrollTaps != 0
            xMax = Int(bytes[2]) | (Int(bytes[3]) << 8)
            yMax = Int(bytes[4]) | (Int(bytes[5]) << 8)
            maxContacts = bytes.count > 6 ? max(1, Int(bytes[6])) : 1
            firmwareVersion = bytes.count > 7 ? RawTouchFirmwareVersion(packed: bytes[7]) : nil
        }
    }

    public var version: Int
    public var padsPresent: UInt8
    /// Capabilities byte (bit0 = host lease supported, bit1 = tap confirm
    /// supported).
    public var capabilityBits: UInt8
    /// Per-pad capabilities keyed by pad_id, one entry per bit set in
    /// `padsPresent`.
    public var pads: [UInt8: Pad]
    /// The firmware module version of the half the host talks to (the
    /// central on a split), or nil when it says nothing.
    public var firmwareVersion: RawTouchFirmwareVersion?
    /// The SoC's own hardware identifier, exactly as the firmware read it
    /// from Zephyr's `hwinfo_get_device_id()` — eight bytes, all-zero when
    /// the firmware could not read one.
    ///
    /// The same chip answers with the same bytes on every transport, which
    /// is the only thing either transport exposes that could tie a USB row
    /// and a Bluetooth row to one physical keyboard. It is an identifier,
    /// not a secret, and nothing is admitted, rejected or authorized on its
    /// value — see `deviceIDHex` for the readable form.
    public var deviceID: [UInt8]

    public init?(reportBytes: [UInt8]) {
        guard reportBytes.count >= Self.minimumPayloadLength,
            // The exact 16 + 8N shape, not merely "at least": the length is
            // part of what identifies the protocol.
            (reportBytes.count - Self.headerLength) % Self.padSlotLength == 0,
            Int(reportBytes[0]) == Self.protocolVersion,
            Array(reportBytes[Self.magicOffset..<Self.magicOffset + Self.magic.count])
                == Self.magic
        else {
            return nil
        }

        version = Self.protocolVersion
        padsPresent = reportBytes[1]
        capabilityBits = reportBytes[2]
        // The central's module version: read, never rejected; 0 says
        // nothing.
        firmwareVersion = RawTouchFirmwareVersion(packed: reportBytes[3])
        deviceID = Array(
            reportBytes[Self.deviceIDOffset..<Self.deviceIDOffset + Self.deviceIDLength]
        )

        // How many slots the body carries: the 16 + 8N formula, whose exact
        // shape the guard above already checked, capped at the 8 pads the
        // bitmask can name.
        let slotsCarried = min(
            (reportBytes.count - Self.headerLength) / Self.padSlotLength,
            Self.maximumPadSlots
        )

        var pads: [UInt8: Pad] = [:]
        // Slots describe present pads in ascending pad_id order.
        var slotOffset = Self.headerLength
        for (index, padID) in Self.presentPadIDs(padsPresent).enumerated() {
            guard index < slotsCarried else {
                // More pads advertised than slots carried — firmware built
                // with fewer slots than it has pads. The pad is present, so
                // it keeps streaming; only its geometry is unknown, and the
                // defaults (a Pinnacle) are the right guess.
                pads[padID] = Pad()
                continue
            }
            pads[padID] = Pad(slotBytes: reportBytes[slotOffset..<slotOffset + Self.padSlotLength])
            slotOffset += Self.padSlotLength
        }
        self.pads = pads
    }

    /// The pad_ids set in a pads-present bitmask, in ascending order.
    private static func presentPadIDs(_ padsPresent: UInt8) -> [UInt8] {
        ((0 as UInt8)..<8).filter { padsPresent & (1 << $0) != 0 }
    }

    /// The module version of the half each pad belongs to, keyed by pad_id.
    /// A pad whose half has not said is simply absent — `pads.keys` is the
    /// list of pads, this is what is known about them.
    ///
    /// **When a pad's version becomes known.** A pad on the half the host
    /// talks to answers from the first read, at endpoint discovery. A pad
    /// relayed from a split peripheral does not: the peripheral has no
    /// connect-time hook on the wired split and announces its version to the
    /// central just before the first frame of each touch on its pad, so the
    /// slot reads 0 until the user first touches that pad after the central
    /// booted. `RawTouchDeviceManager` re-reads the report on that first
    /// frame (see `RawTouchFirmwareVersionProbe`), which is what fills this
    /// in mid-session.
    public var padFirmwareVersions: [UInt8: RawTouchFirmwareVersion] {
        pads.compactMapValues(\.firmwareVersion)
    }

    /// Every firmware-version field of the report. Setting it writes the
    /// central's version and each present pad's; a version for a pad the
    /// report does not have is ignored.
    var firmwareVersions: RawTouchFirmwareVersions {
        get {
            RawTouchFirmwareVersions(central: firmwareVersion, pads: padFirmwareVersions)
        }
        set {
            firmwareVersion = newValue.central
            for padID in pads.keys {
                pads[padID]?.firmwareVersion = newValue.pads[padID]
            }
        }
    }

    /// The same capabilities with every firmware-version field cleared: the
    /// part of a report that describes the *hardware*, and that must not
    /// change while a keyboard stays connected. Comparing two of these is
    /// how a re-read is checked before anything is adopted from it.
    var withoutFirmwareVersions: RawTouchCapabilities {
        var copy = self
        copy.firmwareVersions = RawTouchFirmwareVersions()
        return copy
    }

    /// Whether a re-read disagrees about anything but the versions — pad
    /// geometry, orientation, which pads are present, the capability bits.
    /// Mid-session that is a bug (a squatter answering, a driver returning
    /// someone else's report), never a feature, so the caller warns and
    /// keeps what it admitted the device with.
    func differsBeyondFirmwareVersions(from other: RawTouchCapabilities) -> Bool {
        withoutFirmwareVersions != other.withoutFirmwareVersions
    }

    /// The device id as uppercase hex, or nil when the firmware reported
    /// none (all-zero). Nil rather than "0000000000000000" so a caller
    /// cannot accidentally treat "unknown" as a keyboard's identity — two
    /// keyboards whose firmware cannot read an id are not the same
    /// keyboard.
    public var deviceIDHex: String? {
        guard deviceID.contains(where: { $0 != 0 }) else {
            return nil
        }
        return deviceID.map { String(format: "%02X", $0) }.joined()
    }

    /// A report that names no pad at all describes nothing to stream from.
    public var isSupported: Bool {
        !pads.isEmpty
    }

    /// Whether the firmware supports RawTouch mode (the host lease).
    /// Without it RawTouch refuses to run: such firmware keeps emitting its own
    /// divided-down wheel events, so synthesizing on top would double-scroll.
    public var supportsHostLease: Bool {
        capabilityBits & Capability.hostLease != 0
    }

    /// Whether the firmware accepts the tap-confirm command. Nothing is
    /// written to a keyboard that does not say so, whatever its pads say.
    public var supportsTapConfirm: Bool {
        capabilityBits & Capability.tapConfirm != 0
    }

    /// Pad 0, falling back to the lowest present pad: the pad whose
    /// geometry stands in for a pad the report does not describe. Only nil
    /// for a degenerate empty report (rejected by `isSupported`).
    public var primaryPadID: UInt8? {
        pads[0] != nil ? 0 : pads.keys.min()
    }

    /// The pad `primaryPadID` names.
    public var primaryPad: Pad? {
        primaryPadID.flatMap { pads[$0] }
    }

    /// Parses a feature-report buffer into supported capabilities, in either
    /// framing macOS delivers (bare over Bluetooth, report-ID-prefixed over
    /// USB — see `ReportFraming`). Returns `nil` for short buffers and
    /// unsupported protocol versions alike — either way the device is treated
    /// as non-streaming.
    public static func parse(reportBytes: [UInt8]) -> RawTouchCapabilities? {
        for payload in ReportFraming.payloadCandidates(reportBytes, reportID: UInt8(featureReportID)) {
            if let capabilities = RawTouchCapabilities(reportBytes: payload), capabilities.isSupported {
                return capabilities
            }
        }
        return nil
    }
}

extension RawTouchCapabilities.Pad {
    /// The resolution to do physical math with: the reported counts/mm, or
    /// the Pinnacle fallback when the pad reports none. Never zero, so it is
    /// safe to divide by.
    public var effectiveCountsPerMM: Double {
        countsPerMM > 0 ? Double(countsPerMM) : Self.fallbackCountsPerMM
    }

    /// The raw coordinate that carries logical-vertical finger motion —
    /// the one vertical scrolling reads. Horizontal scrolling reads the
    /// other (`horizontalScrollAxis`).
    ///
    /// The orientation bits mirror the pad's devicetree props, whose
    /// convention (ZMK's `zmk,input-processor-transform`) is: `rotate-90`
    /// swaps the raw axes first, then `x-invert`/`y-invert` negate the
    /// post-swap logical axes. So with `rotate-90` set, logical Y rides the
    /// raw X coordinate and logical X rides raw Y.
    public var scrollAxis: RawTouchAxis {
        rotate90 ? .x : .y
    }

    /// The raw coordinate that carries logical-horizontal finger motion:
    /// whichever one `scrollAxis` is not.
    public var horizontalScrollAxis: RawTouchAxis {
        scrollAxis.other
    }

    /// The device-orientation part of the engine `invert` sign (engine
    /// convention: `invert == false` means a finger moving toward an
    /// increasing raw coordinate produces positive, scroll-up deltas).
    /// `RawTouchConfiguration.engineConfig` layers the macOS Natural
    /// Scrolling preference and the `reverseScrolling` toggle on top.
    ///
    /// This value alone yields the pad's *old-school* ("wheel-like")
    /// direction: a finger moving up scrolls the view up, i.e. content moves
    /// opposite the finger. Derivation: logical Y (post-swap, post-invert) is `iY * raw` where
    /// `iY = invertY ? -1 : +1`, and the old-school direction maps decreasing
    /// logical Y (finger moving "up") to positive deltas, i.e.
    /// `deltaY ∝ -iY * Δraw`. Hence the engine sign is `-iY`, which means
    /// `invert == !invertY`. A pad mounted rotate-90 + y-invert, for
    /// example, gets axis = .x, invert = false.
    public var orientationScrollInverted: Bool {
        !invertY
    }

    /// The device-orientation part of the engine's horizontal sign (engine
    /// convention: `invertHorizontal == false` means a finger moving toward
    /// an increasing raw coordinate on the horizontal axis produces positive
    /// CGEvent deltaX). Derived exactly like `orientationScrollInverted`,
    /// one axis over: logical X (post-swap, post-invert) is `iX * raw` where
    /// `iX = invertX ? -1 : +1`, and logical +X is the finger moving right.
    /// Positive CGEvent deltaX moves content right, i.e. it is "scroll
    /// left" in the old-school sense, so the old-school direction (finger
    /// right → the view scrolls right → content moves left → deltaX
    /// negative) is `deltaX ∝ -iX * Δraw`: the engine sign is `-iX`, which
    /// means `invertHorizontal == !invertX`. A pad mounted rotate-90 +
    /// y-invert (no x-invert), for example, scrolls horizontally from raw
    /// Y, inverted. `pads.<id>.invertHorizontal` overrides it.
    public var orientationHorizontalScrollInverted: Bool {
        !invertX
    }
}
