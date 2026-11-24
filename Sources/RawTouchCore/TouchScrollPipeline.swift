// MIT License
// Copyright (c) 2026 RawTouch contributors
// Derived from LinearMouse's HID device manager, its event-thread half —
// Copyright (c) 2021-2026 LinearMouse (MIT). The IOHID/device half lives in
// `RawTouchDeviceManager`.

import Foundation
import os.log

/// Everything that happens per frame, on one thread: per-source bookkeeping
/// (device clock, seq gaps, stale-touch watchdog), first-touch-wins source
/// arbitration, the host-lease filter, display-rate resampling, the scroll
/// engine, the momentum ticks, and the tap confirm (`onTapConfirm`).
///
/// A *source* is a pad on an endpoint (`RawTouchSourceID`): the pipeline
/// serves every admitted endpoint at once — several keyboards, or one
/// keyboard over USB and Bluetooth — and nothing is keyed by pad ID alone,
/// because two keyboards can both call their pad "0". Each endpoint brings
/// its own geometry and orientation (its capabilities), its own transport,
/// and its own configuration key (`devices.<key>` overrides); each source
/// keeps its own device clock, sequence counter, latency estimate and
/// watchdog. macOS gets exactly one scroll stream, so there is one engine
/// and one gesture at a time, arbitrated across all sources
/// (`activeSource`).
///
/// Display pacing: with `resampling` enabled and a display ticker available,
/// the active source's scroll-mode frames are buffered in a `FrameResampler`
/// and the engine is fed one synthetic frame per vsync of the display under
/// the cursor — the same ticks drive momentum, so coasting is vsync-locked
/// too. The display link runs only from touch-down until the gesture (and
/// any momentum) ends. Without resampling, or when no display link can be
/// made or the one running stops ticking, frames go to the engine as they
/// arrive and momentum runs on a free-running 120 Hz timer.
///
/// All I/O is injected (timers, display ticks, clock, event sink through the
/// poster), so the whole pipeline is unit-testable without hardware, a
/// display, a run loop, or posting a single real CGEvent.
public final class TouchScrollPipeline {
    /// Frame silence longer than this while `touched` was last set ends
    /// the touch, per the protocol spec (~150 ms) — without momentum (see
    /// `handleStaleTouch`). The firmware sends the release frame
    /// undroppably, so this is a **safety net**
    /// rather than a correctness requirement: it covers the stream simply
    /// stopping — a disconnect, a lost packet, a keyboard that went away
    /// mid-touch — which would otherwise leave the gesture (and the app's
    /// scroll phase) open forever. 150 ms is far above any real BLE
    /// connection-interval batch (tens of ms) and still short enough that
    /// the gesture ends without a noticeable hang.
    public static let staleTouchTimeout: TimeInterval = 0.150

    private let poster: RawTouchScrollPoster
    private let scheduler: TimerScheduling
    private let now: () -> TimeInterval

    /// The density of the display the cursor is on, in screen points per
    /// millimetre: what makes `scale` a physical gain rather than an
    /// arbitrary multiplier. Called once per gesture (at touch-down) and
    /// once per `configure`, never per frame. Injectable so tests and the
    /// offline bench pin a density instead of asking CoreGraphics.
    private let pointsPerMM: () -> Double

    private let engine = TouchScrollEngine()

    private var configuration: RawTouchConfiguration

    /// The live macOS Natural Scrolling preference as of the last
    /// `configure`, kept so a touch-down can re-derive a pad's engine
    /// config for the display it happens on.
    private var systemPrefersNatural = false

    /// One admitted endpoint: what it reported, and the engine
    /// configuration per enabled pad. A pad disabled in the configuration
    /// has no entry, which is what `process(frame:)` checks. Each entry's
    /// `pointsPerCount` is the value resolved for the display of the pad's
    /// last touch-down (or of the last `configure`, before any gesture).
    private struct EndpointState {
        var descriptor: RawTouchEndpointDescriptor
        var padConfigs: [UInt8: TouchScrollEngine.Config]
    }

    private var endpoints: [RawTouchEndpointID: EndpointState] = [:]

    /// The active source's resampler (the arbitration above it means one
    /// instance serves every source); reset whenever ownership moves.
    private var resampler = FrameResampler()

    /// The gesture's clock: the display link, or the momentum timer.
    private let pacer: GesturePacer

    /// Per-source stream bookkeeping: device-clock reconstruction, seq-gap
    /// accounting, and the stale-touch watchdog. Never shared between
    /// sources — a second keyboard's pad 0 has its own clock and its own
    /// sequence counter, and its watchdog must not close another
    /// keyboard's gesture.
    private struct SourceStreamState {
        var clock = RawTouchDeviceClock()
        /// The display-sync latency this source's delivery needs, measured
        /// from the same frames; read at touch-down and held for the
        /// gesture.
        var latencyEstimator = RawTouchLatencyEstimator()
        var lastSeq: UInt8?
        /// The device timestamp of the last touched frame, on the
        /// keyboard's own clock — the same clock over every connection,
        /// which is what orders one keyboard's frames across them (see
        /// `isHandover(_:)`).
        var lastTouchedTicks: UInt16?
        /// The split link of the last touched frame, for the gesture
        /// readout; nil for a local pad.
        var splitLink: RawTouchSplitLink?
        /// The stale-touch watchdog: each touched frame's host arrival time
        /// is its activity. Armed when a touch begins, disarmed by a
        /// release.
        var staleDeadline = LazyDeadline(timeout: TouchScrollPipeline.staleTouchTimeout)
        /// The touch in progress, for the tap confirm; nil between touches,
        /// and cleared without a decision when the touch ends in anything
        /// but a leased release frame (see `onTapConfirm`).
        var touch: TouchRecord?

