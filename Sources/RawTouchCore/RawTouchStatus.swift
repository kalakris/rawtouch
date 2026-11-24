// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation

/// A point-in-time snapshot of RawTouch's observable state, published by
/// `RawTouchDeviceManager` on the main queue via `onStatusChange`.
///
/// Deliberately a dumb value type: no display strings, no formatting, no
/// UI-framework types. The app layer (menubar item, settings) derives
/// whatever presentation it wants from these fields, and `Equatable` lets
/// the publisher suppress identical consecutive snapshots.
public struct RawTouchStatus: Equatable {
    /// What the scroll pipeline is doing right now, at gesture granularity
    /// (never per frame): a finger down and scrolling, a momentum tail
    /// coasting after lift-off, or nothing. The pad is named with the
    /// endpoint it is on — two keyboards can both have a pad 0.
    public enum PadActivity: Equatable {
        case idle
        case touching(padID: UInt8, endpoint: RawTouchEndpointID = .default)
        case coasting(padID: UInt8, endpoint: RawTouchEndpointID = .default)
    }

    /// One HID endpoint RawTouch has seen: a keyboard over one transport.
    /// A keyboard present over USB and Bluetooth at once is two of these;
    /// two identical keyboards are two of these with different `id`s (and,
    /// when macOS exposes a stable identifier, different `deviceKey`s).
    public struct Endpoint: Equatable, Identifiable {
        /// Where this endpoint stands with the host lease.
        public enum Lease: Equatable {
            /// The lease is not ours to hold right now: RawTouch is
            /// disabled, or posting is not ready.
            case notWanted
            /// This keyboard is switched off on its own
            /// (`devices.<key>.enabled: false`): released, Standard mode,
            /// while the others carry on.
            case disabled
            /// An acquire write is in flight and none has landed yet.
            case pending
            /// The last acquire write landed: this endpoint is in RawTouch mode.
            case held
            /// The last acquire write failed: the keyboard stays in Standard
            /// mode on this endpoint. Other endpoints are unaffected.
            case failed
            /// The endpoint validated as protocol v4 but its firmware has no
            /// host lease support; it is reported, never leased, never read.
            case unsupportedFirmware
        }

        public var id: RawTouchEndpointID
        public var productName: String
        public var transport: RawTouchTransport
        /// The pad IDs this endpoint reports, ascending.
        public var padIDs: [UInt8]
        /// The `zmk-raw-touch` version this keyboard's central half reports,
        /// or nil when it reports none (firmware from before the feature
        /// report carried one).
        public var firmwareVersion: RawTouchFirmwareVersion?
        /// The version of the half each pad belongs to, keyed by pad_id: on
        /// a split, a relayed pad carries its own peripheral's. A pad absent
        /// here is one whose half has not said — `padIDs` is the list.
        ///
        /// A relayed pad is absent until it is first touched: the peripheral
        /// half announces its version to the central just before the first
        /// frame of a touch, and the manager re-reads the capability report
        /// then (`RawTouchFirmwareVersionProbe`), so this fills itself in
        /// mid-session and the row updates live.
        public var padFirmwareVersions: [UInt8: RawTouchFirmwareVersion]
        /// The SoC's hardware identifier as hex, or nil when the firmware
        /// reports none. The same chip answers with the same string on
        /// every transport, so two endpoints carrying one id are one
        /// keyboard — which is what `deviceKey` is built from.
        public var deviceID: String?
        /// The persistent key this endpoint's settings live under
        /// (`devices.<key>`), or nil when there is nothing stable to build
        /// one from. Both endpoints of one keyboard carry the same key.
        public var deviceKey: String?
        /// What each of this endpoint's pads has measured its frames need,
        /// in milliseconds, keyed by pad_id — the display-sync latency that
        /// pad's next gesture on this connection adopts. A pad is absent
        /// until enough of its frames have arrived. Per pad, not per
        /// endpoint: on a split keyboard the relayed half's pad travels a
        /// longer path than the one wired to the central, and measures it.
        public var measuredLatencyMs: [UInt8: Double]
        public var lease: Lease

