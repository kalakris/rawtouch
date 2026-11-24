// MIT License
// Copyright (c) 2026 RawTouch contributors

import AppKit
import RawTouchAppCore
import SwiftUI

/// First-run Accessibility onboarding: one screen, one paragraph, one
/// primary button, one dialog per press (`AppModel.grantAccessibility`).
/// The first press asks macOS, whose alert puts RawTouch in the
/// Accessibility list and offers its own "Open System Settings"; later
/// presses open that pane directly. The user turns the switch on there.
/// Nothing else here prompts: the state line polls the non-prompting trust
/// check once a second while the window is visible and flips to granted on
/// its own — and then says where the app lives (the menu bar), whether a
/// keyboard is connected, and offers Settings, since closing the window
/// leaves nothing else on screen. The grant is made in System Settings,
/// which is in front at that moment, so the window comes back to the front
/// when it lands.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("RawTouch needs Accessibility permission")
                .font(.headline)

            Text(
                """
                RawTouch scrolls by posting scroll events, which macOS only allows with the \
                Accessibility permission. Until it is granted, your keyboard keeps scrolling on its own.
                """
            )
            .fixedSize(horizontal: false, vertical: true)

            Text(OnboardingCopy.instructions(axTrusted: model.axTrusted, step: model.accessibilityGrantStep))
                .fixedSize(horizontal: false, vertical: true)

            if model.axTrusted {
                // "Can scroll", not "is scrolling": with no keyboard attached the
                // grant is in place and nothing is scrolling, and both are true.
                Label("Accessibility granted — RawTouch can scroll", systemImage: "checkmark.circle.fill")
                keyboardLine
            } else {
                Label("Waiting for the permission…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                if model.axTrusted {
                    // A menu bar app has no Dock icon and no main window:
                    // once this closes, the menu and Settings are all there
                    // is, so the way to Settings is offered here too.
                    // Settings is the next step on a first run, so it is the
                    // default button; Done is the way out.
                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    if #available(macOS 14, *) {
                        OpenSettingsButton(title: "Open Settings\u{2026}") {
                            dismiss()
                        }
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Open Settings\u{2026}") {
                            showSettingsLegacy()
                            dismiss()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                } else {
                    // Deciding later is a legitimate exit: the keyboard is
                    // scrolling either way, and the menu keeps the way back.
                    Button("Not Now") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    let step = model.accessibilityGrantStep
                    Button(OnboardingCopy.grantButtonTitle(step)) {
                        model.grantAccessibility()
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint(
                        step == .askSystem
                            ? "Asks macOS for the Accessibility permission"
                            : "Opens the Accessibility privacy pane")
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .onChange(of: model.axTrusted) { trusted in
            if trusted {
                present(WindowID.onboarding, using: openWindow)
            }
        }
        // The heartbeat: once a second, only while the view is installed —
        // closing the window cancels the task, which ends the loop at its
        // next sleep. A task rather than a `Timer.publish` stored on the
        // view, which would be rebuilt with the view on every model change.
        .task {
            while (try? await Task.sleep(for: .seconds(1))) != nil {
                model.refreshAccessibilityTrust()
            }
        }
    }
}

extension OnboardingView {
    /// Whether there is a keyboard to scroll with, and where to read what
    /// RawTouch needs when there is none.
    @ViewBuilder
    fileprivate var keyboardLine: some View {
        let names = model.settingsKeyboards.map(\.name)
        if names.isEmpty {
            HStack(alignment: .firstTextBaseline) {
                Label(OnboardingCopy.keyboardLine(names: names), systemImage: "keyboard")
                    .foregroundStyle(.secondary)
                Link("What you need", destination: OnboardingCopy.requirementsURL)
            }
        } else {
            Label(OnboardingCopy.keyboardLine(names: names), systemImage: "keyboard")
        }
    }
}