        /// Takes in one frame of `source`: seq-gap accounting, delivery
        /// lateness, the device-clock rewrite, the touch record and the
        /// stale-touch deadline (a release disarms the watchdog; arming it
        /// takes a scheduler, so that is the caller's). Returns the frame on
        /// the device timeline, and the touch a release ended.
        mutating func take(
            _ wireFrame: RawTouchFrame,
            from source: RawTouchSourceID,
            coastRunning: Bool
        ) -> (frame: RawTouchFrame, endedTouch: TouchRecord?) {
            var frame = wireFrame
            // The host arrival time, before the device-clock rewrite below.
            let arrival = frame.timestamp

            // seq gap accounting: the firmware's BLE send queue drops oldest
            // under pressure; device timestamps keep velocity correct across
            // a gap, so this is diagnostic only.
            if let seq = frame.seq {
                if let lastSeq {
                    let dropped = seq &- lastSeq &- 1
                    if dropped != 0 {
                        os_log(
                            "%{public}@ dropped %{public}d frame(s) (seq %{public}d -> %{public}d)",
                            log: RawTouchLog.device,
                            type: .debug,
                            String(describing: source),
                            dropped,
                            lastSeq,
                            seq
                        )
                    }
                }
                lastSeq = seq
            }

            // Delivery lateness, for the measured display-sync latency: every
            // touched frame's device time against its arrival. The release is
            // left out — it is retained and retried on the wire, so its
            // timing is its own thing.
            if frame.touched, let ticks = frame.deviceTimestampTicks {
                latencyEstimator.observe(ticks: ticks, arrival: arrival)
            }

            // Replace the arrival timestamp with the reconstructed
            // device-side sample time, so the engine's velocity math
            // (per-frame dt, lift-off velocity window) sees the true ~100 Hz
            // cadence instead of BLE connection-interval batches. Synthesized
            // frames carry no device timestamp and keep the arrival-time
            // behavior. The clock is per source: another keyboard's
            // timestamps live on another timeline.
            if let ticks = frame.deviceTimestampTicks {
                frame.timestamp = clock.reconstruct(ticks: ticks, arrival: frame.timestamp)
            }

            // The tap confirm's record of this touch, kept for every source.
            var endedTouch: TouchRecord?
            if frame.touched {
                if touch == nil {
                    touch = TouchRecord(touchDown: frame, caughtCoast: coastRunning)
                } else {
                    touch?.note(frame)
                }
            } else {
                endedTouch = touch
                touch = nil
            }

            // Stale-touch watchdog (`staleTouchTimeout`), a lazy deadline:
            // each touched frame just records its arrival time. Disarmed by
            // a real release.
            if frame.touched {
                staleDeadline.lastActivity = arrival
                lastTouchedTicks = frame.deviceTimestampTicks
                splitLink = frame.splitLink
            } else {
                staleDeadline.disarm()
            }
            return (frame, endedTouch)
        }
    }

    /// What the tap confirm needs to know about one touch, from touch-down
    /// to release. Kept for every source, owner of the gesture or not: a tap
    /// on a pad the arbitration is ignoring is still a tap.
    private struct TouchRecord {
        /// Engine-timeline (reconstructed device) time of the touch-down.
        let downTimestamp: TimeInterval
        let downX: Int
        let downY: Int
        /// Whether a coast was running when the finger landed. A coast
        /// that a touch-down finds running is stopped by it — the engine's
        /// own momentum-state catch on the same source, the cross-source
        /// catch in `process(frame:)` on any other — so this one bit is
        /// "the touch caught momentum", whichever pad it landed on. (A
        /// pointer-context touch elsewhere does not catch, but it fails the
        /// scroll-context condition anyway.)
        let caughtCoast: Bool
        /// Whether every touched frame so far carried the scroll-mode flag.
        var scrollContext: Bool
        /// The furthest the finger has been from the touch-down position,
        /// raw counts, on either axis (Chebyshev distance).
        var travel = 0

        init(touchDown frame: RawTouchFrame, caughtCoast: Bool) {
            downTimestamp = frame.timestamp
            downX = frame.x
            downY = frame.y
            self.caughtCoast = caughtCoast
            scrollContext = frame.scrollMode
        }

        mutating func note(_ frame: RawTouchFrame) {
            scrollContext = scrollContext && frame.scrollMode
            travel = max(travel, abs(frame.x - downX), abs(frame.y - downY))
        }
    }

    /// The tap confirm's pre-filter: a touch longer or wider than this is
    /// no tap by any definition, so it is not worth a write. Deliberately
    /// looser than the firmware's own thresholds (180 ms / 30 counts by
    /// default), which decide; this only keeps ordinary drags from sending
    /// a confirm each.
    static let tapConfirmMaximumDuration: TimeInterval = 0.300
    static let tapConfirmMaximumTravel = 60

    private var sourceStates: [RawTouchSourceID: SourceStreamState] = [:]

    /// Whether a non-zero contact_id has already been logged (one-shot; the
    /// hardware is single-touch, so this only ever notes a firmware
    /// surprise).
    private var loggedNonZeroContactID = false

    /// Whether the current run of lease-lapsed (bit-2-clear) frames has been
    /// logged (one-shot per transition; the stream runs at ~100 Hz).
    private var loggedLeaseLapsed = false

    /// Whether the "this pad reports no resolution" note has been logged
    /// (one-shot; it would otherwise repeat on every configure).
    private var loggedUnknownPadResolution = false

