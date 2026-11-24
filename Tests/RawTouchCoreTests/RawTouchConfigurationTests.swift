// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchTestSupport
import XCTest

@testable import RawTouchCore

/// The display density these tests resolve gains against: the same number
/// as the pads' reported resolution (38 counts/mm), so
/// `gain × points/mm ÷ counts/mm` reduces to the gain itself and a test can
/// talk about gain and points per count interchangeably. The derivation
/// itself is pinned separately, in `testPointsPerCountIsGainTimesPhysical1To1`.
private let unitPointsPerMM = RawTouchCapabilities.Pad.fallbackCountsPerMM

final class RawTouchConfigurationTests: XCTestCase {
    private func decode(_ json: String) throws -> RawTouchConfiguration {
        try JSONDecoder().decode(RawTouchConfiguration.self, from: Data(json.utf8))
    }

    // MARK: - Defaults

    func testEmptyObjectDecodesToTheDefaults() throws {
        let configuration = try decode("{}")

        XCTAssertEqual(configuration, RawTouchConfiguration())
        XCTAssertTrue(configuration.enabled)
        XCTAssertEqual(configuration.scale, 1.0)
        XCTAssertFalse(configuration.reverseScrolling)
        XCTAssertTrue(configuration.acceleration.enabled)
        XCTAssertEqual(configuration.acceleration.exponent, 0.9)
        XCTAssertEqual(configuration.acceleration.referenceFingerSpeed, 40)
        XCTAssertEqual(configuration.acceleration.minGain, 1.0)
        XCTAssertEqual(configuration.acceleration.maxGain, 16)
        XCTAssertEqual(configuration.momentum.decayTimeConstant, 0.55)
        XCTAssertEqual(configuration.momentum.minimumFlickSpeed, 23)
        XCTAssertEqual(configuration.momentum.maximumCoastSpeed, 4600)
        XCTAssertEqual(configuration.momentum.liftStrengthFloor, 0.6)
        XCTAssertTrue(configuration.resampling.enabled)
        XCTAssertTrue(configuration.devices.isEmpty)
    }

