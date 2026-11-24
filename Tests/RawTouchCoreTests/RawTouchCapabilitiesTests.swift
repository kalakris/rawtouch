// MIT License
// Copyright (c) 2026 RawTouch contributors
// Derived from LinearMouse — Copyright (c) 2021-2026 LinearMouse (MIT).

import XCTest

@testable import RawTouchCore

final class RawTouchCapabilitiesTests: XCTestCase {
    /// The Go60's feature report: protocol v4, right pad present,
    /// 38 counts/mm, rotate-90 + y-invert, 2047x1535 — the 16-byte header
    /// (the "RAWT" magic and the device id included) plus one populated pad
    /// slot (the right pad) and a zeroed second slot. 32 bytes, the Go60's
    /// two-slot body.
    ///
    /// The device id is the real one read off the user's Go60 (its USB
    /// serial number `moergo.com:GO60-DEADBEEFCAFEF00D` is the same eight
    /// bytes, which is how the board builds it).
    private static let go60Report: [UInt8] = [
        0x04,  // version
        0x01,  // pads present: right pad
        0x00,  // capabilities (host-lease bit reserved)
        0x00,  // the answering half's module version: unknown
        0x52, 0x41, 0x57, 0x54,  // magic, "RAWT"
        0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xF0, 0x0D,  // device id
        // pad slot 0 (pad_id 0)
        0x26,  // 38 counts/mm
        0x05,  // orientation: bit0 rotate-90, bit2 y-invert
        0xFF, 0x07,  // x-max 2047
        0xFF, 0x05,  // y-max 1535
        0x01,  // max contacts
        0x00,  // reserved
        // pad slot 1 (unused: only one pad present)
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]

    /// Index of byte `offset` inside pad slot `slot`, derived from the
    /// protocol constants rather than written out, so a header that grows
    /// again moves every slot-relative index in these tests at once.
    private static func slotByte(_ slot: Int, _ offset: Int) -> Int {
        RawTouchCapabilities.headerLength + slot * RawTouchCapabilities.padSlotLength + offset
    }

    // MARK: - The read buffer

    /// The buffer `RawTouchReportTransfers.readCapabilities` reads into has to
    /// hold the longest report the wire format can describe — all eight pad
    /// slots the pads-present bitmask can name — plus the report-ID byte
    /// macOS prepends over USB; a round 64 would silently truncate anything
    /// past five slots. Pinned here because the two numbers live in
    /// different files.
    func testTheCapabilityReadBufferCoversTheLongestPossibleReport() {
        let longest = RawTouchCapabilities.payloadLength(padSlots: RawTouchCapabilities.maximumPadSlots)
        XCTAssertEqual(longest, 80, "16 + 8 x 8, per the wire format")
        XCTAssertLessThanOrEqual(longest + 1, RawTouchReportTransfers.capabilityBufferLength)
    }

    /// A read that finds no report right after a connect is tried once
    /// more, after a pause, and then the device is left alone: a keyboard
    /// whose first transfer failed is not ignored until it re-enumerates,
    /// and a foreign collection is not polled forever.
    func testAFailedCapabilityReadIsRetriedExactlyOnce() {
        let first = RawTouchReportTransfers.capabilityRetryDelay(afterAttempt: 1)
        XCTAssertNotNil(first)
        XCTAssertGreaterThan(first ?? 0, 0, "not straight away: the first failure is likely still the cause")
        XCTAssertNil(RawTouchReportTransfers.capabilityRetryDelay(afterAttempt: 2))
    }

    // MARK: - Parsing

    func testParsesGo60FeatureReport() {
        XCTAssertEqual(Self.go60Report.count, 32, "the Go60's two-slot body, 16 + 8 x 2")

        guard let capabilities = RawTouchCapabilities.parse(reportBytes: Self.go60Report) else {
            XCTFail("Expected the v4 feature report to parse")
            return
        }

        XCTAssertEqual(capabilities.version, 4)
        XCTAssertEqual(capabilities.padsPresent, 0x01)
        XCTAssertEqual(capabilities.capabilityBits, 0)
        XCTAssertTrue(capabilities.isSupported)

        XCTAssertEqual(capabilities.pads.count, 1)
        let pad = capabilities.pads[0]
        XCTAssertEqual(pad?.countsPerMM, 38)
        XCTAssertEqual(pad?.rotate90, true)
        XCTAssertEqual(pad?.invertX, false)
        XCTAssertEqual(pad?.invertY, true)
        XCTAssertEqual(pad?.xMax, 2047)
        XCTAssertEqual(pad?.yMax, 1535)
        XCTAssertEqual(pad?.maxContacts, 1)

        // The fixture's version bytes are zero: unknown, not a reason to
        // reject.
        XCTAssertNil(capabilities.firmwareVersion)
        XCTAssertNil(pad?.firmwareVersion)
        XCTAssertEqual(capabilities.padFirmwareVersions, [:])

        // Pad 0 is the primary pad, and its orientation derives the axis
        // and direction the engine scrolls with.
        XCTAssertEqual(capabilities.primaryPad, pad)
        XCTAssertEqual(pad?.scrollAxis, .x)
        XCTAssertEqual(pad?.orientationScrollInverted, false)
    }