    /// The source that currently owns the scroll gesture, or nil while no
    /// gesture (including momentum) is in progress. The engine is a single
    /// state machine, so only one source scrolls at a time — one pad, on one
    /// keyboard: the first source to touch owns the gesture, and every
    /// other source's frames — including their releases, which never had a
    /// gesture — are dropped until the ownership clears. It clears
    /// whenever the engine returns to idle: a release without momentum,
    /// momentum decaying away, a mid-touch scroll-mode exit, or a stream
    /// interrupt. Two exceptions, both for a scroll-context touch: while
    /// the owner is only coasting (momentum tail, finger up), a touch on any
    /// other source — the other pad, or another keyboard — catches the tail
    /// and takes the gesture over (otherwise the tail's imperceptible
    /// residue would lock everything else out for the seconds the decay
    /// takes); and the owner's own finger arriving over its keyboard's
    /// other connection takes its gesture over at once (`isHandover(_:)`).
    public private(set) var activeSource: RawTouchSourceID?

    /// Called on the event thread whenever the gesture-level activity
    /// changes: series start (idle → touching), momentum start (touching →
    /// coasting), cross-source catch (coasting → touching), and series end
    /// (→ idle) — never per frame, thanks to the equality check in
    /// `notifyActivityIfChanged()`. Nil (the default) costs nothing: the
    /// derivation is skipped entirely. Install it before frames flow —
    /// `RawTouchDeviceManager` does so at init — because a hook attached
    /// mid-gesture only hears about the *next* transition.
    public var onActivityChange: ((RawTouchStatus.PadActivity) -> Void)?

    /// The last activity delivered through `onActivityChange`, used to
    /// suppress non-transitions (event-thread state).
    private var lastReportedActivity: RawTouchStatus.PadActivity = .idle

    /// Called on the event thread when a touch on a source ends as a tap the
    /// firmware is waiting to hear about: the host's side of
    /// `RawTouchTapConfirm`. A pad that parks scroll taps holds each one
    /// back at lift-off, because only the host knows whether the touch was
    /// a tap or a finger stopping a coast; this says it was not the latter.
    /// The firmware still decides what a tap is and the keymap what it
    /// does. At most once per touch; the receiver writes the confirm to the
    /// source's endpoint. Nil (the default) costs nothing.
    public var onTapConfirm: ((RawTouchSourceID) -> Void)?

    /// Called on the event thread when a gesture's measurements land:
    /// once at lift-off and, if it coasts, once more when the coast ends —
    /// the engine's `lastGestureSummary`, tagged with the pad and endpoint
    /// it came from. Nil (the default) costs nothing.
    public var onGestureSummary: ((RawTouchGestureSummary) -> Void)?

    /// The last summary delivered, to forward each one exactly once
    /// (event-thread state).
    private var lastReportedGestureSummary: RawTouchGestureSummary?

    /// Called on the event thread with what *every* source's frames have
    /// measured they need, milliseconds, whenever a gesture's measurements
    /// land. The estimator only moves while a finger is down, so this is as
    /// often as the answer can change — and it carries every source, not
    /// just the one that scrolled, because that is what a settings window
    /// showing them all needs. Nil (the default) costs nothing.
    public var onMeasuredLatencies: (([RawTouchSourceID: Double]) -> Void)?

    /// What each source's delivery has measured it needs, milliseconds —
    /// the estimator's current level, which is what that source's next
    /// touch-down will adopt. A source with too few frames is absent.
    public var measuredLatencyMs: [RawTouchSourceID: Double] {
        sourceStates.compactMapValues { $0.latencyEstimator.measuredLatency.map { $0 * 1000 } }
    }

    /// `displayTicker` nil means no display pacing at all (the app always
    /// passes one; tests pass one when they test it).
    public init(
        configuration: RawTouchConfiguration = .init(),
        poster: RawTouchScrollPoster,
        scheduler: TimerScheduling,
        displayTicker: DisplayTicking? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pointsPerMM: @escaping () -> Double = DisplayGeometry.pointsPerMMUnderCursor
    ) {
        self.configuration = configuration
        self.poster = poster
        self.scheduler = scheduler
        self.now = now
        self.pointsPerMM = pointsPerMM
        pacer = GesturePacer(displayTicker: displayTicker, scheduler: scheduler, now: now)
        resampler.latency = idleLatency
        pacer.onTick = { [weak self] timestamp in
            self?.handleDisplayTick(at: timestamp)
        }
        pacer.onLinkLost = { [weak self] in
            self?.handleDisplayLinkLost()
        }
        pacer.onMomentumTimer = { [weak self] in
            guard let self else {
                return
            }
            momentumTick(at: now())
            settle()
        }
    }

    /// The display-sync latency in force right now — what the current (or
    /// most recent) gesture adopted at touch-down; before any gesture, the
    /// estimator's cold-start seed. Read-only; exposed for diagnostics and
    /// tests.
    public var resamplerLatency: TimeInterval {
        resampler.latency
    }

    /// Overrides the measured display-sync latency with a fixed one, for
    /// the offline bench's latency sweep and for tests that need a known
    /// estimation delay. Nil — always, in the app — measures
    /// (`RawTouchLatencyEstimator`): the delay a pad's frames need is a
    /// property of the path they travel, not a setting.
    public var fixedLatency: TimeInterval? {
        didSet {
            resampler.latency = idleLatency
        }
    }

    /// The latency before any frame has said otherwise.
    private var idleLatency: TimeInterval {
        fixedLatency ?? RawTouchLatencyEstimator.seed
    }

    /// The latency the gesture in flight (or the last one) adopted, for its
    /// summary.
    private var gestureLatency: TimeInterval = 0

    /// The display density the gesture in flight resolved at touch-down,
    /// for its summary — the cursor can move between panels of different
    /// densities between gestures.
    private var gesturePointsPerMM = DisplayGeometry.fallbackPointsPerMM

