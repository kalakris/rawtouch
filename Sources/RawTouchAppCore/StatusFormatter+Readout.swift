// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import RawTouchCore

// What the settings window reads back from the scrolling itself: the last
// gesture's numbers, and the latency each pad's frames have measured.
extension StatusFormatter {
    // MARK: - Gesture readout

    /// "just now" / "12 s ago" / "3 min ago" / "2 h ago" — how old the
    /// readout's gesture is, so a flick from before lunch is not read as
    /// the one just made.
    public static func gestureAge(since liftOff: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(liftOff).rounded(.down))
        switch seconds {
        case ..<2: return "just now"
        case ..<60: return "\(seconds) s ago"
        case ..<3600: return "\(seconds / 60) min ago"
        default: return "\(seconds / 3600) h ago"
        }
    }

    /// "Peak finger 177 mm/s · acceleration up to 3.2×" — the touch half
    /// of the last gesture, in the units the Advanced tab's acceleration
    /// rows use. "Finger", because the line below it is also millimetres
    /// per second and is *not* the same quantity: this one is how fast the
    /// finger moved on the pad, that one is how fast content moved on
    /// screen. Two numbers in the same apparent unit have to say which is
    /// which where they are read, not in a tooltip. "Acceleration", not
    /// "gain": on the Scrolling tab this line sits under "Scroll gain",
    /// which is a different multiplier and is not included here.
    public static func gestureFingerLine(_ gesture: RawTouchGestureSummary) -> String {
        let countsPerMM =
            gesture.padCountsPerMM > 0
            ? gesture.padCountsPerMM
            : RawTouchCapabilities.Pad.fallbackCountsPerMM
        let speed = (gesture.peakFingerSpeed / countsPerMM).formatted(.number.precision(.fractionLength(0)))
        let gain = gesture.peakGain.formatted(.number.precision(.fractionLength(1)))
        return "Peak finger \(speed) mm/s \u{00B7} acceleration up to \(gain)\u{00D7}"
    }

    /// "Lift-off 1,065 mm/s on screen · coasted 575 mm" / "Lift-off 1,065 mm/s on screen,
    /// carried 4 frames · coasting…" / "Lift-off 14 mm/s on screen · no
    /// coast, under 23" — the lift-off half: the speed against the threshold the
    /// Momentum section sets, what flick sensitivity did to the lift
    /// (`gestureLiftFloorFragment`), and how far the coast went.
    ///
    /// In millimetres, like every other speed and distance on the strip:
    /// the gesture carries the density of the display it scrolled on, and
    /// the sliders it is read against are in millimetres too. The coast's
    /// duration is left out: it follows from the coasting time and the
    /// speed, and the line has to fit the settings window's readout strip
    /// at the fastest lift the momentum cap allows.
    public static func gestureLiftOffLine(_ gesture: RawTouchGestureSummary, minimumFlickSpeed: Double) -> String {
        let pointsPerMM =
            gesture.displayPointsPerMM > 0
            ? gesture.displayPointsPerMM
            : DisplayGeometry.fallbackPointsPerMM
        let speed = (gesture.liftOffSpeed / pointsPerMM).formatted(.number.precision(.fractionLength(0)))
        var lift = "Lift-off \(speed) mm/s on screen"
        if let carried = gestureLiftFloorFragment(gesture) {
            lift += ", \(carried)"
        }
        guard gesture.coasted else {
            let threshold = minimumFlickSpeed.formatted(.number.precision(.fractionLength(0)))
            return "\(lift) \u{00B7} no coast, under \(threshold)"
        }
        guard gesture.complete else {
            return "\(lift) \u{00B7} coasting\u{2026}"
        }
        let distance = (gesture.coastDistance / pointsPerMM).formatted(.number.precision(.fractionLength(0)))
        return "\(lift) \u{00B7} coasted \(distance) mm"
    }

    /// "carried 4 frames" when the lift-off strength floor carried the
    /// flick through that many fading frames, nil when the lift was
    /// followed as reported — absent rather than a word, so the strip says
    /// something only when the floor did something. The Momentum footer
    /// reads the same word: flicks that never say "carried" mean the floor
    /// is under this pad's fade; a plain lift that does means it is
    /// cutting into full contact.
    public static func gestureLiftFloorFragment(_ gesture: RawTouchGestureSummary) -> String? {
        switch gesture.liftFramesCarried {
        case 0: nil
        case 1: "carried 1 frame"
        case let n: "carried \(n) frames"
        }
    }

    /// "Latency 1.5 ms over USB · stalled 0 of 138 frames" /
    /// "Latency 5.2 ms over USB · wired split · stalled 2 of 138 frames" —
    /// the display-sync latency the gesture ran at, the connection it
    /// arrived over and, for a pad on the other half of a split keyboard,
    /// the split link it crossed first (together, what decides that
    /// latency), and how many display frames stalled waiting for a pad
    /// frame that had not arrived: the stutter count.
    public static func gestureTimingLine(_ gesture: RawTouchGestureSummary, in status: RawTouchStatus) -> String {
        let latency = gesture.latencyMs.formatted(.number.precision(.fractionLength(1)))
        let transport =
            status.endpoints.first { $0.id == gesture.endpoint }?
            .transport.displayName
            .map { " over \($0)" } ?? ""
        let split = gesture.splitLink.map { " \u{00B7} \(splitLinkName($0))" } ?? ""
        return
            "Latency \(latency) ms\(transport)\(split) \u{00B7} stalled \(gesture.heldFrames) of \(gesture.displayFrames) frames"
    }

    /// "wired split" / "wireless split".
    public static func splitLinkName(_ link: RawTouchSplitLink) -> String {
        switch link {
        case .wired: "wired split"
        case .wireless: "wireless split"
        }
    }

    /// "Pad 0 · Go60 Right" — which pad of which keyboard the last gesture
    /// came from, the pad under the name its keyboard gives it. Not which
    /// connection: a pad is the same pad however its frames got here, and
    /// the connection is on the latency line below, where it explains
    /// something. `keyboards` are the connected ones, grouped under
    /// `configuration`; a keyboard gone since leaves the pad's number.
    public static func gestureSourceLine(
        _ gesture: RawTouchGestureSummary,
        keyboards: [RawTouchKeyboard],
        configuration: RawTouchConfiguration = .init()
    ) -> String {
        guard
            let keyboard = keyboards.first(where: { $0.endpoints.contains { $0.id == gesture.endpoint } }),
            let endpoint = keyboard.endpoints.first(where: { $0.id == gesture.endpoint })
        else {
            return padName(gesture.padID)
        }
        let pad = padName(gesture.padID, deviceKey: endpoint.deviceKey, in: configuration)
        return "\(pad) \u{00B7} \(keyboard.name)"
    }

    /// How old a reading may be before it is shown as one: past this, the
    /// numbers are still true of the gesture they describe, but not of
    /// whatever the sliders say now.
    public static let staleGestureAge: TimeInterval = 30

    /// Whether the readout's numbers are old enough to be dimmed.
    public static func gestureIsStale(since liftOff: Date, now: Date) -> Bool {
        now.timeIntervalSince(liftOff) >= staleGestureAge
    }

    // MARK: - Measured latency

    /// The Advanced tab's latency row: what each pad's frames have
    /// measured they need over each connection, since that is not a
    /// setting but a measurement.
    ///
    /// Per pad *and* connection, because that is what the estimator is
    /// per: on a split keyboard one pad's frames are relayed from the
    /// other half and arrive later than the pad wired to the half the Mac
    /// talks to, and each transport adds its own delay on top. So a line
    /// is one connection — "USB: Left Pad 1.5 ms · Right Pad 5.2 ms" —
    /// with the keyboard named too once more than one is connected, and
    /// the pads under the names the user gave them.
    ///
    /// A connection with nothing measured on it is left out, and before
    /// anything at all has been measured the row is one line, "Not yet
    /// measured": saying nothing twice is what the row did in the state it
    /// spends its first minutes in. With no keyboard connected it says
    /// that instead, which is the reason there is no measurement.
    public static func measuredLatencyLines(
        for keyboards: [RawTouchKeyboard],
        configuration: RawTouchConfiguration = .init()
    ) -> [String] {
        guard !keyboards.isEmpty else {
            return ["No keyboard connected"]
        }
        let nameConnection = keyboards.count > 1
        let measured = keyboards.flatMap { keyboard in
            keyboard.endpoints.compactMap { endpoint -> String? in
                guard let pads = padLatencies(of: endpoint, in: configuration) else {
                    return nil
                }
                let label =
                    nameConnection
                    ? connectionName(endpoint)
                    : (endpoint.transport.displayName ?? endpoint.productName)
                return "\(label): \(pads)"
            }
        }
        return measured.isEmpty ? ["Not yet measured"] : measured
    }

    /// "Left Pad 1.5 ms · Right Pad 5.2 ms" — one connection's measured
    /// pads, named as the user named them; nil while none of them has a
    /// number, so the connection is left out entirely.
    private static func padLatencies(
        of endpoint: RawTouchStatus.Endpoint,
        in configuration: RawTouchConfiguration
    ) -> String? {
        let measured = endpoint.padIDs.filter { endpoint.measuredLatencyMs[$0] != nil }
        guard !measured.isEmpty else {
            return nil
        }
        return measured.map { padID in
            let name = padName(padID, deviceKey: endpoint.deviceKey, in: configuration)
            let latency = endpoint.measuredLatencyMs[padID] ?? 0
            return "\(name) \(latency.formatted(.number.precision(.fractionLength(1)))) ms"
        }
        .joined(separator: " \u{00B7} ")
    }
}
