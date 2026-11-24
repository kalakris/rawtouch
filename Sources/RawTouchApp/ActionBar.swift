// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchAppCore
import SwiftUI

/// The bar under every tab's form: the live readout of the last gesture
/// on the left — the same numbers whichever tab is up, so tuning the
/// curve on Advanced or a pad on Keyboards reads its effect without
/// switching tabs — and that tab's one button on the right, with the
/// confirmation it opens. The button names its scope in the question so
/// three tabs' buttons never read alike to VoiceOver.
struct ActionBar: View {
    @ObservedObject var model: AppModel
    @Binding var confirming: Bool
    let title: String
    /// What VoiceOver calls the button when the visible title is the same
    /// on every tab ("Remove Settings…"): the scope belongs in the label,
    /// not only in the confirmation it opens.
    var accessibilityTitle: String?
    let confirmTitle: String
    /// Whether what it removes is the user's own writing rather than a
    /// handful of switches.
    var isDestructive = false
    let question: String
    let message: String
    /// False leaves the bar with its readout and no button at all: there
    /// is nothing here to act on, and a greyed control says otherwise.
    var isShown = true
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            LiveReadout(model: model)
            Spacer(minLength: 8)
            if isShown {
                Button(title) {
                    confirming = true
                }
                .accessibilityLabel(accessibilityTitle ?? title)
                .accessibilityHint(message)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
        .confirmationDialog(question, isPresented: $confirming, titleVisibility: .visible) {
            Button(confirmTitle, role: isDestructive ? .destructive : nil, action: action)
            Button("Keep Settings", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(message)
        }
    }
}

/// What the last gesture measured, in the units the sliders use: which
/// pad of which keyboard, the touch's peak finger speed and gain, its
/// lift-off speed and how far it coasted, and the timing of the
/// connection it came in over. Updates at lift-off and again when the
/// coast ends; one placeholder line until the first gesture.
///
/// A reading older than half a minute is dimmed rather than removed: it
/// is still true of the gesture it describes, but no longer of whatever
/// the sliders say now. The next gesture brings it back.
private struct LiveReadout: View {
    @ObservedObject var model: AppModel

    /// Ticks the age line once a second while the window is up. A timeline
    /// rather than a `Timer.publish` stored on the view: this struct is
    /// rebuilt on every model change, and a stored timer would be rebuilt
    /// with it.
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            readout(now: context.date)
        }
        .help(
            "The last gesture, in the sliders\u{2019} units: peak finger speed is what \u{201C}Speed for 1× gain\u{201D} compares against; lift-off speed is what \u{201C}Minimum flick speed\u{201D} compares against; \u{201C}carried\u{201D} means flick sensitivity carried the flick through that many fading frames; stalled frames are display frames that waited for a late pad frame."
        )
    }

    @ViewBuilder
    private func readout(now: Date) -> some View {
        let lines = gestureLines
        let captionLine = captionLine(now: now)
        VStack(alignment: .leading, spacing: 2) {
            if let lines {
                // The caption stays, with the gesture's age: the numbers
                // below are an instrument reading, and a reading needs to
                // say what it is and when it was taken.
                Text(captionLine)
                    .foregroundStyle(.primary)
                ForEach(lines.indices, id: \.self) { index in
                    Text(lines[index])
                }
                .foregroundStyle(isStale(now: now) ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            } else {
                Text("Last gesture")
                    .foregroundStyle(.primary)
                Text("Scroll on a pad and its numbers appear here.")
                    .foregroundStyle(.secondary)
                // The four lines a gesture will fill, drawn as nothing:
                // the strip is as tall empty as it is full, so the window
                // does not grow under the hand at the first flick.
                Text(" ")
                    .foregroundStyle(.clear)
                    .accessibilityHidden(true)
                Text(" ")
                    .foregroundStyle(.clear)
                    .accessibilityHidden(true)
                Text(" ")
                    .foregroundStyle(.clear)
                    .accessibilityHidden(true)
            }
        }
        .font(.footnote)
        .monospacedDigit()
        .lineLimit(1)
        // The lines are written to fit at the sliders' usual values; at
        // their extremes (a 25 ms latency with a four-digit frame count) a
        // line can run 10% over, and a slightly smaller line beats "…".
        .minimumScaleFactor(0.85)
        // One element for VoiceOver, read as sentences rather than the
        // comma-spliced run-on `.combine` produces from five footnotes.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            lines.map { ([captionLine] + $0).joined(separator: ". ") }
                ?? "Last gesture. Scroll on a pad and its numbers appear here."
        )
    }

    /// "Last gesture, 3 s ago" — or just the caption before the model has
    /// stamped one (a gesture published before this window opened).
    private func captionLine(now: Date) -> String {
        guard let liftOff = model.lastGestureAt else {
            return "Last gesture"
        }
        return "Last gesture, \(StatusFormatter.gestureAge(since: liftOff, now: now))"
    }

    /// The four lines under the caption, or nil before the first gesture:
    /// built once, for the strip and for VoiceOver alike.
    private var gestureLines: [String]? {
        let status = model.status
        guard let gesture = status.lastGesture else {
            return nil
        }
        return [
            StatusFormatter.gestureSourceLine(gesture, keyboards: model.settingsKeyboards, configuration: model.config),
            StatusFormatter.gestureFingerLine(gesture),
            StatusFormatter.gestureLiftOffLine(gesture, minimumFlickSpeed: model.config.momentum.minimumFlickSpeed),
            StatusFormatter.gestureTimingLine(gesture, in: status),
        ]
    }

    /// Whether the numbers describe something too long ago to read as
    /// current. Unstamped (published before the window opened) counts as
    /// stale: it is at least as old as this window.
    private func isStale(now: Date) -> Bool {
        guard let liftOff = model.lastGestureAt else {
            return true
        }
        return StatusFormatter.gestureIsStale(since: liftOff, now: now)
    }
}