    /// What the latency log line last said: a gesture's transport and its
    /// latency in whole milliseconds. The line is written when either moves
    /// rather than per gesture.
    private struct LatencyLogLine: Equatable {
        var transport: RawTouchTransport
        var milliseconds: Int
    }

    private var lastLatencyLogLine: LatencyLogLine?

    /// Whether frames are currently consumed (at least one validated
    /// endpoint is present, the configuration enables scrolling, and posting
    /// is possible).
    public var isStreaming: Bool {
        !endpoints.isEmpty && configuration.enabled && postingReady
    }

    /// Whether the host can post what this pipeline synthesizes — the same
    /// readiness that decides the host lease (see
    /// `RawTouchDeviceManaging.setPostingReady`). Frames that arrive while it
    /// is false are dropped rather than turned into events nobody will see,
    /// which also keeps the engine from carrying stale positions across the
    /// gap. Event-thread state, like everything else here.
    public private(set) var postingReady = true

    /// Sets `postingReady`, closing out any gesture in flight when it drops:
    /// the lease is being released at the same moment, and the firmware is
    /// about to resume its own wheel scrolling — an open scroll phase would
    /// be left hanging in whatever app was scrolling.
    public func setPostingReady(_ ready: Bool) {
        guard ready != postingReady else {
            return
        }
        postingReady = ready
        if !ready {
            interrupt()
        }
    }

    // MARK: - Configuration

    /// Single-endpoint form of `configure(endpoints:configuration:systemPrefersNatural:)`:
    /// installs one device's capabilities as `RawTouchEndpointID.default`
    /// (nil when no validated device is present). Frames built without an
    /// endpoint — the fixtures, the bench — land on that one.
    public func configure(
        capabilities: RawTouchCapabilities?,
        configuration: RawTouchConfiguration? = nil,
        deviceKey: String? = nil,
        systemPrefersNatural: Bool
    ) {
        configure(
            endpoints: capabilities.map {
                [RawTouchEndpointDescriptor(id: .default, capabilities: $0, deviceKey: deviceKey)]
            } ?? [],
            configuration: configuration,
            systemPrefersNatural: systemPrefersNatural
        )
    }

    /// Installs the set of admitted endpoints (empty when none is present)
    /// and re-derives the per-pad engine configuration for each. An endpoint
    /// that left the set takes its sources' bookkeeping (clocks, watchdogs)
    /// with it, and if it owned the gesture in flight the gesture is closed
    /// out — canceled, without momentum, exactly like the trailing
    /// bit-2-clear release. Endpoints that stayed are untouched: their
    /// gesture, if one of them owns it, continues with its timing intact.
    public func configure(
        endpoints descriptors: [RawTouchEndpointDescriptor],
        configuration: RawTouchConfiguration? = nil,
        systemPrefersNatural: Bool
    ) {
        if let configuration {
            self.configuration = configuration
        }
        self.systemPrefersNatural = systemPrefersNatural

        // A gesture keeps the latency it adopted at touch-down (raising
        // it mid-gesture would ask the resampler for a time before its
        // last estimate), so nothing here touches it. Switching resampling
        // off mid-gesture hands the resampler's final real position to the
        // engine now, so the frames that follow (straight to the engine)
        // continue from it without a gap.
        if !self.configuration.resampling.enabled, resampler.isTracking {
            for frame in resampler.flush() {
                feed(frame)
            }
        }

        guard !descriptors.isEmpty, self.configuration.enabled else {
            endpoints = [:]
            interrupt()
            return
        }

        if !loggedUnknownPadResolution,
            descriptors.contains(where: { $0.capabilities.pads.values.contains(where: { $0.countsPerMM <= 0 }) })
        {
            loggedUnknownPadResolution = true
            os_log(
                "A pad reports no resolution; assuming %{public}.0f counts/mm for the physical scroll gain",
                log: RawTouchLog.device,
                type: .info,
                RawTouchCapabilities.Pad.fallbackCountsPerMM
            )
        }

        // A pad disabled in the configuration gets no engine config, which
        // is what `process(frame:)` checks: no per-frame lookup by name.
        // The display density is resolved once here so a config is ready
        // for diagnostics before the first gesture; every touch-down
        // resolves it again for the display it lands on. The gesture in
        // flight keeps the density it started with (see
        // `resolveConfigForThisGesture`), whatever display the cursor is
        // over now.
        let pointsPerMM = pointsPerMM()
        var newEndpoints: [RawTouchEndpointID: EndpointState] = [:]
        for descriptor in descriptors {
            var configs: [UInt8: TouchScrollEngine.Config] = [:]
            for padID in descriptor.capabilities.pads.keys
            where self.configuration.isEnabled(forPad: padID, deviceKey: descriptor.deviceKey) {
                let source = RawTouchSourceID(endpoint: descriptor.id, padID: padID)
                configs[padID] = self.configuration.engineConfig(
                    forPad: padID,
                    deviceKey: descriptor.deviceKey,
                    capabilities: descriptor.capabilities,
                    systemPrefersNatural: systemPrefersNatural,
                    pointsPerMM: source == activeSource ? gesturePointsPerMM : pointsPerMM
                )
            }
            newEndpoints[descriptor.id] = EndpointState(descriptor: descriptor, padConfigs: configs)
        }
        // Read before the overwrite: the axis mapping the gesture in flight
        // is running on decides whether it can survive this edit.
        let previousMapping = activeSource.flatMap { padConfig(for: $0)?.axisMapping }
        endpoints = newEndpoints

        // Sources that no longer exist — their endpoint is gone, or their
        // pad was disabled — take their bookkeeping with them, watchdog
        // included: a source nobody consumes has no touch to end, and a
        // clock carried across a reconnect
        // would be stale by definition. Every other source keeps its state.
        for (source, var state) in sourceStates where padConfig(for: source) == nil {
            state.staleDeadline.disarm()
            sourceStates[source] = nil
        }

        // Keep an in-flight gesture consistent with the new settings (gain,
        // direction signs, ballistics, momentum apply live; the resampler
        // fits both raw axes regardless, so it needs nothing). Two edits,
        // though, the gesture cannot survive, and both end it *without*
        // momentum (momentum for a pad the user just turned off, or on an
        // axis they just changed, is motion they did not ask for):
        //
        // 1. The active source is gone from the set — its pad disabled in the
        //    configuration, or its endpoint disconnected. Its frames are
        //    dropped from here on by the guard in `process(frame:)`, including
        //    its release, and its watchdog left with its bookkeeping, so nothing
        //    would ever clear the ownership: the display link would stay live
        //    and no other source could take a gesture again.
        // 2. The active source's axis mapping changed — which raw axis is
        //    vertical, or which directions are on. The engine's position
        //    history is on the old mapping: for an axis swap the next delta
        //    would difference a new-axis coordinate against an old-axis one
        //    — a large jump of pure fiction from a finger that never moved.
        //    A direction flip is not in this set: the history is sign-free,
        //    so a new sign simply applies from the next delta on.
        if let activeSource {
            if let config = padConfig(for: activeSource), config.axisMapping == previousMapping {
                engine.config = config
            } else {
                endGesture()
            }
        }
    }

