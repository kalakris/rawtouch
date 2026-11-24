// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchTestSupport
import XCTest

@testable import RawTouchCore

/// The one rule for report-ID framing, exercised directly: both transports
/// (USB prefixes the ID, Bluetooth does not), both report types (fixed-length
/// input frames and the variable-length feature report), and the rejections.
final class ReportFramingTests: XCTestCase {
    private let reportID = UInt8(0x04)
    private let frameLength = RawTouchFrame.payloadLength  // 11

    // MARK: - Fixed-length input reports

    /// Bluetooth: the payload arrives bare, exactly the contract length.
    func testBareInputReportStartsAtZero() {
        XCTAssertEqual(
            ReportFraming.payloadOffset(
                bufferLength: frameLength,
                firstByte: 0x00,
                reportID: reportID,
                payloadLength: frameLength
            ),
            0
        )
    }

    /// USB: one byte longer, and that byte is the report ID.
    func testPrefixedInputReportStartsAtOne() {
        XCTAssertEqual(
            ReportFraming.payloadOffset(
                bufferLength: frameLength + 1,
                firstByte: reportID,
                reportID: reportID,
                payloadLength: frameLength
            ),
            1
        )
    }

    /// A bare payload whose own first byte happens to equal the report ID
    /// (pad_id 4) must not be mistaken for a prefixed one: the exact length
    /// decides first.
    func testAnExactLengthBufferIsBareEvenWhenItStartsWithTheReportID() {
        XCTAssertEqual(
            ReportFraming.payloadOffset(
                bufferLength: frameLength,
                firstByte: reportID,
                reportID: reportID,
                payloadLength: frameLength
            ),
            0
        )
    }

    /// Wrong ID: a longer buffer that does not start with the report ID is a
    /// bare payload with trailing padding, never a prefixed one.
    func testALongerBufferWithTheWrongLeadingByteIsReadAsBare() {
        XCTAssertEqual(
            ReportFraming.payloadOffset(
                bufferLength: frameLength + 1,
                firstByte: 0x09,  // ZMK's mouse report ID, say
                reportID: reportID,
                payloadLength: frameLength
            ),
            0
        )
    }

    func testPaddedPrefixedBufferStillStartsAtOne() {
        XCTAssertEqual(
            ReportFraming.payloadOffset(
                bufferLength: frameLength + 4,
                firstByte: reportID,
                reportID: reportID,
                payloadLength: frameLength
            ),
            1
        )
    }

    func testShortBuffersHaveNoPayload() {
        for length in 0...(frameLength - 1) {
            XCTAssertNil(
                ReportFraming.payloadOffset(
                    bufferLength: length,
                    firstByte: length > 0 ? reportID : nil,
                    reportID: reportID,
                    payloadLength: frameLength
                ),
                "\(length) bytes cannot hold an \(frameLength)-byte payload"
            )
        }
        // Even prefixed, the ID byte does not make up the difference.
        XCTAssertNil(
            ReportFraming.payloadOffset(
                bufferLength: frameLength,
                firstByte: reportID,
                reportID: reportID,
                payloadLength: frameLength + 1
            )
        )
    }

    /// The framing rule, end to end through the frame parser: the same
    /// payload parses to the same frame bare and prefixed.
    func testBothFramingsParseToTheSameFrame() {
        let payload = v3FrameBytes(pad: 1, x: 1234, y: 567, seq: 9, timestampTicks: 4242)
        let prefixed = [reportID] + payload

        func parse(_ bytes: [UInt8]) -> RawTouchFrame? {
            guard
                let offset = ReportFraming.payloadOffset(
                    bufferLength: bytes.count,
                    firstByte: bytes.first,
                    reportID: reportID,
                    payloadLength: frameLength
                )
            else {
                return nil
            }
            return bytes.withUnsafeBytes {
                RawTouchFrame(reportBytes: $0, offset: offset, timestamp: 1)
            }
        }

        XCTAssertEqual(parse(payload), parse(prefixed))
        XCTAssertEqual(parse(payload)?.padID, 1)
        XCTAssertEqual(parse(payload)?.x, 1234)
    }

    // MARK: - Variable-length feature reports

    func testCandidatesForABareBufferAreJustTheBuffer() {
        let bare: [UInt8] = [0x03, 0x01, 0x01, 0x00]
        XCTAssertEqual(ReportFraming.payloadCandidates(bare, reportID: reportID), [bare])
    }

    /// A buffer that starts with the report ID could be either: the bare
    /// reading is offered first, the stripped one second.
    func testCandidatesForAPrefixedBufferOfferBareFirst() {
        let body: [UInt8] = [0x03, 0x01, 0x01, 0x00]
        let prefixed = [reportID] + body
        XCTAssertEqual(ReportFraming.payloadCandidates(prefixed, reportID: reportID), [prefixed, body])
    }

    func testCandidatesForAnEmptyBufferAreTheEmptyBuffer() {
        XCTAssertEqual(ReportFraming.payloadCandidates([], reportID: reportID), [[]])
    }

}
