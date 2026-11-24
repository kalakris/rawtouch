// MIT License
// Copyright (c) 2026 RawTouch contributors

import CoreGraphics
import XCTest

@testable import RawTouchCore

/// Whether a gesture lands in one of RawTouch's own windows, decided from
/// an injected window list — no window server, no pointer, no AppKit.
final class PointerWindowOwnershipTests: XCTestCase {
    private let ours: pid_t = 501
    private let theirs: pid_t = 777

    private func window(
        pid: pid_t,
        x: CGFloat = 100,
        y: CGFloat = 200,
        width: CGFloat = 480,
        height: CGFloat = 600,
        layer: Int = 0,
        alpha: Double = 1
    ) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: [
                "X": x, "Y": y, "Width": width, "Height": height,
            ] as [String: Any],
        ]
    }

    private func ownership(
        _ windows: [[String: Any]],
        pointer: CGPoint? = CGPoint(x: 200, y: 300),
        listCalls: (() -> Void)? = nil,
        pointerCalls: (() -> Void)? = nil
    ) -> CGWindowPointerOwnership {
        CGWindowPointerOwnership(
            pointerLocation: {
                pointerCalls?()
                return pointer
            },
            windowList: {
                listCalls?()
                return windows
            },
            processID: ours
        )
    }

    func testAPointerOverOurOwnWindowIsOurs() {
        XCTAssertTrue(ownership([window(pid: ours)]).pointerIsOverOwnWindow())
    }

    /// Front to back: another app's window over ours takes the scroll.
    func testAWindowInFrontOfOursTakesIt() {
        XCTAssertFalse(ownership([window(pid: theirs), window(pid: ours)]).pointerIsOverOwnWindow())
        XCTAssertTrue(ownership([window(pid: ours), window(pid: theirs)]).pointerIsOverOwnWindow())
    }

    func testAPointerBesideOurWindowIsNotOurs() {
        XCTAssertFalse(ownership([window(pid: ours)], pointer: CGPoint(x: 900, y: 300)).pointerIsOverOwnWindow())
    }

    /// The menu bar is where a pointer sits while someone types. Our status
    /// item lives there, far above the ordinary window layer, and must
    /// never suppress a gesture.
    func testOurMenuBarStatusItemDoesNotCount() {
        let statusItem = window(pid: ours, x: 1200, y: 0, width: 30, height: 24, layer: 25)
        let ownership = ownership([statusItem], pointer: CGPoint(x: 1210, y: 10))
        XCTAssertFalse(ownership.pointerIsOverOwnWindow())
    }

    /// With no ordinary window of its own on screen — which is RawTouch
    /// whenever Settings is closed — the answer comes without even asking
    /// where the pointer is.
    func testWithoutOurOwnWindowThePointerIsNeverConsulted() {
        var pointerAsks = 0
        let ownership = ownership(
            [window(pid: theirs), window(pid: ours, layer: 25)],
            pointerCalls: { pointerAsks += 1 }
        )
        XCTAssertFalse(ownership.pointerIsOverOwnWindow())
        XCTAssertEqual(pointerAsks, 0)
    }

    /// A zero-sized or fully transparent window is not something the user
    /// is looking at, whoever owns it.
    func testEmptyAndInvisibleWindowsAreIgnored() {
        XCTAssertFalse(ownership([window(pid: ours, width: 0, height: 0)]).pointerIsOverOwnWindow())
        XCTAssertFalse(ownership([window(pid: ours, alpha: 0)]).pointerIsOverOwnWindow())
    }
}