    /// The engine configuration that would be used for a pad on an
    /// endpoint — nil for a pad that is absent or disabled. Exposed for
    /// diagnostics and tests.
    ///
    /// `pointsPerCount` is display-dependent, so it reads as of the last
    /// resolution for that pad: the display of its last touch-down, or of
    /// the last `configure` if it has not been touched since.
    public func engineConfig(forPad padID: UInt8, on endpoint: RawTouchEndpointID = .default) -> TouchScrollEngine
        .Config?
    {
        padConfig(for: RawTouchSourceID(endpoint: endpoint, padID: padID))
    }

    private func padConfig(for source: RawTouchSourceID) -> TouchScrollEngine.Config? {
        endpoints[source.endpoint]?.padConfigs[source.padID]
    }

    /// Re-derives a source's engine config for the display the cursor is on
    /// right now, and remembers it. Called at touch-down only: the lookup
    /// costs a CoreGraphics round trip, and a gesture keeps the density it
    /// started with just as it keeps the display link it started with.
    private func resolveConfigForThisGesture(source: RawTouchSourceID) -> TouchScrollEngine.Config? {
        guard let endpoint = endpoints[source.endpoint], endpoint.padConfigs[source.padID] != nil else {
            return nil  // absent or disabled: the source's frames are dropped
        }
        // The density of the display this gesture is on: the gain, the two
        // momentum speeds and the readout's millimetres all come from it,
        // so it is resolved once here and kept for the gesture.
        gesturePointsPerMM = pointsPerMM()
        let config = configuration.engineConfig(
            forPad: source.padID,
            deviceKey: endpoint.descriptor.deviceKey,
            capabilities: endpoint.descriptor.capabilities,
            systemPrefersNatural: systemPrefersNatural,
            pointsPerMM: gesturePointsPerMM
        )
        endpoints[source.endpoint]?.padConfigs[source.padID] = config
        return config
    }

    /// Sets the display-sync latency for the whole gesture that is
    /// beginning: what this source's own frames have shown they need, at
    /// this touch-down (see `RawTouchLatencyEstimator`). Logged with the
    /// gesture's transport when either changes — a keyboard present over
    /// both endpoints at once can alternate between gestures, and this is
    /// the only visible sign of it.
    private func adoptLatency(for source: RawTouchSourceID, transport: RawTouchTransport) {
        let estimator = sourceStates[source]?.latencyEstimator ?? RawTouchLatencyEstimator()
        let latency = fixedLatency ?? estimator.latency
        let origin =
            fixedLatency != nil
            ? "fixed"
            : (estimator.measuredLatency != nil ? "measured over \(estimator.sampleCount) frames" : "cold-start seed")
        let logLine = LatencyLogLine(transport: transport, milliseconds: Int((latency * 1000).rounded()))
        if logLine != lastLatencyLogLine {
            os_log(
                "Scrolling over %{public}@: display-sync latency %{public}.1f ms (%{public}@)",
                log: RawTouchLog.scroll,
                type: .debug,
                transport.displayName ?? "an unnamed transport",
                latency * 1000,
                origin
            )
            lastLatencyLogLine = logLine
        }
        gestureLatency = latency
        resampler.latency = latency
    }

    // MARK: - Frame input

