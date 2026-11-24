// MIT License
// Copyright (c) 2026 RawTouch contributors

import XCTest

@testable import RawTouchAppCore

/// The setup window's words follow the button's step and the grant.
final class OnboardingCopyTests: XCTestCase {
    /// The first press is not labeled like the system alert it brings up;
    /// later presses say where they go.
    func testTheButtonIsNamedForWhatItsPressDoes() {
        XCTAssertEqual(OnboardingCopy.grantButtonTitle(.askSystem), "Grant Access\u{2026}")
        XCTAssertEqual(OnboardingCopy.grantButtonTitle(.openSettings), "Open System Settings")
    }

    /// The instructions walk through what the user will see, in order.
    func testTheInstructionsFollowTheStep() {
        let ask = OnboardingCopy.instructions(axTrusted: false, step: .askSystem)
        XCTAssertTrue(ask.hasPrefix("Click Grant Access. macOS asks"), ask)
        XCTAssertTrue(ask.contains("choose Open System Settings there"), ask)

        let open = OnboardingCopy.instructions(axTrusted: false, step: .openSettings)
        XCTAssertTrue(open.hasPrefix("Click Open System Settings, then switch on RawTouch"), open)
        XCTAssertTrue(open.contains("+ button"), open)
    }

    /// Granted, the window says where the app went — the menu bar, with
    /// the icon described as it is drawn.
    func testTheGrantedStateSaysWhereTheAppLives() {
        for step in [AppModel.AccessibilityGrantStep.askSystem, .openSettings] {
            let granted = OnboardingCopy.instructions(axTrusted: true, step: step)
            XCTAssertTrue(granted.hasPrefix("RawTouch runs in the menu bar"), granted)
            XCTAssertTrue(granted.contains("a hand pointing at a rectangle"), granted)
        }
        for state in [MenuBarIconState.active, .noDevice] {
            XCTAssertTrue(state.symbolName.hasPrefix("rectangle.and.hand.point"), "the copy describes this glyph")
        }
    }

    /// The granted state also says whether there is a keyboard to scroll
    /// with.
    func testTheKeyboardLineNamesWhatIsConnected() {
        XCTAssertEqual(OnboardingCopy.keyboardLine(names: []), "No keyboard with RawTouch firmware is connected")
        XCTAssertEqual(OnboardingCopy.keyboardLine(names: ["Go60"]), "Go60 is connected")
        XCTAssertEqual(OnboardingCopy.keyboardLine(names: ["Go60", "Sofle"]), "2 keyboards are connected")
        XCTAssertEqual(OnboardingCopy.requirementsURL.fragment, "what-you-need")
    }
}
