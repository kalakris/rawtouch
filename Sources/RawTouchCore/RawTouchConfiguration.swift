// MIT License
// Copyright (c) 2026 RawTouch contributors
// Derived from LinearMouse — Copyright (c) 2021-2026 LinearMouse (MIT).
// The knobs, defaults and ranges follow LinearMouse's scrolling scheme,
// flattened into a standalone JSON file.

import Foundation
import os.log

/// RawTouch's JSON configuration, loaded from
/// `~/.config/rawtouch/config.json` at start and reloaded live whenever the
/// file changes (see `ConfigFileWatcher`). Every key is optional; a missing
/// file means "all defaults".
///
/// ```json
/// {
///   "enabled": true,
///   "scale": 1.0,
///   "reverseScrolling": false,
///   "acceleration": { "enabled": true, "exponent": 0.9, "referenceFingerSpeed": 40,
///                     "minGain": 1.0, "maxGain": 16.0 },
///   "momentum": { "decayTimeConstant": 0.55, "minimumFlickSpeed": 23, "maximumCoastSpeed": 4600 },
///   "resampling": { "enabled": true },
///   "updates": { "checkAutomatically": true },
///   "devices": { "id:DEADBEEFCAFEF00D": { "pads": { "1": { "scale": 0.5, "axes": "vertical" } } } }
/// }
/// ```
///
/// Precedence for a pad's settings: `devices.<key>.pads.<id>` over the
/// top-level value. Pad IDs are firmware-assigned and mean nothing across
/// keyboards, so there is no shared per-pad layer: a pad's settings always
/// belong to one keyboard. A pad is enabled only if the master switch,
/// `devices.<key>.enabled` and its own `enabled` all are. `<key>` is the
/// keyboard's persistent identity (`RawTouchDeviceKey`) — its hardware id,
/// the same over every transport, so one keyboard has one entry however it
/// is connected.
public struct RawTouchConfiguration: Codable, Equatable {
    public static let defaultPath = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/rawtouch/config.json")

    public static let scaleRange: ClosedRange<Double> = 0.1...10.0
    public static let defaultScale = 1.0

    /// How long a name a settings UI may write for a keyboard or a pad.
    /// Both stand in for a firmware-given name in the settings window's
    /// headings, the menu and the gesture readout, and the readout's strip
    /// has about a tenth of slack at the sliders' extremes; this is what
    /// fits. A hand-written file is the writer's business — nothing is
    /// clamped on load, only on the way in from a UI.
    public static let nameLimit = 24

    /// Master switch. `false` leaves RawTouch running but silent: it
    /// releases the host lease (the keyboard returns to Standard mode) and
    /// synthesizes nothing.
    public var enabled: Bool

    /// Scroll gain relative to physical 1:1, dimensionless. 1.0 moves
    /// content exactly as far as the finger moves on the pad; 2.0 moves it
    /// twice as far. The screen points per pad count the engine runs on are
    /// derived from this per display and per pad — see
    /// `pointsPerCount(gain:pointsPerMM:countsPerMM:)`.
    public var scale: Double

    /// Flips the scroll direction on both axes.
    public var reverseScrolling: Bool

    public var acceleration: Acceleration

    public var momentum: Momentum

    public var resampling: Resampling

    public var updates: Updates

    /// Per-keyboard overrides keyed by the keyboard's persistent device key
    /// (`RawTouchDeviceKey`: `id:<hardware id>`, or a per-transport
    /// `usb:<serial>` / `bt:<address>` for firmware that reports no id).
    /// Each entry can switch the whole keyboard off (its lease is released:
    /// Standard mode) and carries its `pads` map, keyed by `pad_id` as a
    /// decimal string (the firmware assigns the IDs). Absent pads use the top-level values and the
    /// device's self-reported orientation. An entry with nothing in it is
    /// legal and means nothing.
    public var devices: [String: Device]

    public init(
        enabled: Bool = true,
        scale: Double = RawTouchConfiguration.defaultScale,
        reverseScrolling: Bool = false,
        acceleration: Acceleration = .init(),
        momentum: Momentum = .init(),
        resampling: Resampling = .init(),
        updates: Updates = .init(),
        devices: [String: Device] = [:]
    ) {
        self.enabled = enabled
        self.scale = scale
        self.reverseScrolling = reverseScrolling
        self.acceleration = acceleration
        self.momentum = momentum
        self.resampling = resampling
        self.updates = updates
        self.devices = devices
    }