    /// Handles a frame that came off the wire. Frames whose `lease_held` bit is
    /// clear are dropped silently: the keyboard is in Standard mode, scrolling
    /// with its own wheel events, and synthesizing on top would double-scroll.
    /// One exception: such a frame for the source that owns the active series
    /// means the lease lapsed mid-gesture — the firmware emits exactly one such
    /// trailing release frame before going silent — and the series is canceled,
    /// like `interrupt()`, deliberately **without** lift-off momentum: the
    /// finger may still be down and scrolling through the firmware's resumed
    /// wheel events, and momentum on top of those would double-scroll.
    public func handle(wireFrame frame: RawTouchFrame) {
        guard isStreaming else {
            return
        }

        // Bit 2 clear means the firmware is back in Standard mode for this
        // endpoint, emitting its own wheel events (the lease has not landed,
        // has expired, or belongs to another endpoint); synthesizing on top
        // of that double-scrolls. Bit 1 (scroll mode) is *not* filtered
        // here: the engine needs to see leased non-scroll-mode frames to
        // close out a gesture when the user releases the scroll layer
        // mid-touch, and it never synthesizes scroll for them. The net
        // effect is the contract's "synthesize only when bits 1 and 2 are
        // both set".
        guard frame.leaseHeld else {
            // Whatever the touch was, it ended without the lease, so there
            // is no one to confirm a tap to (see `onTapConfirm`).
            sourceStates[frame.source]?.touch = nil
            if frame.source == activeSource {
                os_log(
                    "%{public}@ lease lapsed mid-series; canceling without momentum",
                    log: RawTouchLog.lease,
                    type: .info,
                    String(describing: frame.source)
                )
                endGesture()
                dropSourceState(frame.source)
            }
            if !loggedLeaseLapsed {
                loggedLeaseLapsed = true
                os_log(
                    "Dropping %{public}@ frames: no host lease, the keyboard is scrolling in Standard mode",
                    log: RawTouchLog.lease,
                    type: .info,
                    String(describing: frame.source)
                )
            }
            return
        }

        if loggedLeaseLapsed {
            loggedLeaseLapsed = false
            os_log("Host lease held; consuming raw touch frames (RawTouch mode)", log: RawTouchLog.lease, type: .info)
        }

        process(frame: frame)
    }

    /// Close out any gesture in progress and drop all per-source
    /// bookkeeping — the whole pipeline is stopping (posting lost, RawTouch
    /// disabled, the last endpoint gone, shutdown). For one endpoint going
    /// away, `configure` does the source-specific version.
    public func interrupt() {
        endGesture()
        resetSourceStates()
    }

    /// Closes out the gesture in flight, if any, leaving every source's
    /// bookkeeping alone: the engine is interrupted (a touch ends without
    /// momentum, a coasting tail ends), the series is closed on the wire,
    /// the momentum timer and display link stop, and ownership clears.
    private func endGesture() {
        for event in engine.interrupt() {
            poster.post(event, at: now())
        }
        forwardGestureSummaryIfNew()
        poster.closeGestureSeriesIfNeeded()
        resampler.reset()
        pacer.stop()
        activeSource = nil
        notifyActivityIfChanged()
    }

    /// Derives the gesture-level activity from the engine's state plus the
    /// scroll-source ownership and delivers it through `onActivityChange` if it
    /// differs from the last delivery. Called after every state-mutating
    /// entry point (frame processing, momentum ticks, interrupts); the
    /// equality check makes that a transition-only stream, and a nil hook
    /// short-circuits the whole derivation.
    private func notifyActivityIfChanged() {
        guard let onActivityChange else {
            return
        }

        let activity: RawTouchStatus.PadActivity =
            if let activeSource {
                engine.wantsMomentumTicks
                    ? .coasting(padID: activeSource.padID, endpoint: activeSource.endpoint)
                    : .touching(padID: activeSource.padID, endpoint: activeSource.endpoint)
            } else {
                .idle
            }

        guard activity != lastReportedActivity else {
            return
        }
        lastReportedActivity = activity
        onActivityChange(activity)
    }

    // MARK: - Processing

    private func process(frame: RawTouchFrame) {
        guard isStreaming else {
            return
        }

        let source = frame.source
        guard padConfig(for: source) != nil else {
            return  // unknown endpoint (gone, or never admitted), or the pad is disabled
        }

        // Single-touch hardware today: secondary contacts are dropped rather
        // than misread as primary-contact motion. Logged once so a
        // multi-touch firmware surprise is visible without spamming at
        // 100 Hz.
        guard frame.contactID == 0 else {
            if !loggedNonZeroContactID {
                loggedNonZeroContactID = true
                os_log(
                    "Ignoring touch frames with contact_id %{public}d (%{public}@): multi-touch not consumed yet",
                    log: RawTouchLog.device,
                    type: .debug,
                    frame.contactID,
                    String(describing: source)
                )
            }
            return
        }

        let frame = noteFrame(frame)
        guard takeOwnershipIfStarting(frame) else {
            return
        }
        route(frame)
        settle()
    }

    /// The per-source bookkeeping every frame gets, owner of the gesture or
    /// not: its source's stream state takes it in (`SourceStreamState.take`),
    /// the stale-touch watchdog is armed when a touch begins, and a touch
    /// that ended as a confirmable tap is confirmed. Returns the frame on
    /// its source's device timeline.
    private func noteFrame(_ wireFrame: RawTouchFrame) -> RawTouchFrame {
        let source = wireFrame.source
        var state = sourceStates[source] ?? SourceStreamState()
        // Before the engine sees this frame, so `wantsMomentumTicks` still
        // says whether a coast was running when the finger landed.
        let (frame, endedTouch) = state.take(wireFrame, from: source, coastRunning: engine.wantsMomentumTicks)
        if frame.touched, !state.staleDeadline.isArmed {
            state.staleDeadline.arm(on: scheduler, handler: staleTouchHandler(for: source))
        }
        sourceStates[source] = state

        if let endedTouch, shouldConfirmTap(endedTouch, endedBy: frame) {
            onTapConfirm?(source)
        }
        return frame
    }

