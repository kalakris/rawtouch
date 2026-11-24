// MIT License
// Copyright (c) 2026 RawTouch contributors

import CoreGraphics

/// Where the cursor is and how dense that display is — the two facts that
/// turn a dimensionless scroll gain into screen points per pad count.
///
/// Gain 1.0 means physical 1:1: a millimetre of finger travel on the pad
/// moves content a millimetre on screen. That is a property of the display,
/// not of the configuration — a 5K 27" panel and a 1080p 27" one differ by
/// a factor of two in points per millimetre — so the pipeline resolves the
/// density at every touch-down rather than once at startup.
///
/// Both lookups go through CoreGraphics (not AppKit) because the pipeline
/// runs on its own event thread, where `NSScreen` is off limits.
public enum DisplayGeometry {
    /// Points per millimetre assumed when no display will say.
    /// `CGDisplayScreenSize` returns 0 for virtual displays and for
    /// externals with an unusable EDID; 4.3 pt/mm is what real panels
    /// report at their default scaled resolution (a 16" MacBook Pro and a
    /// 27" 1440p external both measure ≈4.3).
    public static let fallbackPointsPerMM = 4.3

    /// The display containing the cursor, or the main display when the
    /// cursor is on none (mid-switch, or a headless moment). Read through
    /// CoreGraphics rather than `NSEvent.mouseLocation` so it works off the
    /// main thread.
    public static func displayUnderCursor() -> CGDirectDisplayID {
        guard let location = CGEvent(source: nil)?.location else {
            return CGMainDisplayID()
        }
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        let result = CGGetDisplaysWithPoint(location, 1, &displayID, &count)
        guard result == .success, count > 0 else {
            return CGMainDisplayID()
        }
        return displayID
    }

    /// Screen points per millimetre of a display: its bounds (points, the
    /// same units scroll deltas are in — so this already accounts for a
    /// scaled "looks like" resolution) over its physical width in
    /// millimetres.
    ///
    /// A display that reports no size (a virtual one, an external with an
    /// unusable EDID) borrows the main display's answer before the constant
    /// does: a second panel on the same desk is a far better guess about
    /// what a millimetre means there than any number compiled in.
    public static func pointsPerMM(of displayID: CGDirectDisplayID) -> Double {
        reportedPointsPerMM(of: displayID)
            ?? reportedPointsPerMM(of: CGMainDisplayID())
            ?? fallbackPointsPerMM
    }

    /// What a display says about itself, or nil when it says nothing
    /// usable.
    private static func reportedPointsPerMM(of displayID: CGDirectDisplayID) -> Double? {
        let widthPoints = Double(CGDisplayBounds(displayID).width)
        let widthMM = CGDisplayScreenSize(displayID).width
        guard widthPoints > 0, widthMM > 0 else {
            return nil
        }
        return widthPoints / widthMM
    }

    /// The density of the display the cursor is on — the pipeline's default
    /// provider.
    public static func pointsPerMMUnderCursor() -> Double {
        pointsPerMM(of: displayUnderCursor())
    }
}
