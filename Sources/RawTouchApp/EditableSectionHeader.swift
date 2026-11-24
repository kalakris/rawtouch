// MIT License
// Copyright (c) 2026 RawTouch contributors

import AppKit
import RawTouchAppCore
import RawTouchCore
import SwiftUI

/// A section heading that is also the thing's name: the text sits exactly
/// where a plain `Section` header's does, with a pencil beside it saying
/// so. Click the text to edit from where you clicked, click the pencil (or
/// use Rename, from the context menu, the accessibility action or Return
/// on the focused heading) to replace the name wholesale.
///
/// The one custom control in this window, and it earns its place by
/// removing rows: without it a keyboard and each of its pads would need a
/// "Name" row under a heading that already says the name, in a tab that
/// grows a section per pad. Naming a thing where its name is written is also what
/// the Finder, Photos and System Settings' own sidebars do, so the gesture
/// is learned, not taught.
///
/// Three choices hold it together: the pencil is drawn
/// always, not on hover, because an affordance nobody can see is recall,
/// not recognition; the heading is focusable and answers Return, and
/// carries an accessibility action, because a rename reachable only by
/// mouse is a rename half the users do not have; and a plain click places
/// the caret rather than selecting everything, because one stray click
/// plus one keystroke should not replace a name.
///
/// Return commits, Escape reverts, clicking away commits, and an empty
/// field restores the default — which then shows as the placeholder, so
/// "no name of its own" reads as what it is. Nothing is focused when the
/// window opens: the field does not exist until the user asks for it.
struct EditableSectionHeader: View {
    /// The name in the file, or nil when the thing goes by its default.
    let name: String?
    /// What it is called when it has no name of its own.
    let placeholder: String
    /// "Keyboard name" / "Pad name", for VoiceOver — the visible text is
    /// the value, not the label.
    let accessibilityLabel: String
    let help: String
    /// Nil where there is nothing to write to (a keyboard with no key).
    let rename: ((String) -> Void)?

    /// The edit's state and rules (`RenameField`): the view only reports
    /// what happened and does what it is told.
    @State private var field = RenameField()
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    private var isEditing: Bool {
        field.isEditing
    }

    private var title: String {
        RawTouchConfiguration.usableName(name) ?? placeholder
    }