    /// Single-gesture arbitration (`activeSource`): whether `frame`'s source
    /// owns the gesture once this frame is taken into account. A scroll
    /// touch starts a gesture when there is none, catches a coast, or is
    /// the owner's handover; pointer-context touches never take over a
    /// gesture, nor start one. A catch drives the engine's ordinary
    /// momentum-state catch, which closes the old source's series
    /// (`.momentumEnded`) before beginning the new gesture (`.touchBegan`);
    /// a handover continues the touch from the new source's first frame,
    /// with no new series and no momentum.
    private func takeOwnershipIfStarting(_ frame: RawTouchFrame) -> Bool {
        let source = frame.source
        let startsGesture =
            frame.touched && frame.scrollMode
            && (activeSource == nil || engine.wantsMomentumTicks || isHandover(frame))
        if startsGesture {
            if source != activeSource {
                // A fresh owner starts a fresh resampler track, so the old
                // source's samples never seed the new one's estimates. What
                // that track still holds is the old owner's finger (a coast
                // tracks nothing), delivered first.
                for flushed in resampler.flush() {
                    feed(flushed)
                }
                resampler.reset()
                activeSource = source
            }
            // Physical 1:1 is a property of the display, so the gain is
            // resolved here — the cursor may have moved to a panel of a
            // different density since the last gesture — and so is the
            // geometry: this endpoint's, not whichever was admitted first.
            if let config = resolveConfigForThisGesture(source: source) {
                engine.config = config
            }
            // A new gesture for the engine, a catch included, so it adopts
            // the latency afresh; the change lands before the resampler's
            // first sample.
            adoptLatency(for: source, transport: frame.transport)
        }
        return source == activeSource
    }

    /// Display pacing (see the class comment) for a frame of the owner. A
    /// scroll-mode touch is buffered and reaches the engine on the next
    /// vsync; the display link starts with the first such frame of a
    /// gesture. Everything else — releases, pointer-mode frames, and scroll
    /// frames when resampling is off or no display link could be started —
    /// goes to the engine now, after the resampler flushes whatever it
    /// tracked.
    private func route(_ frame: RawTouchFrame) {
        if configuration.resampling.enabled, frame.touched, frame.scrollMode, pacer.startIfNeeded() {
            _ = resampler.ingest(frame)
        } else {
            for frame in resampler.passThrough(frame) {
                feed(frame)
            }
        }
    }

    /// Whether `frame` is the owner's own finger over another connection
    /// of the owner's keyboard: the same pad, a different endpoint, the
    /// same hardware id, and sampled after the owner's last frame — so a
    /// straggler still in flight on the connection it left does not take
    /// the gesture back. A frame without a device timestamp is taken as
    /// newer.
    private func isHandover(_ frame: RawTouchFrame) -> Bool {
        guard let owner = activeSource, owner.endpoint != frame.endpoint, owner.padID == frame.padID,
            let keyboard = endpoints[owner.endpoint]?.descriptor.capabilities.deviceIDHex,
            endpoints[frame.endpoint]?.descriptor.capabilities.deviceIDHex == keyboard
        else {
            return false
        }
        guard let ownerTicks = sourceStates[owner]?.lastTouchedTicks, let ticks = frame.deviceTimestampTicks else {
            return true
        }
        return Int16(bitPattern: ticks &- ownerTicks) > 0
    }

    /// The tap confirm's one decision, at a touch's release: the pad parks
    /// scroll taps on firmware that takes a confirm, the touch was in scroll
    /// context throughout, it did not catch a coast, and it was short and
    /// still enough to be a tap at all. The lease is not a condition here
    /// because it cannot be false: a release without the lease bit never
    /// reaches `process(frame:)`, and a lapse or the stale-touch watchdog
    /// drops the touch record before anything is decided.
    private func shouldConfirmTap(_ touch: TouchRecord, endedBy release: RawTouchFrame) -> Bool {
        let capabilities = endpoints[release.endpoint]?.descriptor.capabilities
        let padParksTaps =
            capabilities?.supportsTapConfirm == true
            && capabilities?.pads[release.padID]?.parksScrollTaps == true
        let tapSized =
            release.timestamp - touch.downTimestamp <= Self.tapConfirmMaximumDuration
            && touch.travel <= Self.tapConfirmMaximumTravel
        return padParksTaps && touch.scrollContext && !touch.caughtCoast && tapSized
    }

    /// Hands one frame to the engine and posts what it produces.
    private func feed(_ frame: RawTouchFrame) {
        afterEngineStep(engine.handle(frame: frame), at: frame.timestamp)
    }

    /// Everything one engine step (a frame or a momentum tick) leads to:
    /// its events posted at `timestamp`, a new gesture summary forwarded,
    /// and the ownership released once the engine is idle.
    private func afterEngineStep(_ events: [TouchScrollEngine.Event], at timestamp: TimeInterval) {
        for event in events {
            poster.post(event, at: timestamp)
        }
        forwardGestureSummaryIfNew()
        if !engine.isActive {
            activeSource = nil
        }
    }

    /// Brings the momentum timer, the display link and the activity report
    /// in line with the engine's state after anything that may have moved
    /// it: a processed frame, a vsync, a momentum tick, a link given up on.
    private func settle() {
        pacer.updateMomentumTimer(coasting: engine.wantsMomentumTicks)
        pacer.stopIfIdle(
            tracking: resampler.isTracking,
            coasting: engine.wantsMomentumTicks,
            gestureActive: engine.isActive
        )
        notifyActivityIfChanged()
    }