    func testParsesTwoPadSlotsInAscendingPadIDOrder() {
        var report = Self.go60Report
        report[1] = 0x03  // both pads present
        // Populate slot 1 (pad_id 1) with a distinct geometry.
        report[Self.slotByte(1, 0)] = 0x20  // 32 counts/mm
        report[Self.slotByte(1, 1)] = 0x01  // rotate-90 only
        report[Self.slotByte(1, 2)] = 0x00
        report[Self.slotByte(1, 3)] = 0x04  // x-max 1024
        report[Self.slotByte(1, 4)] = 0x00
        report[Self.slotByte(1, 5)] = 0x03  // y-max 768
        report[Self.slotByte(1, 6)] = 0x02  // max contacts 2

        guard let capabilities = RawTouchCapabilities.parse(reportBytes: report) else {
            XCTFail("Expected the two-pad feature report to parse")
            return
        }

        XCTAssertEqual(capabilities.pads.count, 2)
        XCTAssertEqual(capabilities.pads[0]?.xMax, 2047)
        XCTAssertEqual(capabilities.pads[1]?.countsPerMM, 32)
        XCTAssertEqual(capabilities.pads[1]?.rotate90, true)
        XCTAssertEqual(capabilities.pads[1]?.invertY, false)
        XCTAssertEqual(capabilities.pads[1]?.xMax, 1024)
        XCTAssertEqual(capabilities.pads[1]?.yMax, 768)
        XCTAssertEqual(capabilities.pads[1]?.maxContacts, 2)

        // The primary pad is still pad 0.
        XCTAssertEqual(capabilities.primaryPad?.xMax, 2047)
    }

    /// A report advertising only the left pad still exposes it through
    /// `primaryPad` (slots describe present pads in ascending pad_id order,
    /// so the first slot is pad 1 here).
    func testLeftPadOnlyUsesFirstSlot() {
        var report = Self.go60Report
        report[1] = 0x02  // pads present: left pad only

        guard let capabilities = RawTouchCapabilities.parse(reportBytes: report) else {
            XCTFail("Expected the left-pad-only feature report to parse")
            return
        }

        XCTAssertEqual(capabilities.pads.count, 1)
        XCTAssertNil(capabilities.pads[0])
        XCTAssertEqual(capabilities.pads[1]?.xMax, 2047)
        XCTAssertEqual(capabilities.primaryPad?.xMax, 2047)
    }

    func testParsesOrientationBitsIndividually() {
        var report = Self.go60Report

        report[Self.slotByte(0, 1)] = 0x00
        let plain = RawTouchCapabilities.parse(reportBytes: report)?.primaryPad
        XCTAssertEqual(plain?.rotate90, false)
        XCTAssertEqual(plain?.invertX, false)
        XCTAssertEqual(plain?.invertY, false)

        report[Self.slotByte(0, 1)] = 0x02
        let invertedX = RawTouchCapabilities.parse(reportBytes: report)?.primaryPad
        XCTAssertEqual(invertedX?.rotate90, false)
        XCTAssertEqual(invertedX?.invertX, true)
        XCTAssertEqual(invertedX?.invertY, false)

        report[Self.slotByte(0, 1)] = 0x07
        let all = RawTouchCapabilities.parse(reportBytes: report)?.primaryPad
        XCTAssertEqual(all?.rotate90, true)
        XCTAssertEqual(all?.invertX, true)
        XCTAssertEqual(all?.invertY, true)
        XCTAssertEqual(all?.parksScrollTaps, false, "bits 0-2 are the mounting only")
    }

    // MARK: - Tap confirm (additive inside protocol 4)

    func testParsesTheTapConfirmCapabilityBit() {
        var report = Self.go60Report

        report[2] = 0x01
        let leaseOnly = RawTouchCapabilities.parse(reportBytes: report)
        XCTAssertEqual(leaseOnly?.supportsHostLease, true)
        XCTAssertEqual(leaseOnly?.supportsTapConfirm, false)

        report[2] = 0x03
        let both = RawTouchCapabilities.parse(reportBytes: report)
        XCTAssertEqual(both?.supportsHostLease, true)
        XCTAssertEqual(both?.supportsTapConfirm, true)

        report[2] = 0x02
        let confirmOnly = RawTouchCapabilities.parse(reportBytes: report)
        XCTAssertEqual(confirmOnly?.supportsHostLease, false)
        XCTAssertEqual(confirmOnly?.supportsTapConfirm, true)
    }

