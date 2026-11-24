// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import RawTouchCore

/// The menubar icon's four states. When more than one applies, needs
/// attention beats disabled, disabled beats active, and active beats no
/// device: the icon shows the one thing the user most needs to know. The
/// mapping from status to state and from state to SF Symbol both live here
/// so the icon can never disagree with itself.
public enum MenuBarIconState: Equatable {
    /// Device present and lease held — RawTouch mode is live. Quiet,
    /// filled glyph.
    case active

    /// Running and healthy but with no validated device (or the lease
    /// has not landed) — "present but idle". Outline glyph.
    case noDevice

    /// The master switch (`enabled`) is off; the firmware's wheel fallback
    /// is scrolling instead.
    case disabled

    /// Something needs the user: Accessibility missing, firmware without
    /// RawTouch-mode support, a malformed config file, or a Start at Login
    /// change macOS refused. The only state that carries color.
    case needsAttention

    /// The SF Symbol for this state, rendered as a template image except for
    /// `needsAttention`, which is the multicolor warning triangle — a whole
    /// different glyph, not a badge, because `MenuBarExtra` menu-style
    /// labels render simple images far more reliably than composited
    /// overlays. The shape change carries the state on its own, per the
    /// color-is-never-alone rule.
    public var symbolName: String {
        switch self {
        case .active:
            return "rectangle.and.hand.point.up.left.fill"
        case .noDevice:
            return "rectangle.and.hand.point.up.left"
        case .disabled:
            return "rectangle.slash"
        case .needsAttention:
            return "exclamationmark.triangle.fill"
        }
    }

    /// VoiceOver's name for the icon.
    public var accessibilityLabel: String {
        switch self {
        case .active:
            return "RawTouch: scrolling active"
        case .noDevice:
            return "RawTouch: waiting for device"
        case .disabled:
            return "RawTouch: scrolling disabled"
        case .needsAttention:
            return "RawTouch: needs attention"
        }
    }
}

/// What the menubar icon shows: its state, plus the update mark while the
/// menu lists an update. The mark never joins `needsAttention`: that
/// triangle stays alone, because an available update is never more urgent
/// than scrolling that does not work.
public struct MenuBarIcon: Equatable {
    public let state: MenuBarIconState

    /// The menu lists a newer app or firmware release.
    public let updateAvailable: Bool

    public init(state: MenuBarIconState, updateAvailable: Bool) {
        self.state = state
        self.updateAvailable = updateAvailable
    }

    /// The glyph carries the update mark.
    public var showsUpdateMark: Bool {
        updateAvailable && state != .needsAttention
    }

    /// VoiceOver's name for the icon, and its tooltip. Names an available
    /// update in every state, the attention state included, after the state
    /// itself.
    public var accessibilityLabel: String {
        updateAvailable ? state.accessibilityLabel + ", update available" : state.accessibilityLabel
    }
}

/// Derives the icon state from a status snapshot plus the two conditions the
/// snapshot cannot know about (Accessibility trust and firmware without
/// RawTouch-mode support).
///
/// Precedence: attention beats everything (a problem must be visible even
/// while disabled), disabled beats connection state (the user asked for
/// silence; reporting "active" would be a lie), and active requires both a
/// device and a held lease — a present device without a lease still
/// reads as waiting.
public func iconState(
    for status: RawTouchStatus,
    axTrusted: Bool,
    leaseUnsupported: Bool,
    loginItemFailed: Bool = false
) -> MenuBarIconState {
    if !axTrusted || leaseUnsupported || status.configError != nil || loginItemFailed {
        return .needsAttention
    }
    if !status.enabled {
        return .disabled
    }
    if status.deviceName != nil, status.leaseHeld {
        return .active
    }
    return .noDevice
}
