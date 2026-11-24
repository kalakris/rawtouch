// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchCore
import SwiftUI

/// One pad's override controls for one keyboard's
/// `devices.<key>.pads.<id>`: the caller says where reads and writes go
/// and names that path, so every tooltip here spells the full key the
/// way the keyboard's own switch does. The name row comes first, because
/// "Pad 0" is the firmware's numbering and not the user's. The gain row is
/// always present:
/// a readout of what the pad inherits until "Custom gain" turns it into a
/// slider seeded with that value, so switching it on changes nothing until
/// the slider moves. Orientation and axis overrides live behind a
/// disclosure that opens by itself only when one of them is set.
struct PadSettingsSection: View {
    let title: String
    /// What the name field shows while the pad has no name of its own.
    let placeholder: String
    /// The keyboard the pad belongs to — for VoiceOver, since the visible
    /// title is just "Pad 0".
    let keyboardName: String
    /// "devices.id:….pads.0" — where this pad's keys live in config.json,
    /// for the tooltips.
    let keyPath: String
    /// This layer's overrides only (nil = inherit).
    let pad: RawTouchConfiguration.Pad
    /// The gain in force beneath this layer.
    let inheritedScale: Double
    /// Writes `devices.<key>.pads.<id>.name`; an empty name removes it.
    let rename: (String) -> Void
    let update: ((inout RawTouchConfiguration.Pad) -> Void) -> Void

    @State private var orientationExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// "Pad 0 on Go60 Right": the section's identity for VoiceOver.
    private var spokenTitle: String {
        "\(title) on \(keyboardName)"
    }

    private var hasOrientationOverrides: Bool {
        pad.axes != nil || pad.axis != nil || pad.invert != nil || pad.invertHorizontal != nil
    }