    var body: some View {
        Group {
            if isEditing {
                // The printed words become editable in place: the field
                // takes the heading's position and font, and nothing else
                // is drawn. A `TextField`'s first argument is its *label*,
                // which a Form renders beside the field, so it is hidden
                // and the default name serves as the prompt.
                TextField(text: cappedDraft, prompt: Text(placeholder)) {
                    Text(accessibilityLabel)
                }
                .labelsHidden()
                .textFieldStyle(.plain)
                .focused($isFocused)
                .accessibilityLabel(accessibilityLabel)
                .onSubmit {
                    perform(field.submit(title: title))
                }
                .onExitCommand {
                    perform(field.escape(title: title))
                }
                // Clicking away is a commit, like every rename field in the
                // system — but one turn of the run loop later. Escape can
                // end the field editor's session (so focus is lost) before
                // the exit command reaches us; deferring lets the revert
                // land first, after which this finds the edit closed and
                // does nothing. In the other order — the exit command, then
                // the field disappearing — it finds the edit closed anyway.
                .onChange(of: isFocused) { focused in
                    guard !focused else {
                        return
                    }
                    DispatchQueue.main.async {
                        perform(field.focusLost(title: title))
                    }
                }
                // The heading going away mid-edit (the pop-up moved to
                // another keyboard, or this one was unplugged) is clicking
                // away too: what was typed is kept, for the thing it was
                // typed for — this view's `rename`, which the heading's
                // identity keeps from ever being another's.
                .onDisappear {
                    perform(field.focusLost(title: title))
                }
            } else {
                // The text first, with nothing before it — no padding, no
                // spacer — so it sits exactly where a plain Section header
                // sits. The pencil is a real sibling with a real hit area:
                // drawn in an overlay outside the text's frame, it would be
                // visible but barely clickable.
                HStack(spacing: 8) {
                    Text(title)
                        .accessibilityAddTraits(.isHeader)
                        // The words, and only the words: a click here edits
                        // them in place, caret after them.
                        .contentShape(Rectangle())
                        .onTapGesture {
                            beginEditing(selectingAll: false)
                        }
                    if rename != nil {
                        pencilButton
                    }
                }
            }
        }
        .background {
            // A faint field under the text while the pointer is on it:
            // enough to say "this is editable", not enough to be a box.
            // Inset outward, so the padding it wants is the background's
            // and never the text's.
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.quaternary)
                .padding(.horizontal, -4)
                .padding(.vertical, -1)
                .opacity(isEditing || isHovering ? 1 : 0)
        }
        .onHover { isHovering = $0 && rename != nil }
        // Reachable without a mouse: Full Keyboard Access can land on the
        // heading, and Return opens it the way the pencil does.
        .focusable(rename != nil && !isEditing)
        // Return on the focused heading starts a rename — and while the
        // field is open, it is not ours: answering `.handled` there
        // swallowed the key before the field's `onSubmit` ever saw it.
        .onReturnKey {
            guard field.startsEditingOnReturn else {
                return false
            }
            beginEditing(selectingAll: true)
            return true
        }
        .renamable(rename != nil) {
            beginEditing(selectingAll: true)
        }
        .contextMenu {
            if rename != nil {
                RenameButton()
            }
        }
        .help(help)
    }

    /// Drawn always, in tertiary, and brightened under the pointer: every
    /// heading on this tab is editable, and the only way to know that used
    /// to be to sweep the pointer across them. A button, because it is one:
    /// it answers a click and Full Keyboard Access, and VoiceOver reads it
    /// as "Rename". It selects the whole name — asked as "rename this",
    /// unlike a click on the words.
    private var pencilButton: some View {
        Button {
            beginEditing(selectingAll: true)
        } label: {
            Image(systemName: "pencil")
                .imageScale(.small)
                .foregroundStyle(isHovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                // A few points of target around a small glyph, then taken
                // back out of layout: easier to hit, and the heading's row
                // is no taller or wider than a plain header's.
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-4)
        .accessibilityLabel("Rename")
    }

    /// The field's text, capped where it is typed rather than trimmed
    /// behind the user's back on commit.
    private var cappedDraft: Binding<String> {
        Binding(
            get: { field.draft },
            set: { field.draft = String($0.prefix(RawTouchConfiguration.nameLimit)) }
        )
    }

    /// - Parameter selectingAll: true when the rename was asked for as a
    ///   rename (the pencil, the menu, the accessibility action, Return),
    ///   false when the user clicked into the words themselves, where
    ///   replacing all of them is the last thing they meant.
    private func beginEditing(selectingAll: Bool) {
        guard rename != nil else {
            return
        }
        perform(field.begin(title: title, selectingAll: selectingAll))
    }

    /// Does what the state machine decided. The only place that focuses
    /// the field or writes a name.
    private func perform(_ effect: RenameField.Effect) {
        switch effect {
        case .none:
            break
        case .focusField(let selectingAll):
            isFocused = true
            place(caretAtEnd: !selectingAll)
        case .write(let name):
            rename?(name)
        }
    }

    /// Selects the field's text, or puts the caret after it, once focus
    /// has landed. The window's field editor is the first responder by
    /// then; SwiftUI has no API for either.
    private func place(caretAtEnd: Bool) {
        DispatchQueue.main.async {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else {
                return
            }
            if caretAtEnd {
                editor.setSelectedRange(NSRange(location: editor.string.count, length: 0))
            } else {
                editor.selectAll(nil)
            }
        }
    }
}

extension View {
    /// The system's own rename plumbing — plus an explicit custom action,
    /// because `renameAction` alone puts nothing in the accessibility
    /// tree. Only where there is a name
    /// to write: VoiceOver offering "Rename" on a heading that cannot be
    /// renamed is a promise the heading breaks.
    @ViewBuilder
    fileprivate func renamable(_ isRenamable: Bool, _ action: @escaping () -> Void) -> some View {
        if isRenamable {
            renameAction(action)
                .accessibilityAction(named: "Rename", action)
        } else {
            self
        }
    }

    /// Return on the focused view, where the platform has the API for it.
    /// `action` says whether it took the key: false passes it on (to a
    /// text field inside, whose `onSubmit` is waiting for it). macOS 13 has
    /// no `onKeyPress`; there the pencil, the context menu and the
    /// accessibility action are the routes in.
    @ViewBuilder
    fileprivate func onReturnKey(_ action: @escaping () -> Bool) -> some View {
        if #available(macOS 14, *) {
            onKeyPress(.return) {
                action() ? .handled : .ignored
            }
        } else {
            self
        }
    }
}