    /// Slot bit 3 shares the orientation byte; reading it must leave the
    /// three mounting bits exactly as they were, and they must not read
    /// as it.
    func testParksScrollTapsIsBit3AndLeavesTheOrientationAlone() {
        var report = Self.go60Report

        report[Self.slotByte(0, 1)] = 0x00
        let none = RawTouchCapabilities.parse(reportBytes: report)?.primaryPad
        XCTAssertEqual(none?.parksScrollTaps, false)

        report[Self.slotByte(0, 1)] = 0x08
        let parksOnly = RawTouchCapabilities.parse(reportBytes: report)?.primaryPad
        XCTAssertEqual(parksOnly?.parksScrollTaps, true)
        XCTAssertEqual(parksOnly?.rotate90, false)
        XCTAssertEqual(parksOnly?.invertX, false)
        XCTAssertEqual(parksOnly?.invertY, false)

        // The Go60's mounting (rotate-90 + y-invert) plus bit 3.
        report[Self.slotByte(0, 1)] = 0x0D
        let go60 = RawTouchCapabilities.parse(reportBytes: report)?.primaryPad
        XCTAssertEqual(go60?.parksScrollTaps, true)
        XCTAssertEqual(go60?.rotate90, true)
        XCTAssertEqual(go60?.invertX, false)
        XCTAssertEqual(go60?.invertY, true)
        XCTAssertEqual(go60?.scrollAxis, .x)
        XCTAssertEqual(go60?.orientationScrollInverted, false)

        report[Self.slotByte(0, 1)] = 0x0F
        let all = RawTouchCapabilities.parse(reportBytes: report)?.primaryPad
        XCTAssertEqual(all?.parksScrollTaps, true)
        XCTAssertEqual(all?.rotate90, true)
        XCTAssertEqual(all?.invertX, true)
        XCTAssertEqual(all?.invertY, true)
    }

    /// Per pad: on the Go60 only the dedicated scrolling pad parks.
    func testParksScrollTapsIsReadPerSlot() {
        var report = Self.go60Report
        report[1] = 0x03
        report[Self.slotByte(1, 0)] = 0x26
        report[Self.slotByte(1, 1)] = 0x0D

        let capabilities = RawTouchCapabilities.parse(reportBytes: report)
        XCTAssertEqual(capabilities?.pads[0]?.parksScrollTaps, false)
        XCTAssertEqual(capabilities?.pads[1]?.parksScrollTaps, true)
        XCTAssertEqual(RawTouchCapabilities.Pad().parksScrollTaps, false, "the default says nothing")
    }

    func testRejectsShortReports() {
        XCTAssertNil(RawTouchCapabilities.parse(reportBytes: []))
        XCTAssertNil(RawTouchCapabilities.parse(reportBytes: [0x04]))
        // Shorter than the header plus one slot (16 + 8): nothing to describe
        // a pad with, whatever the version byte says.
        XCTAssertNil(
            RawTouchCapabilities.parse(
                reportBytes: Array(Self.go60Report.prefix(RawTouchCapabilities.minimumPayloadLength - 1))
            ))
        // The header alone, magic and all, describes no pad.
        XCTAssertNil(
            RawTouchCapabilities.parse(
                reportBytes: Array(Self.go60Report.prefix(RawTouchCapabilities.headerLength))
            ))
    }

    // MARK: - Identification: magic, version, length

    /// The whole point of the magic: a device on the same generic
    /// 0xFF00/0x01 vendor usage pair, answering a feature read with a body
    /// that is the right length and names the right protocol version, is
    /// still not this protocol unless those four bytes say "RAWT". A
    /// rejected report means the caller never writes a lease command to it.
    func testRejectsABodyWhoseMagicIsWrong() {
        for corrupted in 0..<RawTouchCapabilities.magic.count {
            var report = Self.go60Report
            report[RawTouchCapabilities.magicOffset + corrupted] ^= 0xFF
            XCTAssertNil(
                RawTouchCapabilities.parse(reportBytes: report),
                "byte \(corrupted) of the magic must be checked"
            )
        }

        // A body of the right shape with no magic at all — zeros where it
        // belongs — is the squatter case.
        var blank = Self.go60Report
        for index in 0..<RawTouchCapabilities.magic.count {
            blank[RawTouchCapabilities.magicOffset + index] = 0
        }
        XCTAssertNil(RawTouchCapabilities.parse(reportBytes: blank))
    }

    /// The magic is the ASCII bytes "RAWT", pinned against the firmware's
    /// `ZMK_RAW_TOUCH_MAGIC_*`.
    func testTheMagicIsRAWT() {
        XCTAssertEqual(RawTouchCapabilities.magic, Array("RAWT".utf8))
        XCTAssertEqual(RawTouchCapabilities.magic, [0x52, 0x41, 0x57, 0x54])
        XCTAssertEqual(RawTouchCapabilities.magicOffset, 4)
        XCTAssertEqual(RawTouchCapabilities.deviceIDOffset, 8)
        XCTAssertEqual(RawTouchCapabilities.deviceIDLength, 8)
        XCTAssertEqual(RawTouchCapabilities.headerLength, 16)
        XCTAssertEqual(
            Array(Self.go60Report[4..<8]),
            RawTouchCapabilities.magic,
            "the Go60 fixture carries the magic where the wire format puts it"
        )
    }

