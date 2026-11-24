// MIT License
// Copyright (c) 2026 RawTouch contributors

import AppKit
import RawTouchAppCore
import SwiftUI

/// The settings window: three toolbar tabs, each one screen, over the same
/// `config.json` a headless user hand-edits. Every control routes through
/// `AppModel.updateConfig`, so an edit applies to the live manager
/// immediately and reaches the file on the model's save debounce.
///
/// - **Scrolling** — what the finger does: gain, direction, and all of
///   momentum (how far a flick coasts, and the flick sensitivity that
///   decides what counts as a flick). The tab a user opens to tune feel.
/// - **Advanced** — the acceleration curve and display sync: the knobs
///   behind the feel, with their config keys in tooltips; and the one app
///   behaviour that is a setting, the automatic update check.
/// - **Keyboards** — one keyboard at a time (a keyboard on USB and
///   Bluetooth is one keyboard, with one set of settings): its status, its
///   own switch, its hardware id, and one section per pad. A pad's
///   orientation and axis overrides sit behind a disclosure that opens by
///   itself only when something in it is set.
///
/// Scrolling and Advanced restore their own defaults with one confirmed
/// button; Keyboards removes the selected keyboard's settings instead.
/// ⌘1 / ⌘2 / ⌘3 switch tabs, as everywhere in System Settings.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var tab = Tab.scrolling

    enum Tab: Int, CaseIterable, Hashable {
        case scrolling
        case advanced
        case keyboards

        var shortcut: KeyEquivalent {
            KeyEquivalent(Character("\(rawValue + 1)"))
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            ScrollingTab(model: model)
                .tabItem {
                    Label("Scrolling", systemImage: "hand.draw")
                        .accessibilityAddTraits(tab == .scrolling ? .isSelected : [])
                }
                .tag(Tab.scrolling)
            AdvancedTab(model: model)
                .tabItem {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                        .accessibilityAddTraits(tab == .advanced ? .isSelected : [])
                }
                .tag(Tab.advanced)
            KeyboardsTab(model: model)
                .tabItem {
                    Label("Keyboards", systemImage: "keyboard")
                        .accessibilityAddTraits(tab == .keyboards ? .isSelected : [])
                }
                .tag(Tab.keyboards)
        }
        .frame(width: 480)
        .background(tabShortcuts)
        .onAppear {
            dropInitialFocus()
            // Every opening starts the Keyboards tab on the keyboard just
            // used; from there on it moves only when the user moves it.
            model.seedKeyboardsSelection()
        }
    }

    /// ⌘1 / ⌘2 / ⌘3, the System Settings convention. `TabView` has no API
    /// for them, so they ride on invisible buttons in the window's own
    /// hierarchy — which is all a keyboard shortcut needs.
    ///
    /// Explicitly unfocusable, and not hit-testable: a focusable control in
    /// the window changes which view AppKit picks as its initial first
    /// responder, and it would pick the gain field — the window would open
    /// with a tuned number selected, one keystroke from being overwritten.
    /// A key equivalent needs neither focus nor a mouse.
    private var tabShortcuts: some View {
        ForEach(Tab.allCases, id: \.self) { tab in
            Button("") {
                self.tab = tab
            }
            .keyboardShortcut(tab.shortcut, modifiers: .command)
        }
        .focusable(false)
        .allowsHitTesting(false)
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// AppKit hands key focus to the first text field in a freshly opened
    /// window, which selects the gain's value: the window then opens "in
    /// edit mode" and a stray keystroke rewrites a tuned number. Settings
    /// are read far more often than typed into, so start with nothing
    /// focused; Tab still reaches every control.
    ///
    /// Every visible window of ours, not just the key one: this runs as the
    /// first tab appears, which can be a moment before the settings window
    /// becomes key, and a `keyWindow` that is still nil then would leave the
    /// field selected.
    private func dropInitialFocus() {
        DispatchQueue.main.async {
            for window in NSApp.windows where window.isVisible {
                window.makeFirstResponder(nil)
            }
        }
    }
}
