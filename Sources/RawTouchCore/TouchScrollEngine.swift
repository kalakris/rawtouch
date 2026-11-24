// MIT License
// Copyright (c) 2026 RawTouch contributors
// Derived from LinearMouse — Copyright (c) 2021-2026 LinearMouse (MIT).

import Foundation

/// Turns a stream of absolute touch frames (`RawTouchFrame`) into
/// trackpad-style scroll gesture events.
///
/// The engine is a pure state machine with no timers or I/O of its own:
/// `handle(frame:)` is called for every parsed frame and `momentumTick(at:)`
/// is called by the owner on every display refresh (a free-running ~120 Hz
/// timer when there is no display link) whenever `wantsMomentumTicks` is
/// true; each tick's dt comes from its timestamp. This keeps the frame →
/// phase/momentum logic fully unit-testable with synthetic frames.
///
/// Gesture model:
/// - A scroll-mode touch-down begins a gesture (`.touchBegan`).
/// - Every subsequent scroll-mode sample emits `.touchChanged` with a
///   two-axis delta: deltaY from the change in the raw coordinate selected
///   by `Config.axis` (Y by default) and deltaX from the change in the other
///   raw coordinate, both scaled by `Config.pointsPerCount` and, when
///   `Config.acceleration` is enabled, by one shared velocity-dependent gain
///   (see `Config.Acceleration`). A pad mounted rotated 90° (its firmware
///   streams raw coordinates, without the `rotate-90; y-invert;` transforms
///   it applies to its own pointer deltas) selects X for vertical, and so Y
///   for horizontal.
/// - Lift-off emits `.touchEnded`; if the measured lift-off speed is high
///   enough, the engine enters momentum and the owner's decay timer produces
///   `.momentumBegan`/`.momentumChanged` deltas until the velocity decays away
///   (`.momentumEnded`).
/// - A touch-down during momentum cancels the momentum immediately
///   (`.momentumEnded` followed by `.touchBegan`) — the "catch" gesture.
///
/// Two axes, like an Apple trackpad: the gain is isotropic (one smoothed
/// speed from the 2-D magnitude, one gain for both components, so a
/// diagonal drag feels the same on both axes) and momentum is a 2-D
/// velocity vector — its start threshold, cap and stop floor apply to the
/// magnitude, and the decay preserves direction. `Config.axes` can switch a
/// component off entirely: its deltas are zero and its motion counts for
/// neither the speed estimate nor the momentum seed. There is no axis
/// locking here; apps that want it (WebKit does) apply their own.
///
/// The engine is pad-agnostic: `TouchScrollPipeline` arbitrates between the
/// device's pads and only ever forwards one pad's frames per gesture, so a
/// single engine instance serves every pad.
public final class TouchScrollEngine {
    /// Plain-value engine tuning, resolved from RawTouch's JSON
    /// configuration (`RawTouchConfiguration`) plus the device's
    /// self-reported orientation.
    public struct Config: Equatable {
        /// The defaults for a `Config` constructed directly (tests, the
        /// bench): the shipped `RawTouchConfiguration`'s, resolved for a pad
        /// of the fallback resolution on a display of the fallback density,
        /// so a directly built engine feels like the app out of the box. In
        /// the app every value comes through
        /// `RawTouchConfiguration.engineConfig`, per gesture, for the real
        /// pad and display.
        public enum Default {
            private static let shipped = RawTouchConfiguration()
            private static let countsPerMM = RawTouchCapabilities.Pad.fallbackCountsPerMM
            private static let pointsPerMM = DisplayGeometry.fallbackPointsPerMM

            public static let pointsPerCount = RawTouchConfiguration.pointsPerCount(
                gain: shipped.scale, pointsPerMM: pointsPerMM, countsPerMM: countsPerMM)
            public static let acceleration = shipped.acceleration.resolved(countsPerMM: countsPerMM)
            public static let momentum = shipped.momentum.resolved(pointsPerMM: pointsPerMM)
        }

        /// Screen points of scroll per Cirque touch count. Derived by the
        /// owner from the configured gain, the density of the display the
        /// gesture is on, and the pad's reported resolution — the engine
        /// itself just multiplies. Shared by both axes.
        public var pointsPerCount: Double

        /// When false, a finger moving toward an increasing raw coordinate
        /// on the vertical axis (`axis`) produces positive CGEvent deltaY
        /// (scroll-up). Set to flip. Derived by the owner from the device's
        /// self-reported orientation plus the user direction overrides (see
        /// `RawTouchCapabilities`).
        public var invert: Bool

