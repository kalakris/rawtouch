// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchAppCore
import RawTouchCore
import SwiftUI

struct ScrollingTab: View {
    @ObservedObject var model: AppModel
    @State private var confirmingRestore = false

    var body: some View {
        Form {
            Section {
                SliderRow(
                    title: "Scroll gain",
                    value: model.binding(\.scale),
                    range: RawTouchConfiguration.scaleRange,
                    track: .logarithmic,
                    unit: "\u{00D7}",
                    help:
                        "scale — content travel relative to finger travel. 1× is physical: a millimetre on the pad moves a millimetre on screen, on any display."
                )
                Toggle("Reverse scrolling", isOn: model.binding(\.reverseScrolling))
                    .help(
                        "reverseScrolling — flips both directions. RawTouch always follows the macOS \u{201C}Natural scrolling\u{201D} setting, like Standard mode does; this flips on top of it."
                    )
            } header: {
                Text("Gain and direction")
            } footer: {
                Text(
                    "1× moves content exactly as far as your finger; acceleration (Advanced tab) adds reach at speed. Direction follows the system\u{2019}s Natural scrolling setting, as in Standard mode."
                )
                .settingsFooter()
            }

            Section {
                SliderRow(
                    title: "Coasting time",
                    value: model.binding(\.momentum.decayTimeConstant),
                    range: RawTouchConfiguration.Momentum.decayTimeConstantRange,
                    unit: "s",
                    help:
                        "momentum.decayTimeConstant — how quickly a coast dies down. An Apple trackpad is about 0.5 s."
                )
                SliderRow(
                    title: "Minimum flick speed (on screen)",
                    value: model.binding(\.momentum.minimumFlickSpeed),
                    range: RawTouchConfiguration.Momentum.minimumFlickSpeedRange,
                    fractionDigits: 0,
                    unit: "mm/s",
                    help:
                        "momentum.minimumFlickSpeed — a lift that moves content slower than this stops dead instead of coasting. Millimetres of content on screen per second (not finger travel), so it means the same on any display."
                )
                // A log track, like the gain: the useful range runs over
                // two and a half decades, and a linear one would leave
                // every usable value in its first centimetre.
                SliderRow(
                    title: "Maximum coast speed (on screen)",
                    value: model.binding(\.momentum.maximumCoastSpeed),
                    range: RawTouchConfiguration.Momentum.maximumCoastSpeedRange,
                    track: .logarithmic,
                    fractionDigits: 0,
                    unit: "mm/s",
                    help:
                        "momentum.maximumCoastSpeed — caps how fast a coast can start, however hard the flick. Millimetres of content on screen per second (not finger travel)."
                )
                SliderRow(
                    title: "Flick sensitivity",
                    value: model.binding(\.momentum.liftStrengthFloor),
                    range: RawTouchConfiguration.Momentum.liftStrengthFloorRange,
                    fractionDigits: 2,
                    help:
                        "momentum.liftStrengthFloor — how faint a touch has to get, against its own firm contact, before RawTouch treats the finger as leaving. A flick keeps its speed through those fading frames and coasts from it; anything else is followed as reported. A fraction, not a speed: 0 = off, 0.95 = most eager."
                )
            } header: {
                Text("Momentum")
            } footer: {
                Text(
                    "How far scrolling keeps going after the finger lifts. Higher values treat a fading touch as a flick sooner. The readout says \u{201C}carried\u{201D} when it acted."
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
                accessibilityTitle: "Restore scrolling defaults",
                confirmTitle: "Restore Defaults",
                question: "Restore scrolling defaults?",
                message:
                    "Scroll gain, direction, momentum and flick sensitivity go back to their defaults. Per-pad gain and direction overrides on the Keyboards tab are kept.",
                action: model.restoreScrollingDefaults
            )
        }
    }

}