        public init(
            id: RawTouchEndpointID,
            productName: String,
            transport: RawTouchTransport,
            padIDs: [UInt8],
            firmwareVersion: RawTouchFirmwareVersion? = nil,
            padFirmwareVersions: [UInt8: RawTouchFirmwareVersion] = [:],
            deviceID: String? = nil,
            deviceKey: String? = nil,
            measuredLatencyMs: [UInt8: Double] = [:],
            lease: Lease
        ) {
            self.id = id
            self.productName = productName
            self.transport = transport
            self.padIDs = padIDs
            self.firmwareVersion = firmwareVersion
            self.padFirmwareVersions = padFirmwareVersions
            self.deviceID = deviceID
            self.deviceKey = deviceKey
            self.measuredLatencyMs = measuredLatencyMs
            self.lease = lease
        }
    }

    /// The first admitted endpoint's product name, or nil while none is
    /// present. A single-keyboard summary; `endpoints` is the full picture.
    public var deviceName: String? {
        endpoints.first { $0.lease != .unsupportedFirmware }?.productName
    }

    /// True when the stream lease has landed on **at least one** admitted
    /// endpoint — RawTouch mode is live somewhere. A lease is held only
    /// while it is wanted, so this is false while disabled, while posting is
    /// not ready, while no endpoint is present, or while every lease is
    /// pending or failed. Per-endpoint outcomes are in `endpoints`.
    public var leaseHeld: Bool {
        endpoints.contains { $0.lease == .held }
    }

    /// The effective `RawTouchConfiguration.enabled` — the master switch.
    public var enabled: Bool

    /// Whether RawTouch can actually post scroll events right now — in
    /// practice, whether Accessibility is granted. This decides the lease as
    /// hard as `enabled` does: holding a lease while nothing can be posted
    /// would suppress the firmware's own wheel scrolling and put nothing in its
    /// place, so a fresh install without a grant would *remove* scrolling that
    /// worked. Surfaced here so `leaseHeld` stays honest and the menu can say
    /// why the keyboard is in Standard mode.
    public var postingReady: Bool

    public var activity: PadActivity

    /// What the most recent scroll gesture measured — the numbers a user
    /// tunes the feel against (peak finger speed and gain, lift-off speed,
    /// how far it coasted). Updated at lift-off and again when the coast
    /// ends; nil until the first gesture. Gesture granularity, never per
    /// frame.
    public var lastGesture: RawTouchGestureSummary?

    /// What went wrong with the configuration file, and the error's own
    /// words for the log. Which of the two it is decides what the menu
    /// says: a file that cannot be read is not saved over at all, while a
    /// failed save leaves the file as it was and edits unkept.
    public enum ConfigError: Equatable {
        /// The file could not be read or decoded.
        case unreadable(String)
        /// Writing the file failed (permissions, a full disk).
        case unsaved(String)
    }

    /// The last configuration-file failure, or nil while the configuration
    /// is healthy. Set via `RawTouchDeviceManager.reportConfigurationError(_:)`
    /// and cleared by a successful `apply(configuration:)`.
    public var configError: ConfigError?

    /// Every endpoint currently present, in connect order: the admitted
    /// ones and any whose firmware lacks RawTouch mode. Empty while nothing
    /// is connected.
    public var endpoints: [Endpoint]

    /// Endpoints that matched but whose capability read is still in flight
    /// — not yet in `endpoints`, but about to be one way or the other.
    public var validatingEndpointCount: Int

    /// True when no endpoint is present that could serve — every present one
    /// has firmware without RawTouch mode and none is still being validated.
    /// Deliberately false while one is still being read: at login two
    /// keyboards enumerate together, and the answer is not known until the
    /// validating one has answered.
    public var noEndpointCouldServe: Bool {
        validatingEndpointCount == 0 && endpoints.allSatisfy { $0.lease == .unsupportedFirmware }
    }

    public init(
        enabled: Bool = true,
        postingReady: Bool = true,
        activity: PadActivity = .idle,
        configError: ConfigError? = nil,
        endpoints: [Endpoint] = [],
        validatingEndpointCount: Int = 0,
        lastGesture: RawTouchGestureSummary? = nil
    ) {
        self.enabled = enabled
        self.postingReady = postingReady
        self.activity = activity
        self.lastGesture = lastGesture
        self.configError = configError
        self.validatingEndpointCount = validatingEndpointCount
        self.endpoints = endpoints
    }
}