        /// The same for the horizontal axis: when false, a finger moving
        /// toward an increasing raw coordinate on `horizontalAxis` produces
        /// positive CGEvent deltaX. Derived like `invert`, from `invertX`
        /// (see `RawTouchCapabilities.Pad.orientationHorizontalScrollInverted`).
        public var invertHorizontal: Bool

        /// The raw Cirque coordinate that drives vertical scrolling. The
        /// other one drives horizontal scrolling (`horizontalAxis`). Derived
        /// by the owner from the device's self-reported orientation.
        public var axis: RawTouchAxis

        /// Which scroll directions this pad produces. A component left out
        /// contributes nothing: zero deltas, and no say in the speed
        /// estimate or the momentum seed.
        public var axes: RawTouchScrollAxes

        /// Velocity-dependent gain ("ballistics"). Disabled by default, which
        /// preserves the plain linear counts → points mapping exactly.
        public var acceleration: Acceleration

        /// Momentum (coasting) tuning.
        public var momentum: Momentum

        /// The raw coordinate horizontal scrolling reads: the one `axis`
        /// does not.
        public var horizontalAxis: RawTouchAxis {
            axis.other
        }

        public var directionSign: Double {
            invert ? -1 : 1
        }

        public var horizontalDirectionSign: Double {
            invertHorizontal ? -1 : 1
        }

        /// The part of the configuration that decides which raw coordinate
        /// feeds which direction, and whether at all. A gesture cannot
        /// survive a change to it (its position history is on the old
        /// mapping), so the pipeline compares this to decide whether a live
        /// edit ends the gesture. The direction signs are deliberately not
        /// in here: the history is sign-free (the sign is applied on the way
        /// out), so `invert`/`invertHorizontal` apply live, like the gain.
        public struct AxisMapping: Equatable {
            public var axis: RawTouchAxis
            public var axes: RawTouchScrollAxes
        }

        public var axisMapping: AxisMapping {
            .init(axis: axis, axes: axes)
        }

        public init(
            pointsPerCount: Double = Default.pointsPerCount,
            invert: Bool = false,
            invertHorizontal: Bool = false,
            axis: RawTouchAxis = .y,
            axes: RawTouchScrollAxes = .both,
            acceleration: Acceleration = .init(),
            momentum: Momentum = .init()
        ) {
            self.pointsPerCount = pointsPerCount
            self.invert = invert
            self.invertHorizontal = invertHorizontal
            self.axis = axis
            self.axes = axes
            self.acceleration = acceleration
            self.momentum = momentum
        }

        /// Apple-trackpad-style ballistics: slow finger motion scrolls with
        /// sub-linear precision, fast flicks travel super-linearly.
        ///
        /// The gain applied to each frame's delta is
        /// `clamp((smoothedSpeed / referenceSpeed) ^ exponent, minGain, maxGain)`
        /// where `smoothedSpeed` is the exponentially smoothed finger speed in
        /// raw Cirque counts per second — the 2-D magnitude over the enabled
        /// axes, so the gain is the same for both components. With
        /// `exponent` 0 the curve is the identity (gain 1 everywhere).
        public struct Acceleration: Equatable {
            public var enabled: Bool
            public var exponent: Double
            public var referenceSpeed: Double
            public var minGain: Double
            public var maxGain: Double

            public init(
                enabled: Bool = false,
                exponent: Double = Default.acceleration.exponent,
                referenceSpeed: Double = Default.acceleration.referenceSpeed,
                minGain: Double = Default.acceleration.minGain,
                maxGain: Double = Default.acceleration.maxGain
            ) {
                self.enabled = enabled
                self.exponent = exponent
                self.referenceSpeed = referenceSpeed
                self.minGain = minGain
                self.maxGain = maxGain
            }
        }

        /// Momentum (coasting after lift-off) tuning. Every speed here is
        /// the magnitude of the 2-D momentum velocity.
        public struct Momentum: Equatable {
            /// Exponential decay time constant for the momentum velocity, in
            /// seconds.
            public var decayTimeConstant: TimeInterval

            /// Minimum measured lift-off speed (points/second) required to
            /// start momentum at all.
            public var startThreshold: Double

            /// Safety cap for the momentum seed (points/second). A faster
            /// seed is scaled down to this, keeping its direction.
            public var maxSpeed: Double

            /// A frame whose touch strength is below this fraction of the
            /// touch's reference strength (its 75th percentile) marks the
            /// finger leaving: the contact patch shrinks over the last few
            /// frames before a release and the reported position wanders
            /// with it. A flick (fast enough to coast, not braking) is then
            /// carried through the fade at its firm-contact velocity and
            /// coasts from it; anything else is followed as reported. 0
            /// turns this off.
            public var liftStrengthFloor: Double

