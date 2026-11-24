// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import RawTouchCore

/// The rename field's whole life, as a value: what each thing the user can
/// do to an editable heading turns into. The view owns one of these and
/// does what the returned `Effect` says — focus the field, write a name,
/// or nothing — so the rules live here, where they can be tested, and not
/// in the order SwiftUI happens to deliver callbacks.
///
/// Four events, and what they mean:
///
/// - `begin` — the pencil, the Rename action, Return on the focused heading,
///   or a click on the words: seed the field with what the heading says.
/// - `submit` — Return in the field: write the name if it changed.
/// - `escape` — Escape: put the text back and write nothing.
/// - `focusLost` — the field lost focus (a click elsewhere, or the field
///   going away because one of the above already ended the edit): write
///   the name if it changed *and the edit is still open*.
///
/// That last clause is what keeps the events from fighting. An edit ends
/// exactly once; whichever of submit, escape or focus loss gets there
/// first decides, and every later one finds nothing open and does nothing.
/// So Escape followed by the focus loss it causes stays a revert, and
/// Return followed by the same focus loss writes once.
public struct RenameField: Equatable {
    public enum Effect: Equatable {
        case none
        /// Focus the field, with the text selected whole or the caret
        /// after it.
        case focusField(selectingAll: Bool)
        /// Write this as the new name (empty clears it back to the default).
        case write(String)
    }

    public private(set) var isEditing = false
    /// The field's text while editing; the view binds to it.
    public var draft = ""

    public init() {}

    /// Whether a Return that reaches the heading's container is the
    /// heading's to handle. While the field is open it belongs to the
    /// field: answering it there swallowed the key before `onSubmit` could
    /// see it, which is how Return stopped committing.
    public var startsEditingOnReturn: Bool {
        !isEditing
    }

    public mutating func begin(title: String, selectingAll: Bool) -> Effect {
        guard !isEditing else {
            return .none
        }
        draft = title
        isEditing = true
        return .focusField(selectingAll: selectingAll)
    }

    public mutating func submit(title: String) -> Effect {
        end(writing: true, title: title)
    }

    public mutating func escape(title: String) -> Effect {
        end(writing: false, title: title)
    }

    public mutating func focusLost(title: String) -> Effect {
        end(writing: true, title: title)
    }

    /// Ends an open edit, once. The draft goes back to the title either
    /// way, so nothing typed survives into a later edit or a late
    /// callback.
    private mutating func end(writing: Bool, title: String) -> Effect {
        guard isEditing else {
            return .none
        }
        let typed = draft
        isEditing = false
        draft = title
        guard writing, let name = Self.committedName(draft: typed, title: title) else {
            return .none
        }
        return .write(name)
    }

    /// The text a committed edit stores, or nil when there is nothing to
    /// write.
    ///
    /// A heading is seeded with what it currently *says* — the name the
    /// user gave the thing, or the one its firmware reports — and the whole
    /// of it is selected, so typing replaces it and a stray Return changes
    /// nothing. That last part is the rule here: committing text that still
    /// says what the heading already said must not write anything, or
    /// renaming a keyboard to the name it already had would store "Go60
    /// Right" as if someone had chosen it, and the entry would stop
    /// following the firmware.
    ///
    /// - `draft` — what the field was left holding.
    /// - `title` — what the heading said when editing began (the custom
    ///   name if there was one, else the default).
    ///
    /// Compared as they would be stored — trimmed — so a stray space after
    /// the firmware's name is not a rename either. Emptying the field *is*
    /// a change: it writes an empty name, which clears the key and puts
    /// the default back.
    static func committedName(draft: String, title: String) -> String? {
        RawTouchConfiguration.usableName(draft) == RawTouchConfiguration.usableName(title) ? nil : draft
    }
}
