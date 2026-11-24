// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchCore
import RawTouchTestSupport
import XCTest

@testable import RawTouchAppCore

/// The icon-state precedence: attention beats disabled beats active beats
/// no-device.
final class MenuBarIconStateTests: XCTestCase {
    private let healthy = RawTouchStatus(
        enabled: true,
        endpoints: [.keyboard(lease: .held)]
    )

    // MARK: - Attention outranks everything

    func testMissingAccessibilityIsAttentionEvenWhenOtherwiseActive() {
        XCTAssertEqual(iconState(for: healthy, axTrusted: false, leaseUnsupported: false), .needsAttention)
    }

    func testFirmwareWithoutLeaseSupportIsAttention() {
        XCTAssertEqual(iconState(for: healthy, axTrusted: true, leaseUnsupported: true), .needsAttention)
    }

    func testConfigErrorIsAttention() {
        var status = healthy
        status.configError = .unreadable("bad JSON")
        XCTAssertEqual(iconState(for: status, axTrusted: true, leaseUnsupported: false), .needsAttention)
    }

    func testAttentionOutranksDisabled() {
        let status = RawTouchStatus(enabled: false)
        XCTAssertEqual(iconState(for: status, axTrusted: false, leaseUnsupported: false), .needsAttention)
    }

    // MARK: - Disabled outranks connection state

    func testDisabledWithDevicePresentIsDisabled() {
        var status = healthy
        status.enabled = false
        status.endpoints[0].lease = .notWanted
        XCTAssertEqual(iconState(for: status, axTrusted: true, leaseUnsupported: false), .disabled)
    }

    func testDisabledWithNoDeviceIsDisabled() {
        let status = RawTouchStatus(enabled: false)
        XCTAssertEqual(iconState(for: status, axTrusted: true, leaseUnsupported: false), .disabled)
    }

    // MARK: - Active requires device and lease

    func testDeviceWithHeldLeaseIsActive() {
        XCTAssertEqual(iconState(for: healthy, axTrusted: true, leaseUnsupported: false), .active)
    }

    func testDeviceWithoutHeldLeaseIsNoDevice() {
        var status = healthy
        status.endpoints[0].lease = .pending
        XCTAssertEqual(iconState(for: status, axTrusted: true, leaseUnsupported: false), .noDevice)
    }

    func testNoDeviceIsNoDevice() {
        XCTAssertEqual(iconState(for: RawTouchStatus(), axTrusted: true, leaseUnsupported: false), .noDevice)
    }

    // MARK: - Symbol mapping

    func testEveryStateHasADistinctSymbol() {
        let states: [MenuBarIconState] = [.active, .noDevice, .disabled, .needsAttention]
        XCTAssertEqual(Set(states.map(\.symbolName)).count, states.count)
        XCTAssertEqual(Set(states.map(\.accessibilityLabel)).count, states.count)
    }

    func testActiveAndNoDeviceShareTheBaseGlyph() {
        // "Present but idle" is the same glyph, outline instead of fill.
        XCTAssertEqual(MenuBarIconState.active.symbolName, "rectangle.and.hand.point.up.left.fill")
        XCTAssertEqual(MenuBarIconState.noDevice.symbolName, "rectangle.and.hand.point.up.left")
    }

    // MARK: - Update mark

    func testUpdateMarksEveryStateButAttention() {
        for state in [MenuBarIconState.active, .noDevice, .disabled] {
            XCTAssertTrue(MenuBarIcon(state: state, updateAvailable: true).showsUpdateMark, "\(state)")
            XCTAssertFalse(MenuBarIcon(state: state, updateAvailable: false).showsUpdateMark, "\(state)")
        }
    }

    func testAttentionWinsOverAnUpdate() {
        let icon = MenuBarIcon(
            state: iconState(for: healthy, axTrusted: false, leaseUnsupported: false),
            updateAvailable: true
        )
        XCTAssertEqual(icon.state, .needsAttention)
        XCTAssertFalse(icon.showsUpdateMark)
    }

    func testAccessibilityLabelNamesAnUpdate() {
        XCTAssertEqual(
            MenuBarIcon(state: .active, updateAvailable: true).accessibilityLabel,
            "RawTouch: scrolling active, update available"
        )
        XCTAssertEqual(
            MenuBarIcon(state: .active, updateAvailable: false).accessibilityLabel,
            "RawTouch: scrolling active"
        )
    }

    func testAttentionLabelNamesTheProblemFirstAndStillTheUpdate() {
        XCTAssertEqual(
            MenuBarIcon(state: .needsAttention, updateAvailable: true).accessibilityLabel,
            "RawTouch: needs attention, update available"
        )
    }

    func testLoginItemFailureNeedsAttention() {
        let healthy = RawTouchStatus(endpoints: [.keyboard(lease: .held)])
        XCTAssertEqual(
            iconState(for: healthy, axTrusted: true, leaseUnsupported: false, loginItemFailed: true), .needsAttention)
    }
}
