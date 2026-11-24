// MIT License
// Copyright (c) 2026 RawTouch contributors

import AppKit
import RawTouchAppCore
import SwiftUI

/// The menubar icon: one SF Symbol whose shape carries the state (see
/// `MenuBarIconState`), plus the update mark while the menu lists an update
/// (`MenuBarIcon`). Template rendering everywhere except the attention
/// triangle, which uses the system's multicolor warning rendering — the only
/// colored state. No animation at rest, ever.
struct MenuBarLabelView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var icon: MenuBarIcon {
        MenuBarIcon(
            state: iconState(
                for: model.status,
                axTrusted: model.axTrusted,
                leaseUnsupported: model.leaseUnsupportedProductName != nil,
                loginItemFailed: model.loginItemError != nil
            ),
            updateAvailable: !model.updateNotices.isEmpty
        )
    }

    var body: some View {
        glyph
            .accessibilityLabel(icon.accessibilityLabel)
            .help(icon.accessibilityLabel)
            // The label is the app's one always-alive view, so it doubles as
            // the bridge from the delegate's "show onboarding" flag to
            // openWindow, which only views can reach. Checked on appear too:
            // `onChange` never fires for the value a view starts with, so a
            // flag the delegate set before this view existed would otherwise
            // wait forever — and the delegate sets it only once.
            .onAppear(perform: showOnboardingIfAsked)
            .onChange(of: model.shouldShowOnboarding) { _ in
                showOnboardingIfAsked()
            }
    }

    /// The state's symbol; with the update mark, one composed template image
    /// (`MenuBarIconImage`), since the label draws only a single image.
    @ViewBuilder private var glyph: some View {
        if icon.showsUpdateMark, let marked = MenuBarIconImage.marked(icon.state.symbolName) {
            Image(nsImage: marked)
        } else {
            Image(systemName: icon.state.symbolName)
                .symbolRenderingMode(icon.state == .needsAttention ? .multicolor : .monochrome)
        }
    }

    private func showOnboardingIfAsked() {
        guard model.shouldShowOnboarding else {
            return
        }
        model.shouldShowOnboarding = false
        present(WindowID.onboarding, using: openWindow)
    }
}
