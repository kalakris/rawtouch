// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import RawTouchCore

// MARK: - Which keyboards the settings window shows

extension AppModel {
    /// Device keys the configuration carries settings for that belong to no
    /// connected keyboard — one that is unplugged right now, or one whose
    /// key changed (a settings reset on the keyboard side). Shown so they
    /// can be removed; never silently dropped.
    public var disconnectedDeviceKeys: [String] {
        let connected = Set(status.endpoints.compactMap(\.deviceKey))
        return config.devices.keys.filter { !connected.contains($0) }.sorted()
    }

    /// The keyboard the last scroll gesture came from, while it is still
    /// connected: what the Keyboards tab opens on, so the keyboard you just
    /// used is the one whose settings are up. Read when the window opens
    /// (`seedKeyboardsSelection`) — a picker that moved under the user while
    /// they were setting something would be worse than a stale one.
    public var lastScrolledKeyboardID: RawTouchKeyboard.ID? {
        guard let endpoint = status.lastGesture?.endpoint else {
            return nil
        }
        return settingsKeyboards.first { $0.endpoints.contains { $0.id == endpoint } }?.id
    }

    /// Points the Keyboards tab at the keyboard that last scrolled (else
    /// the first there is: `KeyboardsTabSelection.initial`). Called as the
    /// settings window opens, so every opening starts on the keyboard just
    /// used.
    public func seedKeyboardsSelection() {
        keyboardsSelection = KeyboardsTabSelection.initial(
            keyboards: settingsKeyboards,
            savedKeys: disconnectedDeviceKeys,
            lastScrolled: lastScrolledKeyboardID
        )
    }

    /// What the Keyboards tab shows: the pick while it still names
    /// something, else the opening choice again (the picked keyboard was
    /// unplugged).
    public var resolvedKeyboardsSelection: KeyboardsTabSelection? {
        KeyboardsTabSelection.resolve(
            picked: keyboardsSelection,
            keyboards: settingsKeyboards,
            savedKeys: disconnectedDeviceKeys,
            lastScrolled: lastScrolledKeyboardID
        )
    }

    /// The connected keyboard the Keyboards tab is showing, if it is
    /// showing one.
    public var selectedKeyboard: RawTouchKeyboard? {
        guard case .keyboard(let id)? = resolvedKeyboardsSelection else {
            return nil
        }
        return settingsKeyboards.first { $0.id == id }
    }

    /// The keyboards whose latency the Advanced tab reports: the selected
    /// one while more than one is connected, all of them otherwise (which
    /// is one, or none).
    public var latencyKeyboards: [RawTouchKeyboard] {
        let keyboards = settingsKeyboards
        guard keyboards.count > 1, let selected = selectedKeyboard else {
            return keyboards
        }
        return [selected]
    }
}
