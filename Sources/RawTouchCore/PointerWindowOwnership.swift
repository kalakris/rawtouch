// MIT License
// Copyright (c) 2026 RawTouch contributors

import CoreGraphics
import Foundation

/// Whether the window the pointer is over belongs to this process.
///
/// RawTouch's own Settings window is where a user tunes scroll feel, and
/// tuning means flicking the pad while looking at the readout — which
/// would scroll the settings form out from under them. A gesture that
/// starts over our own window posts nothing; the readout still measures it.
///
/// A protocol so the poster can be driven without a window server.
public protocol PointerWindowOwnership {
    /// Answered once per gesture, at touch-down — never per frame.
    func pointerIsOverOwnWindow() -> Bool
}

/// The real check: is the frontmost *ordinary* window under the pointer one
/// of ours?
///
/// `CGWindowListCopyWindowInfo` returns windows front to back, so the first
/// hit is the one the pointer is over. Bounds, owner pid and layer come
/// back without any permission (the window *names* are what Screen
/// Recording protects, and nothing here reads them).
///
/// Two filters matter. **Layer**: only ordinary windows (layer 0) count, so
/// a pointer parked in the menu bar — over our own status item, which lives
/// far above that — does not suppress a gesture; the menu bar is exactly
/// where a pointer sits while someone uses the keyboard. **Ownership
/// first**: if this process has no ordinary window on screen at all, the
/// answer is no before the pointer is even consulted, which is every touch
/// while Settings is closed.
public struct CGWindowPointerOwnership: PointerWindowOwnership {
    /// The window layer an ordinary document/settings window sits on.
    /// Panels, menus and status items are all above it.
    static let ordinaryWindowLayer = 0

    private let pointerLocation: () -> CGPoint?
    private let windowList: () -> [[String: Any]]
    private let processID: pid_t

    public init(
        pointerLocation: @escaping () -> CGPoint? = { CGEvent(source: nil)?.location },
        windowList: @escaping () -> [[String: Any]] = {
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
        },
        processID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        self.pointerLocation = pointerLocation
        self.windowList = windowList
        self.processID = processID
    }

    public func pointerIsOverOwnWindow() -> Bool {
        let ordinary = windowList().filter {
            $0[kCGWindowLayer as String] as? Int == Self.ordinaryWindowLayer
                && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0
                && (bounds(of: $0)?.isEmpty == false)
        }
        // Nothing of ours is on screen: no window to scroll by accident,
        // and no reason to ask where the pointer is.
        guard ordinary.contains(where: { $0[kCGWindowOwnerPID as String] as? pid_t == processID }),
            let point = pointerLocation()
        else {
            return false
        }
        // Front to back: the first window containing the pointer is the one
        // a scroll event would land in.
        let hit = ordinary.first { bounds(of: $0)?.contains(point) == true }
        return hit?[kCGWindowOwnerPID as String] as? pid_t == processID
    }

    private func bounds(of window: [String: Any]) -> CGRect? {
        (window[kCGWindowBounds as String] as? [String: Any])
            .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
    }
}
