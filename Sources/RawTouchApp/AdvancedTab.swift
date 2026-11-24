// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchAppCore
import RawTouchCore
import SwiftUI

struct AdvancedTab: View {
    @ObservedObject var model: AppModel
    @State private var confirmingRestore = false

    var body: some View {
        Form {
            Section {
                Toggle("Accelerate with finger speed", isOn: model.binding(\.acceleration.enabled))
                    .help("acceleration.enabled — gain that rises with finger speed, on top of the scroll gain.")
                Group {
                    SliderRow(
                        title: "Curve steepness",
                        value: model.binding(\.acceleration.exponent),
                        range: RawTouchConfiguration.Acceleration.exponentRange,
                        help:
                            "acceleration.exponent — 0 is no acceleration at all, 1 is proportional to speed, 2 is steep."
                    )
                    SliderRow(
                        title: "Speed for 1× gain (finger)",
                        value: model.binding(\.acceleration.referenceFingerSpeed),
                        range: RawTouchConfiguration.Acceleration.referenceFingerSpeedRange,
                        fractionDigits: 0,
                        unit: "mm/s",
                        help:
                            "acceleration.referenceFingerSpeed — how fast the finger itself has to move on the pad, in millimetres per second, for the gain to be exactly 1×. Slower fingers get less, faster fingers more; the readout below says what the last gesture peaked at."
                    )
                    SliderRow(
                        title: "Lowest gain",
                        value: model.binding(\.acceleration.minGain),
                        range: RawTouchConfiguration.Acceleration.minGainRange,
                        fractionDigits: 2,
                        unit: "\u{00D7}",
                        help:
                            "acceleration.minGain — the floor for slow fingers. 1× keeps slow scrolling exactly physical."
                    )
                    SliderRow(
                        title: "Highest gain",
                        value: model.binding(\.acceleration.maxGain),
                        range: RawTouchConfiguration.Acceleration.maxGainRange,
                        fractionDigits: 2,
                        unit: "\u{00D7}",
                        help: "acceleration.maxGain — the ceiling for fast fingers."
                    )
                }
                .disabled(!model.config.acceleration.enabled)
            } header: {
                Text("Acceleration")
            } footer: {
                Text(
                    "Faster fingers scroll further: 1× at the speed set above, never below the lowest or above the highest gain."
                )
                .settingsFooter()
            }

            Section {
                Toggle("Sync scrolling to the display", isOn: model.binding(\.resampling.enabled))
                    .help(
                        "resampling.enabled \u{2014} one scroll step per display frame, timed to the display\u{2019}s refresh, instead of one per pad sample."
                    )
                // Not a setting: how late a connection's frames arrive is a
                // property of the path they take, which RawTouch measures.
                // Shown because it explains what the sync is doing.
                LabeledContent("Latency") {
                    VStack(alignment: .trailing, spacing: 1) {
                        // One line per connection, each allowed to wrap
                        // once: a row that grows without limit would push
                        // the form's own controls around.
                        ForEach(latencyLines, id: \.self) { line in
                            Text(line)
                                .lineLimit(2)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                }
                // One element, read as "Latency, USB: Left Pad 1.5 ms …",
                // rather than a label and two or three loose numbers.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Latency")
                .accessibilityValue(latencyLines.joined(separator: ". "))
                .help(latencyHelp)
            } header: {
                Text("Display sync")
            } footer: {
                Text(
                    "RawTouch measures how late each pad\u{2019}s frames arrive over each connection, from its first scroll, and picks the delay per gesture."
                )
                .settingsFooter()
            }

            Section {
                Toggle("Check for updates automatically", isOn: model.binding(\.updates.checkAutomatically))
                    .help(
                        "updates.checkAutomatically \u{2014} once a day, ask GitHub for the latest RawTouch and firmware releases. Check for Updates\u{2026} in the menu works either way."
                    )
            } header: {
                Text("Updates")
            } footer: {
                Text(
                    "The menu lists a newer RawTouch, or newer firmware for a connected keyboard. Nothing is downloaded."
                )
                .settingsFooter()
            }
        }
        .formStyle(.grouped)
        // Exactly as tall as its content, and the window sizes to it: the
        // whole form is always in view. Scrolling is off so that pixel
        // rounding between the form's height and the window's whole-point
        // height cannot leave a fraction of a point to scroll.
        .fixedSize(horizontal: false, vertical: true)
        .scrollDisabled(true)
        .safeAreaInset(edge: .bottom) {
            ActionBar(
                model: model,
                confirming: $confirmingRestore,
                title: "Restore Defaults\u{2026}",
                accessibilityTitle: "Restore advanced defaults",
                confirmTitle: "Restore Defaults",
                question: "Restore advanced defaults?",
                message: "Acceleration, display sync and the update check go back to their defaults.",
                action: model.restoreAdvancedDefaults
            )
        }
    }
}

extension AdvancedTab {
    /// One line per measured connection of the keyboard the Keyboards tab
    /// is pointed at — every connected keyboard's, while there is only one
    /// to point at.
    private var latencyLines: [String] {
        StatusFormatter.measuredLatencyLines(for: model.latencyKeyboards, configuration: model.config)
    }

    /// The row's tooltip carries the whole thing, in case a line wrapped
    /// out of sight.
    private var latencyHelp: String {
        let explanation =
            "What each pad\u{2019}s frames have measured they need over each connection, from their "
            + "own arrival times. RawTouch adopts it at the start of each gesture; there is nothing to set."
        return "\(latencyLines.joined(separator: "\n"))\n\n\(explanation)"
    }
}