    /// A 20-byte body with version byte 3 and no magic is simply not this
    /// protocol.
    func testRejectsAProtocol3Body() {
        let v3Body: [UInt8] = [
            0x03,  // version 3
            0x01,  // pads present: pad 0
            0x00,  // capabilities
            0x00,  // the central's module version
            // what would be the magic in protocol 4
            0x26, 0x05, 0xFF, 0x07, 0xFF, 0x05, 0x01, 0x00,
            // pad slot 1
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]
        XCTAssertEqual(v3Body.count, 20, "a 4 + 8 x 2 body")
        XCTAssertNil(RawTouchCapabilities.parse(reportBytes: v3Body))

        // Nor does stamping the magic into it rescue it: the version byte
        // is checked too.
        var stamped = v3Body
        for (index, byte) in RawTouchCapabilities.magic.enumerated() {
            stamped[RawTouchCapabilities.magicOffset + index] = byte
        }
        XCTAssertNil(RawTouchCapabilities.parse(reportBytes: stamped))
    }

    /// The exact `16 + 8N` shape is part of the identification, so a body
    /// with a byte too many or too few is rejected rather than floored —
    /// this is a deliberate change from protocol 3, which tolerated
    /// trailing padding.
    func testRejectsABodyThatIsNotHeaderPlusWholeSlots() {
        for extra in 1...7 {
            let padded = Self.go60Report + [UInt8](repeating: 0, count: extra)
            XCTAssertNil(
                RawTouchCapabilities.parse(reportBytes: padded),
                "\(padded.count) bytes is not 16 + 8N"
            )
            XCTAssertNil(
                RawTouchCapabilities.parse(reportBytes: Array(Self.go60Report.dropLast(extra))),
                "\(Self.go60Report.count - extra) bytes is not 16 + 8N"
            )
        }

        // A whole extra slot is fine: that is a three-slot firmware.
        XCTAssertNotNil(
            RawTouchCapabilities.parse(
                reportBytes: Self.go60Report + [UInt8](repeating: 0, count: RawTouchCapabilities.padSlotLength)
            ))
    }

    // MARK: - Device id

    /// Eight bytes, read verbatim and exposed as hex. Nothing is judged on
    /// its value — it is how a host can tell that the USB row and the
    /// Bluetooth row are one keyboard.
    func testParsesTheDeviceID() {
        guard let capabilities = RawTouchCapabilities.parse(reportBytes: Self.go60Report) else {
            XCTFail("Expected the v4 feature report to parse")
            return
        }
        XCTAssertEqual(capabilities.deviceID, [0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xF0, 0x0D])
        XCTAssertEqual(capabilities.deviceIDHex, "DEADBEEFCAFEF00D")

        // The same body framed the way USB delivers it yields the same id:
        // the field is read after framing is settled, not from the buffer.
        XCTAssertEqual(
            RawTouchCapabilities.parse(reportBytes: [UInt8(0x04)] + Self.go60Report)?.deviceIDHex,
            "DEADBEEFCAFEF00D"
        )
    }

    /// Firmware that could not read an id sends zeros. That parses — no
    /// value of this field rejects a keyboard — but reads as "unknown"
    /// rather than as the identity `0000000000000000`, which two different
    /// keyboards would otherwise appear to share.
    func testAnAllZeroDeviceIDIsUnknownNotAnIdentity() {
        var report = Self.go60Report
        for index in 0..<RawTouchCapabilities.deviceIDLength {
            report[RawTouchCapabilities.deviceIDOffset + index] = 0
        }

        guard let capabilities = RawTouchCapabilities.parse(reportBytes: report) else {
            XCTFail("An all-zero device id must still parse")
            return
        }
        XCTAssertTrue(capabilities.isSupported)
        XCTAssertEqual(capabilities.deviceID, [UInt8](repeating: 0, count: 8))
        XCTAssertNil(capabilities.deviceIDHex)
    }

    /// Every other value parses too, including ones that look like
    /// something else — the field is never validated.
    func testNoDeviceIDValueIsEverRejected() {
        for filler in [0xFF, 0x04, 0x52] as [UInt8] {
            var report = Self.go60Report
            for index in 0..<RawTouchCapabilities.deviceIDLength {
                report[RawTouchCapabilities.deviceIDOffset + index] = filler
            }
            XCTAssertNotNil(
                RawTouchCapabilities.parse(reportBytes: report),
                "device id filled with 0x\(String(filler, radix: 16)) must parse"
            )
        }
    }

    // MARK: - Variable slot count (body = 16 + 8N)

    /// Firmware built with a single pad slot sends a 24-byte body. It is not
    /// a truncated 32-byte report: N is read from the length.
    func testParsesASingleSlotBody() {
        let report = Array(Self.go60Report.prefix(RawTouchCapabilities.payloadLength(padSlots: 1)))
        XCTAssertEqual(report.count, 24)

        guard let capabilities = RawTouchCapabilities.parse(reportBytes: report) else {
            XCTFail("Expected a one-slot feature report to parse")
            return
        }
        XCTAssertEqual(capabilities.pads.count, 1)
        XCTAssertEqual(capabilities.pads[0]?.countsPerMM, 38)
        XCTAssertEqual(capabilities.pads[0]?.xMax, 2047)
        XCTAssertEqual(capabilities.primaryPad?.scrollAxis, .x)
    }