    func testPartialObjectsKeepDefaultsForEveryAbsentKey() throws {
        let configuration = try decode(#"{"scale": 0.5, "acceleration": {"enabled": false}}"#)

        XCTAssertEqual(configuration.scale, 0.5)
        XCTAssertFalse(configuration.acceleration.enabled)
        XCTAssertEqual(configuration.acceleration.exponent, 0.9)
        XCTAssertEqual(configuration.momentum.maximumCoastSpeed, 4600)
    }

    func testMissingFileYieldsDefaults() throws {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rawtouch-absent-\(UUID().uuidString).json")
        XCTAssertEqual(try RawTouchConfiguration.load(from: path), RawTouchConfiguration())
    }

    func testLoadsFromDisk() throws {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rawtouch-\(UUID().uuidString).json")
        try Data(#"{"reverseScrolling": true, "devices": {"usb:test": {"pads": {"1": {"scale": 0.75}}}}}"#.utf8).write(
            to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        let configuration = try RawTouchConfiguration.load(from: path)
        XCTAssertTrue(configuration.reverseScrolling)
        XCTAssertEqual(configuration[pad: "1"]?.scale, 0.75)
    }

    func testMalformedFileThrows() throws {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rawtouch-bad-\(UUID().uuidString).json")
        try Data("{ not json".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        XCTAssertThrowsError(try RawTouchConfiguration.load(from: path))
    }

    func testSaveCreatesTheParentDirectoryAndRoundTrips() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rawtouch-save-\(UUID().uuidString)/nested")
        let path = directory.appendingPathComponent("config.json")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        var configuration = RawTouchConfiguration()
        configuration.enabled = false
        configuration.scale = 0.4
        configuration.reverseScrolling = true
        configuration.acceleration = .init(enabled: true, exponent: 0.7)
        configuration.momentum.decayTimeConstant = 1.2
        configuration[pad: "0"] = .init(
            enabled: true, scale: 0.3, axis: .x, invert: false, invertHorizontal: true, axes: .horizontal
        )

        try configuration.save(to: path)
        XCTAssertEqual(try RawTouchConfiguration.load(from: path), configuration)

        // Pretty-printed with sorted keys — the `--print-config` spelling —
        // so a hand-editor finds a stable, readable file.
        let text = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(text.contains("\n"))
        let accelerationKey = try XCTUnwrap(text.range(of: "\"acceleration\""))
        let scaleKey = try XCTUnwrap(text.range(of: "\"scale\""))
        XCTAssertLessThan(accelerationKey.lowerBound, scaleKey.lowerBound)
    }

    func testRoundTripsThroughItsOwnEncoder() throws {
        var configuration = RawTouchConfiguration()
        configuration.scale = 0.4
        configuration[pad: "0"] = .init(
            enabled: true, scale: 0.3, axis: .x, invert: false, invertHorizontal: false, axes: .vertical
        )

        let data = try JSONEncoder().encode(configuration)
        XCTAssertEqual(try JSONDecoder().decode(RawTouchConfiguration.self, from: data), configuration)
    }

    /// The defaults survive their own encoder: a user who opens the
    /// settings window (which rewrites the file in full) must not have the
    /// configuration drift from what a missing file would have meant.
    func testTheDefaultsRoundTripThroughTheEncoderUnchanged() throws {
        let data = try JSONEncoder().encode(RawTouchConfiguration())
        XCTAssertEqual(try JSONDecoder().decode(RawTouchConfiguration.self, from: data), RawTouchConfiguration())
    }

    /// `resources/config.example.json` is what the README points people at,
    /// so it has to spell the real defaults — every key, every value. Read
    /// from the source tree rather than a bundled copy: it is documentation,
    /// not a resource the package ships.
    func testTheShippedExampleConfigurationSpellsTheDefaults() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RawTouchCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("resources/config.example.json"))

        XCTAssertEqual(try JSONDecoder().decode(RawTouchConfiguration.self, from: data), RawTouchConfiguration())
        XCTAssertEqual(RawTouchConfiguration.unknownKeys(in: data), [])
        // Key for key, not just "decodes to the defaults": a key the example
        // forgot would decode to its default and pass silently.
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RawTouchConfiguration()))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? NSDictionary, encoded as? NSDictionary)
    }

    // MARK: - Resampling

    func testResamplingKeysDecodeWithDefaultsForTheAbsentOnes() throws {
        XCTAssertEqual(try decode(#"{"resampling": {"enabled": false}}"#).resampling, .init(enabled: false))
        XCTAssertEqual(try decode(#"{"resampling": {}}"#).resampling, .init())
    }

    // MARK: - Updates

    func testUpdateKeysDecodeWithDefaultsForTheAbsentOnes() throws {
        XCTAssertEqual(
            try decode(#"{"updates": {"checkAutomatically": false}}"#).updates, .init(checkAutomatically: false))
        XCTAssertEqual(try decode(#"{"updates": {}}"#).updates, .init())
        XCTAssertTrue(RawTouchConfiguration().updates.checkAutomatically, "on unless switched off")
    }

    /// Both speeds are the finger's, in millimetres, so the engine's
    /// points-per-second come from the display the gesture is on — a dense
    /// panel needs more points for the same millimetre.
    func testMomentumSpeedsAreResolvedAgainstTheDisplay() {
        let momentum = RawTouchConfiguration.Momentum(minimumFlickSpeed: 20, maximumCoastSpeed: 1000)
        XCTAssertEqual(momentum.resolved(pointsPerMM: 4).startThreshold, 80)
        XCTAssertEqual(momentum.resolved(pointsPerMM: 8).startThreshold, 160)
        XCTAssertEqual(momentum.resolved(pointsPerMM: 4).maxSpeed, 4000)
        XCTAssertEqual(momentum.resolved(pointsPerMM: 8).maxSpeed, 8000)
    }

    /// And the engine configuration a gesture runs on carries that
    /// display's answer, next to the gain it already derived from it.
    func testAGesturesEngineConfigCarriesTheDisplaysMomentumSpeeds() {
        var configuration = RawTouchConfiguration()
        configuration.momentum.minimumFlickSpeed = 20
        configuration.momentum.maximumCoastSpeed = 1000
        let capabilities = RawTouchCapabilities(
            padsPresent: 0x01,
            capabilityBits: RawTouchCapabilities.Capability.hostLease,
            countsPerMM: 38
        )
        for pointsPerMM in [4.0, 8.0] {
            let config = configuration.engineConfig(
                forPad: 0,
                capabilities: capabilities,
                systemPrefersNatural: false,
                pointsPerMM: pointsPerMM
            )
            XCTAssertEqual(config.momentum.startThreshold, 20 * pointsPerMM)
            XCTAssertEqual(config.momentum.maxSpeed, 1000 * pointsPerMM)
            XCTAssertEqual(config.acceleration.referenceSpeed, 40 * 38, "the pad's own unit, not the display's")
        }
    }

    // MARK: - Names

    /// What an editable heading shows, and what a rename stores, both go
    /// through this: a stored label is a name only if there is something
    /// in it, so clearing a heading (or typing spaces into one) reads as
    /// "no name of its own" and the default shows instead.
    func testABlankStoredNameIsNoNameAtAll() {
        XCTAssertNil(RawTouchConfiguration.usableName(nil))
        XCTAssertNil(RawTouchConfiguration.usableName(""))
        XCTAssertNil(RawTouchConfiguration.usableName("   \n "))
        XCTAssertEqual(RawTouchConfiguration.usableName("  Desk Go60  "), "Desk Go60")
    }

    // MARK: - Pad names

    /// A pad's name is a label the user writes; blank means it has none,
    /// which is how the settings field clears it.
    func testAPadNameIsReadBackAndBlankMeansUnnamed() throws {
        let configuration = try decode(
            """
            {"devices": {"id:AAAA": {"pads": {"0": {"name": "Scroll pad"}, "1": {"name": "  "}}}}}
            """)
        XCTAssertEqual(configuration.configuredPadName(forPad: 0, deviceKey: "id:AAAA"), "Scroll pad")
        XCTAssertNil(configuration.configuredPadName(forPad: 1, deviceKey: "id:AAAA"))
        XCTAssertNil(configuration.configuredPadName(forPad: 0, deviceKey: "id:BBBB"))
        XCTAssertNil(configuration.configuredPadName(forPad: 0, deviceKey: nil))
        XCTAssertEqual(
            RawTouchConfiguration.unknownKeys(
                in: Data(
                    """
                    {"devices": {"id:AAAA": {"pads": {"0": {"name": "Scroll pad"}}}}}
                    """.utf8)), [])
    }

    func testResamplingRoundTripsThroughSave() throws {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rawtouch-resampling-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: path) }

        var configuration = RawTouchConfiguration()
        configuration.resampling = .init(enabled: false)
        try configuration.save(to: path)

        XCTAssertEqual(try RawTouchConfiguration.load(from: path), configuration)
        let text = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(text.contains("\"resampling\""))
        XCTAssertTrue(text.contains("\"enabled\""))
    }

    // MARK: - Clamping

    func testOutOfRangeValuesAreClampedWhenResolved() throws {
        let configuration = try decode(
            """
            {
              "scale": 99,
              "acceleration": {"exponent": 9, "referenceFingerSpeed": 0, "minGain": 0, "maxGain": 99},
              "momentum": {"decayTimeConstant": 99, "minimumFlickSpeed": -5, "maximumCoastSpeed": 1}
            }
            """)

        XCTAssertEqual(configuration.resolvedGain(forPad: 0, deviceKey: testDeviceKey), 10.0)
        XCTAssertEqual(try decode(#"{"scale": 0.001}"#).resolvedGain(forPad: 0, deviceKey: testDeviceKey), 0.1)

        let acceleration = configuration.acceleration.resolved(countsPerMM: 38)
        XCTAssertEqual(acceleration.exponent, 2)
        XCTAssertEqual(acceleration.referenceSpeed, 38, "1 mm/s, the floor, at this pad's resolution")
        XCTAssertEqual(acceleration.minGain, 0.05)
        XCTAssertEqual(acceleration.maxGain, 20)

        let momentum = configuration.momentum.resolved(pointsPerMM: 4)
        XCTAssertEqual(momentum.decayTimeConstant, 5.0)
        XCTAssertEqual(momentum.startThreshold, 0, "0 mm/s, the floor, on this display")
        XCTAssertEqual(momentum.maxSpeed, 100, "25 mm/s, the floor, at 4 pt/mm")
    }

    // MARK: - Physical 1:1 derivation

    /// Gain 1.0 means physical 1:1 on any display: a millimetre of finger
    /// travel moves content a millimetre. That fixes the derivation to
    /// `gain × display points/mm ÷ pad counts/mm` — the two physical
    /// resolutions cancel, leaving the gain.
    func testPointsPerCountIsTheGainScaledByDisplayAndPadResolution() {
        XCTAssertEqual(RawTouchConfiguration.pointsPerCount(gain: 1, pointsPerMM: 4, countsPerMM: 38), 4.0 / 38)
        // Twice the gain, twice the content travel.
        XCTAssertEqual(RawTouchConfiguration.pointsPerCount(gain: 2, pointsPerMM: 4, countsPerMM: 38), 8.0 / 38)
        // A denser display spends more points on the same millimetre.
        XCTAssertEqual(RawTouchConfiguration.pointsPerCount(gain: 1, pointsPerMM: 8, countsPerMM: 38), 8.0 / 38)
        // A finer pad spends fewer points per count — the same distance.
        XCTAssertEqual(RawTouchConfiguration.pointsPerCount(gain: 1, pointsPerMM: 4, countsPerMM: 76), 2.0 / 38)

        // End to end through the engine config: 76 counts on a 38 counts/mm
        // pad is 2 mm, which at 4 points/mm must be 8 points of content.
        let config = RawTouchConfiguration().engineConfig(
            forPad: 0,
            capabilities: RawTouchCapabilities(countsPerMM: 38),
            systemPrefersNatural: false,
            pointsPerMM: 4
        )
        XCTAssertEqual(76 * config.pointsPerCount, 8, accuracy: 1e-12)
    }

    /// A pad whose feature report carries no resolution (0) must still
    /// scroll: the Pinnacle's ≈38 counts/mm stands in, so the derivation
    /// never divides by zero.
    func testAPadThatReportsNoResolutionUsesThePinnacleFallback() {
        XCTAssertEqual(RawTouchCapabilities.Pad(countsPerMM: 0).effectiveCountsPerMM, 38)

        let unknown = RawTouchConfiguration().engineConfig(
            forPad: 0,
            capabilities: RawTouchCapabilities(countsPerMM: 0),
            systemPrefersNatural: false,
            pointsPerMM: 4
        )
        let reported = RawTouchConfiguration().engineConfig(
            forPad: 0,
            capabilities: RawTouchCapabilities(countsPerMM: 38),
            systemPrefersNatural: false,
            pointsPerMM: 4
        )
        XCTAssertEqual(unknown.pointsPerCount, reported.pointsPerCount)
    }

    // MARK: - Engine configuration derivation

    /// GROUND TRUTH: the Go60's orientation (rotate-90 + y-invert) with
    /// Natural Scrolling off and no reverse must give axis x, invert false —
    /// the direction checked on the hardware. If this fails, the
    /// scroll direction or axis has silently flipped; fix the derivation,
    /// not the test.
    func testGo60AnchorConfiguration() {
        let capabilities = RawTouchCapabilities(
            padsPresent: 0x03,
            capabilityBits: RawTouchCapabilities.Capability.hostLease,
            rotate90: true,
            invertY: true
        )
        let config = RawTouchConfiguration().engineConfig(
            forPad: 0,
            deviceKey: testDeviceKey,
            capabilities: capabilities,
            systemPrefersNatural: false, pointsPerMM: unitPointsPerMM
        )

        XCTAssertEqual(config.axis, .x)
        XCTAssertFalse(config.invert)
        // Horizontal from the other raw axis, inverted (no x-invert on the
        // Go60): the derivation, not hardware truth — see
        // `RawTouchCapabilitiesTests.testHorizontalOrientationDerivationTable`.
        XCTAssertEqual(config.horizontalAxis, .y)
        XCTAssertTrue(config.invertHorizontal)
        XCTAssertEqual(config.axes, .both)
        // The default gain 1.0 at 38 pt/mm over a 38 counts/mm pad: 1:1.
        XCTAssertEqual(config.pointsPerCount, 1.0)
    }

    // MARK: - Two-axis keys

    /// Which directions a pad scrolls in is the pad's own setting — there
    /// is no global value, and an old top-level `axes` key is unknown.
    func testScrollAxesDefaultToBothAndArePerPad() throws {
        let capabilities = RawTouchCapabilities(padsPresent: 0x03, rotate90: true, invertY: true)
        func config(_ configuration: RawTouchConfiguration, pad: UInt8) -> TouchScrollEngine.Config {
            configuration.engineConfig(
                forPad: pad, deviceKey: testDeviceKey, capabilities: capabilities, systemPrefersNatural: false,
                pointsPerMM: unitPointsPerMM
            )
        }

        XCTAssertEqual(config(RawTouchConfiguration(), pad: 0).axes, .both)

        let perPad = try decode(#"{"devices": {"usb:test": {"pads": {"1": {"axes": "horizontal"}}}}}"#)
        XCTAssertEqual(perPad[pad: "1"]?.axes, .horizontal)
        XCTAssertEqual(config(perPad, pad: 0).axes, .both, "the other pad: both")
        XCTAssertEqual(config(perPad, pad: 1).axes, .horizontal)
        XCTAssertEqual(perPad.resolvedAxes(forPad: 1, deviceKey: testDeviceKey), .horizontal)
        XCTAssertEqual(perPad.resolvedAxes(forPad: 1, deviceKey: "bt:other"), .both, "another keyboard: both")

        // There is no top-level `axes`: it is an unknown key and changes
        // nothing.
        let topLevel = #"{"axes": "vertical"}"#
        XCTAssertEqual(config(try decode(topLevel), pad: 0).axes, .both)
        XCTAssertEqual(RawTouchConfiguration.unknownKeys(in: Data(topLevel.utf8)), ["axes"])
    }

    /// An `axis` override that points vertical at the other raw axis swaps
    /// the automatic baselines with it: each raw axis keeps the sign its own
    /// invert bit implies. On the Go60 (rotate-90, y-invert, no x-invert)
    /// vertical-from-Y therefore reads raw Y's baseline (`!invertY` = false)
    /// and horizontal-from-X reads raw X's (`!invertX` = true) — the
    /// opposite of the reported assignment. Explicit overrides still win.
    func testAnAxisOverrideToTheOtherRawAxisSwapsTheAutomaticBaselines() throws {
        let capabilities = RawTouchCapabilities(padsPresent: 0x03, rotate90: true, invertY: true)
        func config(_ configuration: RawTouchConfiguration, pad: UInt8) -> TouchScrollEngine.Config {
            configuration.engineConfig(
                forPad: pad, deviceKey: testDeviceKey, capabilities: capabilities, systemPrefersNatural: false,
                pointsPerMM: unitPointsPerMM
            )
        }

        let reported = config(RawTouchConfiguration(), pad: 0)
        XCTAssertEqual(reported.axis, .x)
        XCTAssertFalse(reported.invert)
        XCTAssertTrue(reported.invertHorizontal)

        let swapped = config(try decode(#"{"devices": {"usb:test": {"pads": {"0": {"axis": "y"}}}}}"#), pad: 0)
        XCTAssertEqual(swapped.axis, .y)
        XCTAssertEqual(swapped.horizontalAxis, .x)
        XCTAssertTrue(swapped.invert, "raw X's baseline, now driving horizontal, moved with it")
        XCTAssertFalse(swapped.invertHorizontal, "and raw Y's baseline is now the vertical one")

        // An override to the axis the firmware already reports swaps nothing.
        let same = config(try decode(#"{"devices": {"usb:test": {"pads": {"0": {"axis": "x"}}}}}"#), pad: 0)
        XCTAssertFalse(same.invert)
        XCTAssertTrue(same.invertHorizontal)

        // Explicit directions win over either baseline.
        let explicit = config(
            try decode(
                #"{"devices": {"usb:test": {"pads": {"0": {"axis": "y", "invert": false, "invertHorizontal": true}}}}}"#
            ), pad: 0)
        XCTAssertFalse(explicit.invert)
        XCTAssertTrue(explicit.invertHorizontal)
    }

    func testAnUnknownScrollAxesValueIsRejectedLikeAnyMalformedValue() {
        XCTAssertThrowsError(try decode(#"{"devices": {"usb:test": {"pads": {"0": {"axes": "diagonal"}}}}}"#))
    }

    /// `invertHorizontal` mirrors `invert`: absent inherits the orientation
    /// baseline (true for a pad the firmware does not x-invert), so leaving
    /// it out is not the same as `false`.
    func testInvertHorizontalOverridesTheOrientationBaseline() throws {
        let capabilities = RawTouchCapabilities(padsPresent: 0x03, rotate90: true, invertY: true)
        func config(_ configuration: RawTouchConfiguration, pad: UInt8) -> TouchScrollEngine.Config {
            configuration.engineConfig(
                forPad: pad, deviceKey: testDeviceKey, capabilities: capabilities, systemPrefersNatural: false,
                pointsPerMM: unitPointsPerMM
            )
        }

        XCTAssertTrue(config(RawTouchConfiguration(), pad: 0).invertHorizontal, "the Go60 baseline")

        let explicit = try decode(#"{"devices": {"usb:test": {"pads": {"0": {"invertHorizontal": false}}}}}"#)
        XCTAssertEqual(explicit[pad: "0"]?.invertHorizontal, false)
        XCTAssertFalse(config(explicit, pad: 0).invertHorizontal)
        XCTAssertTrue(config(explicit, pad: 1).invertHorizontal, "the other pad keeps its baseline")
        XCTAssertFalse(config(explicit, pad: 0).invert, "the vertical baseline is untouched")

        // Natural scrolling and the reverse toggle still layer on top.
        var reversed = explicit
        reversed.reverseScrolling = true
        XCTAssertTrue(config(reversed, pad: 0).invertHorizontal)
        XCTAssertTrue(
            reversed.engineConfig(
                forPad: 1, deviceKey: testDeviceKey, capabilities: capabilities, systemPrefersNatural: true,
                pointsPerMM: unitPointsPerMM
            ).invertHorizontal, "baseline true, natural, reversed: flipped twice")
    }

    func testTheTwoAxisKeysRoundTripThroughTheEncoder() throws {
        var configuration = RawTouchConfiguration()
        configuration[pad: "1"] = .init(invertHorizontal: true, axes: .vertical)

        let data = try JSONEncoder().encode(configuration)
        XCTAssertEqual(try JSONDecoder().decode(RawTouchConfiguration.self, from: data), configuration)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""axes":"vertical""#))
        XCTAssertTrue(text.contains(#""invertHorizontal":true"#))
    }

    func testTheTwoAxisKeysAreKnownToTheUnknownKeyCheck() {
        let known = """
            {"devices": {"usb:test": {"pads": {"0": {"axes": "vertical", "invertHorizontal": true}}}}}
            """
        XCTAssertEqual(RawTouchConfiguration.unknownKeys(in: Data(known.utf8)), [])

        let typos = """
            {"axse": "both", "devices": {"usb:test": {"pads": {"0": {"invertHorizontl": true, "axes": "vertical"}}}}}
            """
        XCTAssertEqual(
            RawTouchConfiguration.unknownKeys(in: Data(typos.utf8)),
            ["axse", "devices.usb:test.pads.0.invertHorizontl"]
        )
    }

    func testNaturalScrollingAndReverseEachFlipTheDirection() {
        let capabilities = RawTouchCapabilities(rotate90: true, invertY: true)
        var reversed = RawTouchConfiguration()
        reversed.reverseScrolling = true

        XCTAssertTrue(
            RawTouchConfiguration().engineConfig(
                forPad: 0, deviceKey: testDeviceKey, capabilities: capabilities, systemPrefersNatural: true,
                pointsPerMM: unitPointsPerMM
            ).invert)
        XCTAssertTrue(
            reversed.engineConfig(
                forPad: 0, deviceKey: testDeviceKey, capabilities: capabilities, systemPrefersNatural: false,
                pointsPerMM: unitPointsPerMM
            ).invert)
        // Both flips cancel.
        XCTAssertFalse(
            reversed.engineConfig(
                forPad: 0, deviceKey: testDeviceKey, capabilities: capabilities, systemPrefersNatural: true,
                pointsPerMM: unitPointsPerMM
            ).invert)
    }

    /// The system's Natural scrolling preference is always followed —
    /// macOS applies it to the firmware's own wheel events in Standard
    /// mode, so following it is what keeps RawTouch mode scrolling the
    /// same way — and there is no key to opt out: one is reported as
    /// unknown and changes nothing.
    func testTheSystemNaturalScrollingPreferenceIsAlwaysFollowed() throws {
        let capabilities = RawTouchCapabilities(rotate90: true, invertY: true)
        let optOut = #"{"followSystemNaturalScrolling": false}"#
        let configuration = try decode(optOut)
        XCTAssertEqual(RawTouchConfiguration.unknownKeys(in: Data(optOut.utf8)), ["followSystemNaturalScrolling"])

        XCTAssertTrue(
            configuration.engineConfig(
                forPad: 0, deviceKey: testDeviceKey, capabilities: capabilities, systemPrefersNatural: true,
                pointsPerMM: unitPointsPerMM
            ).invert)
        XCTAssertFalse(
            configuration.engineConfig(
                forPad: 0, deviceKey: testDeviceKey, capabilities: capabilities, systemPrefersNatural: false,
                pointsPerMM: unitPointsPerMM
            ).invert)
    }

    func testEachPadUsesItsOwnReportedOrientation() {
        // A device whose two pads are mounted differently: pad 0 rotated,
        // pad 1 not. Each must follow its own slot, not pad 0's.
        let report = featureReportBytes(
            slots: [
                // pad 0: rotate-90 + y-invert
                FeatureReportSlot(flags: 0x05, xMax: 2047, yMax: 0, maxContacts: 0),
                // pad 1: no rotation, no inversion
                FeatureReportSlot(flags: 0x00, xMax: 2047, yMax: 0, maxContacts: 0),
            ]
        )

        guard let capabilities = RawTouchCapabilities.parse(reportBytes: report) else {
            XCTFail("Expected the report to parse")
            return
        }

        let configuration = RawTouchConfiguration()
        func config(forPad padID: UInt8) -> TouchScrollEngine.Config {
            configuration.engineConfig(
                forPad: padID,
                capabilities: capabilities,
                systemPrefersNatural: false,
                pointsPerMM: unitPointsPerMM
            )
        }

        XCTAssertEqual(config(forPad: 0).axis, .x)
        XCTAssertEqual(config(forPad: 1).axis, .y)
        XCTAssertTrue(config(forPad: 1).invert)
    }

    func testPerPadOverridesTakePrecedence() {
        let capabilities = RawTouchCapabilities(
            padsPresent: 0x03, rotate90: true, invertY: true
        )
        var configuration = RawTouchConfiguration()
        configuration.scale = 0.5
        configuration[pad: "1"] = .init(scale: 2.0, axis: .y, invert: true, invertHorizontal: false, axes: .vertical)

        let padOne = configuration.engineConfig(
            forPad: 1, deviceKey: testDeviceKey, capabilities: capabilities, systemPrefersNatural: false,
            pointsPerMM: unitPointsPerMM
        )
        XCTAssertEqual(padOne.pointsPerCount, 2.0)
        XCTAssertEqual(padOne.axis, .y)
        XCTAssertEqual(padOne.horizontalAxis, .x, "horizontal follows the vertical override to the other axis")
        XCTAssertTrue(padOne.invert)
        XCTAssertFalse(padOne.invertHorizontal)
        XCTAssertEqual(padOne.axes, .vertical)

        // The other pad is untouched.
        let padZero = configuration.engineConfig(
            forPad: 0, deviceKey: testDeviceKey, capabilities: capabilities, systemPrefersNatural: false,
            pointsPerMM: unitPointsPerMM
        )
        XCTAssertEqual(padZero.pointsPerCount, 0.5)
        XCTAssertEqual(padZero.axis, .x)
        XCTAssertEqual(padZero.horizontalAxis, .y)
        XCTAssertFalse(padZero.invert)
        XCTAssertTrue(padZero.invertHorizontal)
        XCTAssertEqual(padZero.axes, .both)
    }

    func testAccelerationAndMomentumReachTheEngineConfiguration() throws {
        let configuration = try decode(
            """
            {"acceleration": {"enabled": true, "exponent": 0.7}, "momentum": {"decayTimeConstant": 1.2}}
            """)
        let config = configuration.engineConfig(
            forPad: 0,
            capabilities: RawTouchCapabilities(),
            systemPrefersNatural: false, pointsPerMM: unitPointsPerMM
        )

        XCTAssertTrue(config.acceleration.enabled)
        XCTAssertEqual(config.acceleration.exponent, 0.7)
        XCTAssertEqual(config.momentum.decayTimeConstant, 1.2)
    }

    func testUnknownKeysAreReportedAsDottedPaths() {
        let json = """
            {"scal": 1, "acceleration": {"enabled": true, "expnent": 2},
             "pads": {"1": {"scale": 0.5, "axsi": "x"}}, "momentum": {}}
            """
        // `pads` at the top level is not a key — pad settings belong to one
        // keyboard — so it is reported like any other key the decoder does
        // not read.
        XCTAssertEqual(
            RawTouchConfiguration.unknownKeys(in: Data(json.utf8)),
            ["acceleration.expnent", "pads", "scal"]
        )
        XCTAssertEqual(RawTouchConfiguration.unknownKeys(in: Data("{}".utf8)), [])
        XCTAssertEqual(RawTouchConfiguration.unknownKeys(in: Data("not json".utf8)), [])
    }

    /// What `load` logs names a keyboard's entry by its redacted key: the
    /// key is a hardware id, a USB serial or a Bluetooth address, and these
    /// logs end up attached to public bug reports.
    func testUnknownKeysUnderADeviceAreLoggedWithTheKeyRedacted() {
        let json = """
            {"devices": {"id:0123456789ABCDEF": {"pads": {"1": {"axsi": "x"}}},
                         "bt:aa-bb-cc-dd-ee-ff": {"nmae": "Desk"}}}
            """
        XCTAssertEqual(
            RawTouchConfiguration.unknownKeys(in: Data(json.utf8), redactingDeviceKeys: true),
            ["devices.bt:\u{2026}e-ff.nmae", "devices.id:\u{2026}CDEF.pads.1.axsi"]
        )
        XCTAssertEqual(
            RawTouchConfiguration.unknownKeys(in: Data(json.utf8)),
            ["devices.bt:aa-bb-cc-dd-ee-ff.nmae", "devices.id:0123456789ABCDEF.pads.1.axsi"],
            "unredacted unless asked"
        )
    }

    func testPadEnableDefaultsToOnAndFollowsTheMasterSwitch() {
        var configuration = RawTouchConfiguration()
        XCTAssertTrue(configuration.isEnabled(forPad: 0, deviceKey: testDeviceKey))

        configuration[pad: "0"] = .init(enabled: false)
        XCTAssertFalse(configuration.isEnabled(forPad: 0, deviceKey: testDeviceKey))
        XCTAssertTrue(configuration.isEnabled(forPad: 1, deviceKey: testDeviceKey))

        configuration.enabled = false
        XCTAssertFalse(configuration.isEnabled(forPad: 1, deviceKey: testDeviceKey))
    }
}
