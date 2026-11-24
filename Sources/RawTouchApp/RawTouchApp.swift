// MIT License
// Copyright (c) 2026 RawTouch contributors

import AppKit
import RawTouchAppCore
import RawTouchCore
import SwiftUI

/// The one model instance, shared between the SwiftUI scenes and the app
/// delegate (the delegate needs it before any view exists).
enum AppEnvironment {
    static let model = AppModel()
}

/// Scene identifiers for `openWindow`.
enum WindowID {
    static let onboarding = "onboarding"
}

/// Activates the app and opens a scene window. An `.accessory` app is never
/// frontmost, so without the activation the window opens behind whatever the
/// user is working in.
func present(_ id: String, using openWindow: OpenWindowAction) {
    openWindow(id: id)
    NSApp.activate(ignoringOtherApps: true)
}

/// Opens the Settings scene on macOS 13, where `openSettings` does not
/// exist yet: SwiftUI still builds the (invisible, for an accessory app)
/// main menu with the app menu's "Settings…" item, so find that item and
/// perform its own action, whatever selector it carries this release.
/// Activated first: an `.accessory` app is never frontmost, and the window
/// would otherwise open behind whatever the user is working in. On 14+
/// the menu uses `SettingsMenuItem` instead.
func showSettingsLegacy() {
    NSApp.activate(ignoringOtherApps: true)
    let appMenu = NSApp.mainMenu?.items.first?.submenu
    if let item = appMenu?.items.first(where: { $0.title.hasPrefix("Settings") && $0.action != nil }),
        let action = item.action
    {
        NSApp.sendAction(action, to: item.target, from: item)
    } else {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}

/// Opens the system About panel — the stock one, nothing custom in it.
/// Activated first for the same reason the Settings window is: an
/// `.accessory` app is never frontmost, so the panel would otherwise open
/// behind whatever the user is working in. The bundle supplies the name,
/// icon, version and copyright; the credits add the two facts a user of
/// this app wants from an About panel — which protocol the host speaks and
/// where the documentation is — plus the commit, when the build records one.
func showAbout() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [.credits: aboutCredits()])
}

/// The answer to "Check for Updates…". Activated first, like every window
/// this app opens: an `.accessory` app is never frontmost, and the alert
/// would otherwise open behind whatever the user is working in. An alert
/// that only informs has one button, OK; one that found updates offers
/// their release pages, or Not Now.
func showUpdateCheckReport(_ report: UpdateCheckReport) {
    let alert = NSAlert()
    alert.messageText = report.title
    alert.informativeText = report.message
    if report.releasePages.isEmpty {
        alert.addButton(withTitle: "OK")
    } else {
        alert.addButton(withTitle: report.viewButtonTitle)
        alert.addButton(withTitle: "Not Now")
    }
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else {
        return
    }
    for page in report.releasePages {
        NSWorkspace.shared.open(page)
    }
}

/// The About panel's credits: `AppVersion`'s lines in the system font, with
/// the documentation line as a link. No styling beyond that.
private func aboutCredits() -> NSAttributedString {
    let lines = AppVersion.current
        .creditLines(protocolVersion: RawTouchCapabilities.protocolVersion)

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let credits = NSMutableAttributedString(
        string: lines.joined(separator: "\n"),
        attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
    )
    let link = (credits.string as NSString).range(of: AppVersion.readmeLinkText)
    if link.location != NSNotFound {
        credits.addAttribute(.link, value: AppVersion.readmeURL, range: link)
    }
    return credits
}

/// The menu's "Settings…" item on macOS 14+, where the environment
/// provides the action that opens the Settings scene.
@available(macOS 14, *)
struct SettingsMenuItem: View {
    var body: some View {
        OpenSettingsButton(title: "Settings…")
            .keyboardShortcut(",")
    }
}

/// A button that opens the Settings scene on macOS 14+, then runs `then`
/// (onboarding closes its own window with it). On 13 the same job is
/// `showSettingsLegacy()`.
@available(macOS 14, *)
struct OpenSettingsButton: View {
    let title: String
    var then: () -> Void = {}
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(title) {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
            then()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Sends SIGTERM/SIGINT/SIGHUP through `NSApp.terminate`, which ends in
    /// `applicationWillTerminate` and so releases the lease like Quit does.
    private let terminationSignals = TerminationSignals { NSApp.terminate(nil) }

    func applicationDidFinishLaunching(_: Notification) {
        terminationSignals.install()

        // Safety net alongside LSUIElement: no Dock icon, no app menu, even
        // when the bare executable is run outside its bundle.
        NSApp.setActivationPolicy(.accessory)

        let model = AppEnvironment.model
        guard model.start() else {
            // Without the single-instance lock two copies could
            // double-scroll, so explain why it could not be had and bow out.
            let alert = NSAlert()
            alert.alertStyle = .critical
            switch model.startFailure {
            case .alreadyRunning(let holderPID)?:
                alert.messageText = "RawTouch is already running"
                let holder = holderPID.map { " (pid \($0))" } ?? ""
                alert.informativeText = """
                    Another copy of RawTouch\(holder) is already scrolling. Quit it from its menu bar icon, \
                    then reopen this one.
                    """
            case .lockUnavailable(let reason)?:
                alert.messageText = "RawTouch can\u{2019}t start"
                alert.informativeText = """
                    \(reason). RawTouch needs that file to make sure only one copy of it scrolls. \
                    Check who owns ~/.config/rawtouch, then reopen RawTouch.
                    """
            case nil:
                // `start()` records a reason whenever it returns false.
                break
            }
            alert.addButton(withTitle: "Quit")
            // Activated first, like every window this app opens: an
            // `.accessory` app is never frontmost, and the alert would
            // otherwise open behind whatever the user is working in.
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        // Onboarding: without Accessibility nothing scrolls, so the
        // explainer opens when that is news (`openOnboardingAtLaunchIfNeeded`).
        // After "Not Now" the icon and the menu's "Grant Accessibility…"
        // keep the way back at every launch. The menubar label view
        // observes the flag this sets (only views can reach openWindow).
        model.openOnboardingAtLaunchIfNeeded()
    }

    func applicationWillTerminate(_: Notification) {
        // Covers the quit paths that bypass the menu item (log out, ⌘Q from
        // another surface, a termination signal). Idempotent with the menu's
        // own call.
        AppEnvironment.model.shutdownForQuit()
    }
}

@main
struct RawTouchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppEnvironment.model

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            MenuBarLabelView(model: model)
        }

        // The Settings scene gives the window the system's own settings
        // chrome — toolbar tabs, the selected tab as the title, a size that
        // follows the tab. Opened from the menu by `SettingsMenuItem` on
        // macOS 14+ and by `showSettingsLegacy()` on 13.
        Settings {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)

        // Titled for what the window is about, the same as its headline's
        // subject, rather than a greeting the headline then contradicts.
        Window("RawTouch Setup", id: WindowID.onboarding) {
            OnboardingView(model: model)
        }
        .windowResizability(.contentSize)
    }
}