    /// Firmware with more slots than a Go60: a four-slot body, all four pads
    /// advertised, each slot read in ascending pad-id order.
    func testParsesAFourSlotBody() {
        var report = Array(Self.go60Report.prefix(RawTouchCapabilities.payloadLength(padSlots: 2)))
        report[1] = 0x0F  // pads 0-3 present
        for slot in 2...3 {
            var bytes = [UInt8](repeating: 0, count: 8)
            bytes[0] = UInt8(30 + slot)  // distinct resolution per pad
            bytes[2] = UInt8(slot)  // x-max low byte, distinct
            bytes[6] = 1
            report += bytes
        }
        XCTAssertEqual(report.count, RawTouchCapabilities.payloadLength(padSlots: 4))

        guard let capabilities = RawTouchCapabilities.parse(reportBytes: report) else {
            XCTFail("Expected a four-slot feature report to parse")
            return
        }
        XCTAssertEqual(capabilities.pads.count, 4)
        XCTAssertEqual(capabilities.pads[0]?.countsPerMM, 38)
        XCTAssertEqual(capabilities.pads[2]?.countsPerMM, 32)
        XCTAssertEqual(capabilities.pads[2]?.xMax, 2)
        XCTAssertEqual(capabilities.pads[3]?.countsPerMM, 33)
        XCTAssertEqual(capabilities.pads[3]?.xMax, 3)
    }

    /// More pads advertised than slots carried: the extra pads are present
    /// with default geometry, not dropped — they still stream frames, only
    /// their resolution and mounting are unknown.
    func testPadsBeyondTheCarriedSlotsGetDefaultGeometry() {
        var report = Array(Self.go60Report.prefix(RawTouchCapabilities.payloadLength(padSlots: 1)))
        report[1] = 0x03  // two pads present, one slot carried

        guard let capabilities = RawTouchCapabilities.parse(reportBytes: report) else {
            XCTFail("Expected the one-slot two-pad report to parse")
            return
        }
        XCTAssertEqual(capabilities.pads.count, 2)
        XCTAssertEqual(capabilities.pads[0]?.xMax, 2047, "the carried slot describes pad 0")
        XCTAssertEqual(capabilities.pads[1], RawTouchCapabilities.Pad(), "pad 1 falls back to the defaults")
    }

    /// The bitmask names at most 8 pads, so a body declaring more slots than
    /// that describes nothing extra.
    func testSlotsBeyondTheEighthAreIgnored() {
        var report = Array(Self.go60Report.prefix(RawTouchCapabilities.headerLength))
        report[1] = 0xFF  // all eight pads present
        report += [UInt8](repeating: 0, count: RawTouchCapabilities.padSlotLength * 10)

        let capabilities = RawTouchCapabilities.parse(reportBytes: report)
        XCTAssertEqual(capabilities?.pads.count, 8)
    }

    /// Only protocol 4. Every other version is treated as non-streaming
    /// rather than guessed at — even with the magic present, which the
    /// fixture has.
    func testRejectsUnsupportedVersions() {
        var report = Self.go60Report

        for version in [0x00, 0x01, 0x02, 0x03, 0x05, 0xFF] as [UInt8] {
            report[0] = version
            XCTAssertNil(
                RawTouchCapabilities.parse(reportBytes: report),
                "protocol \(version) is not protocol 4"
            )
        }
    }

    /// Over USB macOS prefixes the report ID, which is 0x04 — the same
    /// value as the protocol version byte that starts a bare body. Both
    /// framings must land on the same capabilities: the bare reading is
    /// tried first, and a prefixed buffer fails it on length and magic
    /// before the ID-stripped reading succeeds.
    func testStripsPrependedReportID() {
        let prefixed = [UInt8(0x04)] + Self.go60Report
        XCTAssertEqual(prefixed.count, 33, "the Go60's USB framing")
        let capabilities = RawTouchCapabilities.parse(reportBytes: prefixed)
        XCTAssertEqual(capabilities?.version, 4)
        XCTAssertEqual(capabilities?.primaryPad?.xMax, 2047)
        XCTAssertEqual(capabilities?.primaryPad?.invertY, true)

        // The bare body starts with 0x04 too, and must still parse bare.
        XCTAssertEqual(
            RawTouchCapabilities.parse(reportBytes: Self.go60Report),
            capabilities
        )
    }

    // MARK: - Firmware module version

    /// One byte, `(major << 4) | minor`.
    func testUnpacksTheVersionByte() {
        XCTAssertNil(RawTouchFirmwareVersion(packed: 0), "0 is unknown, not 0.0")
        XCTAssertEqual(RawTouchFirmwareVersion(packed: 0x01)?.description, "0.1")
        XCTAssertEqual(RawTouchFirmwareVersion(packed: 0x10)?.description, "1.0")
        XCTAssertEqual(RawTouchFirmwareVersion(packed: 0x23), RawTouchFirmwareVersion(major: 2, minor: 3))
        XCTAssertEqual(RawTouchFirmwareVersion(packed: 0xFF), RawTouchFirmwareVersion(major: 15, minor: 15))
    }