    var body: some View {
        Section {
            // `true` is the inherit default, so switching back on removes
            // the override instead of storing an explicit `true`.
            Toggle(
                "Use this pad",
                isOn: Binding(
                    get: { pad.enabled ?? true },
                    set: { newValue in update { $0.enabled = newValue ? nil : false } }
                )
            )
            .accessibilityLabel("Use \(spokenTitle)")
            .help("\(keyPath).enabled — off ignores this pad\u{2019}s touches entirely.")

            Toggle(
                "Custom gain",
                isOn: Binding(
                    get: { pad.scale != nil },
                    set: { override in update { $0.scale = override ? inheritedScale : nil } }
                )
            )
            .accessibilityLabel("Custom gain for \(spokenTitle)")
            .help(
                "\(keyPath).scale — a gain of this pad\u{2019}s own instead of the Scrolling tab\u{2019}s, for pads with different sensitivity."
            )

            if pad.scale != nil {
                SliderRow(
                    title: "Gain",
                    accessibilityTitle: "Gain for \(spokenTitle)",
                    value: Binding(
                        get: { pad.scale ?? inheritedScale },
                        set: { newValue in update { $0.scale = newValue } }
                    ),
                    range: RawTouchConfiguration.scaleRange,
                    track: .logarithmic,
                    unit: "\u{00D7}",
                    help: "\(keyPath).scale — this pad\u{2019}s gain relative to physical 1:1."
                )
            } else {
                LabeledContent("Gain") {
                    Text("\(inheritedScale, format: .number.precision(.fractionLength(2)))\u{00D7} from Scrolling")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            // A disclosure row of our own rather than `DisclosureGroup`: in a
            // grouped Form that control exposes nothing to accessibility but
            // its label text — no button, no triangle — so VoiceOver could
            // never open it. This one is a real button.
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    orientationExpanded.toggle()
                }
            } label: {
                LabeledContent("Orientation") {
                    // The chevron takes the width of a pop-up's capsule
                    // (system pop-ups end their value text 35 pt in from
                    // the row's edge), so this row's summary sits in the
                    // same column as the pop-up values it discloses.
                    HStack(spacing: 0) {
                        Text(hasOrientationOverrides ? "Custom" : "Default")
                            .foregroundStyle(.secondary)
                        // Down, turning up: expand-in-place. A right chevron
                        // is the grouped-form glyph for "opens a page".
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(orientationExpanded ? -180 : 0))
                            .frame(width: 35, alignment: .trailing)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(spokenTitle) orientation, \(hasOrientationOverrides ? "custom" : "default")")
            .accessibilityValue(orientationExpanded ? "expanded" : "collapsed")
            .help(
                "Which directions this pad scrolls in and which way. Default follows the mounting the firmware reports and scrolls both ways; change these only if a pad scrolls the wrong way."
            )

            if orientationExpanded {
                Group {
                    // Both is the default, so choosing it removes the key rather
                    // than storing an explicit "both".
                    Picker(
                        "Scroll axes",
                        selection: Binding(
                            get: { pad.axes ?? .both },
                            set: { axes in update { $0.axes = axes == .both ? nil : axes } }
                        )
                    ) {
                        Text("Both").tag(RawTouchScrollAxes.both)
                        Text("Vertical").tag(RawTouchScrollAxes.vertical)
                        Text("Horizontal").tag(RawTouchScrollAxes.horizontal)
                    }
                    .help(
                        "\(keyPath).axes — which directions this pad scrolls in. A direction that is off contributes nothing, so a pad meant for one direction never drifts sideways."
                    )

                    // Automatic (nil) inherits the device-reported
                    // orientation; a sensor axis forces it (a pad mounted
                    // rotated 90° scrolls vertically from X). Horizontal
                    // scrolling always reads the other one.
                    Picker(
                        "Vertical axis",
                        selection: Binding(
                            get: { pad.axis },
                            set: { axis in update { $0.axis = axis } }
                        )
                    ) {
                        Text("Automatic").tag(RawTouchAxis?.none)
                        Text("Sensor X").tag(RawTouchAxis?.some(.x))
                        Text("Sensor Y").tag(RawTouchAxis?.some(.y))
                    }
                    .help(
                        "\(keyPath).axis — which raw sensor axis scrolls vertically; the other scrolls horizontally. Automatic follows the mounting the firmware reports. Change it only if the axes come out swapped."
                    )

                    DirectionPicker(
                        title: "Vertical direction",
                        invert: Binding(
                            get: { pad.invert },
                            set: { invert in update { $0.invert = invert } }
                        ),
                        help:
                            "\(keyPath).invert — this pad\u{2019}s vertical baseline before natural scrolling and Reverse scrolling apply. Automatic follows the mounting the firmware reports."
                    )

                    DirectionPicker(
                        title: "Horizontal direction",
                        invert: Binding(
                            get: { pad.invertHorizontal },
                            set: { invert in update { $0.invertHorizontal = invert } }
                        ),
                        help: "\(keyPath).invertHorizontal — the same for the horizontal baseline."
                    )
                }
                // Inset under the row that discloses them, so they read as
                // its contents and not as four more pad settings.
                .padding(.leading, 16)
            }
        } header: {
            // Pad IDs come from the firmware and say nothing about which
            // pad is which, so the heading is where the user says.
            EditableSectionHeader(
                name: pad.name,
                placeholder: placeholder,
                accessibilityLabel: "Pad name",
                help:
                    "\(keyPath).name \u{2014} what to call this pad here, in the rows above and in the readout below, up to \(RawTouchConfiguration.nameLimit) characters. Empty goes back to the firmware\u{2019}s own numbering.",
                rename: rename
            )
        }
        .onAppear {
            orientationExpanded = hasOrientationOverrides
        }
    }
}

/// One of a pad's direction overrides (one per axis): Automatic (nil)
/// inherits the baseline the device-reported orientation implies
/// (`orientationScrollInverted`, which is `true` for a pad the firmware does
/// not y-invert; `orientationHorizontalScrollInverted` likewise from
/// x-invert), or the direction is stated outright. The system's Natural
/// scrolling setting and `reverseScrolling` are applied on top of the result, so "Normal" means
/// "not inverted before those", not "scrolls down when the finger moves down"
/// in every configuration.
private struct DirectionPicker: View {
    let title: String
    let invert: Binding<Bool?>
    let help: String

    var body: some View {
        Picker(title, selection: invert) {
            Text("Automatic").tag(Bool?.none)
            Text("Normal").tag(Bool?.some(false))
            Text("Inverted").tag(Bool?.some(true))
        }
        .help(help)
    }
}