            public init(
                decayTimeConstant: TimeInterval = Default.momentum.decayTimeConstant,
                startThreshold: Double = Default.momentum.startThreshold,
                maxSpeed: Double = Default.momentum.maxSpeed,
                liftStrengthFloor: Double = Default.momentum.liftStrengthFloor
            ) {
                self.decayTimeConstant = decayTimeConstant
                self.startThreshold = startThreshold
                self.maxSpeed = maxSpeed
                self.liftStrengthFloor = liftStrengthFloor
            }
        }
    }

    public enum Event: Equatable {
        case touchBegan
        case touchChanged(deltaX: Double, deltaY: Double)
        case touchEnded
        case momentumBegan(deltaX: Double, deltaY: Double)
        case momentumChanged(deltaX: Double, deltaY: Double)
        /// Momentum is over, whether it decayed away or was cut short by a
        /// touch (the catch) or `interrupt()`. Real trackpads tell the two
        /// apart with a bit on the event's IOHIDEvent; events made with
        /// `CGEvent(...)` carry none, so the distinction has no wire form.
        case momentumEnded
    }

    private enum State {
        case idle
        case touching
        case momentum
    }

    /// A 2-D quantity in (horizontal, vertical) order — raw counts, output
    /// counts, points or points/second depending on where it is used.
    private struct Vector: Equatable {
        var x: Double
        var y: Double

        static let zero = Vector(x: 0, y: 0)

        var magnitude: Double {
            (x * x + y * y).squareRoot()
        }

