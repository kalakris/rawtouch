// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import RawTouchCore

// Feature-report bodies and the capabilities they parse to, for the tests
// and the offline bench. Every capabilities value built here goes through
// the real parser, so a fixture cannot describe something the wire format
// could not carry.

/// One 8-byte pad slot as the wire carries it. The defaults are a Go60
/// pad: 38 counts/mm, rotate-90 + y-invert, 2047 × 1535, one contact, no
/// version reported.
public struct FeatureReportSlot {
    public var countsPerMM: UInt8
    public var flags: UInt8
    public var xMax: UInt16
    public var yMax: UInt16
    public var maxContacts: UInt8
    public var version: UInt8

    public init(
        countsPerMM: UInt8 = 38,
        flags: UInt8 = RawTouchCapabilities.PadFlag.rotate90 | RawTouchCapabilities.PadFlag.invertY,
        xMax: UInt16 = 2047,
        yMax: UInt16 = 1535,
        maxContacts: UInt8 = 1,
        version: UInt8 = 0
    ) {
        self.countsPerMM = countsPerMM
        self.flags = flags
        self.xMax = xMax
        self.yMax = yMax
        self.maxContacts = maxContacts
        self.version = version
    }

    /// An all-zero slot: a pad that describes nothing.
    public static let empty = FeatureReportSlot(countsPerMM: 0, flags: 0, xMax: 0, yMax: 0, maxContacts: 0)

    var bytes: [UInt8] {
        [
            countsPerMM, flags,
            UInt8(xMax & 0xFF), UInt8(xMax >> 8),
            UInt8(yMax & 0xFF), UInt8(yMax >> 8),
            maxContacts, version,
        ]
    }
}

/// A protocol-4 feature-report body (no report-ID prefix): the 16-byte
/// header — version, pads present, capability bits, the central's packed
/// module version, the "RAWT" magic, the device id — then one slot per
/// entry of `slots`.
public func featureReportBytes(
    padsPresent: UInt8 = 0x03,
    capabilityBits: UInt8 = RawTouchCapabilities.Capability.hostLease,
    centralVersion: UInt8 = 0,
    deviceID: [UInt8] = [UInt8](repeating: 0, count: RawTouchCapabilities.deviceIDLength),
    slots: [FeatureReportSlot] = [FeatureReportSlot(), FeatureReportSlot()]
) -> [UInt8] {
    [UInt8(RawTouchCapabilities.protocolVersion), padsPresent, capabilityBits, centralVersion]
        + RawTouchCapabilities.magic
        + deviceID
        + slots.flatMap(\.bytes)
}

extension RawTouchFirmwareVersion {
    /// The wire byte `init?(packed:)` reads.
    public var packed: UInt8 {
        UInt8(major << 4 | minor)
    }
}

extension RawTouchCapabilities {
    /// One keyboard, one build: every present pad gets the same geometry
    /// and belongs to the half this describes, so its version is the
    /// central's. A split flashed on one side only is a wire-format case,
    /// built with `featureReportBytes`.
    public init(
        padsPresent: UInt8 = 0x1,
        capabilityBits: UInt8 = 0,
        countsPerMM: Int = 38,
        rotate90: Bool = false,
        invertX: Bool = false,
        invertY: Bool = false,
        xMax: Int = 2047,
        yMax: Int = 1535,
        firmwareVersion: RawTouchFirmwareVersion? = nil,
        deviceID: [UInt8] = [UInt8](repeating: 0, count: RawTouchCapabilities.deviceIDLength)
    ) {
        var flags: UInt8 = 0
        if rotate90 { flags |= PadFlag.rotate90 }
        if invertX { flags |= PadFlag.invertX }
        if invertY { flags |= PadFlag.invertY }
        let version = firmwareVersion?.packed ?? 0
        let slot = FeatureReportSlot(
            countsPerMM: UInt8(countsPerMM),
            flags: flags,
            xMax: UInt16(xMax),
            yMax: UInt16(yMax),
            maxContacts: 1,
            version: version
        )
        let padCount = padsPresent.nonzeroBitCount
        self.init(
            reportBytes: featureReportBytes(
                padsPresent: padsPresent,
                capabilityBits: capabilityBits,
                centralVersion: version,
                deviceID: deviceID,
                slots: [FeatureReportSlot](repeating: slot, count: padCount)
            ))!
    }

    /// The Go60's report as these tests use it: both pads, host lease
    /// supported, rotate-90 + y-invert (⇒ the engine reads raw x,
    /// old-school direction).
    public static func go60(padsPresent: UInt8 = 0x03) -> RawTouchCapabilities {
        RawTouchCapabilities(
            padsPresent: padsPresent,
            capabilityBits: Capability.hostLease,
            rotate90: true,
            invertY: true
        )
    }
}