/// One scroll gesture, measured: the readout the settings window shows so
/// tuning is a felt loop — flick, read the numbers, move a slider. Built by
/// `TouchScrollEngine` (pad-agnostic) and tagged with its source by
/// `TouchScrollPipeline`. Delivered once at lift-off (`complete` false
/// while a coast is still running) and once more when the coast ends.
public struct RawTouchGestureSummary: Equatable {
    /// Which gesture this is, unique per engine (0: not from an engine).
    /// The coast half of a gesture carries its touch half's ID.
    public var gestureID: UInt64
    public var padID: UInt8
    public var endpoint: RawTouchEndpointID
    /// The fastest the smoothed finger speed got, raw counts/second — the
    /// engine's own unit.
    public var peakFingerSpeed: Double
    /// The pad's resolution, counts per millimetre, so the readout can say
    /// the peak in the millimetres per second `acceleration.referenceFingerSpeed`
    /// is in. 0 until a gesture is tagged with its source.
    public var padCountsPerMM: Double
    /// The density of the display this gesture scrolled on, points per
    /// millimetre — what turns its screen-side speeds and distances
    /// (points) into the millimetres their settings are in.
    public var displayPointsPerMM: Double
    /// The largest acceleration gain applied during the touch (1 with
    /// acceleration off).
    public var peakGain: Double
    /// Points of scroll the touch itself produced (path length, both axes).
    public var touchDistance: Double
    /// The finger's speed at lift-off, points/second — what
    /// `momentum.minimumFlickSpeed` is compared against, once that has been
    /// resolved to this display's points.
    public var liftOffSpeed: Double
    /// Points the coast added after lift-off (0 when it did not coast).
    public var coastDistance: Double
    /// How long the coast ran, seconds (0 when it did not coast).
    public var coastDuration: TimeInterval
    /// False while the coast is still running; true once the gesture is
    /// entirely over (or never coasted).
    public var complete: Bool
    /// The display-sync latency the gesture ran at, milliseconds.
    public var latencyMs: Double
    /// What the pad's frame delivery measured by the end of the touch —
    /// the latency its next gesture adopts; nil until enough frames have
    /// been seen.
    public var measuredLatencyMs: Double?
    /// Display frames the touch spanned, and how many of them held the
    /// position because the newest frame was too old to estimate from:
    /// the stutter a latency below the delivery's need shows as.
    public var displayFrames: Int
    public var heldFrames: Int
    /// Fading frames the touch was carried through at its firm-contact
    /// velocity — a flick (`momentum.liftStrengthFloor`); 0 when the finger
    /// was followed to the lift. Always 0 on flicks means the floor is
    /// below this pad's fade; a carry on a plain lift means it is too high.
    public var liftFramesCarried: Int
    /// The split link the pad's frames crossed inside the keyboard, from
    /// the gesture's latest touched frame; nil for a pad on the half the
    /// Mac talks to, or firmware that does not say.
    public var splitLink: RawTouchSplitLink?

    public var coasted: Bool {
        coastDistance > 0 || !complete
    }

    /// Whether two summaries describe the same touch: its lift-off half
    /// and the coast half that completes it.
    public func isSameTouch(as other: RawTouchGestureSummary) -> Bool {
        gestureID == other.gestureID
    }

    public init(
        gestureID: UInt64 = 0,
        padID: UInt8 = 0,
        endpoint: RawTouchEndpointID = .default,
        padCountsPerMM: Double = RawTouchCapabilities.Pad.fallbackCountsPerMM,
        displayPointsPerMM: Double = DisplayGeometry.fallbackPointsPerMM,
        peakFingerSpeed: Double,
        peakGain: Double,
        touchDistance: Double,
        liftOffSpeed: Double,
        coastDistance: Double = 0,
        coastDuration: TimeInterval = 0,
        complete: Bool,
        latencyMs: Double = 0,
        measuredLatencyMs: Double? = nil,
        displayFrames: Int = 0,
        heldFrames: Int = 0,
        liftFramesCarried: Int = 0,
        splitLink: RawTouchSplitLink? = nil
    ) {
        self.gestureID = gestureID
        self.padID = padID
        self.endpoint = endpoint
        self.padCountsPerMM = padCountsPerMM
        self.displayPointsPerMM = displayPointsPerMM
        self.peakFingerSpeed = peakFingerSpeed
        self.peakGain = peakGain
        self.touchDistance = touchDistance
        self.liftOffSpeed = liftOffSpeed
        self.coastDistance = coastDistance
        self.coastDuration = coastDuration
        self.complete = complete
        self.latencyMs = latencyMs
        self.measuredLatencyMs = measuredLatencyMs
        self.displayFrames = displayFrames
        self.heldFrames = heldFrames
        self.liftFramesCarried = liftFramesCarried
        self.splitLink = splitLink
    }
}