    /// Header byte 3 is the central's version; each slot's byte +7 is the
    /// version of the half that owns that pad.
    func testParsesTheCentralAndPerPadVersions() {
        var report = Self.go60Report
        report[1] = 0x03  // both pads present
        report[3] = 0x01  // central: 0.1
        report[Self.slotByte(0, 7)] = 0x01  // pad 0's half: 0.1, the central's own
        report[Self.slotByte(1, 7)] = 0x10  // pad 1's half: 1.0, a peripheral on another build

        guard let capabilities = RawTouchCapabilities.parse(reportBytes: report) else {
            XCTFail("Expected the versioned two-pad report to parse")
            return
        }
        XCTAssertEqual(capabilities.firmwareVersion, RawTouchFirmwareVersion(major: 0, minor: 1))
        XCTAssertEqual(capabilities.pads[0]?.firmwareVersion, RawTouchFirmwareVersion(major: 0, minor: 1))
        XCTAssertEqual(capabilities.pads[1]?.firmwareVersion, RawTouchFirmwareVersion(major: 1, minor: 0))
        XCTAssertEqual(
            capabilities.padFirmwareVersions,
            [
                0: RawTouchFirmwareVersion(major: 0, minor: 1),
                1: RawTouchFirmwareVersion(major: 1, minor: 0),
            ])
    }

    /// A pad whose half has not said keeps its slot's zero and is left out
    /// of `padFirmwareVersions`: the geometry it did report still stands.
    func testAPadHalfThatReportsNoVersionIsSimplyAbsent() {
        var report = Self.go60Report
        report[1] = 0x03
        report[3] = 0x01
        report[Self.slotByte(0, 7)] = 0x01
        report[Self.slotByte(1, 2)] = 0x00
        report[Self.slotByte(1, 3)] = 0x04  // pad 1 x-max 1024, so the slot is demonstrably read
        // Pad 1's slot keeps its zero version byte: a peripheral that has not
        // reported to the central yet.

        let capabilities = RawTouchCapabilities.parse(reportBytes: report)
        XCTAssertEqual(capabilities?.pads[1]?.xMax, 1024)
        XCTAssertNil(capabilities?.pads[1]?.firmwareVersion)
        XCTAssertEqual(capabilities?.padFirmwareVersions, [0: RawTouchFirmwareVersion(major: 0, minor: 1)])
    }

    /// The version bytes are diagnostic, so a non-zero value in either is
    /// read, never grounds for rejecting the report. Only byte 0, the
    /// magic and the body length decide that.
    func testNonZeroVersionBytesNeverRejectAReport() {
        var report = Self.go60Report
        report[3] = 0xAB
        report[Self.slotByte(0, 7)] = 0xCD

        guard let capabilities = RawTouchCapabilities.parse(reportBytes: report) else {
            XCTFail("Expected a report with non-zero version bytes to parse")
            return
        }
        XCTAssertTrue(capabilities.isSupported)
        XCTAssertEqual(capabilities.firmwareVersion, RawTouchFirmwareVersion(major: 10, minor: 11))
        XCTAssertEqual(capabilities.pads[0]?.firmwareVersion, RawTouchFirmwareVersion(major: 12, minor: 13))
    }

    // MARK: - Orientation → axis/direction derivation

    /// The engine configuration `RawTouchConfiguration` derives for pad 0 —
    /// the shipping derivation, not a helper standing in for it.
    private func engineConfig(
        _ capabilities: RawTouchCapabilities,
        systemPrefersNatural: Bool,
        reversed: Bool
    ) -> TouchScrollEngine.Config {
        // Gain 1.0 against a display pinned at 0.25 × the pad's 38 counts/mm
        // is 0.25 points per count — a round number to check against — and
        // ballistics off keep the deltas a plain multiplication (the
        // acceleration curve is `TouchScrollEngineTests`' subject).
        RawTouchConfiguration(
            scale: 1.0,
            reverseScrolling: reversed,
            acceleration: .init(enabled: false)
        ).engineConfig(
            forPad: 0,
            capabilities: capabilities,
            systemPrefersNatural: systemPrefersNatural,
            pointsPerMM: 0.25 * RawTouchCapabilities.Pad.fallbackCountsPerMM
        )
    }

    /// GROUND TRUTH TRUTH TABLE: for the Go60's orientation (rotate-90 +
    /// y-invert), the engine sign for every combination of the system
    /// Natural Scrolling preference and the "Reverse scrolling" toggle. The
    /// (system natural OFF, reverse OFF) row MUST be the direction checked
    /// on the hardware — `{axis: "x", invert: false}`, old-school: content
    /// moves opposite the fingers. If a
    /// row fails, the scroll direction or axis has silently flipped — do not
    /// "fix" the test; fix the derivation.
    func testGo60DirectionTruthTable() {
        guard let capabilities = RawTouchCapabilities.parse(reportBytes: Self.go60Report) else {
            XCTFail("Expected the Go60 feature report to parse")
            return
        }

        XCTAssertEqual(capabilities.primaryPad?.scrollAxis, .x)
        XCTAssertEqual(capabilities.primaryPad?.orientationScrollInverted, false)

        // system natural OFF, reverse OFF → old-school (the
        // hardware-checked direction).
        XCTAssertFalse(engineConfig(capabilities, systemPrefersNatural: false, reversed: false).invert)
        // system natural OFF, reverse ON → phone-style.
        XCTAssertTrue(engineConfig(capabilities, systemPrefersNatural: false, reversed: true).invert)
        // system natural ON, reverse OFF → content follows the fingers
        // (phone-style), matching what wheel devices do under the system
        // preference.
        XCTAssertTrue(engineConfig(capabilities, systemPrefersNatural: true, reversed: false).invert)
        // system natural ON, reverse ON → flipped back to old-school.
        XCTAssertFalse(engineConfig(capabilities, systemPrefersNatural: true, reversed: true).invert)
    }