    // Hand-written so that any subset of keys decodes, with defaults for the
    // rest (the synthesized initializer would require every non-optional key).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RawTouchConfiguration()
        enabled = try container.decode(.enabled, or: defaults.enabled)
        scale = try container.decode(.scale, or: defaults.scale)
        reverseScrolling = try container.decode(.reverseScrolling, or: defaults.reverseScrolling)
        acceleration = try container.decode(.acceleration, or: defaults.acceleration)
        momentum = try container.decode(.momentum, or: defaults.momentum)
        resampling = try container.decode(.resampling, or: defaults.resampling)
        updates = try container.decode(.updates, or: defaults.updates)
        devices = try container.decode(.devices, or: defaults.devices)
    }

    /// Velocity-dependent scroll gain ("ballistics"):
    /// `clamp((fingerSpeed / referenceFingerSpeed) ^ exponent, minGain, maxGain)`.
    ///
    /// The defaults are tuned on hardware to feel like an Apple trackpad on
    /// a pad a fraction of its size (≈54 × 40 mm): `minGain` 1.0 keeps slow
    /// motion at exactly the physical 1:1 the gain asks for — never below
    /// it — while a steep exponent and a high ceiling buy the reach a
    /// 40 mm-tall pad cannot give by travel alone.
    public struct Acceleration: Codable, Equatable {
        public static let exponentRange: ClosedRange<Double> = 0...2
        public static let defaultExponent = 0.9

        /// The reference speed is the finger's own, in millimetres per
        /// second, so it means the same thing on any pad: the engine wants
        /// it in that pad's counts per second, and `resolved(countsPerMM:)`
        /// converts it per gesture from the pad's own resolution — exactly
        /// as the gain becomes points per count from the same number.
        public static let referenceFingerSpeedRange: ClosedRange<Double> = 1...500
        public static let defaultReferenceFingerSpeed = 40.0

        public static let minGainRange: ClosedRange<Double> = 0.05...1.0
        public static let defaultMinGain = 1.0

        public static let maxGainRange: ClosedRange<Double> = 1.0...20.0
        public static let defaultMaxGain = 16.0

        public var enabled: Bool
        public var exponent: Double
        /// The finger speed at which the gain is exactly 1×, millimetres
        /// per second.
        public var referenceFingerSpeed: Double
        public var minGain: Double
        public var maxGain: Double

        public init(
            enabled: Bool = true,
            exponent: Double = Acceleration.defaultExponent,
            referenceFingerSpeed: Double = Acceleration.defaultReferenceFingerSpeed,
            minGain: Double = Acceleration.defaultMinGain,
            maxGain: Double = Acceleration.defaultMaxGain
        ) {
            self.enabled = enabled
            self.exponent = exponent
            self.referenceFingerSpeed = referenceFingerSpeed
            self.minGain = minGain
            self.maxGain = maxGain
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Acceleration()
            enabled = try container.decode(.enabled, or: defaults.enabled)
            exponent = try container.decode(.exponent, or: defaults.exponent)
            referenceFingerSpeed = try container.decode(.referenceFingerSpeed, or: defaults.referenceFingerSpeed)
            minGain = try container.decode(.minGain, or: defaults.minGain)
            maxGain = try container.decode(.maxGain, or: defaults.maxGain)
        }

        /// The engine-ready values, clamped to the supported ranges, with
        /// the reference speed converted into the pad's own counts per
        /// second — the unit the engine measures the finger in.
        public func resolved(countsPerMM: Double) -> TouchScrollEngine.Config.Acceleration {
            .init(
                enabled: enabled,
                exponent: exponent.clamped(to: Self.exponentRange),
                referenceSpeed: referenceFingerSpeed.clamped(to: Self.referenceFingerSpeedRange) * countsPerMM,
                minGain: minGain.clamped(to: Self.minGainRange),
                maxGain: maxGain.clamped(to: Self.maxGainRange)
            )
        }
    }

    /// Momentum ("coasting") tuning: how the lift-off velocity decays.
    ///
    /// The two speeds are millimetres per second of content on screen, so
    /// they mean the same thing on any display: the engine wants them in
    /// screen points per second, and `resolved(pointsPerMM:)` converts them
    /// per gesture from the density of the display the gesture happens on —
    /// exactly as the gain becomes points per count.
    public struct Momentum: Codable, Equatable {
        public static let decayTimeConstantRange: ClosedRange<Double> = 0.05...5.0

        /// 0.55 s, close to the ≈0.5 s an Apple trackpad coasts with: long
        /// enough that a flick carries, short enough that the tail does not
        /// outlive the user's interest in it.
        public static let defaultDecayTimeConstant = 0.55

        public static let minimumFlickSpeedRange: ClosedRange<Double> = 0...1200
        public static let defaultMinimumFlickSpeed = 23.0

        public static let maximumCoastSpeedRange: ClosedRange<Double> = 25...12_000
        /// The seed cap has to clear what the acceleration ceiling can
        /// produce (a fast flick through `maxGain`), or hard flicks would
        /// all coast at the same speed.
        public static let defaultMaximumCoastSpeed = 4600.0

        /// The finger does not leave a pad instantly: over the last 30–50 ms
        /// before the release the reported touch strength collapses as the
        /// contact patch shrinks, and the reported position wanders with
        /// it. Measured on 61 recorded touches, fitting the lift-off speed
        /// through those frames moved it by a median factor 0.86 with a
        /// p10–p90 spread of 0.36–1.26 against a fit through the frames
        /// with full contact. Samples below this fraction of the touch's
        /// reference strength (its 75th percentile) are left out of the
        /// lift-off fit; 0 turns the floor off.
        public static let liftStrengthFloorRange: ClosedRange<Double> = 0...0.95
        public static let defaultLiftStrengthFloor = 0.6

        public var decayTimeConstant: Double
        /// A lift-off slower than this, in millimetres per second of
        /// content on screen, stops dead instead of coasting.
        public var minimumFlickSpeed: Double
        /// The fastest a coast may start, in millimetres per second of
        /// content on screen, however hard the flick.
        public var maximumCoastSpeed: Double
        public var liftStrengthFloor: Double

        public init(
            decayTimeConstant: Double = Momentum.defaultDecayTimeConstant,
            minimumFlickSpeed: Double = Momentum.defaultMinimumFlickSpeed,
            maximumCoastSpeed: Double = Momentum.defaultMaximumCoastSpeed,
            liftStrengthFloor: Double = Momentum.defaultLiftStrengthFloor
        ) {
            self.decayTimeConstant = decayTimeConstant
            self.minimumFlickSpeed = minimumFlickSpeed
            self.maximumCoastSpeed = maximumCoastSpeed
            self.liftStrengthFloor = liftStrengthFloor
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Momentum()
            decayTimeConstant = try container.decode(.decayTimeConstant, or: defaults.decayTimeConstant)
            minimumFlickSpeed = try container.decode(.minimumFlickSpeed, or: defaults.minimumFlickSpeed)
            maximumCoastSpeed = try container.decode(.maximumCoastSpeed, or: defaults.maximumCoastSpeed)
            liftStrengthFloor = try container.decode(.liftStrengthFloor, or: defaults.liftStrengthFloor)
        }

        /// The engine-ready values, clamped, with the two speeds converted
        /// into the screen points per second the engine measures scrolling
        /// in — at the density of the display this gesture is on.
        public func resolved(pointsPerMM: Double) -> TouchScrollEngine.Config.Momentum {
            .init(
                decayTimeConstant: decayTimeConstant.clamped(to: Self.decayTimeConstantRange),
                startThreshold: minimumFlickSpeed.clamped(to: Self.minimumFlickSpeedRange) * pointsPerMM,
                maxSpeed: maximumCoastSpeed.clamped(to: Self.maximumCoastSpeedRange) * pointsPerMM,
                liftStrengthFloor: liftStrengthFloor.clamped(to: Self.liftStrengthFloorRange)
            )
        }
    }

    /// Display-rate resampling: one scroll delta per display frame, locked
    /// to the vsync of the display under the cursor, instead of one per
    /// 100 Hz pad sample (see `FrameResampler` for the why and how).
    ///
    /// How far behind each tick the finger is estimated for is not a
    /// setting: it depends on the path a pad's frames take to get here,
    /// which changes with the transport and even with a split's cable, and
    /// which `RawTouchLatencyEstimator` measures from the frames themselves.
    public struct Resampling: Codable, Equatable {
        /// `false` hands frames to the engine as they arrive, one delta per
        /// pad sample, with momentum on a free-running 120 Hz timer.
        public var enabled: Bool

        public init(enabled: Bool = true) {
            self.enabled = enabled
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decode(.enabled, or: Resampling().enabled)
        }
    }

    /// The update check: whether the app asks GitHub for the latest app and
    /// firmware releases by itself, once a day. The menu's "Check for
    /// Updates…" asks whatever this says.
    public struct Updates: Codable, Equatable {
        /// `false` leaves the app making no network connection unless asked.
        public var checkAutomatically: Bool

        public init(checkAutomatically: Bool = true) {
            self.checkAutomatically = checkAutomatically
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            checkAutomatically = try container.decode(.checkAutomatically, or: Updates().checkAutomatically)
        }
    }

    /// Per-pad overrides. Everything is optional; `nil` means "inherit".
    /// Two pads on one keyboard need not match (mounting, sensitivity,
    /// purpose), so scale, axes and directions can be set per pad.
    public struct Pad: Codable, Equatable {
        /// What to call this pad in the settings window and the gesture
        /// readout ("Scroll pad"), instead of the firmware's "Pad 0". The
        /// user writes it in the pad's own heading; absent means the
        /// firmware's numbering.
        public var name: String?
        /// `false` ignores this pad's frames entirely.
        public var enabled: Bool?
        /// Overrides the top-level `scale` (gain relative to physical 1:1)
        /// for this pad.
        public var scale: Double?
        /// The raw pad axis that drives *vertical* scrolling (the other one
        /// drives horizontal), overriding the one derived from the pad's
        /// reported orientation.
        public var axis: RawTouchAxis?
        /// Overrides the *orientation-derived* vertical direction baseline.
        /// The natural-scrolling preference and `reverseScrolling` still
        /// apply on top, so this behaves exactly like a different pad
        /// mounting.
        public var invert: Bool?
        /// The same for the horizontal direction baseline.
        public var invertHorizontal: Bool?
        /// The scroll directions this pad produces; absent means both.
        public var axes: RawTouchScrollAxes?

        public init(
            name: String? = nil,
            enabled: Bool? = nil,
            scale: Double? = nil,
            axis: RawTouchAxis? = nil,
            invert: Bool? = nil,
            invertHorizontal: Bool? = nil,
            axes: RawTouchScrollAxes? = nil
        ) {
            self.name = name
            self.enabled = enabled
            self.scale = scale
            self.axis = axis
            self.invert = invert
            self.invertHorizontal = invertHorizontal
            self.axes = axes
        }
    }

    /// Per-keyboard overrides (one `devices.<key>` entry).
    public struct Device: Codable, Equatable {
        /// `false` ignores every pad of this keyboard; the top-level
        /// `enabled` still applies on top.
        public var enabled: Bool?
        /// What to call this keyboard, instead of the name its firmware
        /// reports ("Desk Go60" rather than "Go60 Right"). The user writes
        /// it in the keyboard's own heading; absent means the firmware's
        /// name — and the key, once the keyboard is unplugged and there is
        /// nothing else to go by.
        public var name: String?
        /// This keyboard's pad overrides, one entry per pad ID.
        public var pads: [String: Pad]

        public init(enabled: Bool? = nil, name: String? = nil, pads: [String: Pad] = [:]) {
            self.enabled = enabled
            self.name = name
            self.pads = pads
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            pads = try container.decode(.pads, or: [:])
        }

        /// Nothing worth keeping in it. A name counts: the user wrote it,
        /// and an entry that holds only a name is a keyboard they chose to
        /// call something.
        public var hasNoOverrides: Bool {
            enabled == nil && name == nil && pads.isEmpty
        }
    }
}

