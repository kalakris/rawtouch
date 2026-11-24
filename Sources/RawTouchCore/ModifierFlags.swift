// MIT License
// Copyright (c) 2026 RawTouch contributors
// Derived from LinearMouse — Copyright (c) 2021-2026 LinearMouse (MIT).
// The flag masks follow LinearMouse's `ModifierState`.

import CoreGraphics
import IOKit.hidsystem

/// Supplies the modifier flags stamped on synthesized scroll events, so
/// Shift-scroll (horizontal) and Command-scroll (zoom) keep working.
///
/// LinearMouse keeps this state warm from its own CGEventTap; RawTouch has
/// no tap (and promises it never will), so the flags are read live from the
/// session state on each posted event (cheap, and never stale). Injectable
/// so tests never touch global state.
public enum ModifierFlagsProvider {
    /// The generic modifier bits plus their left/right device-specific
    /// bits (`NX_DEVICE*KEYMASK`), which some apps use to tell the two Shift
    /// keys apart. Everything else (caps lock, function, numeric pad) is
    /// stripped.
    private static let relevantFlags: CGEventFlags = [
        .maskCommand,
        .maskShift,
        .maskAlternate,
        .maskControl,
        CGEventFlags(
            rawValue: UInt64(
                NX_DEVICELCTLKEYMASK | NX_DEVICERCTLKEYMASK
                    | NX_DEVICELSHIFTKEYMASK | NX_DEVICERSHIFTKEYMASK
                    | NX_DEVICELALTKEYMASK | NX_DEVICERALTKEYMASK
                    | NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK
            )),
    ]

    /// The current session-wide modifier flags, normalized.
    public static func current() -> CGEventFlags {
        CGEventSource.flagsState(.combinedSessionState).intersection(relevantFlags)
    }
}