    /// Tags the engine's latest gesture summary with the source that owns
    /// the gesture and delivers it if it is new. The touch half is tagged
    /// with `activeSource` at lift-off (so this must run before the caller
    /// clears it on gesture end); the coast half keeps the tag its touch
    /// half got, because a cross-source catch has already moved
    /// `activeSource` to the catching pad by the time the engine closes
    /// the coasting gesture.
    private func forwardGestureSummaryIfNew() {
        guard let onGestureSummary, var summary = engine.lastGestureSummary else {
            return
        }
        if let last = lastReportedGestureSummary, summary.isSameTouch(as: last) {
            // The same touch as the last report — its coast half, or the
            // engine's finished summary re-read on every tick of the next
            // gesture: it keeps the tags and counts its touch half got.
            // Tagging it from live state instead would splice the next
            // gesture's running counts into it and re-deliver it per tick.
            summary.copyTags(from: last)
        } else if let activeSource {
            summary.padID = activeSource.padID
            summary.endpoint = activeSource.endpoint
            // The pad's own resolution, so the readout can put the peak
            // finger speed in millimetres per second.
            summary.padCountsPerMM =
                endpoints[activeSource.endpoint]?
                .descriptor.capabilities.pads[activeSource.padID]?.effectiveCountsPerMM
                ?? RawTouchCapabilities.Pad.fallbackCountsPerMM
            summary.displayPointsPerMM = gesturePointsPerMM
            // The touch half, at lift-off: the latency it ran at, what its
            // frames measured, and the resampler's counts for this touch
            // (the next touch-down restarts them).
            summary.latencyMs = gestureLatency * 1000
            summary.measuredLatencyMs = sourceStates[activeSource]?.latencyEstimator.measuredLatency.map { $0 * 1000 }
            summary.displayFrames = resampler.tickCount
            summary.heldFrames = resampler.heldTickCount
            summary.splitLink = sourceStates[activeSource]?.splitLink
        } else if let last = lastReportedGestureSummary {
            summary.copyTags(from: last)
        }
        guard summary != lastReportedGestureSummary else {
            return
        }
        lastReportedGestureSummary = summary
        onGestureSummary(summary)
        onMeasuredLatencies?(measuredLatencyMs)
    }

    private func staleTouchHandler(for source: RawTouchSourceID) -> () -> Void {
        { [weak self] in
            self?.handleStaleTouch(source: source)
        }
    }

    /// Fires when the source's stale-touch deadline is due. If a touched
    /// frame arrived since arming, the deadline re-arms for the remainder;
    /// otherwise the stream went silent mid-touch and the touch is over. If
    /// the source owns the gesture, the gesture ends without momentum, like
    /// a lease lapse: the finger's real lift-off was never seen, so neither
    /// was its speed, and a coast on this host while the keyboard scrolls
    /// another would be motion nobody asked for. What the source did
    /// deliver is flushed first. A timer whose source has since been
    /// dropped (its endpoint left) finds no state and does nothing.
    private func handleStaleTouch(source: RawTouchSourceID) {
        guard var state = sourceStates[source] else {
            return
        }
        guard
            let elapsed = state.staleDeadline.fire(
                now: now(),
                scheduler: scheduler,
                handler: staleTouchHandler(for: source)
            )
        else {
            // A touched frame kept the touch fresh; the deadline re-armed.
            sourceStates[source] = state
            return
        }

        // The finger's real lift-off was never seen, so neither was a tap:
        // the touch ends here without a tap confirm.
        state.touch = nil
        sourceStates[source] = state

        os_log(
            "%{public}@ silent for %{public}.0f ms while touched; ending the touch without momentum",
            log: RawTouchLog.device,
            type: .debug,
            String(describing: source),
            elapsed * 1000
        )

        guard source == activeSource else {
            return
        }
        for frame in resampler.flush() {
            feed(frame)
        }
        endGesture()
    }

    /// Drops one source's bookkeeping (its stale-touch timer, device clock,
    /// seq tracking).
    private func dropSourceState(_ source: RawTouchSourceID) {
        guard var state = sourceStates[source] else {
            return
        }
        state.staleDeadline.disarm()
        // The clock and sequence bookkeeping are stale once the lease has
        // lapsed; what the source's delivery measured is not — the path is
        // the same when the lease comes back, and the estimator's own
        // epoch rule handles the gap.
        var fresh = SourceStreamState()
        fresh.latencyEstimator = state.latencyEstimator
        sourceStates[source] = fresh
    }

    /// Drops every source's bookkeeping and the gesture ownership.
    private func resetSourceStates() {
        for var state in sourceStates.values {
            state.staleDeadline.disarm()
        }
        sourceStates.removeAll()
        activeSource = nil
    }

    // MARK: - Display ticks and momentum

    /// The display link went silent mid-gesture and was let go: what the
    /// resampler holds reaches the engine now, later frames go straight to
    /// it, and a coast moves to the momentum timer.
    private func handleDisplayLinkLost() {
        for frame in resampler.flush() {
            feed(frame)
        }
        settle()
    }

    /// One vsync (event thread, via the ticker's hop): the resampled frame
    /// for this tick first — a catch lands before the momentum step it
    /// cancels — then the momentum step if the engine is still coasting.
    private func handleDisplayTick(at timestamp: TimeInterval) {
        if let frame = resampler.tick(at: timestamp) {
            feed(frame)
        }
        if engine.wantsMomentumTicks {
            momentumTick(at: timestamp)
        }
        settle()
    }

    /// One momentum step; the caller settles the timer afterwards.
    private func momentumTick(at timestamp: TimeInterval) {
        afterEngineStep(engine.momentumTick(at: timestamp), at: timestamp)
    }
}

extension RawTouchGestureSummary {
    /// Takes over everything the pipeline tags a summary with — which
    /// source it came from and what that source's delivery and display
    /// were — from an earlier summary of the same gesture.
    fileprivate mutating func copyTags(from other: RawTouchGestureSummary) {
        padID = other.padID
        endpoint = other.endpoint
        latencyMs = other.latencyMs
        measuredLatencyMs = other.measuredLatencyMs
        padCountsPerMM = other.padCountsPerMM
        displayPointsPerMM = other.displayPointsPerMM
        displayFrames = other.displayFrames
        heldFrames = other.heldFrames
        splitLink = other.splitLink
    }
}