extension RawTouchConfiguration {
    /// The overrides in force for one pad on one keyboard:
    /// `devices.<key>.pads.<id>`, or an all-inherit blank — also for an
    /// endpoint macOS exposes no stable identifier for, which therefore has
    /// no entry to be found under.
    public func padOverrides(forPad padID: UInt8, deviceKey: String?) -> Pad {
        guard let deviceKey, let own = devices[deviceKey]?.pads[String(padID)] else {
            return Pad()
        }
        return own
    }

    /// The name this pad was given (`devices.<key>.pads.<id>.name`), or
    /// nil when it goes by the firmware's own numbering. Blank counts as
    /// unnamed: emptying the heading clears the key.
    public func configuredPadName(forPad padID: UInt8, deviceKey: String?) -> String? {
        Self.usableName(padOverrides(forPad: padID, deviceKey: deviceKey).name)
    }

    /// The name this keyboard was given (`devices.<key>.name`), or nil when
    /// it goes by the name its firmware reports.
    public func configuredKeyboardName(forDeviceKey deviceKey: String?) -> String? {
        Self.usableName(deviceKey.flatMap { devices[$0]?.name })
    }

    /// A stored label, or nil when it is missing or blank.
    public static func usableName(_ name: String?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The scroll gain for a pad — relative to physical 1:1 — clamped.
    public func resolvedGain(forPad padID: UInt8, deviceKey: String? = nil) -> Double {
        (padOverrides(forPad: padID, deviceKey: deviceKey).scale ?? scale).clamped(to: Self.scaleRange)
    }

    /// Screen points of scroll per pad count: the engine's unit, derived
    /// from a dimensionless gain plus the two physical facts that define
    /// 1:1 — how dense the display under the cursor is (points/mm) and how
    /// finely the pad counts (counts/mm).
    ///
    /// At gain 1.0 the two cancel into "a millimetre moves a millimetre",
    /// whatever the display's DPI or the pad's resolution.
    public static func pointsPerCount(gain: Double, pointsPerMM: Double, countsPerMM: Double) -> Double {
        gain * pointsPerMM / countsPerMM
    }

    /// Whether a keyboard is wanted at all: the master switch and the
    /// keyboard's own switch (`devices.<key>.enabled`). This is what decides
    /// whether its endpoint's host lease is held — a keyboard switched off is
    /// released back to Standard mode, not left holding its lease and silent.
    public func isEnabled(deviceKey: String?) -> Bool {
        enabled && (deviceKey.flatMap { devices[$0]?.enabled } ?? true)
    }

    /// Whether a pad's frames are consumed at all: the keyboard must be
    /// wanted (`isEnabled(deviceKey:)`) and the resolved per-pad `enabled`
    /// must agree.
    public func isEnabled(forPad padID: UInt8, deviceKey: String? = nil) -> Bool {
        isEnabled(deviceKey: deviceKey)
            && (padOverrides(forPad: padID, deviceKey: deviceKey).enabled ?? true)
    }

    /// The scroll directions a pad produces: its own setting, else both.
    /// Which directions a pad scrolls in is a property of that pad's job on
    /// that keyboard, so there is no global value.
    public func resolvedAxes(forPad padID: UInt8, deviceKey: String? = nil) -> RawTouchScrollAxes {
        padOverrides(forPad: padID, deviceKey: deviceKey).axes ?? .both
    }

    /// Builds the engine configuration for one pad from the device's
    /// self-reported geometry plus this configuration.
    ///
    /// `systemPrefersNatural` is the live macOS preference, always folded
    /// in: macOS applies it to the firmware's own wheel events in Standard
    /// mode but not to synthetic ones, so following it is what keeps the
    /// two modes scrolling the same way. `pointsPerMM` is the
    /// density of the display the gesture happens on, which is what makes
    /// the gain physical — the caller resolves it per gesture
    /// (`DisplayGeometry.pointsPerMMUnderCursor()` in production), because
    /// the cursor can move between displays of different densities.
    public func engineConfig(
        forPad padID: UInt8,
        deviceKey: String? = nil,
        capabilities: RawTouchCapabilities,
        systemPrefersNatural: Bool,
        pointsPerMM: Double
    ) -> TouchScrollEngine.Config {
        let overrides: Pad? = padOverrides(forPad: padID, deviceKey: deviceKey)
        let pad = capabilities.pads[padID] ?? capabilities.primaryPad ?? .init()
        let axis = overrides?.axis ?? pad.scrollAxis
        // The orientation baselines describe the assignment the firmware
        // reports. An `axis` override that points vertical at the *other*
        // raw axis swaps the assignment, so the baselines swap with it —
        // each raw axis keeps the sign its own invert bit implies.
        let swapped = axis != pad.scrollAxis
        let verticalBaseline = swapped ? pad.orientationHorizontalScrollInverted : pad.orientationScrollInverted
        let horizontalBaseline = swapped ? pad.orientationScrollInverted : pad.orientationHorizontalScrollInverted
        let orientationInverted = overrides?.invert ?? verticalBaseline
        let orientationHorizontalInverted = overrides?.invertHorizontal ?? horizontalBaseline
        // Natural Scrolling and the reverse toggle flip both axes, as macOS
        // does for a real trackpad.
        let natural = systemPrefersNatural

        return .init(
            pointsPerCount: Self.pointsPerCount(
                gain: resolvedGain(forPad: padID, deviceKey: deviceKey),
                pointsPerMM: pointsPerMM,
                countsPerMM: pad.effectiveCountsPerMM
            ),
            invert: (orientationInverted != natural) != reverseScrolling,
            invertHorizontal: (orientationHorizontalInverted != natural) != reverseScrolling,
            axis: axis,
            axes: resolvedAxes(forPad: padID, deviceKey: deviceKey),
            // The reference finger speed is millimetres per second, so it
            // becomes counts per second at this pad's own resolution — the
            // same conversion the gain goes through.
            acceleration: acceleration.resolved(countsPerMM: pad.effectiveCountsPerMM),
            // The momentum speeds are the finger's, in millimetres per
            // second, so they become points per second at this display's
            // density — the same conversion the gain goes through.
            momentum: momentum.resolved(pointsPerMM: pointsPerMM)
        )
    }

    /// Loads the configuration from `path`. A missing file yields the
    /// defaults; a malformed file throws (the caller decides whether to fall
    /// back or refuse to start).
    public static func load(from path: URL = RawTouchConfiguration.defaultPath) throws -> RawTouchConfiguration {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return RawTouchConfiguration()
        }
        return try decode(fileContents: Data(contentsOf: path))
    }