    /// End-to-end anchor: an engine configured from the Go60 capabilities
    /// with Natural Scrolling off and reverse unset must produce the exact
    /// vertical deltas of `{axis: "x", invert: false}` at 0.25 points per
    /// count — a finger
    /// moving toward increasing raw X produces positive (scroll-up) deltaY
    /// scaled by pointsPerCount, whatever raw Y does. Raw Y is the
    /// horizontal axis, inverted (`invertHorizontal == !invertX`, and the
    /// Go60 does not x-invert): −300 raw Y counts × 0.25 × −1 = +75 deltaX.
    /// Both halves match the direction checked on the hardware.
    func testGo60OrientationAnchorDrivesEngineLikeTheValidatedConfig() {
        guard let capabilities = RawTouchCapabilities.parse(reportBytes: Self.go60Report) else {
            XCTFail("Expected the Go60 feature report to parse")
            return
        }

        let engine = TouchScrollEngine(config: engineConfig(capabilities, systemPrefersNatural: false, reversed: false))

        _ = engine.handle(frame: .init(x: 1000, y: 700, touched: true, scrollMode: true, timestamp: 0))
        let events = engine.handle(frame: .init(x: 1030, y: 400, touched: true, scrollMode: true, timestamp: 0.01))

        // +30 raw X counts * 0.25 points/count = +7.5 vertically; −300 raw
        // Y counts, inverted, = +75 horizontally.
        XCTAssertEqual(events, [.touchChanged(deltaX: 75, deltaY: 7.5)])

        // Raw X alone moves only the vertical delta.
        let vertical = engine.handle(frame: .init(x: 1060, y: 400, touched: true, scrollMode: true, timestamp: 0.02))
        XCTAssertEqual(vertical, [.touchChanged(deltaX: 0, deltaY: 7.5)])
    }

    /// The "Reverse scrolling" toggle flips the baseline: with it set
    /// (system preference unchanged), the same finger motion produces the
    /// exactly negated deltas of the anchor.
    func testReverseScrollingFlipsTheAnchorBehavior() {
        guard let capabilities = RawTouchCapabilities.parse(reportBytes: Self.go60Report) else {
            XCTFail("Expected the Go60 feature report to parse")
            return
        }

        let engine = TouchScrollEngine(config: engineConfig(capabilities, systemPrefersNatural: false, reversed: true))

        _ = engine.handle(frame: .init(x: 1000, y: 700, touched: true, scrollMode: true, timestamp: 0))
        let events = engine.handle(frame: .init(x: 1030, y: 400, touched: true, scrollMode: true, timestamp: 0.01))

        // Both axes flip.
        XCTAssertEqual(events, [.touchChanged(deltaX: -75, deltaY: -7.5)])
    }

    /// Enabling the system Natural Scrolling preference (reverse toggle
    /// unchanged) produces the same flip: content follows the fingers, so
    /// the anchor motion's deltas come out negated — on both axes, as
    /// macOS flips both for a real trackpad.
    func testSystemNaturalScrollingFlipsTheAnchorBehavior() {
        guard let capabilities = RawTouchCapabilities.parse(reportBytes: Self.go60Report) else {
            XCTFail("Expected the Go60 feature report to parse")
            return
        }

        let engine = TouchScrollEngine(config: engineConfig(capabilities, systemPrefersNatural: true, reversed: false))

        _ = engine.handle(frame: .init(x: 1000, y: 700, touched: true, scrollMode: true, timestamp: 0))
        let events = engine.handle(frame: .init(x: 1030, y: 400, touched: true, scrollMode: true, timestamp: 0.01))

        XCTAssertEqual(events, [.touchChanged(deltaX: -75, deltaY: -7.5)])
    }

