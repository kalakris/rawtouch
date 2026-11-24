// MIT License
// Copyright (c) 2026 RawTouch contributors

import XCTest

@testable import RawTouchCore

/// The `kIOHIDTransportKey` mapping. It is a display-ish string from
/// macOS, not an identifier, so the match is deliberately lenient about
/// case — and deliberately strict about everything it does not know.
final class RawTouchTransportTests: XCTestCase {
    func testUSBAndBluetoothSpellingsMap() {
        XCTAssertEqual(RawTouchTransport(hidTransport: "USB"), .usb)
        XCTAssertEqual(RawTouchTransport(hidTransport: "usb"), .usb)
        XCTAssertEqual(RawTouchTransport(hidTransport: "Bluetooth"), .bluetooth)
        XCTAssertEqual(RawTouchTransport(hidTransport: "Bluetooth Low Energy"), .bluetooth)
    }

    /// A transport nobody has seen yet must not be guessed at: unknown
    /// takes the USB latency, which adds no lag.
    func testAnythingElseIsUnknown() {
        XCTAssertEqual(RawTouchTransport(hidTransport: nil), .unknown)
        XCTAssertEqual(RawTouchTransport(hidTransport: ""), .unknown)
        XCTAssertEqual(RawTouchTransport(hidTransport: "SPI"), .unknown)
    }

    func testOnlyNamedTransportsHaveADisplayName() {
        XCTAssertEqual(RawTouchTransport.usb.displayName, "USB")
        XCTAssertEqual(RawTouchTransport.bluetooth.displayName, "Bluetooth")
        XCTAssertNil(RawTouchTransport.unknown.displayName)
    }
}
