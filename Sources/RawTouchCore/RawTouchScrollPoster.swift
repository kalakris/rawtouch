// MIT License
// Copyright (c) 2026 RawTouch contributors
// Derived from LinearMouse — Copyright (c) 2021-2026 LinearMouse (MIT).

import CoreGraphics
import Foundation
import os.log

/// Posts `TouchScrollEngine.Event`s as phased continuous scroll events:
/// pixel-unit scroll wheel events with scroll/momentum phase fields,
/// companion gesture events so apps treat the stream as a real trackpad
/// gesture series, a synthetic-source marker, and subpixel point-delta
/// accumulation.
///
/// Events go to `.cgSessionEventTap` — deliberately *not* the HID tap.
/// Posting at the HID tap would let `deviceFromCGEvent`'s last-active-device
/// fallback attribute the synthetic events to whatever mouse moved last, so
/// they would inherit that device's scrolling scheme; the session tap also
/// puts them downstream of other tools' HID-level taps, which is what lets
/// RawTouch compose with stock LinearMouse.
///
/// Must only be used from the event thread (the engine's owner already runs
/// there).
public final class RawTouchScrollPoster {
    private static let outputLineStepInPoints = 12.0

    private let eventSink: (CGEvent) -> Void
    private let modifierFlags: () -> CGEventFlags
    private let now: () -> TimeInterval
    private let windowOwnership: PointerWindowOwnership

    /// Set at each touch-down and held for the whole gesture, momentum
    /// included: a gesture that began over RawTouch's own window posts
    /// nothing at all (see `PointerWindowOwnership`). One decision per
    /// gesture — the window under the pointer is never consulted again
    /// while a finger is down.
    private var suppressingGesture = false

    /// One integer-point remainder per axis (axis 1 vertical, axis 2
    /// horizontal, as CoreGraphics numbers them).
    private var pointDeltaAccumulatorY = ScrollPointDeltaAccumulator()
    private var pointDeltaAccumulatorX = ScrollPointDeltaAccumulator()
    private let gestureSeriesPoster: GestureScrollSeriesPoster