    /// The horizontal derivation, the same rule one axis over: horizontal
    /// scrolling reads whichever raw axis vertical does not, and its
    /// old-school sign is `-1` unless x-invert flips it back
    /// (`invertHorizontal == !invertX`). The Go60 (rotate-90 + y-invert, no
    /// x-invert) therefore scrolls horizontally from raw Y, inverted, as
    /// checked on the hardware; pinned so a change is deliberate.
    func testHorizontalOrientationDerivationTable() {
        func derive(rotate90: Bool, invertX: Bool) -> (axis: RawTouchAxis, inverted: Bool) {
            let pad = RawTouchCapabilities.Pad(rotate90: rotate90, invertX: invertX)
            return (pad.horizontalScrollAxis, pad.orientationHorizontalScrollInverted)
        }

        // A non-rotated pad: horizontal from raw X.
        XCTAssertEqual(derive(rotate90: false, invertX: false).axis, .x)
        XCTAssertEqual(derive(rotate90: false, invertX: false).inverted, true)
        XCTAssertEqual(derive(rotate90: false, invertX: true).axis, .x)
        XCTAssertEqual(derive(rotate90: false, invertX: true).inverted, false)

        // Rotated: horizontal from raw Y. The Go60 is the first row.
        XCTAssertEqual(derive(rotate90: true, invertX: false).axis, .y)
        XCTAssertEqual(derive(rotate90: true, invertX: false).inverted, true)
        XCTAssertEqual(derive(rotate90: true, invertX: true).axis, .y)
        XCTAssertEqual(derive(rotate90: true, invertX: true).inverted, false)

        // The Go60 feature report itself.
        guard let capabilities = RawTouchCapabilities.parse(reportBytes: Self.go60Report) else {
            XCTFail("Expected the Go60 feature report to parse")
            return
        }
        XCTAssertEqual(capabilities.primaryPad?.scrollAxis, .x)
        XCTAssertEqual(capabilities.primaryPad?.horizontalScrollAxis, .y)
        XCTAssertEqual(capabilities.primaryPad?.orientationHorizontalScrollInverted, true)
        let go60 = engineConfig(capabilities, systemPrefersNatural: false, reversed: false)
        XCTAssertEqual(go60.axis, .x)
        XCTAssertEqual(go60.horizontalAxis, .y)
        XCTAssertFalse(go60.invert)
        XCTAssertTrue(go60.invertHorizontal)

        // The system preference and the reverse toggle XOR onto the
        // horizontal baseline exactly as they do onto the vertical one.
        for rotate90 in [false, true] {
            for invertX in [false, true] {
                let capabilities = RawTouchCapabilities(rotate90: rotate90, invertX: invertX)
                let baseline = derive(rotate90: rotate90, invertX: invertX).inverted
                for systemPrefersNatural in [false, true] {
                    for reversed in [false, true] {
                        let config = engineConfig(
                            capabilities, systemPrefersNatural: systemPrefersNatural, reversed: reversed)
                        XCTAssertEqual(
                            config.invertHorizontal,
                            (baseline != systemPrefersNatural) != reversed,
                            "rotate90=\(rotate90) invertX=\(invertX) "
                                + "natural=\(systemPrefersNatural) reversed=\(reversed)"
                        )
                        XCTAssertEqual(config.horizontalAxis, config.axis.other)
                    }
                }
            }
        }
    }

    /// The general derivation: rotate-90 moves logical-vertical motion onto
    /// the raw X axis; the old-school engine sign is `-1` unless y-invert
    /// flips it back (`invert == !invertY`), because the devicetree
    /// convention (ZMK input transforms) swaps axes first and then inverts
    /// the post-swap logical axes. The full engine sign layers the system
    /// Natural Scrolling preference and the reverse toggle on top as XORs.
    func testOrientationDerivationTable() {
        func derive(rotate90: Bool, invertY: Bool) -> (axis: RawTouchAxis, inverted: Bool) {
            let pad = RawTouchCapabilities.Pad(rotate90: rotate90, invertY: invertY)
            return (pad.scrollAxis, pad.orientationScrollInverted)
        }

        XCTAssertEqual(derive(rotate90: false, invertY: false).axis, .y)
        XCTAssertEqual(derive(rotate90: false, invertY: false).inverted, true)

        XCTAssertEqual(derive(rotate90: false, invertY: true).axis, .y)
        XCTAssertEqual(derive(rotate90: false, invertY: true).inverted, false)

        XCTAssertEqual(derive(rotate90: true, invertY: false).axis, .x)
        XCTAssertEqual(derive(rotate90: true, invertY: false).inverted, true)

        // The Go60 case (also pinned by testGo60DirectionTruthTable).
        XCTAssertEqual(derive(rotate90: true, invertY: true).axis, .x)
        XCTAssertEqual(derive(rotate90: true, invertY: true).inverted, false)

        // The system preference and the reverse toggle each XOR onto the
        // orientation baseline, for every orientation.
        for rotate90 in [false, true] {
            for invertY in [false, true] {
                let capabilities = RawTouchCapabilities(rotate90: rotate90, invertY: invertY)
                let baseline = derive(rotate90: rotate90, invertY: invertY).inverted
                for systemPrefersNatural in [false, true] {
                    for reversed in [false, true] {
                        XCTAssertEqual(
                            engineConfig(capabilities, systemPrefersNatural: systemPrefersNatural, reversed: reversed)
                                .invert,
                            (baseline != systemPrefersNatural) != reversed,
                            "rotate90=\(rotate90) invertY=\(invertY) "
                                + "natural=\(systemPrefersNatural) reversed=\(reversed)"
                        )
                    }
                }
            }
        }
    }
}
