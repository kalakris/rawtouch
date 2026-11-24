// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchAppCore
import RawTouchCore
import SwiftUI

/// One keyboard at a time. A keyboard reachable over USB and Bluetooth is
/// **one** keyboard here — its firmware reports the same hardware id over
/// both, its settings live under that id, and they apply however it is
/// connected. The page is its status, its firmware, its own switch, its
/// hardware id, then one section per pad.
///
/// The pop-up opens on the keyboard that last scrolled and then stays put:
/// re-selecting under the user while they are setting something would be
/// worse than showing a keyboard they have to pick again. It is hidden
/// altogether when there is only one keyboard and nothing saved — a pop-up
/// with one choice asks a question that has no answer.
struct KeyboardsTab: View {
    @ObservedObject var model: AppModel
    @State private var confirmingRemoval = false
    /// The form's content height, as its scroll view measures it. Nil
    /// until measured, and always nil before macOS 15, which has no API
    /// to read it.
    @State private var contentHeight: CGFloat?

    /// The tallest the form grows before it scrolls: room for one keyboard
    /// with two pads, orientation collapsed.
    private static let maximumFormHeight: CGFloat = 640

    /// As tall as the content, up to the cap: one keyboard or none leaves
    /// no empty space below the last section, and more keyboards' pads
    /// scroll. Rounded up to a whole point, so pixel rounding never leaves
    /// a fraction of a point to scroll. Unmeasured, the cap.
    private var formHeight: CGFloat {
        min(contentHeight?.rounded(.up) ?? Self.maximumFormHeight, Self.maximumFormHeight)
    }

    private var keyboards: [RawTouchKeyboard] {
        model.settingsKeyboards
    }

    private var savedKeys: [String] {
        model.disconnectedDeviceKeys
    }

    /// The saved entry the page shows, when it shows one. What it shows
    /// lives on the model (`resolvedKeyboardsSelection`), which is what
    /// lets the Advanced tab's latency row speak about the same keyboard.
    private var selectedSavedKey: String? {
        guard case .saved(let key)? = model.resolvedKeyboardsSelection else {
            return nil
        }
        return key
    }

    /// The key "Remove Settings…" would remove: the one the page's
    /// settings are stored under, when the file holds anything under it.
    private var removableKey: String? {
        (model.selectedKeyboard?.editableKey ?? selectedSavedKey).flatMap {
            model.config.devices[$0] == nil ? nil : $0
        }
    }

    private var selectedName: String {
        if let keyboard = model.selectedKeyboard {
            return keyboard.name
        }
        return selectedSavedKey.map(model.savedEntryName) ?? "this keyboard"
    }

    /// What removing takes with it — and, since no row on the page prints
    /// the key, the one place a hand-editor can read it.
    /// Only ever shown with the button, so with a key.
    private var removalMessage: String {
        "Removes \(selectedName)\u{2019}s switch, pad settings and the names you gave it and its pads "
            + "(devices.\(removableKey ?? "") in config.json). It goes back to the Scrolling tab\u{2019}s values."
    }

    /// The pop-up earns its row only when there is a choice to make.
    private var showsPicker: Bool {
        keyboards.count + savedKeys.count > 1
    }

    var body: some View {
        Form {
            if showsPicker {
                pickerSection
            }
            if let keyboard = model.selectedKeyboard {
                keyboardSection(keyboard)
                if let key = keyboard.editableKey {
                    ForEach(keyboard.padIDs, id: \.self) { padID in
                        padSection(padID, deviceKey: key, keyboardName: keyboard.name)
                    }
                }
            } else if let key = selectedSavedKey {
                savedSection(key)
            } else {
                emptySection
            }
        }
        .formStyle(.grouped)
        // The one tab that can scroll: it grows with the keyboards
        // connected and the pads they have.
        .modifier(ScrollContentHeightReader(height: $contentHeight))
        .frame(height: formHeight)
        .safeAreaInset(edge: .bottom) {
            ActionBar(
                model: model,
                confirming: $confirmingRemoval,
                title: "Remove Settings\u{2026}",
                // Named, so it is not the third "Remove Settings…" button
                // VoiceOver has read today with nothing to tell them apart.
                accessibilityTitle: "Remove \(selectedName)\u{2019}s settings",
                confirmTitle: "Remove Settings",
                // It takes names the user typed, not just switches: that is
                // data, and the confirmation is the last place to say so.
                isDestructive: true,
                question: "Remove \(selectedName)\u{2019}s settings?",
                message: removalMessage,
                // Hidden rather than greyed with nothing saved to remove:
                // a disabled button is a promise about a state the user
                // cannot reach from here.
                isShown: removableKey != nil
            ) {
                if let key = removableKey {
                    model.removeDevice(key)
                }
            }
        }
    }

    // MARK: The pop-up

    private var pickerSection: some View {
        Section {
            Picker(
                "Keyboard",
                selection: Binding(
                    get: { model.resolvedKeyboardsSelection },
                    set: { model.keyboardsSelection = $0 }
                )
            ) {
                ForEach(keyboards) { keyboard in
                    Text(keyboard.name)
                        .tag(Optional(KeyboardsTabSelection.keyboard(keyboard.id)))
                }
                if !savedKeys.isEmpty {
                    Divider()
                    ForEach(savedKeys, id: \.self) { key in
                        Text("\(model.savedEntryName(key)) \u{2014} not connected")
                            .tag(Optional(KeyboardsTabSelection.saved(key)))
                    }
                }
            }
            .pickerStyle(.menu)
            .help(
                "Which keyboard the settings below belong to. A keyboard reachable over USB and Bluetooth is one keyboard, with one set of settings."
            )
        }
    }

