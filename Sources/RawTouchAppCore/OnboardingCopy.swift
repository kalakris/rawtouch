// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation

/// The setup window's words, kept out of the view so they can be tested
/// against the step the button is on.
public enum OnboardingCopy {
    /// The primary button while access is missing. Not the system alert's
    /// own label on the first press: that alert, which the press brings up,
    /// has an "Open System Settings" button of its own.
    public static func grantButtonTitle(_ step: AppModel.AccessibilityGrantStep) -> String {
        switch step {
        case .askSystem: "Grant Access\u{2026}"
        case .openSettings: "Open System Settings"
        }
    }

    /// The paragraph under the explanation: what the next press leads to,
    /// in the order the user will see it — or, once granted, where the app
    /// went, since a menu bar app leaves nothing else on screen.
    public static func instructions(axTrusted: Bool, step: AppModel.AccessibilityGrantStep) -> String {
        if axTrusted {
            // The icon in its usual states (`MenuBarIconState.noDevice` and
            // `.active`).
            return """
                RawTouch runs in the menu bar: its icon is a hand pointing at a rectangle, near the \
                clock. Click it for status and settings.
                """
        }
        return switch step {
        case .askSystem:
            """
            Click Grant Access. macOS asks whether RawTouch may control this computer: choose \
            Open System Settings there, then switch on RawTouch in the Accessibility list.
            """
        case .openSettings:
            """
            Click Open System Settings, then switch on RawTouch in the Accessibility list. If \
            RawTouch is not in the list, add it with the + button. If scrolling ever stops after \
            an update, check that list first: the permission is tied to the app\u{2019}s signature.
            """
        }
    }

    /// The granted state's second line: whether there is anything to scroll
    /// with. The grant alone does not answer "is it working?"; a connected
    /// keyboard does, and its absence is the other thing a first run can
    /// be missing.
    public static func keyboardLine(names: [String]) -> String {
        switch names.count {
        case 0: "No keyboard with RawTouch firmware is connected"
        case 1: "\(names[0]) is connected"
        default: "\(names.count) keyboards are connected"
        }
    }

    /// Where the no-keyboard line sends the user: what RawTouch needs,
    /// firmware included.
    public static let requirementsURL = URL(string: "https://github.com/kalakris/rawtouch#what-you-need")!
}
