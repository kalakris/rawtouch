// MIT License
// Copyright (c) 2026 RawTouch contributors

import XCTest

@testable import RawTouchAppCore

/// The rename field's state machine: what each thing the user does to an
/// editable heading turns into, including the orders SwiftUI delivers them
/// in — among them Return followed by the focus loss it causes (one
/// write), and Escape followed by the same (no write).
final class RenameFieldTests: XCTestCase {
    private let title = "Go60 Right"

    /// An open field with "Desk Go60" typed into it.
    private func editing(selectingAll: Bool = true) -> RenameField {
        var field = RenameField()
        XCTAssertEqual(field.begin(title: title, selectingAll: selectingAll), .focusField(selectingAll: selectingAll))
        XCTAssertTrue(field.isEditing)
        XCTAssertEqual(field.draft, title, "seeded with what the heading says")
        field.draft = "Desk Go60"
        return field
    }

    // MARK: - Begin

    func testBeginSeedsTheFieldAndSaysHowToSelect() {
        var byPencil = RenameField()
        XCTAssertEqual(byPencil.begin(title: title, selectingAll: true), .focusField(selectingAll: true))
        var byClick = RenameField()
        XCTAssertEqual(byClick.begin(title: title, selectingAll: false), .focusField(selectingAll: false))
    }

    /// A second begin while open does nothing — in particular it does not
    /// re-seed the draft over what the user has typed.
    func testBeginWhileEditingChangesNothing() {
        var field = editing()
        XCTAssertEqual(field.begin(title: title, selectingAll: true), .none)
        XCTAssertEqual(field.draft, "Desk Go60")
    }

    // MARK: - Return

    /// Return at rest on the focused heading starts a rename; Return while
    /// the field is open belongs to the field. The heading's handler
    /// answering it there is what swallowed the key before `onSubmit`.
    func testReturnBelongsToTheHeadingOnlyAtRest() {
        XCTAssertTrue(RenameField().startsEditingOnReturn)
        XCTAssertFalse(editing().startsEditingOnReturn)
    }

    func testReturnCommits() {
        var field = editing()
        XCTAssertEqual(field.submit(title: title), .write("Desk Go60"))
        XCTAssertFalse(field.isEditing)
    }

    /// Return also takes the field away, which loses focus: that second
    /// event must not write again.
    func testReturnThenTheFocusLossItCausesWritesOnce() {
        var field = editing()
        XCTAssertEqual(field.submit(title: title), .write("Desk Go60"))
        XCTAssertEqual(field.focusLost(title: title), .none)
    }

    // MARK: - Escape

    func testEscapeRevertsAndWritesNothing() {
        var field = editing()
        XCTAssertEqual(field.escape(title: title), .none)
        XCTAssertFalse(field.isEditing)
        XCTAssertEqual(field.draft, title, "the typed text does not survive")
    }

    /// Escape closes the field, and the field losing focus then looks like
    /// a click away — which must not write the name the user just threw
    /// away. An edit ends once; the focus loss after an Escape finds it
    /// closed.
    func testEscapeThenTheFocusLossItCausesStillWritesNothing() {
        var field = editing()
        XCTAssertEqual(field.escape(title: title), .none)
        XCTAssertEqual(field.focusLost(title: title), .none)
    }

    // MARK: - Click-away

    func testClickingAwayCommits() {
        var field = editing()
        XCTAssertEqual(field.focusLost(title: title), .write("Desk Go60"))
        XCTAssertFalse(field.isEditing)
    }

    /// Clicking away from an untouched field writes nothing: the firmware's
    /// name must not be stored as a chosen one.
    func testClickingAwayFromAnUntouchedFieldWritesNothing() {
        var field = RenameField()
        _ = field.begin(title: title, selectingAll: true)
        XCTAssertEqual(field.focusLost(title: title), .none)
    }

    /// Emptying the field and committing writes the empty name, which
    /// clears the key and brings the default back.
    func testCommittingAnEmptyFieldRestoresTheDefault() {
        var field = editing()
        field.draft = ""
        XCTAssertEqual(field.submit(title: title), .write(""))
    }

    /// After any ending, a fresh begin starts from the title again, not
    /// from anything typed last time.
    func testAFreshEditStartsFromTheTitle() {
        var field = editing()
        _ = field.escape(title: title)
        _ = field.begin(title: title, selectingAll: false)
        XCTAssertEqual(field.draft, title)
    }

    // MARK: - What a commit writes

    /// A Return on an untouched field must write nothing. The field is
    /// seeded with what the heading says, so on a keyboard that has never
    /// been renamed that text *is* the firmware's name — writing it would
    /// store "Go60 Right" as a chosen name and stop the entry following
    /// the firmware.
    func testCommittingTheTextItAlreadySaidWritesNothing() {
        XCTAssertNil(RenameField.committedName(draft: "Go60 Right", title: "Go60 Right"))
        XCTAssertNil(RenameField.committedName(draft: "Desk Go60", title: "Desk Go60"))
    }

    func testATypedNameIsWritten() {
        XCTAssertEqual(RenameField.committedName(draft: "Desk Go60", title: "Go60 Right"), "Desk Go60")
    }

    /// Emptying the field is a change: it writes an empty name, which
    /// clears the key and puts the firmware's name back.
    func testAnEmptiedFieldIsWrittenSoTheDefaultComesBack() {
        XCTAssertEqual(RenameField.committedName(draft: "", title: "Desk Go60"), "")
        XCTAssertEqual(RenameField.committedName(draft: "   ", title: "Desk Go60"), "   ")
    }

    /// Whitespace typed around the name it already had is not a rename
    /// anyone meant. Written, a space after the firmware's name would be
    /// trimmed into that same name and stored as a custom one.
    func testWhitespaceAroundTheSameNameWritesNothing() {
        XCTAssertNil(RenameField.committedName(draft: " Desk Go60 ", title: "Desk Go60"))
        XCTAssertNil(RenameField.committedName(draft: "Go60 Right ", title: "Go60 Right"))
    }
}
