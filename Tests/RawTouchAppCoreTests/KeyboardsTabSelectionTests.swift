// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchCore
import XCTest

@testable import RawTouchAppCore

/// The Keyboards tab's selection rule: seeded from the keyboard that last
/// scrolled, then left alone.
final class KeyboardsTabSelectionTests: XCTestCase {
    private func keyboard(_ key: String, name: String = "Go60 Right") -> RawTouchKeyboard {
        RawTouchKeyboard.grouped(
            in: RawTouchStatus(endpoints: [
                .init(
                    id: RawTouchEndpointID(rawValue: 1),
                    productName: name,
                    transport: .usb,
                    padIDs: [0],
                    deviceKey: key,
                    lease: .held
                )
            ]))[0]
    }

    private var mine: RawTouchKeyboard { keyboard("id:AAAA") }
    private var other: RawTouchKeyboard { keyboard("id:BBBB", name: "Sofle") }

    func testTheOpeningChoiceIsTheKeyboardThatLastScrolled() {
        XCTAssertEqual(
            KeyboardsTabSelection.initial(keyboards: [mine, other], savedKeys: [], lastScrolled: other.id),
            .keyboard(other.id)
        )
        XCTAssertEqual(
            KeyboardsTabSelection.initial(keyboards: [mine, other], savedKeys: [], lastScrolled: nil),
            .keyboard(mine.id),
            "else the first connected one"
        )
        XCTAssertEqual(
            KeyboardsTabSelection.initial(keyboards: [], savedKeys: ["id:CCCC"], lastScrolled: nil),
            .saved("id:CCCC"),
            "else a saved entry"
        )
        XCTAssertNil(KeyboardsTabSelection.initial(keyboards: [], savedKeys: [], lastScrolled: nil))
    }

    /// The whole point: once the window is open, scrolling on the other
    /// keyboard must not move the page out from under a hand on a slider.
    func testAPickIsNeverOverruledByWhatScrolledLast() {
        let picked = KeyboardsTabSelection.keyboard(mine.id)
        XCTAssertEqual(
            KeyboardsTabSelection.resolve(
                picked: picked,
                keyboards: [mine, other],
                savedKeys: [],
                lastScrolled: other.id
            ),
            picked
        )
    }

    /// A keyboard that goes away falls back rather than blanking the tab.
    func testAnUnpluggedSelectionFallsBack() {
        XCTAssertEqual(
            KeyboardsTabSelection.resolve(
                picked: .keyboard(other.id),
                keyboards: [mine],
                savedKeys: [],
                lastScrolled: nil
            ),
            .keyboard(mine.id)
        )
        XCTAssertEqual(
            KeyboardsTabSelection.resolve(
                picked: .saved("id:GONE"),
                keyboards: [],
                savedKeys: ["id:CCCC"],
                lastScrolled: nil
            ),
            .saved("id:CCCC")
        )
    }

    /// The Advanced tab's latency row speaks about the keyboard the
    /// Keyboards tab is pointed at: with two connected, a row listing
    /// every connection of both is a list, not an answer.
    func testTheLatencyRowFollowsTheSelectedKeyboard() {
        let model = AppModel()
        let status = RawTouchStatus(endpoints: [
            .init(
                id: RawTouchEndpointID(rawValue: 1),
                productName: "Go60 Right",
                transport: .usb,
                padIDs: [0],
                deviceKey: "id:AAAA",
                lease: .held
            ),
            .init(
                id: RawTouchEndpointID(rawValue: 2),
                productName: "Sofle",
                transport: .usb,
                padIDs: [0],
                deviceKey: "id:BBBB",
                lease: .held
            ),
        ])
        model.receiveForTesting(status)

        XCTAssertEqual(model.latencyKeyboards.map(\.name), ["Go60 Right"], "the first, until one is picked")
        model.keyboardsSelection = .keyboard(.key("id:BBBB"))
        XCTAssertEqual(model.latencyKeyboards.map(\.name), ["Sofle"])
    }

    /// With one keyboard there is nothing to choose between, so the row
    /// speaks about it whatever the picker says.
    func testOneKeyboardNeedsNoSelection() {
        let model = AppModel()
        model.receiveForTesting(
            RawTouchStatus(endpoints: [
                .init(
                    id: RawTouchEndpointID(rawValue: 1),
                    productName: "Go60 Right",
                    transport: .usb,
                    padIDs: [0],
                    deviceKey: "id:AAAA",
                    lease: .held
                )
            ]))
        XCTAssertEqual(model.latencyKeyboards.map(\.name), ["Go60 Right"])
    }

    /// Each opening of the window starts on the keyboard just used, not
    /// on whatever was picked the last time it was open.
    func testEveryOpeningSeedsFromTheKeyboardThatLastScrolled() {
        let model = AppModel()
        func status(lastScrolledOn endpoint: UInt64) -> RawTouchStatus {
            RawTouchStatus(
                endpoints: [
                    .init(
                        id: RawTouchEndpointID(rawValue: 1), productName: "Go60 Right", transport: .usb, padIDs: [0],
                        deviceKey: "id:AAAA", lease: .held),
                    .init(
                        id: RawTouchEndpointID(rawValue: 2), productName: "Sofle", transport: .usb, padIDs: [0],
                        deviceKey: "id:BBBB", lease: .held),
                ],
                lastGesture: RawTouchGestureSummary(
                    endpoint: RawTouchEndpointID(rawValue: endpoint),
                    peakFingerSpeed: 1240, peakGain: 3.2, touchDistance: 400, liftOffSpeed: 1850, complete: true,
                    latencyMs: 1.5, displayFrames: 138, heldFrames: 0
                )
            )
        }

        model.receiveForTesting(status(lastScrolledOn: 1))
        model.seedKeyboardsSelection()
        XCTAssertEqual(model.selectedKeyboard?.name, "Go60 Right")

        // Picked by hand, then the other keyboard scrolls: the open window
        // stays put.
        model.keyboardsSelection = .keyboard(.key("id:BBBB"))
        model.receiveForTesting(status(lastScrolledOn: 1))
        XCTAssertEqual(model.selectedKeyboard?.name, "Sofle")

        // Opened again: the keyboard just used.
        model.seedKeyboardsSelection()
        XCTAssertEqual(model.selectedKeyboard?.name, "Go60 Right")
    }

    /// Nothing picked yet — the state a window has for the instant before
    /// it seeds itself — reads as the opening choice.
    func testNothingPickedReadsAsTheOpeningChoice() {
        XCTAssertEqual(
            KeyboardsTabSelection.resolve(
                picked: nil,
                keyboards: [mine, other],
                savedKeys: [],
                lastScrolled: other.id
            ),
            .keyboard(other.id)
        )
    }
}
