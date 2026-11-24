// MIT License
// Copyright (c) 2026 RawTouch contributors

import AppKit
import RawTouchAppCore
import SwiftUI

/// The menubar menu. Top block: status as disabled items (plain `Text`
/// renders exactly that in a `MenuBarExtra` menu) — one line per keyboard
/// with its mode, activity while non-idle, and the attention reason when
/// there is one ("Grant Accessibility…" when that is the reason), then any
/// update on offer. Bottom block: the actions — "Use RawTouch Scrolling",
/// "Start at Login", "About RawTouch", "Check for Updates…", "Settings… ⌘,"
/// and "Quit RawTouch ⌘Q".
struct MenuContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let status = model.status
        // One line per keyboard — a keyboard on USB and Bluetooth is one
        // thing with two connections, and says so in one line unless they
        // disagree.
        ForEach(StatusFormatter.keyboardLines(for: model.settingsKeyboards), id: \.self) { line in
            Text(line)
        }

        if let activity = StatusFormatter.activityLine(
            for: status, keyboards: model.settingsKeyboards, configuration: model.config)
        {
            Text(activity)
        }

        if let attention = StatusFormatter.attentionLine(
            axTrusted: model.axTrusted,
            leaseUnsupportedProductName: model.leaseUnsupportedProductName,
            configError: status.configError,
            loginItemError: model.loginItemError
        ) {
            Text(attention)
        }

        if !model.axTrusted {
            // Onboarding shortcut: the window that explains the grant and
            // deep-links to System Settings.
            Button("Grant Accessibility…") {
                present(WindowID.onboarding, using: openWindow)
            }
        }

        // Notify-only: each opens the release's page in the browser, where
        // the release notes say what changed and how to install it.
        ForEach(model.updateNotices, id: \.self) { notice in
            Button(notice.menuTitle) {
                NSWorkspace.shared.open(notice.release.url)
            }
        }

        Divider()

        // Flipping this off releases the lease; the keyboard returns to
        // Standard mode — and keeps scrolling on its own, so the switch
        // names what actually stops (RawTouch's scrolling), the way the
        // Keyboards tab's "Use RawTouch with this keyboard" does. A
        // verb phrase, like the system's own menu toggles ("Show Battery
        // Percentage"), not a state noun.
        Toggle("Use RawTouch Scrolling", isOn: model.binding(\.enabled))

        Toggle(
            "Start at Login",
            isOn: Binding(
                get: { model.startAtLogin },
                set: { model.setStartAtLogin($0) }
            ))

        // Where an app menu keeps it: above Settings…, with no keyboard
        // equivalent. It opens the system panel, so the item's title is the
        // whole label VoiceOver needs.
        Button("About RawTouch") {
            showAbout()
        }

        // Below About, where apps that check for updates put it. The menu
        // closes on the click, so the answer is an alert; while it is on
        // its way the item says so, should the menu be reopened.
        Button(model.isCheckingForUpdates ? "Checking for Updates\u{2026}" : "Check for Updates\u{2026}") {
            model.checkForUpdates(then: showUpdateCheckReport)
        }
        .disabled(model.isCheckingForUpdates)

        if #available(macOS 14, *) {
            SettingsMenuItem()
        } else {
            Button("Settings…") {
                showSettingsLegacy()
            }
            .keyboardShortcut(",")
        }

        Divider()

        Button("Quit RawTouch") {
            // Release the lease before dying so the keyboard returns
            // to Standard mode immediately, not after the lease times out.
            model.shutdownForQuit()
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