        static func + (lhs: Vector, rhs: Vector) -> Vector {
            Vector(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
        }

        static func - (lhs: Vector, rhs: Vector) -> Vector {
            Vector(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
        }

        static func * (lhs: Vector, rhs: Double) -> Vector {
            Vector(x: lhs.x * rhs, y: lhs.y * rhs)
        }

        static func += (lhs: inout Vector, rhs: Vector) {
            lhs = lhs + rhs
        }

        static func *= (lhs: inout Vector, rhs: Double) {
            lhs = lhs * rhs
        }
    }

    // MARK: - Tuning constants

    /// Momentum ends once the decayed speed (the vector's magnitude) drops
    /// below this (points/second). 40 pt/s is a third of a point per 120 Hz
    /// tick — invisible — yet every tick below it would still stream a
    /// momentum event and keep consumers in their momentum state. WebKit's
    /// ProMotion interpolator holds a rubber-band open for as long as that
    /// stream lasts, so an over-long crawl made Safari's post-bounce dead
    /// window trivially easy to hit (Apple's own tail ends far sooner). A
    /// floor of 10 would add more than a second to every tail with no
    /// visible change to the coast.
    private static let momentumStopSpeed = 40.0

    /// Only samples this recent (relative to lift-off) are retained for the
    /// momentum seed fit. Retention only — how much each sample counts is
    /// the weighting below.
    private static let velocityWindow: TimeInterval = 0.1

    /// Firm-contact history a touch needs before its strength can be
    /// judged to be fading (the touch-down ramp must not look like a
    /// lift): ten of the pad's 10 ms frames, whatever rate the frames
    /// reach the engine at.
    private static let carryMinimumHistory: TimeInterval = 0.1

    /// A fade longer than this is a light touch, not a lift: stop carrying
    /// and follow the finger again. Recorded lifts fade over 2–9 frames.
    private static let carryMaxDuration: TimeInterval = 0.12

    /// Along-track acceleration over speed (1/s) below which the finger is
    /// landing, not flicking, and the fade is followed rather than carried.
    /// −5/s would halve the speed within 140 ms; on the recordings 32 of 37
    /// flicks sat above it and most landings well below.
    private static let carryDecelerationLimit = -5.0

    /// Recency-weighting time constant for the lift-off velocity fit: a
    /// sample's weight is `exp(-age / this)` relative to the newest sample,
    /// so ~3 frames at the pad's 100 Hz cadence carry most of the estimate.
    /// This is what keeps the seed close to the finger's speed *at release*
    /// (a flick still accelerating at lift-off seeds at its final speed, not
    /// its 100 ms average), while a stop-then-lift still yields ~zero — the
    /// stationary tail out-weighs everything and fits a flat line. The same
    /// estimator (`WeightedVelocityFit`) extrapolates in `FrameResampler`.
    private static let liftOffWeightTimeConstant = WeightedVelocityFit.defaultWeightTimeConstant

    /// Exponential smoothing time constant for the finger-speed estimate that
    /// drives the acceleration gain. ~40 ms (about 4 frames at the pad's
    /// ~100 Hz cadence) keeps the gain from jittering frame to frame while
    /// still responding quickly to a flick.
    private static let speedSmoothingTimeConstant: TimeInterval = 0.04

    /// Per-frame position jumps larger than this many Cirque counts, on
    /// either enabled axis, are treated as sensor glitches: the position is
    /// re-anchored without emitting a huge delta, and the touch's velocity
    /// history restarts there. A jump on a disabled axis is nothing to the
    /// engine, so it does not veto the other axis. `FrameResampler` applies
    /// the same bound so a jump reaches the engine whole.
    static let maxPlausibleStepCounts = 512.0

    // MARK: - State

    public var config: Config

    private var state: State = .idle

    /// Everything one touch accumulates, from its touch-down through the
    /// end of the coast that may follow it. Replaced whole at every
    /// touch-down and by `reset()`, so nothing of one touch can leak into
    /// the next.
    private struct Touch {
        /// Names the gesture in its summary: two touches whose numbers
        /// happen to match (two identical taps) are still two gestures.
        var gestureID: UInt64 = 0

        /// Where this touch's frames come from. Positions and times are
        /// only ever differenced within one source.
        var source = RawTouchSourceID(endpoint: .default, padID: 0)

        /// The last frame's raw position, in the engine's (horizontal,
        /// vertical) order — `x` is the raw coordinate on
        /// `config.horizontalAxis`, `y` the one on `config.axis`.
        var lastPosition = Vector.zero
        var lastTimestamp: TimeInterval = 0

        /// When the finger landed, and the newest frame whose strength is
        /// in the histogram: the firm history `carryMinimumHistory` asks
        /// for is the time between them.
        var downTimestamp: TimeInterval = 0
        var lastStrengthTimestamp: TimeInterval = 0

        /// Exponentially smoothed finger speed in raw counts/second — the
        /// 2-D magnitude over the enabled axes — or nil until the first
        /// movement frame of the touch. Seeding from the first observed
        /// instantaneous speed (rather than ramping up from zero) means a
        /// slow deliberate drag gets its sub-unity gain immediately instead
        /// of starting in a minGain dead zone, and a fast flick gets
        /// boosted from its very first frames.
        var smoothedSpeed: Double?

        /// Recent raw finger positions (counts, in scroll-axis order) used
        /// to measure the lift-off velocity, each with the touch strength
        /// its frame reported (nil: the touch-down origin).
        var samples: [(position: Vector, timestamp: TimeInterval, strength: Int?)] = []

        /// Touch strengths seen this touch, binned (the wire value is a
        /// byte), for the reference strength the lift-off floor is
        /// relative to. A percentile rather than the peak, so one hard
        /// press does not set it.
        var strengthHistogram = [Int](repeating: 0, count: 256)
        var strengthSampleCount = 0

        var fade = Fade.none

        /// Points/second, direction-adjusted, while coasting.
        var momentumVelocity = Vector.zero
        var momentumBegan = false
        var lastMomentumTimestamp: TimeInterval = 0

        // Gesture bookkeeping for `lastGestureSummary`: peaks over the
        // touch, path length in points, and the coast's distance and start
        // time.
        var peakFingerSpeed = 0.0
        var peakGain = 1.0
        var touchDistance = 0.0
        var coastDistance = 0.0
        var coastStartTimestamp: TimeInterval = 0
    }

    /// What the touch is doing once its strength has started to fade.
    private enum Fade: Equatable {
        /// Firm contact so far.
        case none
        /// A landing (or a slow lift): the finger is followed as reported.
        case follow
        /// A flick: the firm-contact finger velocity (counts per second)
        /// being carried through the fading frames, the acceleration gain
        /// in force when it began, since when, and how many frames it has
        /// covered.
        case carry(Vector, gain: Double, since: TimeInterval, frames: Int)
    }

    /// What one touched frame does once its fade has been decided.
    private enum FadeStep {
        /// Follow the finger as reported (the ordinary path, glitch guard
        /// included).
        case follow
        /// Emit the carried velocity (counts per second) at its gain over
        /// the time since the last frame.
        case carry(Vector, gain: Double)
        /// Emit nothing; this frame's position becomes the new anchor.
        case reanchor
    }

    private var touch = Touch()

    /// Touches begun so far; the latest one's `gestureID`.
    private var touchCount: UInt64 = 0

    /// What the most recent gesture measured (pad-agnostic: `padID` and
    /// `endpoint` are left at their defaults for the owner to fill in).
    /// Written at lift-off — `complete` false when a coast follows — and
    /// again when that coast ends, is caught, or is interrupted. Nil until
    /// the first gesture ends. Read it after `handle(frame:)`,
    /// `momentumTick(at:)` or `interrupt()`; it changes only there.
    public private(set) var lastGestureSummary: RawTouchGestureSummary?

    public init(config: Config = .init()) {
        self.config = config
    }

    /// True while the owner should drive `momentumTick(at:)`, once per
    /// display refresh.
    public var wantsMomentumTicks: Bool {
        state == .momentum
    }

    /// True while a gesture is in progress (touching or coasting).
    /// `TouchScrollPipeline` uses this to clear its gesture ownership once
    /// a gesture has fully ended.
    public var isActive: Bool {
        state != .idle
    }

    // MARK: - Frame input

    public func handle(frame: RawTouchFrame) -> [Event] {
        if frame.touched, frame.scrollMode {
            return handleScrollTouch(frame: frame)
        }

        if !frame.touched {
            return handleRelease(frame: frame)
        }

        // touched, but not in scroll mode: pointer-time frames. The firmware
        // handles the pointer via its normal relative reports, so these are
        // ignored for scrolling — except that a gesture in progress ends
        // (without momentum) when the scroll layer is released mid-touch.
        if state == .touching {
            recordLiftOff(speed: 0, willCoast: false)
            reset()
            return [.touchEnded]
        }

        return []
    }

    /// Close out any gesture in progress (device disconnected, feature
    /// disabled, app stopping). Returns the events needed to leave the
    /// synthetic event stream in a consistent state.
    public func interrupt() -> [Event] {
        defer {
            reset()
        }

        switch state {
        case .idle:
            return []
        case .touching:
            recordLiftOff(speed: 0, willCoast: false)
            return [.touchEnded]
        case .momentum:
            completeGestureSummary(at: touch.lastMomentumTimestamp)
            return touch.momentumBegan ? [.momentumEnded] : []
        }
    }

    /// The raw position driving the scroll math, in (horizontal, vertical)
    /// order per `Config.axis` — the two coordinates `FrameResampler` fits.
    private func position(of frame: RawTouchFrame) -> Vector {
        Vector(x: Double(frame[config.horizontalAxis]), y: Double(frame[config.axis]))
    }

    /// Zeroes the component of a raw-count vector whose scroll direction is
    /// switched off (`Config.axes`), so it contributes to nothing — not the
    /// delta, not the speed, not the momentum seed.
    private func enabled(_ vector: Vector) -> Vector {
        Vector(
            x: config.axes.includesHorizontal ? vector.x : 0,
            y: config.axes.includesVertical ? vector.y : 0
        )
    }

    /// Applies the direction signs: raw-axis motion → CGEvent delta sign.
    private func signed(_ vector: Vector) -> Vector {
        Vector(x: vector.x * config.horizontalDirectionSign, y: vector.y * config.directionSign)
    }

    private func handleScrollTouch(frame: RawTouchFrame) -> [Event] {
        let position = position(of: frame)

        switch state {
        case .idle:
            beginTouch(position: position, frame: frame)
            return [.touchBegan]

        case .momentum:
            // The "catch": a finger touching down while coasting stops the
            // scroll dead, exactly like a real trackpad.
            let hadBegunMomentum = touch.momentumBegan
            completeGestureSummary(at: frame.timestamp)
            beginTouch(position: position, frame: frame)
            return hadBegunMomentum ? [.momentumEnded, .touchBegan] : [.touchBegan]

        case .touching where frame.source != touch.source:
            // The same finger over another of its keyboard's connections:
            // the one way the pipeline lets a second source into a touch
            // (its handover). Its positions and times are on that source's
            // timeline, so the touch continues from here without a delta.
            restartHistory(at: position, frame: frame)
            return []

        case .touching:
            let (fade, step) = nextFade(weak: isWeak(strength: frame.z), at: frame.timestamp)
            touch.fade = fade
            switch step {
            case .follow:
                break
            case .carry(let velocity, let gain):
                return carriedStep(velocity, gain: gain, to: position, at: frame.timestamp)
            case .reanchor:
                // The finger is followed from where it is now; the distance
                // carried stays as a gesture-local offset, exactly like the
                // resampler's carry.
                touch.lastPosition = position
                touch.lastTimestamp = frame.timestamp
                return []
            }

            let deltaCounts = enabled(position - touch.lastPosition)
            let dt = frame.timestamp - touch.lastTimestamp
            guard abs(deltaCounts.x) <= Self.maxPlausibleStepCounts, abs(deltaCounts.y) <= Self.maxPlausibleStepCounts
            else {
                // A glitch, not motion.
                restartHistory(at: position, frame: frame)
                return [.touchChanged(deltaX: 0, deltaY: 0)]
            }
            touch.lastPosition = position
            touch.lastTimestamp = frame.timestamp

            let gain = updatedGain(deltaCounts: deltaCounts, dt: dt)
            appendSample(position: position, timestamp: frame.timestamp, strength: frame.z)
            let delta = signed(deltaCounts * (gain * config.pointsPerCount))
            touch.peakGain = max(touch.peakGain, gain)
            if let smoothedSpeed = touch.smoothedSpeed {
                touch.peakFingerSpeed = max(touch.peakFingerSpeed, smoothedSpeed)
            }
            touch.touchDistance += delta.magnitude
            return [.touchChanged(deltaX: delta.x, deltaY: delta.y)]
        }
    }

    /// The touch's fade after a frame of this strength at `timestamp`, and
    /// what that frame does — the one place the fade is decided. Reads only
    /// state from before the frame: `flickVelocity` and `currentGain` see
    /// firm contact alone.
    private func nextFade(weak: Bool, at timestamp: TimeInterval) -> (Fade, FadeStep) {
        switch (touch.fade, weak) {
        case (.none, false), (.follow, _):
            return (touch.fade, .follow)
        case (.none, true):
            // The finger is leaving. Decided once: a flick is carried
            // through the fade at its firm-contact velocity (the shrinking
            // contact patch's positions are not the finger), anything else
            // is followed as reported, starting with this frame.
            guard let velocity = flickVelocity() else {
                return (.follow, .follow)
            }
            let gain = currentGain
            return (.carry(velocity, gain: gain, since: timestamp, frames: 1), .carry(velocity, gain: gain))
        case (.carry(let velocity, let gain, let since, let frames), true)
        where timestamp - since <= Self.carryMaxDuration:
            return (.carry(velocity, gain: gain, since: since, frames: frames + 1), .carry(velocity, gain: gain))
        case (.carry, _):
            // Firm contact again, and the next fade is judged afresh; or a
            // fade too long to be a lift — a light touch, followed from here
            // on (the carry's samples stopped where it began, so judging it
            // again would only carry it again).
            return (weak ? .follow : .none, .reanchor)
        }
    }

    /// Carries a flick through one fading frame: the carried velocity over
    /// the time since the last frame, whatever the frame reported.
    private func carriedStep(
        _ velocity: Vector,
        gain: Double,
        to position: Vector,
        at timestamp: TimeInterval
    ) -> [Event] {
        let step = velocity * (max(0, timestamp - touch.lastTimestamp) * gain)
        touch.lastPosition = position
        touch.lastTimestamp = timestamp
        let delta = signed(step * config.pointsPerCount)
        touch.touchDistance += delta.magnitude
        return [.touchChanged(deltaX: delta.x, deltaY: delta.y)]
    }

    /// Updates the smoothed finger-speed estimate with this frame's movement
    /// and returns the acceleration gain to apply to its delta — one gain
    /// for both components, from the 2-D speed. Gain is 1 (plain linear
    /// behavior) while acceleration is disabled.
    private func updatedGain(deltaCounts: Vector, dt: TimeInterval) -> Double {
        let acceleration = config.acceleration
        guard acceleration.enabled else {
            return 1
        }

        if dt > 0 {
            let instantaneousSpeed = deltaCounts.magnitude / dt
            if let smoothedSpeed = touch.smoothedSpeed {
                let alpha = 1 - exp(-dt / Self.speedSmoothingTimeConstant)
                touch.smoothedSpeed = smoothedSpeed + alpha * (instantaneousSpeed - smoothedSpeed)
            } else {
                touch.smoothedSpeed = instantaneousSpeed
            }
        }

        return currentGain
    }

    /// The acceleration gain the smoothed finger speed currently earns
    /// (1 with acceleration off): what the next delta is scaled by, and
    /// what a lift-off velocity is scaled by once.
    private var currentGain: Double {
        let acceleration = config.acceleration
        guard acceleration.enabled, let smoothedSpeed = touch.smoothedSpeed, acceleration.referenceSpeed > 0 else {
            return 1
        }
        // pow(0, 0) == 1, so exponent 0 is the identity even from rest.
        let gain = pow(smoothedSpeed / acceleration.referenceSpeed, acceleration.exponent)
        return gain.clamped(to: acceleration.minGain...acceleration.maxGain)
    }

    private func handleRelease(frame: RawTouchFrame) -> [Event] {
        guard state == .touching else {
            // A stray release while idle or coasting carries no information.
            return []
        }

        // Do not trust x/y on the release report — only the flags matter.
        // A flick carried through its fade coasts from the very velocity
        // that was on screen; anything else from the motion it showed.
        let velocity: Vector
        let framesCarried: Int
        if case .carry(let carried, let gain, _, let frames) = touch.fade {
            velocity = signed(carried * (gain * config.pointsPerCount))
            framesCarried = frames
        } else {
            velocity = liftOffVelocity()
            framesCarried = 0
        }
        touch.fade = .none
        let speed = velocity.magnitude

        recordLiftOff(
            speed: speed,
            willCoast: speed >= config.momentum.startThreshold,
            framesCarried: framesCarried
        )
        touch.coastDistance = 0
        touch.coastStartTimestamp = frame.timestamp

        if speed >= config.momentum.startThreshold {
            state = .momentum
            // Cap the magnitude, keep the direction.
            touch.momentumVelocity =
                speed > config.momentum.maxSpeed
                ? velocity * (config.momentum.maxSpeed / speed)
                : velocity
            touch.momentumBegan = false
            touch.lastMomentumTimestamp = frame.timestamp
            touch.samples.removeAll(keepingCapacity: true)
            return [.touchEnded]
        }

        reset()
        return [.touchEnded]
    }

    private func beginTouch(position: Vector, frame: RawTouchFrame) {
        state = .touching
        touchCount += 1
        touch = Touch(
            gestureID: touchCount,
            source: frame.source,
            lastPosition: position,
            lastTimestamp: frame.timestamp,
            downTimestamp: frame.timestamp
        )
        appendSample(position: position, timestamp: frame.timestamp, strength: nil)
    }

    /// Re-anchors the touch at `frame` without a delta, and restarts the
    /// velocity fit and the speed estimate from there: a history spanning
    /// a jump (a glitch, or a switch to another source's timeline) would
    /// read it as a flick.
    private func restartHistory(at position: Vector, frame: RawTouchFrame) {
        touch.source = frame.source
        touch.lastPosition = position
        touch.lastTimestamp = frame.timestamp
        touch.samples.removeAll(keepingCapacity: true)
        touch.smoothedSpeed = nil
        appendSample(position: position, timestamp: frame.timestamp, strength: frame.z)
    }

    // MARK: - Gesture summary

    /// Writes the touch half of the summary at lift-off. `willCoast` false
    /// closes the gesture right here; true leaves it open for
    /// `completeGestureSummary(at:)`.
    private func recordLiftOff(speed: Double, willCoast: Bool, framesCarried: Int = 0) {
        lastGestureSummary = RawTouchGestureSummary(
            gestureID: touch.gestureID,
            peakFingerSpeed: touch.peakFingerSpeed,
            peakGain: touch.peakGain,
            touchDistance: touch.touchDistance,
            liftOffSpeed: speed,
            complete: !willCoast,
            liftFramesCarried: framesCarried
        )
    }

    /// Whether a frame's strength is below the lift floor — once the touch
    /// has enough firm history for its reference to mean something.
    private func isWeak(strength: Int) -> Bool {
        // A microsecond of slack: a history met exactly on the frames' own
        // timeline must not miss through rounding.
        let history = touch.lastStrengthTimestamp - touch.downTimestamp + 1e-6
        guard config.momentum.liftStrengthFloor > 0, history >= Self.carryMinimumHistory,
            let reference = referenceStrength
        else {
            return false
        }
        return Double(strength) < config.momentum.liftStrengthFloor * Double(reference)
    }

    /// The firm-contact velocity to carry through a lift (output units per
    /// second), or nil when the fade is not a flick: too slow to coast, or
    /// the finger was decelerating hard — a landing, whose fade is real
    /// slowing and is followed. Called at the first fading frame, before
    /// it is recorded, so every sample here is firm contact.
    private func flickVelocity() -> Vector? {
        guard touch.samples.count >= 3 else {
            return nil
        }
        let velocity = fingerVelocity()
        let speed = velocity.magnitude
        guard speed > 0, speed * currentGain * config.pointsPerCount >= config.momentum.startThreshold else {
            return nil
        }
        let xs = touch.samples.map { ($0.position.x, $0.timestamp) }
        let ys = touch.samples.map { ($0.position.y, $0.timestamp) }
        if let qx = WeightedVelocityFit.quadratic(through: xs, weightTimeConstant: Self.liftOffWeightTimeConstant),
            let qy = WeightedVelocityFit.quadratic(through: ys, weightTimeConstant: Self.liftOffWeightTimeConstant)
        {
            let alongTrack = (qx.acceleration * velocity.x + qy.acceleration * velocity.y) / speed
            if alongTrack / speed < Self.carryDecelerationLimit {
                return nil
            }
        }
        return velocity
    }

    /// Fills in the coast half once the coast is over — decayed away,
    /// caught, or interrupted — so the readout says how far it went.
    private func completeGestureSummary(at timestamp: TimeInterval) {
        guard var summary = lastGestureSummary, !summary.complete else {
            return
        }
        summary.coastDistance = touch.coastDistance
        summary.coastDuration = max(0, timestamp - touch.coastStartTimestamp)
        summary.complete = true
        lastGestureSummary = summary
    }

    private func appendSample(position: Vector, timestamp: TimeInterval, strength: Int?) {
        touch.samples.append((position: position, timestamp: timestamp, strength: strength))
        let cutoff = timestamp - Self.velocityWindow
        touch.samples.removeAll { $0.timestamp < cutoff }
        if let strength {
            touch.strengthHistogram[min(255, max(0, strength))] += 1
            touch.strengthSampleCount += 1
            touch.lastStrengthTimestamp = timestamp
        }
    }

    /// The touch's reference strength: the 75th percentile of every
    /// strength reported since touch-down. Nil before any was.
    private var referenceStrength: Int? {
        guard touch.strengthSampleCount > 0 else {
            return nil
        }
        let target = Int(Double(touch.strengthSampleCount) * 0.75)
        var seen = 0
        for (value, count) in touch.strengthHistogram.enumerated() where count > 0 {
            seen += count
            if seen > target {
                return value
            }
        }
        return 255
    }

    /// The finger's velocity in raw counts per second, per enabled axis:
    /// the slope of a recency-weighted least-squares line through the
    /// retained raw finger positions, fitted on each axis over the same
    /// timestamps. Weighting (see `liftOffWeightTimeConstant`) puts the
    /// estimate at the newest sample's speed with ~30 ms of effective lag;
    /// fitting all samples rather than differencing two endpoints keeps it
    /// robust to single-frame noise. A disabled axis contributes nothing.
    private func fingerVelocity() -> Vector {
        enabled(
            Vector(
                x: WeightedVelocityFit.slope(
                    through: touch.samples.map { ($0.position.x, $0.timestamp) },
                    weightTimeConstant: Self.liftOffWeightTimeConstant
                ) ?? 0,
                y: WeightedVelocityFit.slope(
                    through: touch.samples.map { ($0.position.y, $0.timestamp) },
                    weightTimeConstant: Self.liftOffWeightTimeConstant
                ) ?? 0
            ))
    }

    /// Velocity in scroll points/second (scaled and direction-adjusted)
    /// at the moment of lift-off, per component: `fingerVelocity()` times
    /// the acceleration gain in force at lift, times points per count. The
    /// gain is applied once, to the fitted finger velocity, rather than
    /// fitted through gain-scaled positions: the gain lags the finger by
    /// its own smoothing, and a fit through scaled positions would blend
    /// that lag over the whole window — on recorded flicks that puts the
    /// seed at a median 0.69 of peak speed × peak gain, against 0.96 this
    /// way. (A flick never gets here — it is carried through its fade
    /// instead.)
    private func liftOffVelocity() -> Vector {
        signed(fingerVelocity() * (currentGain * config.pointsPerCount))
    }

    // MARK: - Momentum

    public func momentumTick(at timestamp: TimeInterval) -> [Event] {
        guard state == .momentum else {
            return []
        }

        let dt = (timestamp - touch.lastMomentumTimestamp).clamped(to: 1.0 / 240.0...1.0 / 24.0)
        touch.lastMomentumTimestamp = timestamp

        // Isotropic decay: the speed decays, the direction holds.
        touch.momentumVelocity *= exp(-dt / config.momentum.decayTimeConstant)

        guard touch.momentumVelocity.magnitude > Self.momentumStopSpeed else {
            let hadBegunMomentum = touch.momentumBegan
            completeGestureSummary(at: timestamp)
            reset()
            return hadBegunMomentum ? [.momentumEnded] : []
        }

        let delta = touch.momentumVelocity * dt
        touch.coastDistance += delta.magnitude
        if touch.momentumBegan {
            return [.momentumChanged(deltaX: delta.x, deltaY: delta.y)]
        }

        touch.momentumBegan = true
        return [.momentumBegan(deltaX: delta.x, deltaY: delta.y)]
    }

    private func reset() {
        state = .idle
        touch = Touch()
    }
}