    public init(
        eventSink: @escaping (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) },
        modifierFlags: @escaping () -> CGEventFlags = ModifierFlagsProvider.current,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        windowOwnership: PointerWindowOwnership = CGWindowPointerOwnership()
    ) {
        self.eventSink = eventSink
        self.modifierFlags = modifierFlags
        self.now = now
        self.windowOwnership = windowOwnership
        gestureSeriesPoster = GestureScrollSeriesPoster(eventSink: eventSink)
    }

    /// The stamp for everything posted in one burst: `CGEventTimestamp` is
    /// nanoseconds of system uptime (the clock `NSEvent.timestamp` divides
    /// down from). Real timestamps matter: programmatic `CGEvent`s carry
    /// none by default, and WebKit's ProMotion momentum interpolator fits
    /// its velocity curve from event timestamps — unstamped events broke
    /// Safari's rubber-band recovery on >60 Hz displays (scrolling dead at
    /// the page edge right after a bounce). Posting happens on the event
    /// thread within a millisecond of the frame or momentum tick it renders,
    /// so "now" is an honest stamp with correct ~10 ms spacing.
    private func currentTimestamp() -> CGEventTimestamp {
        CGEventTimestamp((now() * 1_000_000_000).rounded())
    }

    /// A scroll `began` is deferred until the finger's direction is known,
    /// and names one axis.
    ///
    /// Two facts about the apps on the other end drive this. WebKit's
    /// scrolling tree never delivers a zero-delta began to its rubber-band
    /// controller (`canHandleWheelEvent`), and to WebKit "zero" means the
    /// INTEGER point delta (`kCGScrollWheelEventPointDeltaAxis1`, which
    /// backs both AppKit's `scrollingDeltaY` and WebKit's unaccelerated
    /// delta), not the precise fixed-point one: without a real began, the
    /// reset that clears `m_ignoreMomentumScrolls` never fires and a
    /// re-scroll that lands while a bounce is settling vanishes whole,
    /// momentum included (`scroll-bench --catch-ramp` reproduces it). And
    /// WebKit and Chromium latch a gesture to the dominant axis of its
    /// first event: a began that leads on the wrong axis loses the whole
    /// gesture on the right one — a vertical flick whose first whole point
    /// of motion is sideways first-frame jitter latches horizontal, and
    /// all its vertical motion and momentum are ignored.
    ///
    /// So motion accumulates silently until the began can be trusted —
    /// until the motion meets one of `beganRules`: a flick-sized frame at
    /// once, anything else only after the landing window, whose direction
    /// is not believed, and an ambiguous start at the cap. The began then
    /// carries the dominant axis alone; the minor axis's accumulated
    /// motion rides on the next changed event instead, so nothing is lost
    /// and the first integer delta names the direction the finger is
    /// travelling. Flicks pay nothing; only the genuinely ambiguous starts
    /// wait for the cap. Real trackpads send mayBegin at rest and
    /// a began with the first motion; this mirrors that with the rounding,
    /// the latching and the landing accounted for. A lift decides a began
    /// still pending on the dominant axis; a touch that never reaches a
    /// whole point ends as `cancelled`, also like hardware.
    ///
    /// On a pad set to one scroll axis the engine zeroes the other before
    /// it gets here; its slow drags wait out the landing window too, its
    /// flicks do not.
    ///
    /// Nil once the began is out, and between touches.
    private var beganPending: PendingBegan?

    /// A touch's began while it waits for a direction: the motion
    /// accumulated since touch-down, the touch-down's time (which the
    /// rules' windows run from), and the latest frame's time and velocity
    /// (points per second, for the flick rules).
    struct PendingBegan {
        private let touchDownTimestamp: TimeInterval
        private var lastTimestamp: TimeInterval
        private var pending = (x: 0.0, y: 0.0)
        private var lastFrameVelocity = (x: 0.0, y: 0.0)

        init(touchDownAt timestamp: TimeInterval) {
            touchDownTimestamp = timestamp
            lastTimestamp = timestamp
        }

        /// Adds one frame's motion. Once the motion decides a direction —
        /// the first rule in `beganRules` it meets names the axis — returns
        /// the began, which carries that axis's accumulated motion alone,
        /// and the other axis's, which rides on the next changed event.
        /// Whatever the rule, that axis must hold at least a whole point,
        /// so the began's integer point delta is never zero — a flick-speed
        /// frame can follow a reversal and leave less than that pending.
        /// Nil keeps waiting.
        mutating func add(
            deltaX dx: Double,
            deltaY dy: Double,
            at timestamp: TimeInterval
        ) -> (began: (x: Double, y: Double), carried: (x: Double, y: Double))? {
            pending.x += dx
            pending.y += dy
            // A frame with no duration has no speed.
            let frameDuration = timestamp - lastTimestamp
            lastFrameVelocity = frameDuration > 0 ? (dx / frameDuration, dy / frameDuration) : (0, 0)
            lastTimestamp = timestamp

            let elapsed = timestamp - touchDownTimestamp
            let pending = pending
            let lastFrameVelocity = lastFrameVelocity
            guard
                let rule = RawTouchScrollPoster.beganRules.first(where: {
                    $0.matches(pending: pending, lastFrame: lastFrameVelocity, elapsed: elapsed)
                        && abs($0.axis == .vertical ? pending.y : pending.x) >= 1
                })
            else {
                return nil
            }
            let began = rule.axis == .vertical ? (x: 0.0, y: pending.y) : (x: pending.x, y: 0.0)
            return (began, (pending.x - began.x, pending.y - began.y))
        }

        /// What a lift makes of a began still pending: a whole point of
        /// motion releases it on the dominant axis, so the gesture that
        /// ends — and any coast after it — is one that began. Nil means
        /// the touch never began.
        func resolvedAtLift() -> (x: Double, y: Double)? {
            let ax = abs(pending.x)
            let ay = abs(pending.y)
            guard max(ax, ay) >= 1 else {
                return nil
            }
            return ax > ay ? (pending.x, 0) : (0, pending.y)
        }
    }

    /// One way the motion so far can decide the began's axis: once
    /// `after` has passed since touch-down, `axis`'s share of `motion` has
    /// reached `atLeast` and the other axis's share is under `ratio` of it.
    struct BeganRule {
        enum Axis {
            case vertical
            case horizontal
        }

        /// What a rule reads: the latest frame's velocity (`atLeast` in
        /// points per second), or all the motion pending since touch-down
        /// (`atLeast` in points).
        enum Motion {
            case lastFrame
            case pending
        }

        let axis: Axis
        let motion: Motion
        let after: TimeInterval
        let atLeast: Double
        let ratio: Double

        init(_ axis: Axis, _ motion: Motion, _ after: TimeInterval, _ atLeast: Double, _ ratio: Double) {
            self.axis = axis
            self.motion = motion
            self.after = after
            self.atLeast = atLeast
            self.ratio = ratio
        }

        func matches(
            pending: (x: Double, y: Double),
            lastFrame: (x: Double, y: Double),
            elapsed: TimeInterval
        ) -> Bool {
            let (x, y) = motion == .pending ? pending : lastFrame
            let (major, minor) = axis == .vertical ? (abs(y), abs(x)) : (abs(x), abs(y))
            // A microsecond of slack: a window met exactly on the frames'
            // own timeline must not miss through rounding.
            return elapsed + 1e-6 >= after && major >= atLeast && minor < major * ratio
        }
    }

    /// The flick speed: a single frame this fast along one axis (600 pt/s,
    /// six points a frame at the pad's 100 Hz) is one no landing slide
    /// reaches — the recorded ones topped out at 5.5 pt — and any real
    /// flick does.
    static let beganFlickSpeed = 600.0

    /// The landing window: a finger landing flattens onto the pad over its
    /// first frames, and the contact centroid slides along the finger
    /// meanwhile — sideways on this pad, 1 to 5 pt, before the gesture
    /// proper — so what the first 30 ms say about direction is not about
    /// the gesture.
    static let beganLandingWindow: TimeInterval = 0.030

    /// The cap: an ambiguous start is released anyway 80 ms after the
    /// touch-down.
    static let beganDecisionCap: TimeInterval = 0.080

    /// The began's direction rules, first match wins. Times and speeds, so
    /// they hold at any frame rate: the frames reaching the poster are the
    /// pad's (100 Hz) or the display's (60 or 120 Hz, resampled).
    /// Vertical is the far more common scroll and the landing slide never
    /// runs vertical, so it needs little evidence; horizontal, the axis
    /// the slide runs along and the rarer intent, is trusted only once it
    /// has travelled further than any slide does (a recorded slide ran
    /// 4.5 pt of pure sideways over four frames before a vertical flick).
    static let beganRules: [BeganRule] = [
        //    axis         motion      after               at least         ratio
        .init(.vertical, .lastFrame, 0, beganFlickSpeed, 1 / 3),  // a flick-sized frame decides alone
        .init(.horizontal, .lastFrame, 0, beganFlickSpeed, 1 / 3),
        .init(.vertical, .pending, beganLandingWindow, 2, 1 / 3),  // clear
        .init(.vertical, .pending, beganLandingWindow, 4, 1 / 2),  // settled
        .init(.horizontal, .pending, beganLandingWindow, 8, 1 / 3),  // horizontal needs more than a slide
        .init(.horizontal, .pending, beganLandingWindow, 12, 1 / 2),
        .init(.horizontal, .pending, beganDecisionCap, 8, 1 / 2),  // past the cap: horizontal only beyond a slide
        .init(.vertical, .pending, beganDecisionCap, 1, .infinity),  // otherwise vertical, once it has a whole point
    ]

    /// The minor axis's motion held back from the began, delivered with the
    /// next changed event.
    private var carried = (x: 0.0, y: 0.0)

    /// The touch ended as `cancelled` — it never began — so the coast the
    /// engine may still run after it has no gesture to belong to: its
    /// momentum events are not posted. Cleared at the next touch-down.
    private var touchCancelled = false

    /// Posts one engine event. `timestamp` is when the frame or display
    /// tick that produced it was sampled, on the engine's timeline: what
    /// the began's windows and flick speed are measured on (the events
    /// themselves are stamped with `now`, see `currentTimestamp`).
    public func post(_ engineEvent: TouchScrollEngine.Event, at timestamp: TimeInterval) {
        if case .touchBegan = engineEvent {
            suppressingGesture = windowOwnership.pointerIsOverOwnWindow()
            touchCancelled = false
        }
        guard !suppressingGesture, !(touchCancelled && engineEvent.isMomentum) else {
            // A gesture over RawTouch's own window (the engine still ran:
            // it reaches the settings window's readout, it just does not
            // scroll it), or the coast of a touch that never began.
            return
        }

        var scrollPhase: CGScrollPhase?
        var momentumPhase = CGMomentumScrollPhase.none
        var deltaX = 0.0
        var deltaY = 0.0

        switch engineEvent {
        case .touchBegan:
            // No scroll event yet (see `beganPending`); open the gesture
            // series now, exactly when a real trackpad's fingers-resting
            // event goes out.
            pointDeltaAccumulatorX.reset()
            pointDeltaAccumulatorY.reset()
            beganPending = PendingBegan(touchDownAt: timestamp)
            carried = (0, 0)
            gestureSeriesPoster.openSeriesIfNeeded(flags: modifierFlags(), timestamp: currentTimestamp())
            return
        case .touchChanged(let dx, let dy) where beganPending != nil:
            guard let release = beganPending?.add(deltaX: dx, deltaY: dy, at: timestamp) else {
                return
            }
            beganPending = nil
            scrollPhase = .began
            (deltaX, deltaY) = release.began
            // The axis the began leaves out is not lost: it rides on the
            // next changed event.
            carried = release.carried
        case .touchChanged(let dx, let dy):
            scrollPhase = .changed
            deltaX = dx + carried.x
            deltaY = dy + carried.y
            carried = (0, 0)
        case .touchEnded:
            // A lift decides a began still pending (see `resolvedAtLift`);
            // one that never began ends as `cancelled`, like hardware, with
            // no coast.
            switch beganPending.map({ $0.resolvedAtLift() }) {
            case .some(.some(let began)):
                postScrollEvent(scrollPhase: .began, deltaX: began.x, deltaY: began.y)
                scrollPhase = .ended
            case .some(.none):
                scrollPhase = .cancelled
            case .none:
                scrollPhase = .ended
            }
            touchCancelled = scrollPhase == .cancelled
            beganPending = nil
            carried = (0, 0)
        case .momentumBegan(let dx, let dy):
            momentumPhase = .begin
            deltaX = dx
            deltaY = dy
        case .momentumChanged(let dx, let dy):
            momentumPhase = .continuous
            deltaX = dx
            deltaY = dy
        case .momentumEnded:
            momentumPhase = .end
        }

        postScrollEvent(
            scrollPhase: scrollPhase,
            momentumPhase: momentumPhase,
            deltaX: deltaX,
            deltaY: deltaY
        )

        if case .momentumEnded = engineEvent {
            pointDeltaAccumulatorX.reset()
            pointDeltaAccumulatorY.reset()
        }
    }

    /// Builds and posts one phased scroll event, gesture companions first.
    private func postScrollEvent(
        scrollPhase: CGScrollPhase?,
        momentumPhase: CGMomentumScrollPhase = .none,
        deltaX: Double,
        deltaY: Double
    ) {
        guard
            let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: 0,
                wheel2: 0,
                wheel3: 0
            )
        else {
            return
        }

        let flags = modifierFlags()
        let timestamp = currentTimestamp()

        let view = ScrollWheelEventView(event)
        view.continuous = true
        view.scrollPhase = scrollPhase
        view.momentumPhase = momentumPhase

        // Axis 1 (vertical) and axis 2 (horizontal) carry the same set of
        // fields: line steps, integer points with subpixel carry, the
        // precise fixed-point delta. The integer
        // point delta is what AppKit's `scrollingDeltaY` reads (the field
        // stores whole points; see `ScrollPointDeltaAccumulator`), so the
        // carry runs through the coast too: truncated per tick, a coast
        // would lose up to a point every frame and stop moving in AppKit
        // apps well before it ends.
        view.deltaY = Int64((deltaY / Self.outputLineStepInPoints).rounded(.towardZero))
        view.deltaYPt = pointDeltaAccumulatorY.pointDelta(for: deltaY)
        view.deltaYFixedPt = deltaY
        view.deltaX = Int64((deltaX / Self.outputLineStepInPoints).rounded(.towardZero))
        view.deltaXPt = pointDeltaAccumulatorX.pointDelta(for: deltaX)
        view.deltaXFixedPt = deltaX

        event.flags = flags
        event.timestamp = timestamp
        event.isRawTouchSyntheticEvent = true

        gestureSeriesPoster.postCompanionsIfNeeded(
            scrollPhase: scrollPhase,
            deltaX: deltaX,
            deltaY: deltaY,
            flags: flags,
            timestamp: timestamp
        )
        eventSink(event)

        // Guarded: os_log's arguments are evaluated before the level check,
        // and this runs once per posted event.
        if RawTouchLog.scroll.isEnabled(type: .debug) {
            os_log(
                "post scroll deltaX=%{public}.3f deltaY=%{public}.3f phase=%{public}d momentum=%{public}d",
                log: RawTouchLog.scroll,
                type: .debug,
                deltaX,
                deltaY,
                scrollPhase?.rawValue ?? 0,
                momentumPhase.rawValue
            )
        }
    }

    /// Cancels an open synthetic gesture series (on teardown, when the
    /// engine was interrupted).
    public func closeGestureSeriesIfNeeded() {
        gestureSeriesPoster.endSeriesIfNeeded(flags: [], timestamp: currentTimestamp())
    }
}

extension TouchScrollEngine.Event {
    fileprivate var isMomentum: Bool {
        switch self {
        case .momentumBegan, .momentumChanged, .momentumEnded:
            true
        case .touchBegan, .touchChanged, .touchEnded:
            false
        }
    }
}