    private var emptySection: some View {
        Section {
            Text(
                "No keyboard connected. Connect a keyboard running the zmk-raw-touch firmware module over USB or Bluetooth; its settings appear here."
            )
            .foregroundStyle(.secondary)
        }
    }

    // MARK: One keyboard

    /// The selected keyboard: what mode it is in over which connections,
    /// what firmware it runs, its own switch, and the hardware id its
    /// settings are keyed by. A keyboard macOS and its firmware expose no
    /// stable identity for has no settings of its own: an override keyed by
    /// something that changes with the USB port would silently stop
    /// applying.
    @ViewBuilder
    private func keyboardSection(_ keyboard: RawTouchKeyboard) -> some View {
        let name = keyboard.name
        Section {
            LabeledContent("Status") {
                Text(StatusFormatter.keyboardStatus(for: keyboard, in: model.status, configuration: model.config))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            if let firmware = StatusFormatter.keyboardFirmwareLine(for: keyboard, configuration: model.config) {
                // Left off for firmware without RawTouch mode: the section's
                // footer already says the one thing there is to say about it.
                LabeledContent("Firmware") {
                    Text(firmware)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                .help(StatusFormatter.firmwareHelp)
            }
            if let key = keyboard.editableKey {
                // `true` is the inherit default, so switching back on removes
                // the key instead of storing an explicit `true`.
                Toggle(
                    "Use RawTouch with this keyboard",
                    isOn: Binding(
                        get: { model.deviceOverrides(key).enabled ?? true },
                        set: { model.setDeviceEnabled(key, $0) }
                    )
                )
                .accessibilityLabel("Use RawTouch with \(name)")
                .help(
                    "devices.\(key).enabled \u{2014} off returns this keyboard to Standard mode on every connection: it keeps scrolling on its own while other keyboards carry on."
                )
            }
        } header: {
            // A keyboard is called whatever its owner calls it; the name
            // its firmware reports is only the starting point.
            EditableSectionHeader(
                name: keyboard.editableKey.flatMap { model.deviceOverrides($0).name },
                placeholder: keyboard.defaultName,
                accessibilityLabel: "Keyboard name",
                help: keyboard.editableKey.map {
                    "devices.\($0).name \u{2014} what to call this keyboard here, in the menu and in the readout below, up to \(RawTouchConfiguration.nameLimit) characters. Empty goes back to the name its firmware reports."
                } ?? "",
                rename: keyboard.editableKey.map { key in
                    { newName in model.setKeyboardName(key, newName) }
                }
            )
            // One heading per keyboard, not one reused as the pop-up moves:
            // a rename open when it does ends with the keyboard it was
            // typed for.
            .id(keyboard.id)
        } footer: {
            Group {
                if keyboard.editableKey == nil, keyboard.endpoints.allSatisfy({ $0.lease == .unsupportedFirmware }) {
                    Text(
                        "This keyboard\u{2019}s firmware has no RawTouch mode. Update it to a build of the zmk-raw-touch module with host lease support."
                    )
                } else if keyboard.key == nil {
                    Text(
                        "Neither this keyboard\u{2019}s firmware nor macOS exposes a stable identifier for it, so it has no settings of its own; the Scrolling and Advanced tabs apply as they are."
                    )
                } else {
                    Text(
                        "Pad settings start from the Scrolling tab\u{2019}s values and apply on every connection. Only what you change is saved."
                    )
                }
            }
            .settingsFooter()
        }
    }

    @ViewBuilder
    private func padSection(_ padID: UInt8, deviceKey: String, keyboardName: String) -> some View {
        let key = String(padID)
        let pad = model.devicePadOverrides(deviceKey, key)
        PadSettingsSection(
            title: StatusFormatter.padName(padID, deviceKey: deviceKey, in: model.config),
            placeholder: StatusFormatter.padName(padID),
            keyboardName: keyboardName,
            keyPath: keyPath(deviceKey, key),
            pad: pad,
            inheritedScale: model.config.scale,
            rename: { name in model.setPadName(deviceKey, key, name) },
            update: { mutate in model.updateDevicePad(deviceKey, key, mutate) }
        )
        // Every keyboard has a Pad 0: without an identity of its own the
        // section would be reused as the pop-up moves, carrying an open
        // rename and the disclosure's state to the other keyboard's pad.
        .id(keyPath(deviceKey, key))
    }

    /// Where a pad's keys live in config.json — also the pad section's
    /// identity.
    private func keyPath(_ deviceKey: String, _ padID: String) -> String {
        "devices.\(deviceKey).pads.\(padID)"
    }

    // MARK: A saved entry

    private func savedSection(_ key: String) -> some View {
        Section {
            LabeledContent("Status") {
                Text("Not connected")
                    .foregroundStyle(.secondary)
            }
            // The key itself, for the headless user matching the entry to
            // the file — the header carries the name the entry was saved
            // under, when there is one.
            LabeledContent("Saved as") {
                Text("devices.\(key)")
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text(model.savedEntryName(key))
        } footer: {
            Text(
                "Settings saved for a keyboard that is not connected right now, or whose identity changed after a settings reset on the keyboard."
            )
            .settingsFooter()
        }
    }
}

/// Reports the height of the content inside the modified view's scroll
/// view. Reports nothing before macOS 15.
private struct ScrollContentHeightReader: ViewModifier {
    @Binding var height: CGFloat?

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(
                for: CGFloat.self,
                of: { $0.contentSize.height },
                action: { _, newHeight in height = newHeight }
            )
        } else {
            content
        }
    }
}