    /// The configuration a file's bytes describe: an empty file is the
    /// defaults, malformed content throws, and each unknown key is logged.
    static func decode(fileContents data: Data) throws -> RawTouchConfiguration {
        guard !data.isEmpty else {
            return RawTouchConfiguration()
        }
        let configuration = try JSONDecoder().decode(RawTouchConfiguration.self, from: data)
        for key in unknownKeys(in: data, redactingDeviceKeys: true) {
            os_log("Ignoring unknown configuration key %{public}@", log: RawTouchLog.configuration, type: .error, key)
        }
        return configuration
    }

    /// The keys in a configuration file that nothing reads — typos, mostly —
    /// as dotted paths (`acceleration.expnent`,
    /// `devices.<key>.pads.1.axsi`). Decoding skips them silently, and with
    /// live reload a mistyped key would otherwise fail without a trace, so
    /// `load` logs each one — with `redactingDeviceKeys`, the `<key>` of a
    /// `devices` entry as `RawTouchDeviceKey.redacted`, since a device key
    /// is a hardware id, serial or Bluetooth address.
    public static func unknownKeys(in data: Data, redactingDeviceKeys: Bool = false) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return []
        }
        return unknownKeys(in: json, schema: knownKeys, path: "", redactingDeviceKeys: redactingDeviceKeys)
    }

    /// The key tree the decoder understands, taken from the encoder so the
    /// two can never drift: a fully populated configuration, encoded.
    private static let knownKeys: Any = {
        var configuration = RawTouchConfiguration()
        let pad = Pad(
            name: "Pad", enabled: true, scale: 1, axis: .x, invert: false, invertHorizontal: false, axes: .both)
        configuration.devices = ["id:EXAMPLE": .init(enabled: true, name: "Example", pads: ["0": pad])]
        let data = try! JSONEncoder().encode(configuration)
        return try! JSONSerialization.jsonObject(with: data)
    }()

    /// The maps whose keys are user-chosen (pad IDs, device keys): every
    /// entry follows the one schema entry rather than being a known key.
    private static func isKeyedMap(_ path: String) -> Bool {
        path == "devices" || path.hasSuffix(".pads")
    }

    private static func unknownKeys(
        in value: Any, schema: Any, path: String, redactingDeviceKeys: Bool
    ) -> [String] {
        guard let object = value as? [String: Any], let schemaObject = schema as? [String: Any] else {
            return []
        }
        let isKeyed = isKeyedMap(path)
        let redacts = redactingDeviceKeys && path == "devices"
        return object.flatMap { key, child -> [String] in
            let name = redacts ? RawTouchDeviceKey.redacted(key) : key
            let childPath = path.isEmpty ? name : "\(path).\(name)"
            guard let childSchema = isKeyed ? schemaObject.values.first : schemaObject[key] else {
                return [childPath]
            }
            return unknownKeys(
                in: child, schema: childSchema, path: childPath, redactingDeviceKeys: redactingDeviceKeys)
        }.sorted()
    }

    /// Saves the configuration to `path` — pretty-printed with sorted keys,
    /// written atomically so a concurrent reader (or the file watcher) never
    /// sees a half-written file, creating the parent directory if needed.
    public func save(to path: URL = RawTouchConfiguration.defaultPath) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: path, options: .atomic)
    }
}

extension KeyedDecodingContainer {
    /// `decodeIfPresent` with a fallback, so any subset of keys decodes.
    fileprivate func decode<T: Decodable>(_ key: Key, or fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}
