// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchCore
import SwiftUI

/// Width of the unit column that trails every slider's value field — the
/// same on every row, empty where a value has no unit, so the sliders and
/// fields of a tab line up in one column whatever their units. Sized for
/// the widest unit shown ("mm/s"); what those millimetres are *of* is in
/// the row's label, where it can be read.
private let unitColumnWidth: CGFloat = 44

/// The editable value box next to each slider (the LinearMouse pattern:
/// drag for feel, type for exactness). `TextField(value:format:)` commits on
/// Enter or focus loss — not per keystroke — so half-typed numbers never
/// reach the engine; the clamping binding folds out-of-range entries back
/// into the supported range. The row's label titles the field for
/// VoiceOver (LabeledContent does that), so it carries no label of its own.
private struct NumericField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var fractionDigits: Int

    private var clampedValue: Binding<Double> {
        Binding(
            get: { value },
            set: { newValue in
                value = newValue.clamped(to: range)
            }
        )
    }

    var body: some View {
        TextField(
            title,
            value: clampedValue,
            format: .number.precision(.fractionLength(fractionDigits))
        )
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .frame(width: 64)
    }
}

/// The unit that trails a value field, in the fixed unit column; an empty
/// column keeps the row aligned with the ones that have a unit.
private struct UnitLabel: View {
    let unit: String?

    var body: some View {
        Text(unit ?? "")
            .foregroundStyle(.secondary)
            .frame(width: unitColumnWidth, alignment: .leading)
            .accessibilityHidden(true)
    }
}

/// A labeled slider paired with an editable exact-value field and the
/// unit column. The help text names the config key the row edits, so the
/// JSON a headless user hand-edits is one hover away.
///
/// The track is linear, or logarithmic for a wide multiplicative range
/// (the gain spans 0.1…10), where a linear track would cram everything
/// below 1.0 into its first tenth. Either way the value field reads and
/// writes real units, and so does VoiceOver: the slider's accessible
/// value is the value, not the track position.
struct SliderRow: View {
    /// How the track's position maps to the value.
    enum Track {
        case linear
        /// Linear in log10 space: every decade gets equal travel.
        case logarithmic

        func position(of value: Double) -> Double {
            switch self {
            case .linear:
                return value
            case .logarithmic:
                return log10(value)
            }
        }

        func value(at position: Double) -> Double {
            switch self {
            case .linear:
                return position
            case .logarithmic:
                return pow(10, position)
            }
        }
    }

    let title: String
    /// What VoiceOver calls the slider and its field when the visible
    /// title alone would not tell two rows apart ("Gain" under Pad 0 and
    /// under Pad 1).
    var accessibilityTitle: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    var track = Track.linear
    var fractionDigits: Int = 2
    var unit: String?
    var help: String

    /// The value as a track position, clamped both ways so the log of a
    /// hand-edited zero never reaches the slider.
    private var position: Binding<Double> {
        Binding(
            get: { track.position(of: value.clamped(to: range)) },
            set: { newValue in
                value = track.value(at: newValue).clamped(to: range)
            }
        )
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: position, in: track.position(of: range.lowerBound)...track.position(of: range.upperBound))
                    .accessibilityLabel(accessibilityTitle ?? title)
                    .accessibilityValue(spokenValue)
                NumericField(
                    title: accessibilityTitle ?? title, value: $value, range: range, fractionDigits: fractionDigits)
                UnitLabel(unit: unit)
            }
        }
        .help(help)
    }

    private var spokenValue: String {
        let number = value.formatted(.number.precision(.fractionLength(fractionDigits)))
        // The unit as VoiceOver should say it: "×" is "times" on every
        // gain row.
        let spokenUnit = unit == "\u{00D7}" ? "times" : unit
        return spokenUnit.map { "\(number) \($0)" } ?? number
    }
}

/// How far a grouped form insets section headers and row labels from the
/// edge of the section's box. A footer's own frame starts at that edge.
private let footerLeadingInset: CGFloat = 10

extension View {
    /// A section footer's layout, the same in every tab: leading-aligned,
    /// starting in line with the section's header and row labels, and
    /// wrapping across the section's width. Left alone, a grouped form sets
    /// a footer flush right.
    func settingsFooter() -> some View {
        multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, footerLeadingInset)
    }
}
