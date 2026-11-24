// MIT License
// Copyright (c) 2026 RawTouch contributors
// Derived from LinearMouse — Copyright (c) 2021-2026 LinearMouse (MIT).

import RawTouchTestSupport
import XCTest

@testable import RawTouchCore

final class TouchScrollEngineTests: XCTestCase {
    private static let frameInterval: TimeInterval = 0.01  // ~100 Hz device cadence
    private static let tickInterval: TimeInterval = 1.0 / 120.0

    /// The ballistics these tests are written against: a square-root curve
    /// with an 800 counts/s reference, clamped to 0.4…3. Pinned here, like
    /// `referenceMomentum`, so the engine's math is tested on known numbers
    /// while its own defaults follow the shipped tuning.
    private static let referenceCurve = TouchScrollEngine.Config.Acceleration(
        enabled: true, exponent: 0.5, referenceSpeed: 800, minGain: 0.4, maxGain: 3)

    /// The momentum these tests are written against: a 0.83 s decay, a
    /// 100 pt/s start threshold and an 8000 pt/s cap.
    private static let referenceMomentum = TouchScrollEngine.Config.Momentum(
        decayTimeConstant: 0.83, startThreshold: 100, maxSpeed: 8000)

    private func makeEngine(
        pointsPerCount: Double = 0.25,
        invert: Bool = false,
        invertHorizontal: Bool = false,
        axis: RawTouchAxis = .y,
        axes: RawTouchScrollAxes = .both,
        acceleration: TouchScrollEngine.Config.Acceleration = .init(),
        momentum: TouchScrollEngine.Config.Momentum = referenceMomentum
    ) -> TouchScrollEngine {
        TouchScrollEngine(
            config: .init(
                pointsPerCount: pointsPerCount,
                invert: invert,
                invertHorizontal: invertHorizontal,
                axis: axis,
                axes: axes,
                acceleration: acceleration,
                momentum: momentum
            ))
    }

    /// Every touchChanged delta as (x, y).
    private func touchDeltas(_ events: [TouchScrollEngine.Event]) -> [(x: Double, y: Double)] {
        events.compactMap {
            if case .touchChanged(let x, let y) = $0 {
                return (x, y)
            }
            return nil
        }
    }

    /// Every momentum delta as (x, y), began first.
    private func momentumDeltas(_ events: [TouchScrollEngine.Event]) -> [(x: Double, y: Double)] {
        events.compactMap {
            switch $0 {
            case .momentumBegan(let x, let y), .momentumChanged(let x, let y):
                return (x, y)
            default:
                return nil
            }
        }
    }

    /// Drives a fast steady drag and lift-off; returns (dragEvents, liftTime).
    private func performFlick(
        on engine: TouchScrollEngine,
        frames: Int = 12,
        countsPerFrame: Int = 25
    ) -> (events: [TouchScrollEngine.Event], liftTime: TimeInterval) {
        var events: [TouchScrollEngine.Event] = []
        var y = 500
        var timestamp: TimeInterval = 0

        for step in 0..<frames {
            timestamp = Double(step) * Self.frameInterval
            events += engine.handle(frame: scrollFrame(y: y, at: timestamp))
            y += countsPerFrame
        }

        timestamp += Self.frameInterval
        events += engine.handle(frame: releaseFrame(at: timestamp, scrollMode: true))
        return (events, timestamp)
    }

    private func drainMomentum(
        on engine: TouchScrollEngine,
        from startTime: TimeInterval,
        maxTicks: Int = 2000
    ) -> [TouchScrollEngine.Event] {
        var events: [TouchScrollEngine.Event] = []
        var timestamp = startTime

        for _ in 0..<maxTicks {
            guard engine.wantsMomentumTicks else {
                break
            }
            timestamp += Self.tickInterval
            events += engine.momentumTick(at: timestamp)
        }

        return events
    }

    // MARK: - Touch, drag, lift with momentum

    // MARK: - Gesture summary

    /// The readout the settings window shows: written at lift-off with the
    /// touch's peaks and the lift-off speed (open while a coast follows),
    /// then closed with the coast's distance and duration once it ends.
    func testGestureSummaryIsWrittenAtLiftOffAndClosedWhenTheCoastEnds() {
        let engine = makeEngine(
            acceleration: .init(
                enabled: true, exponent: 1, referenceSpeed: 1000, minGain: 1, maxGain: 4
            ))
        XCTAssertNil(engine.lastGestureSummary)

        let (_, liftTime) = performFlick(on: engine)
        guard let atLiftOff = engine.lastGestureSummary else {
            return XCTFail("no summary at lift-off")
        }
        XCTAssertFalse(atLiftOff.complete, "the coast is still to come")
        XCTAssertTrue(atLiftOff.coasted)
        XCTAssertEqual(atLiftOff.peakFingerSpeed, 2500, accuracy: 1, "25 counts per 10 ms frame")
        XCTAssertEqual(atLiftOff.peakGain, 2.5, accuracy: 0.01, "2500 / 1000 with exponent 1")
        XCTAssertGreaterThan(atLiftOff.touchDistance, 0)
        XCTAssertGreaterThanOrEqual(atLiftOff.liftOffSpeed, engine.config.momentum.startThreshold)
        XCTAssertEqual(atLiftOff.coastDistance, 0)

        _ = drainMomentum(on: engine, from: liftTime)
        guard let closed = engine.lastGestureSummary else {
            return XCTFail("summary vanished")
        }
        XCTAssertTrue(closed.complete)
        XCTAssertEqual(closed.peakGain, atLiftOff.peakGain, "the touch half is untouched")
        XCTAssertEqual(closed.liftOffSpeed, atLiftOff.liftOffSpeed)
        XCTAssertGreaterThan(closed.coastDistance, 0)
        XCTAssertGreaterThan(closed.coastDuration, 0)
    }

    /// Every touch is its own gesture, however alike: the coast's closing
    /// summary keeps its touch's ID, the next touch gets a new one.
    func testEachTouchGetsItsOwnGestureID() {
        let engine = makeEngine()
        let (_, liftTime) = performFlick(on: engine)
        let flickID = engine.lastGestureSummary?.gestureID
        _ = drainMomentum(on: engine, from: liftTime)
        XCTAssertEqual(engine.lastGestureSummary?.gestureID, flickID, "the coast closes the same gesture")

        var ids: [UInt64?] = [flickID]
        for tap in 0..<2 {
            let start = 10.0 + Double(tap)
            _ = engine.handle(frame: scrollFrame(y: 500, at: start))
            _ = engine.handle(frame: releaseFrame(at: start + Self.frameInterval, scrollMode: true))
            ids.append(engine.lastGestureSummary?.gestureID)
        }
        XCTAssertEqual(Set(ids.compactMap { $0 }).count, 3, "two identical taps are two gestures")
    }

    /// A slow release that does not coast is complete at lift-off, with a
    /// gain of exactly 1 when acceleration is off.
    func testAGestureThatDoesNotCoastIsCompleteAtLiftOff() {
        let engine = makeEngine(momentum: .init(decayTimeConstant: 0.55, startThreshold: 100_000, maxSpeed: 20_000))
        _ = performFlick(on: engine, frames: 4, countsPerFrame: 2)
        guard let summary = engine.lastGestureSummary else {
            return XCTFail("no summary")
        }
        XCTAssertTrue(summary.complete)
        XCTAssertFalse(summary.coasted)
        XCTAssertEqual(summary.peakGain, 1)
        XCTAssertEqual(summary.coastDistance, 0)
        XCTAssertFalse(engine.isActive)
    }

    /// A catch closes the coasting summary with what it managed so far
    /// before the new touch starts its own bookkeeping.
    func testACatchClosesTheCoastingSummary() {
        let engine = makeEngine()
        let (_, liftTime) = performFlick(on: engine)
        var timestamp = liftTime
        for _ in 0..<6 {
            timestamp += Self.tickInterval
            _ = engine.momentumTick(at: timestamp)
        }
        XCTAssertFalse(engine.lastGestureSummary?.complete ?? true)

        _ = engine.handle(frame: scrollFrame(y: 900, at: timestamp + Self.frameInterval))
        guard let caught = engine.lastGestureSummary else {
            return XCTFail("no summary")
        }
        XCTAssertTrue(caught.complete)
        XCTAssertGreaterThan(caught.coastDistance, 0)
        XCTAssertEqual(caught.coastDuration, timestamp + Self.frameInterval - liftTime, accuracy: 1e-9)
    }

    func testDragAndFlickProducesPhasesAndMomentum() {
        let engine = makeEngine()
        let (dragEvents, liftTime) = performFlick(on: engine)

        XCTAssertEqual(dragEvents.first, .touchBegan)
        let changedDeltas: [Double] = dragEvents.compactMap {
            if case .touchChanged(_, let deltaY) = $0 {
                return deltaY
            } else {
                return nil
            }
        }
        XCTAssertEqual(changedDeltas.count, 11)
        // 25 counts * 0.25 points per count per frame.
        XCTAssertTrue(changedDeltas.allSatisfy { abs($0 - 6.25) < 1e-9 })
        XCTAssertEqual(dragEvents.last, .touchEnded)

        XCTAssertTrue(engine.wantsMomentumTicks)

        let momentumEvents = drainMomentum(on: engine, from: liftTime)
        guard case .momentumBegan(_, let firstDelta) = momentumEvents.first else {
            XCTFail("Expected momentumBegan first, got \(String(describing: momentumEvents.first))")
            return
        }
        XCTAssertGreaterThan(firstDelta, 0)
        XCTAssertTrue(
            momentumEvents.dropFirst().dropLast().allSatisfy {
                if case .momentumChanged = $0 {
                    return true
                } else {
                    return false
                }
            })
        XCTAssertEqual(momentumEvents.last, .momentumEnded)
        XCTAssertFalse(engine.wantsMomentumTicks)

        // Momentum deltas decay monotonically.
        let momentumDeltas: [Double] = momentumEvents.compactMap {
            switch $0 {
            case .momentumBegan(_, let deltaY), .momentumChanged(_, let deltaY):
                return deltaY
            default:
                return nil
            }
        }
        XCTAssertGreaterThan(momentumDeltas.count, 10)
        XCTAssertTrue(zip(momentumDeltas, momentumDeltas.dropFirst()).allSatisfy { $0 >= $1 })
        XCTAssertTrue(momentumDeltas.allSatisfy { $0 > 0 })
    }

    // MARK: - Drag, stop, lift: no momentum

    func testStopBeforeLiftYieldsNoMomentum() {
        let engine = makeEngine()
        var events: [TouchScrollEngine.Event] = []
        var timestamp: TimeInterval = 0

        // Fast drag...
        var y = 500
        for step in 0..<10 {
            timestamp = Double(step) * Self.frameInterval
            events += engine.handle(frame: scrollFrame(y: y, at: timestamp))
            y += 25
        }

        // ...then hold still for 300 ms (device keeps streaming while touched)...
        for _ in 0..<30 {
            timestamp += Self.frameInterval
            events += engine.handle(frame: scrollFrame(y: y, at: timestamp))
        }

        // ...then lift.
        timestamp += Self.frameInterval
        events += engine.handle(frame: releaseFrame(at: timestamp, scrollMode: true))

        XCTAssertEqual(events.last, .touchEnded)
        XCTAssertFalse(engine.wantsMomentumTicks)
        XCTAssertTrue(engine.momentumTick(at: timestamp + Self.tickInterval).isEmpty)
    }

    // MARK: - The catch: touch-down during momentum cancels it

    func testTouchDownDuringMomentumCancelsItImmediately() {
        let engine = makeEngine()
        let (_, liftTime) = performFlick(on: engine)

        // Let momentum begin and coast for a few ticks.
        var timestamp = liftTime
        var sawMomentumBegan = false
        for _ in 0..<10 {
            timestamp += Self.tickInterval
            for event in engine.momentumTick(at: timestamp) {
                if case .momentumBegan = event {
                    sawMomentumBegan = true
                }
            }
        }
        XCTAssertTrue(sawMomentumBegan)
        XCTAssertTrue(engine.wantsMomentumTicks)

        // A resting finger touches down: momentum must end instantly and a
        // fresh gesture must begin.
        let catchEvents = engine.handle(frame: scrollFrame(y: 900, at: timestamp + Self.frameInterval))
        XCTAssertEqual(catchEvents, [.momentumEnded, .touchBegan])
        XCTAssertFalse(engine.wantsMomentumTicks)
        XCTAssertTrue(engine.momentumTick(at: timestamp + 1).isEmpty)

        // The caught gesture keeps working normally.
        let followUp = engine.handle(
            frame: scrollFrame(y: 910, at: timestamp + Self.frameInterval * 2)
        )
        XCTAssertEqual(followUp, [.touchChanged(deltaX: 0, deltaY: 2.5)])
    }

    // MARK: - Direction and scale

    func testInvertFlipsDeltaSignAndMomentumDirection() {
        let engine = makeEngine(invert: true)
        let (dragEvents, liftTime) = performFlick(on: engine)

        let changedDeltas: [Double] = dragEvents.compactMap {
            if case .touchChanged(_, let deltaY) = $0 {
                return deltaY
            } else {
                return nil
            }
        }
        XCTAssertTrue(changedDeltas.allSatisfy { $0 < 0 })

        let momentumEvents = drainMomentum(on: engine, from: liftTime)
        guard case .momentumBegan(_, let firstDelta) = momentumEvents.first else {
            XCTFail("Expected momentum to begin")
            return
        }
        XCTAssertLessThan(firstDelta, 0)
    }

    func testAxisXDrivesDeltasFromRawXAndComposesWithInvert() {
        // Rotated pad mount (Go60): physical up/down motion changes raw X.
        let engine = makeEngine(axis: .x)
        _ = engine.handle(frame: .init(x: 1000, y: 500, z: 40, touched: true, scrollMode: true, timestamp: 0))
        let events = engine.handle(
            frame: .init(x: 1030, y: 500, z: 40, touched: true, scrollMode: true, timestamp: Self.frameInterval)
        )
        XCTAssertEqual(events, [.touchChanged(deltaX: 0, deltaY: 7.5)])

        // Raw-Y movement is horizontal on axis x: +400 counts × 0.25.
        let yOnly = engine.handle(
            frame: .init(x: 1030, y: 900, z: 40, touched: true, scrollMode: true, timestamp: Self.frameInterval * 2)
        )
        XCTAssertEqual(yOnly, [.touchChanged(deltaX: 100, deltaY: 0)])

        // invert composes with the axis selection unchanged.
        let invertedEngine = makeEngine(invert: true, axis: .x)
        _ = invertedEngine.handle(
            frame: .init(x: 1000, y: 500, z: 40, touched: true, scrollMode: true, timestamp: 0)
        )
        let invertedEvents = invertedEngine.handle(
            frame: .init(x: 1030, y: 500, z: 40, touched: true, scrollMode: true, timestamp: Self.frameInterval)
        )
        XCTAssertEqual(invertedEvents, [.touchChanged(deltaX: 0, deltaY: -7.5)])
    }

    func testScaleAppliesToDeltas() {
        let engine = makeEngine(pointsPerCount: 1.0)
        _ = engine.handle(frame: scrollFrame(y: 500, at: 0))
        let events = engine.handle(frame: scrollFrame(y: 530, at: Self.frameInterval))
        XCTAssertEqual(events, [.touchChanged(deltaX: 0, deltaY: 30)])
    }

    // MARK: - Two axes

    func testInvertHorizontalFlipsOnlyTheHorizontalComponent() {
        // Default mapping: vertical from raw y, horizontal from raw x.
        let engine = makeEngine(invertHorizontal: true)
        _ = engine.handle(frame: scrollFrame(x: 1000, y: 500, at: 0))
        let events = engine.handle(frame: scrollFrame(x: 1020, y: 530, at: Self.frameInterval))
        XCTAssertEqual(events, [.touchChanged(deltaX: -5, deltaY: 7.5)])

        let both = makeEngine(invert: true, invertHorizontal: true)
        _ = both.handle(frame: scrollFrame(x: 1000, y: 500, at: 0))
        XCTAssertEqual(
            both.handle(frame: scrollFrame(x: 1020, y: 530, at: Self.frameInterval)),
            [.touchChanged(deltaX: -5, deltaY: -7.5)]
        )
    }

    /// One gain for both components, from the 2-D speed: a diagonal drag
    /// scrolls both axes by the same factor, so its direction on screen is
    /// its direction on the pad. Per-axis gains would bend it toward the
    /// faster axis.
    func testDiagonalDragEmitsBothComponentsWithOneSharedGain() {
        let engine = makeEngine(acceleration: Self.referenceCurve)
        var events: [TouchScrollEngine.Event] = []
        // 30 counts/frame on x, 40 on y: 3000 and 4000 counts/s, a 2-D
        // speed of exactly 5000 counts/s.
        for step in 0..<10 {
            events += engine.handle(
                frame: scrollFrame(
                    x: 1000 + step * 30, y: 500 + step * 40, at: Double(step) * Self.frameInterval
                ))
        }

        let deltas = touchDeltas(events)
        XCTAssertEqual(deltas.count, 9)
        let sharedGain = pow(5000.0 / 800.0, 0.5)  // 2.5, under the 3.0 cap
        let xAloneGain = pow(3000.0 / 800.0, 0.5)
        let yAloneGain = pow(4000.0 / 800.0, 0.5)
        for delta in deltas {
            XCTAssertEqual(delta.x, 30 * 0.25 * sharedGain, accuracy: 1e-9)
            XCTAssertEqual(delta.y, 40 * 0.25 * sharedGain, accuracy: 1e-9)
            XCTAssertEqual(delta.x / delta.y, 0.75, accuracy: 1e-9, "the pad direction is preserved")
            XCTAssertNotEqual(delta.x, 30 * 0.25 * xAloneGain, accuracy: 1e-6, "not a per-axis gain")
            XCTAssertNotEqual(delta.y, 40 * 0.25 * yAloneGain, accuracy: 1e-6)
        }
    }

    /// A disabled direction contributes nothing: its delta is zero, its
    /// motion does not enter the speed estimate (the enabled axis is not
    /// boosted by a fast drag on the other), and it seeds no momentum.
    func testASingleAxisPadZeroesTheOtherComponentAndLeavesItOutOfSpeedAndMomentum() {
        for axes in [RawTouchScrollAxes.vertical, .horizontal] {
            let engine = makeEngine(axes: axes, acceleration: Self.referenceCurve)
            // The enabled axis crawls at 10 counts/frame (1000 counts/s,
            // gain sqrt(1.25)); the disabled one races at 100 counts/frame,
            // which would push the 2-D speed past the gain cap.
            let slow = { (step: Int) in 500 + step * 10 }
            let fast = { (step: Int) in 500 + step * 100 }
            var events: [TouchScrollEngine.Event] = []
            var timestamp = 0.0
            for step in 0..<12 {
                timestamp = Double(step) * Self.frameInterval
                let frame =
                    axes == .vertical
                    ? scrollFrame(x: fast(step), y: slow(step), at: timestamp)
                    : scrollFrame(x: slow(step), y: fast(step), at: timestamp)
                events += engine.handle(frame: frame)
            }
            let liftTime = timestamp + Self.frameInterval
            events += engine.handle(frame: releaseFrame(at: liftTime, scrollMode: true))

            let slowGain = pow(1000.0 / 800.0, 0.5)
            for delta in touchDeltas(events) {
                let (enabled, disabled) = axes == .vertical ? (delta.y, delta.x) : (delta.x, delta.y)
                XCTAssertEqual(disabled, 0, "\(axes): the disabled axis posts nothing")
                XCTAssertEqual(
                    enabled, 10 * 0.25 * slowGain, accuracy: 1e-9, "\(axes): gain from the enabled axis alone")
            }

            // The enabled axis lifts at ~280 pt/s, above the 100 pt/s
            // threshold: momentum runs, and only along that axis.
            XCTAssertTrue(engine.wantsMomentumTicks, "\(axes)")
            let momentum = momentumDeltas(drainMomentum(on: engine, from: liftTime))
            XCTAssertGreaterThan(momentum.count, 5, "\(axes)")
            for delta in momentum {
                let (enabled, disabled) = axes == .vertical ? (delta.y, delta.x) : (delta.x, delta.y)
                XCTAssertEqual(disabled, 0, "\(axes): no momentum on the disabled axis")
                XCTAssertGreaterThan(enabled, 0, "\(axes)")
            }
        }
    }

    /// The momentum vector keeps the flick's direction: the seed cap scales
    /// the vector rather than clamping each component, the decay is
    /// isotropic, and the stop floor applies to the magnitude.
    func testMomentumVectorPreservesDirectionUnderCapAndDecay() {
        let capped = makeEngine(momentum: .init(maxSpeed: 200))
        var timestamp = 0.0
        // 25 counts/frame on x, 50 on y: (625, 1250) pt/s at lift, a
        // magnitude of ~1398 pt/s — far over the 200 pt/s cap.
        for step in 0..<12 {
            timestamp = Double(step) * Self.frameInterval
            _ = capped.handle(frame: scrollFrame(x: 1000 + step * 25, y: 500 + step * 50, at: timestamp))
        }
        let liftTime = timestamp + Self.frameInterval
        _ = capped.handle(frame: releaseFrame(at: liftTime, scrollMode: true))
        XCTAssertTrue(capped.wantsMomentumTicks)

        let momentum = drainMomentum(on: capped, from: liftTime)
        let deltas = momentumDeltas(momentum)
        XCTAssertGreaterThan(deltas.count, 5)
        XCTAssertEqual(momentum.last, .momentumEnded)

        let dt = Self.tickInterval
        let firstSpeed = (deltas[0].x * deltas[0].x + deltas[0].y * deltas[0].y).squareRoot() / dt
        XCTAssertLessThanOrEqual(firstSpeed, 200 + 1e-9, "the magnitude is capped")
        XCTAssertGreaterThan(firstSpeed, 150, "at the cap, not clamped per component to something smaller")
        var previousSpeed = Double.infinity
        for delta in deltas {
            XCTAssertEqual(delta.x / delta.y, 0.5, accuracy: 1e-9, "direction preserved through cap and decay")
            let speed = (delta.x * delta.x + delta.y * delta.y).squareRoot() / dt
            XCTAssertLessThan(speed, previousSpeed, "the magnitude decays monotonically")
            XCTAssertGreaterThanOrEqual(speed, 40 * 0.99, "the 40 pt/s floor applies to the magnitude")
            previousSpeed = speed
        }
        // Per component the last delta is well under the floor's worth —
        // which is why the floor has to be on the magnitude.
        XCTAssertLessThan(abs(deltas.last!.x), 40 * dt)
    }

    /// The start threshold is on the magnitude too: two components each
    /// below it can still add up to a flick.
    func testMomentumStartThresholdAppliesToTheMagnitude() {
        // 1 count/frame at 1 pt/count on each axis: 100 pt/s per component,
        // ~141 pt/s together.
        func flick(threshold: Double, diagonal: Bool) -> TouchScrollEngine {
            let engine = makeEngine(pointsPerCount: 1, momentum: .init(startThreshold: threshold))
            var timestamp = 0.0
            for step in 0..<12 {
                timestamp = Double(step) * Self.frameInterval
                _ = engine.handle(frame: scrollFrame(x: 1000 + (diagonal ? step : 0), y: 500 + step, at: timestamp))
            }
            _ = engine.handle(frame: releaseFrame(at: timestamp + Self.frameInterval, scrollMode: true))
            return engine
        }

        XCTAssertFalse(flick(threshold: 120, diagonal: false).wantsMomentumTicks, "100 pt/s alone is under 120")
        XCTAssertTrue(flick(threshold: 120, diagonal: true).wantsMomentumTicks, "141 pt/s together is over it")
        XCTAssertFalse(flick(threshold: 150, diagonal: true).wantsMomentumTicks)
    }

    /// A glitch on a disabled axis is nothing to the engine: the enabled
    /// axis's delta goes out as usual (the guard runs on the enabled step).
    func testAGlitchOnADisabledAxisDoesNotVetoTheEnabledAxis() {
        let engine = makeEngine(axes: .vertical)
        _ = engine.handle(frame: scrollFrame(x: 100, y: 500, at: 0))
        XCTAssertEqual(
            engine.handle(frame: scrollFrame(x: 1000, y: 530, at: Self.frameInterval)),
            [.touchChanged(deltaX: 0, deltaY: 7.5)]
        )
    }

    func testAGlitchOnEitherAxisReAnchorsBothWithoutMotion() {
        let engine = makeEngine()
        _ = engine.handle(frame: scrollFrame(x: 1000, y: 500, at: 0))
        // x jumps implausibly while y moves a little: neither is emitted.
        XCTAssertEqual(
            engine.handle(frame: scrollFrame(x: 1900, y: 510, at: Self.frameInterval)),
            [.touchChanged(deltaX: 0, deltaY: 0)]
        )
        // Re-anchored: the next frame differences against the jump.
        XCTAssertEqual(
            engine.handle(frame: scrollFrame(x: 1910, y: 520, at: Self.frameInterval * 2)),
            [.touchChanged(deltaX: 2.5, deltaY: 2.5)]
        )
    }

    // MARK: - Acceleration (velocity-dependent gain)

    /// Steady drag at `countsPerFrame` per ~100 Hz frame; returns the emitted
    /// touchChanged deltas.
    private func steadyDragDeltas(
        acceleration: TouchScrollEngine.Config.Acceleration,
        countsPerFrame: Int,
        frames: Int = 10
    ) -> [Double] {
        let engine = makeEngine(acceleration: acceleration)
        var deltas: [Double] = []
        var y = 200

        for step in 0..<frames {
            let events = engine.handle(frame: scrollFrame(y: y, at: Double(step) * Self.frameInterval))
            for case .touchChanged(_, let deltaY) in events {
                deltas.append(deltaY)
            }
            y += countsPerFrame
        }

        return deltas
    }

    /// Expected steady-state gain for a constant-speed drag with the default
    /// curve: clamp(sqrt(speed / 800), 0.4, 3).
    private func defaultCurveGain(countsPerFrame: Int) -> Double {
        let speed = Double(countsPerFrame) / Self.frameInterval
        return pow(speed / 800.0, 0.5).clamped(to: 0.4...3.0)
    }

    func testAccelerationExponentZeroMatchesDisabledAndLinear() {
        let linear = makeEngine()
        let disabled = makeEngine(acceleration: .init(enabled: false, exponent: 0.7))
        let exponentZero = makeEngine(acceleration: .init(enabled: true, exponent: 0))

        let (linearEvents, linearLift) = performFlick(on: linear)
        let (disabledEvents, disabledLift) = performFlick(on: disabled)
        let (exponentZeroEvents, exponentZeroLift) = performFlick(on: exponentZero)

        XCTAssertEqual(disabledEvents, linearEvents)
        XCTAssertEqual(exponentZeroEvents, linearEvents)

        // The momentum seed and decay must match too.
        let linearMomentum = drainMomentum(on: linear, from: linearLift)
        XCTAssertFalse(linearMomentum.isEmpty)
        XCTAssertEqual(drainMomentum(on: disabled, from: disabledLift), linearMomentum)
        XCTAssertEqual(drainMomentum(on: exponentZero, from: exponentZeroLift), linearMomentum)
    }

    func testAccelerationAttenuatesSlowDragsAndBoostsFastDrags() {
        // Slow drag: 3 counts/frame = 300 counts/s, below the 800 counts/s
        // reference speed, so gain < 1.
        let slowLinear = steadyDragDeltas(acceleration: .init(), countsPerFrame: 3)
        let slowAccelerated = steadyDragDeltas(acceleration: Self.referenceCurve, countsPerFrame: 3)
        XCTAssertEqual(slowAccelerated.count, slowLinear.count)
        for (accelerated, linear) in zip(slowAccelerated, slowLinear) {
            XCTAssertLessThan(accelerated, linear)
            XCTAssertGreaterThan(accelerated, 0)
        }

        // Fast drag: 25 counts/frame = 2500 counts/s, above reference, gain > 1.
        let fastLinear = steadyDragDeltas(acceleration: .init(), countsPerFrame: 25)
        let fastAccelerated = steadyDragDeltas(acceleration: Self.referenceCurve, countsPerFrame: 25)
        for (accelerated, linear) in zip(fastAccelerated, fastLinear) {
            XCTAssertGreaterThan(accelerated, linear)
        }
    }

    func testAccelerationHasNoSlowStartDeadZone() {
        // A steady drag exactly at the reference speed (8 counts/frame =
        // 800 counts/s) must have gain 1 from the very first movement frame:
        // the speed smoother seeds from the first observed instantaneous
        // speed rather than ramping up from zero.
        let deltas = steadyDragDeltas(acceleration: Self.referenceCurve, countsPerFrame: 8)
        XCTAssertEqual(deltas.count, 9)
        for delta in deltas {
            XCTAssertEqual(delta, 8 * 0.25, accuracy: 1e-9)
        }
    }

    func testAccelerationGainClampsAtMinAndMax() {
        // 1 count/frame = 100 counts/s: raw gain sqrt(100/800) ≈ 0.354,
        // clamped up to minGain 0.4.
        let crawlDeltas = steadyDragDeltas(acceleration: Self.referenceCurve, countsPerFrame: 1)
        XCTAssertEqual(defaultCurveGain(countsPerFrame: 1), 0.4)
        for delta in crawlDeltas {
            XCTAssertEqual(delta, 1 * 0.25 * 0.4, accuracy: 1e-9)
        }

        // 100 counts/frame = 10000 counts/s: raw gain sqrt(12.5) ≈ 3.54,
        // clamped down to maxGain 3.
        let sprintDeltas = steadyDragDeltas(acceleration: Self.referenceCurve, countsPerFrame: 100)
        XCTAssertEqual(defaultCurveGain(countsPerFrame: 100), 3.0)
        for delta in sprintDeltas {
            XCTAssertEqual(delta, 100 * 0.25 * 3.0, accuracy: 1e-9)
        }
    }

    func testAccelerationMomentumSeedReflectsBoostedVelocity() {
        let linear = makeEngine()
        let accelerated = makeEngine(acceleration: Self.referenceCurve)

        let (_, linearLift) = performFlick(on: linear)
        let (_, acceleratedLift) = performFlick(on: accelerated)
        XCTAssertTrue(linear.wantsMomentumTicks)
        XCTAssertTrue(accelerated.wantsMomentumTicks)

        guard
            case .momentumBegan(_, let linearSeed)? = drainMomentum(on: linear, from: linearLift).first,
            case .momentumBegan(_, let acceleratedSeed)? = drainMomentum(on: accelerated, from: acceleratedLift).first
        else {
            XCTFail("Expected both engines to begin momentum")
            return
        }

        // The steady 2500 counts/s flick has constant gain sqrt(2500/800),
        // so the output-side (on-screen) lift-off velocity — and therefore
        // the momentum seed — is boosted by exactly that factor.
        let expectedGain = defaultCurveGain(countsPerFrame: 25)
        XCTAssertGreaterThan(expectedGain, 1)
        XCTAssertEqual(acceleratedSeed, linearSeed * expectedGain, accuracy: 1e-6)
    }

    // MARK: - Lift-off velocity fit

    /// Recovers the momentum seed (points/second at lift-off) from the first
    /// tick's delta by undoing the tick's own decay and integration.
    private func seed(fromFirstDelta delta: Double, engine: TouchScrollEngine) -> Double {
        let dt = Self.tickInterval
        return delta / (exp(-dt / engine.config.momentum.decayTimeConstant) * dt)
    }

    func testConstantVelocitySeedMatchesDragSpeedExactly() {
        let engine = makeEngine()
        let (_, liftTime) = performFlick(on: engine)

        guard case .momentumBegan(_, let firstDelta)? = drainMomentum(on: engine, from: liftTime).first else {
            XCTFail("Expected momentum")
            return
        }

        // 25 counts per 10 ms frame = 2500 counts/s × 0.25 points/count.
        // The weighted least-squares fit is exact for constant velocity —
        // recency weighting must not bias a steady drag.
        XCTAssertEqual(seed(fromFirstDelta: firstDelta, engine: engine), 625.0, accuracy: 1e-6)
    }

    /// A drag of `steps` counts per frame, then lift frames (strength 40 →
    /// 22, 14, 8, 4) whose reported positions move by `fadeSteps`. Returns
    /// the deltas shown during the fade and the momentum seed (0 when the
    /// lift does not coast).
    private func liftingFlick(
        floor: Double,
        steps: [Int] = Array(repeating: 25, count: 12),
        fadeSteps: [Int]
    ) -> (fadeDeltas: [Double], seed: Double, engine: TouchScrollEngine) {
        let engine = makeEngine(momentum: .init(liftStrengthFloor: floor))
        var y = 500
        var timestamp: TimeInterval = 0
        for (index, step) in steps.enumerated() {
            timestamp = Double(index) * Self.frameInterval
            _ = engine.handle(frame: scrollFrame(y: y, at: timestamp))
            y += step
        }
        var fadeDeltas: [Double] = []
        for (strength, step) in zip([22, 14, 8, 4], fadeSteps) {
            timestamp += Self.frameInterval
            y += step
            let events = engine.handle(
                frame: .init(x: 1000, y: y, z: strength, touched: true, scrollMode: true, timestamp: timestamp))
            fadeDeltas += touchDeltas(events).map(\.y)
        }
        timestamp += Self.frameInterval
        _ = engine.handle(frame: releaseFrame(at: timestamp, scrollMode: true))
        guard case .momentumBegan(_, let firstDelta)? = drainMomentum(on: engine, from: timestamp).first else {
            return (fadeDeltas, 0, engine)
        }
        return (fadeDeltas, seed(fromFirstDelta: firstDelta, engine: engine), engine)
    }

    /// A flick carried through its lift: once the strength fades on a fast,
    /// non-decelerating finger, the fading frames scroll at the firm-contact
    /// speed whatever their reported positions, and the coast starts from
    /// that same speed — one continuous motion.
    func testAFlickIsCarriedThroughItsFade() {
        let stalling = [6, 2, 2, 2]
        let result = liftingFlick(floor: 0.6, fadeSteps: stalling)
        // 25 counts × 0.25 pt per 10 ms frame, on every fading frame.
        XCTAssertEqual(result.fadeDeltas.count, 4)
        for delta in result.fadeDeltas {
            XCTAssertEqual(delta, 6.25, accuracy: 0.01)
        }
        XCTAssertEqual(result.seed, 625, accuracy: 1)
        XCTAssertEqual(result.engine.lastGestureSummary?.liftFramesCarried, 4)

        // Floor 0: the feature is off — the stalled fade is followed and
        // seeds the coast, as before.
        let off = liftingFlick(floor: 0, fadeSteps: stalling)
        XCTAssertLessThan(off.seed, 625 * 0.7)
        XCTAssertEqual(off.engine.lastGestureSummary?.liftFramesCarried, 0)
    }

    /// The firm history a fade needs before it can be judged a lift is
    /// 100 ms — ten of the pad's frames — at whatever rate frames reach
    /// the engine: resampled to a 120 or 60 Hz display, a strength drop
    /// just short of 100 ms into the touch is still the touch-down ramp.
    func testTheLiftNeedsTheSameFirmHistoryAtEveryFrameRate() {
        for rate in [100.0, 120, 60] {
            let period = 1 / rate
            for firmFrames in [Int((0.1 / period).rounded()) - 1, Int((0.1 / period).rounded())] {
                let engine = makeEngine(momentum: .init(liftStrengthFloor: 0.6))
                var timestamp: TimeInterval = 0
                for frame in 0...firmFrames {
                    timestamp = Double(frame) * period
                    _ = engine.handle(frame: scrollFrame(y: 500 + Int((2500 * timestamp).rounded()), at: timestamp))
                }
                timestamp += period
                _ = engine.handle(
                    frame: .init(
                        x: 1000, y: 500 + Int((2500 * timestamp).rounded()), z: 4, touched: true, scrollMode: true,
                        timestamp: timestamp
                    ))
                timestamp += period
                _ = engine.handle(frame: releaseFrame(at: timestamp, scrollMode: true))

                let history = Double(firmFrames) * period
                XCTAssertEqual(
                    engine.lastGestureSummary?.liftFramesCarried, history >= 0.1 - 1e-9 ? 1 : 0,
                    "\(rate) Hz, \(Int((history * 1000).rounded())) ms of firm history"
                )
            }
        }
    }

    /// A landing: the finger was braking hard before its strength faded, so
    /// the fade is real slowing and is followed, not carried.
    func testALandingIsNotCarriedThrough() {
        // 40 counts per frame braking by 4 per frame: a/v ≈ −16/s at the end.
        let braking = [40, 36, 32, 28, 24, 20, 16, 12, 8, 6, 4, 2]
        let result = liftingFlick(floor: 0.6, steps: braking, fadeSteps: [1, 1, 0, 0])
        XCTAssertEqual(result.engine.lastGestureSummary?.liftFramesCarried, 0)
        XCTAssertEqual(result.seed, 0, "no coast from a landing")
        // The last braking step (2 counts) lands on the first fade frame,
        // plus its own 1: the reported positions are followed as they are.
        XCTAssertEqual(result.fadeDeltas, [0.75, 0.25, 0, 0])
    }

    /// A dip in strength that recovers is not a lift: the carry ends and
    /// the finger is followed again from where it is, with no jump.
    func testARecoveringDipEndsTheCarryWithoutAJump() {
        let engine = makeEngine(momentum: .init(liftStrengthFloor: 0.6))
        var y = 500
        var timestamp: TimeInterval = 0
        for step in 0..<12 {
            timestamp = Double(step) * Self.frameInterval
            _ = engine.handle(frame: scrollFrame(y: y, at: timestamp))
            y += 25
        }
        // Two weak frames that stall, then firm contact well ahead.
        for strength in [20, 18] {
            timestamp += Self.frameInterval
            y += 2
            let events = engine.handle(
                frame: .init(x: 1000, y: y, z: strength, touched: true, scrollMode: true, timestamp: timestamp))
            XCTAssertEqual(touchDeltas(events).map(\.y).first ?? -1, 6.25, accuracy: 0.01)
        }
        timestamp += Self.frameInterval
        y += 80
        let resumed = engine.handle(
            frame: .init(x: 1000, y: y, z: 40, touched: true, scrollMode: true, timestamp: timestamp))
        XCTAssertTrue(touchDeltas(resumed).isEmpty, "resuming emits no catch-up jump")
        timestamp += Self.frameInterval
        y += 25
        let following = engine.handle(
            frame: .init(x: 1000, y: y, z: 40, touched: true, scrollMode: true, timestamp: timestamp))
        XCTAssertEqual(touchDeltas(following).map(\.y).first ?? -1, 6.25, accuracy: 0.01)
    }

    /// A fade that outlasts the carry cap is a light touch, not a lift: once
    /// the cap expires the finger is followed as reported for as long as it
    /// stays light — the carry is not re-decided from the same firm samples
    /// and restarted — and a slow light slide lifts without a coast.
    func testALightSlidePastTheCarryCapIsFollowedNotCarriedAgain() {
        let engine = makeEngine(momentum: .init(liftStrengthFloor: 0.6))
        var y = 500
        var timestamp: TimeInterval = 0
        for step in 0..<12 {
            timestamp = Double(step) * Self.frameInterval
            _ = engine.handle(frame: scrollFrame(y: y, at: timestamp))
            y += 25
        }
        // 300 ms of light contact creeping 2 counts per frame.
        var fadeDeltas: [Double] = []
        for _ in 0..<30 {
            timestamp += Self.frameInterval
            y += 2
            let events = engine.handle(
                frame: .init(x: 1000, y: y, z: 20, touched: true, scrollMode: true, timestamp: timestamp))
            fadeDeltas += touchDeltas(events).map(\.y)
        }
        XCTAssertEqual(fadeDeltas.first ?? -1, 6.25, accuracy: 0.01, "the fade starts as a carried flick")
        for delta in fadeDeltas.suffix(10) {
            XCTAssertEqual(delta, 0.5, accuracy: 1e-9, "past the cap the creep is followed: 2 counts × 0.25")
        }

        timestamp += Self.frameInterval
        _ = engine.handle(frame: releaseFrame(at: timestamp, scrollMode: true))
        XCTAssertFalse(engine.wantsMomentumTicks, "a slow light slide does not coast")
        XCTAssertEqual(engine.lastGestureSummary?.liftFramesCarried, 0)
    }

    /// One frame of `strength` on a test engine, `step` counts past the last.
    private func lightFrame(
        _ engine: TouchScrollEngine, y: inout Int, step: Int, strength: Int, at timestamp: TimeInterval
    ) -> [TouchScrollEngine.Event] {
        y += step
        return engine.handle(
            frame: .init(x: 1000, y: y, z: strength, touched: true, scrollMode: true, timestamp: timestamp))
    }

    /// A first weak frame that is not a flick is that same frame followed
    /// exactly as a firm one would be — its delta, and its sample in the
    /// lift-off fit — so the gesture matches one with the floor off.
    func testAWeakFrameThatIsNotAFlickIsFollowedLikeAFirmOne() {
        func gesture(floor: Double) -> (events: [TouchScrollEngine.Event], summary: RawTouchGestureSummary?) {
            let engine = makeEngine(momentum: .init(liftStrengthFloor: floor))
            var events: [TouchScrollEngine.Event] = []
            var y = 500
            var timestamp: TimeInterval = 0
            // 2 counts per frame: 50 pt/s, too slow to coast.
            for step in 0..<12 {
                timestamp = Double(step) * Self.frameInterval
                events += engine.handle(frame: scrollFrame(y: y, at: timestamp))
                y += 2
            }
            // The weak frame jumps 30 counts: only its own sample makes the
            // lift-off fit fast.
            timestamp += Self.frameInterval
            events += lightFrame(engine, y: &y, step: 30, strength: 4, at: timestamp)
            timestamp += Self.frameInterval
            events += engine.handle(frame: releaseFrame(at: timestamp, scrollMode: true))
            events += drainMomentum(on: engine, from: timestamp)
            return (events, engine.lastGestureSummary)
        }
        let floorOn = gesture(floor: 0.6)
        let floorOff = gesture(floor: 0)
        XCTAssertEqual(floorOn.events, floorOff.events)
        XCTAssertEqual(floorOn.summary?.liftOffSpeed, floorOff.summary?.liftOffSpeed)
        XCTAssertEqual(floorOn.summary?.liftFramesCarried, 0)
        XCTAssertGreaterThan(floorOn.summary?.liftOffSpeed ?? 0, 100, "the weak frame's sample is in the fit")
    }

    /// A touch whose fade was followed stays followed: firm contact again
    /// does not re-judge it, so a later fast fade is followed as reported.
    func testAFollowedFadeIsNotJudgedAgainOnFirmContact() {
        let engine = makeEngine(momentum: .init(liftStrengthFloor: 0.6))
        var y = 500
        var timestamp: TimeInterval = 0
        // Braking hard into a weak frame: a landing, followed.
        for (index, step) in [40, 36, 32, 28, 24, 20, 16, 12, 8, 6, 4, 2].enumerated() {
            timestamp = Double(index) * Self.frameInterval
            _ = engine.handle(frame: scrollFrame(y: y, at: timestamp))
            y += step
        }
        timestamp += Self.frameInterval
        _ = lightFrame(engine, y: &y, step: 1, strength: 4, at: timestamp)
        // Firm again and fast, then a stalling fade.
        for _ in 0..<12 {
            timestamp += Self.frameInterval
            let events = lightFrame(engine, y: &y, step: 25, strength: 40, at: timestamp)
            XCTAssertEqual(touchDeltas(events).map(\.y), [6.25])
        }
        var fadeDeltas: [Double] = []
        for strength in [22, 14, 8, 4] {
            timestamp += Self.frameInterval
            fadeDeltas += touchDeltas(lightFrame(engine, y: &y, step: 2, strength: strength, at: timestamp)).map(\.y)
        }
        XCTAssertEqual(fadeDeltas, [0.5, 0.5, 0.5, 0.5], "followed as reported, not carried")
        timestamp += Self.frameInterval
        _ = engine.handle(frame: releaseFrame(at: timestamp, scrollMode: true))
        XCTAssertEqual(engine.lastGestureSummary?.liftFramesCarried, 0)
    }

    /// The frame on which a carry outlasts its cap emits nothing and
    /// becomes the anchor; the frames after it are followed.
    func testTheFrameThatEndsACarryAtItsCapEmitsNothing() {
        let engine = makeEngine(momentum: .init(liftStrengthFloor: 0.6))
        var y = 500
        var timestamp: TimeInterval = 0
        for step in 0..<12 {
            timestamp = Double(step) * Self.frameInterval
            _ = engine.handle(frame: scrollFrame(y: y, at: timestamp))
            y += 25
        }
        var perFrame: [[Double]] = []
        var times: [TimeInterval] = []
        for _ in 0..<20 {
            timestamp += Self.frameInterval
            times.append(timestamp)
            perFrame.append(touchDeltas(lightFrame(engine, y: &y, step: 2, strength: 20, at: timestamp)).map(\.y))
        }
        let ending = times.firstIndex { $0 - times[0] > 0.12 }!
        XCTAssertEqual(perFrame[ending], [], "the carry ends without a delta")
        for deltas in perFrame[..<ending] {
            XCTAssertEqual(deltas.count, 1)
            XCTAssertEqual(deltas.first ?? -1, 6.25, accuracy: 0.01)
        }
        for deltas in perFrame[(ending + 1)...] {
            XCTAssertEqual(deltas, [0.5], "2 counts × 0.25, followed")
        }
    }

    /// A carry that ends on firm contact leaves the touch unjudged: its next
    /// fade, if a flick, is carried again.
    func testAFadeAfterARecoveredDipIsJudgedAfresh() {
        let engine = makeEngine(momentum: .init(liftStrengthFloor: 0.6))
        var y = 500
        var timestamp: TimeInterval = 0
        for step in 0..<12 {
            timestamp = Double(step) * Self.frameInterval
            _ = engine.handle(frame: scrollFrame(y: y, at: timestamp))
            y += 25
        }
        timestamp += Self.frameInterval
        _ = lightFrame(engine, y: &y, step: 25, strength: 20, at: timestamp)
        // Firm again for longer than the fit's window.
        for _ in 0..<12 {
            timestamp += Self.frameInterval
            _ = lightFrame(engine, y: &y, step: 25, strength: 40, at: timestamp)
        }
        var fadeDeltas: [Double] = []
        for strength in [22, 14] {
            timestamp += Self.frameInterval
            fadeDeltas += touchDeltas(lightFrame(engine, y: &y, step: 2, strength: strength, at: timestamp)).map(\.y)
        }
        XCTAssertEqual(fadeDeltas.count, 2)
        for delta in fadeDeltas {
            XCTAssertEqual(delta, 6.25, accuracy: 0.01, "carried at the firm-contact speed")
        }
        timestamp += Self.frameInterval
        _ = engine.handle(frame: releaseFrame(at: timestamp, scrollMode: true))
        XCTAssertEqual(engine.lastGestureSummary?.liftFramesCarried, 2)
    }

    func testAcceleratingFlickSeedsNearReleaseVelocity() {
        let engine = makeEngine()
        var events: [TouchScrollEngine.Event] = []
        var timestamp: TimeInterval = 0
        var y = 500

        // A flick that is still speeding up at release: per-frame step grows
        // 5, 10, … 50 counts, so velocity rises from 500 to 5000 counts/s.
        events += engine.handle(frame: scrollFrame(y: y, at: 0))
        let firstY = y
        for step in 1...10 {
            timestamp = Double(step) * Self.frameInterval
            y += step * 5
            events += engine.handle(frame: scrollFrame(y: y, at: timestamp))
        }
        let liftTime = timestamp + Self.frameInterval
        events += engine.handle(frame: releaseFrame(at: liftTime, scrollMode: true))
        XCTAssertTrue(engine.wantsMomentumTicks)

        guard case .momentumBegan(_, let firstDelta)? = drainMomentum(on: engine, from: liftTime).first else {
            XCTFail("Expected momentum")
            return
        }
        let fittedSeed = seed(fromFirstDelta: firstDelta, engine: engine)

        // Differencing the window's endpoints would seed at the
        // window-average velocity; the weighted fit must land meaningfully
        // above that, without overshooting the true release-instant speed.
        let windowAverageSeed = Double(y - firstY) / timestamp * 0.25  // 687.5
        let releaseInstantSeed = 5000.0 * 0.25  // 1250
        XCTAssertGreaterThan(fittedSeed, windowAverageSeed * 1.15)
        XCTAssertLessThanOrEqual(fittedSeed, releaseInstantSeed)
    }

    func testMomentumTailStopsAtTheFloorWithoutCrawling() {
        let engine = makeEngine()
        let (_, liftTime) = performFlick(on: engine)  // 625 pt/s seed
        let momentum = drainMomentum(on: engine, from: liftTime)
        XCTAssertEqual(momentum.last, .momentumEnded)

        // Every emitted delta is at or above the floor's per-tick motion —
        // the tail never degenerates into an invisible crawl that only keeps
        // consumers in their momentum state.
        let floorPerTick = 40.0 * Self.tickInterval
        for case .momentumChanged(_, let delta) in momentum {
            XCTAssertGreaterThanOrEqual(abs(delta), floorPerTick * 0.99)
        }

        // Duration follows from the decay: tau * ln(seed / floor).
        let expectedTicks = 0.83 * log(625.0 / 40.0) / Self.tickInterval
        let ticks = Double(momentum.count - 1)
        XCTAssertEqual(ticks, expectedTicks, accuracy: 3)
    }

    // MARK: - Frames that must be ignored

    func testPointerTimeFramesAreIgnored() {
        let engine = makeEngine()
        var events: [TouchScrollEngine.Event] = []

        for step in 0..<5 {
            events += engine.handle(
                frame: pointerFrame(y: 500 + step * 25, at: Double(step) * Self.frameInterval)
            )
        }
        events += engine.handle(frame: releaseFrame(at: 0.06, scrollMode: false))

        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(engine.wantsMomentumTicks)
    }

    func testPointerTimeFramesDoNotCatchMomentum() {
        let engine = makeEngine()
        let (_, liftTime) = performFlick(on: engine)
        _ = engine.momentumTick(at: liftTime + Self.tickInterval)
        XCTAssertTrue(engine.wantsMomentumTicks)

        // Firmware owns the pointer during these frames; scrolling ignores them.
        let events = engine.handle(frame: pointerFrame(y: 700, at: liftTime + 0.05))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(engine.wantsMomentumTicks)
    }

    func testLeftPadFramesDriveTheGestureLikePadZero() {
        // Pad arbitration lives in RawTouchDeviceManager; the engine scrolls
        // for whichever pad's frames it is handed. Pad 1 (the left pad)
        // behaves identically to pad 0.
        let engine = makeEngine()
        XCTAssertEqual(engine.handle(frame: scrollFrame(y: 500, at: 0, pad: 1)), [.touchBegan])
        XCTAssertEqual(
            engine.handle(frame: scrollFrame(y: 525, at: Self.frameInterval, pad: 1)),
            [.touchChanged(deltaX: 0, deltaY: 25 * 0.25)]
        )
    }

    func testScrollModeDroppedMidTouchEndsGestureWithoutMomentum() {
        let engine = makeEngine()
        var events: [TouchScrollEngine.Event] = []
        var y = 500
        for step in 0..<8 {
            events += engine.handle(frame: scrollFrame(y: y, at: Double(step) * Self.frameInterval))
            y += 25
        }
        XCTAssertEqual(events.first, .touchBegan)

        // The user releases the scroll layer while still touching.
        let endEvents = engine.handle(frame: pointerFrame(y: y, at: 0.09))
        XCTAssertEqual(endEvents, [.touchEnded])
        XCTAssertFalse(engine.wantsMomentumTicks)
    }

    // MARK: - Robustness

    func testImplausiblePositionJumpDoesNotEmitHugeDelta() {
        let engine = makeEngine()
        _ = engine.handle(frame: scrollFrame(y: 100, at: 0))
        let events = engine.handle(frame: scrollFrame(y: 1500, at: Self.frameInterval))
        XCTAssertEqual(events, [.touchChanged(deltaX: 0, deltaY: 0)])
    }

    /// A glitch restarts the touch's velocity history: a lift within the
    /// fit window of one must not seed a coast from the jump.
    func testALiftRightAfterAGlitchDoesNotCoastFromTheJump() {
        let engine = makeEngine()
        var y = 500
        var timestamp: TimeInterval = 0
        for step in 0..<10 {
            timestamp = Double(step) * Self.frameInterval
            _ = engine.handle(frame: scrollFrame(y: y, at: timestamp))
            y += 2
        }
        timestamp += Self.frameInterval
        y += 1500
        XCTAssertEqual(engine.handle(frame: scrollFrame(y: y, at: timestamp)), [.touchChanged(deltaX: 0, deltaY: 0)])
        for _ in 0..<2 {
            timestamp += Self.frameInterval
            y += 2
            XCTAssertEqual(
                engine.handle(frame: scrollFrame(y: y, at: timestamp)), [.touchChanged(deltaX: 0, deltaY: 0.5)])
        }

        timestamp += Self.frameInterval
        XCTAssertEqual(engine.handle(frame: releaseFrame(at: timestamp, scrollMode: true)), [.touchEnded])
        XCTAssertFalse(engine.wantsMomentumTicks, "the slow drag after the jump does not coast")
    }

    func testInterruptDuringTouchEmitsTouchEnded() {
        let engine = makeEngine()
        _ = engine.handle(frame: scrollFrame(y: 500, at: 0))
        XCTAssertEqual(engine.interrupt(), [.touchEnded])
        XCTAssertFalse(engine.wantsMomentumTicks)
    }

    func testInterruptDuringMomentumEmitsMomentumEnded() {
        let engine = makeEngine()
        let (_, liftTime) = performFlick(on: engine)
        _ = engine.momentumTick(at: liftTime + Self.tickInterval)
        XCTAssertEqual(engine.interrupt(), [.momentumEnded])
        XCTAssertFalse(engine.wantsMomentumTicks)
    }

    // MARK: - Momentum tuning

    func testMomentumStartThresholdHoldsBackMomentum() {
        // The default flick coasts...
        let defaultEngine = makeEngine()
        _ = performFlick(on: defaultEngine)
        XCTAssertTrue(defaultEngine.wantsMomentumTicks)

        // ...but not when the configured threshold exceeds its lift-off speed.
        let reluctant = makeEngine(momentum: .init(startThreshold: 100_000))
        _ = performFlick(on: reluctant)
        XCTAssertFalse(reluctant.wantsMomentumTicks)
    }

    func testMomentumMaxSpeedCapsSeedVelocity() {
        let capped = makeEngine(momentum: .init(maxSpeed: 200))
        let (_, liftTime) = performFlick(on: capped)
        guard case .momentumBegan(_, let delta)? = drainMomentum(on: capped, from: liftTime).first else {
            XCTFail("Expected momentum to begin")
            return
        }
        // The first tick's delta cannot exceed maxSpeed * dt.
        XCTAssertLessThanOrEqual(delta, 200 * Self.tickInterval + 1e-9)
    }

    func testMomentumDecayTimeConstantControlsCoastDuration() {
        let short = makeEngine(momentum: .init(decayTimeConstant: 0.1))
        let long = makeEngine(momentum: .init(decayTimeConstant: 1.5))

        let (_, shortLift) = performFlick(on: short)
        let (_, longLift) = performFlick(on: long)

        let shortTicks = drainMomentum(on: short, from: shortLift).count
        let longTicks = drainMomentum(on: long, from: longLift).count

        XCTAssertGreaterThan(longTicks, shortTicks * 2)
    }
}

final class RawTouchFrameTests: XCTestCase {
    func testParsesWellFormedV3Payload() {
        // pad 0, contact 1, x = 0x0403 (1027), y = 0x0201 (513), z = 42,
        // touched + scroll mode (lease bit clear), seq 0x2B,
        // timestamp 0x8001 ticks.
        let frame = RawTouchFrame(
            reportBytes: [0x00, 0x01, 0x03, 0x04, 0x01, 0x02, 0x2A, 0x03, 0x2B, 0x01, 0x80],
            timestamp: 1.5
        )
        XCTAssertEqual(frame?.leaseHeld, false)
        XCTAssertEqual(frame?.padID, 0)
        XCTAssertEqual(frame?.contactID, 1)
        XCTAssertEqual(frame?.x, 1027)
        XCTAssertEqual(frame?.y, 513)
        XCTAssertEqual(frame?.z, 42)
        XCTAssertEqual(frame?.touched, true)
        XCTAssertEqual(frame?.scrollMode, true)
        XCTAssertEqual(frame?.seq, 0x2B)
        XCTAssertEqual(frame?.deviceTimestampTicks, 0x8001)
        XCTAssertEqual(frame?.timestamp, 1.5)
    }

    func testParsesV3FixtureRoundTrip() {
        let frame = RawTouchFrame(
            reportBytes: v3FrameBytes(x: 1234, y: 987, seq: 250, timestampTicks: 0xFFFE),
            timestamp: 0
        )
        XCTAssertEqual(frame?.x, 1234)
        XCTAssertEqual(frame?.y, 987)
        XCTAssertEqual(frame?.seq, 250)
        XCTAssertEqual(frame?.deviceTimestampTicks, 0xFFFE)
    }

    func testParsesFlagCombinations() {
        let release = RawTouchFrame(
            reportBytes: v3FrameBytes(z: 0, flags: 0x00),
            timestamp: 0
        )
        XCTAssertEqual(release?.touched, false)
        XCTAssertEqual(release?.scrollMode, false)

        let pointerTime = RawTouchFrame(
            reportBytes: v3FrameBytes(z: 10, flags: 0x01),
            timestamp: 0
        )
        XCTAssertEqual(pointerTime?.touched, true)
        XCTAssertEqual(pointerTime?.scrollMode, false)

        // Bit 2 is the lease_held flag: set means the firmware has suppressed
        // its own wheel fallback for this endpoint, so the host may
        // synthesize.
        let leased = RawTouchFrame(reportBytes: v3FrameBytes(flags: 0b111), timestamp: 0)
        XCTAssertEqual(leased?.touched, true)
        XCTAssertEqual(leased?.scrollMode, true)
        XCTAssertEqual(leased?.leaseHeld, true)

        let unleased = RawTouchFrame(reportBytes: v3FrameBytes(flags: 0b011), timestamp: 0)
        XCTAssertEqual(unleased?.scrollMode, true)
        XCTAssertEqual(unleased?.leaseHeld, false)

        // Reserved flag bits must not confuse parsing.
        let reservedBits = RawTouchFrame(
            reportBytes: v3FrameBytes(pad: 1, z: 10, flags: 0xFF),
            timestamp: 0
        )
        XCTAssertEqual(reservedBits?.padID, 1)
        XCTAssertEqual(reservedBits?.touched, true)
        XCTAssertEqual(reservedBits?.scrollMode, true)
        XCTAssertEqual(reservedBits?.leaseHeld, true)

        // A scroll-mode release: flags live at byte 7.
        let scrollRelease = RawTouchFrame(
            reportBytes: v3FrameBytes(z: 0, flags: 0b10),
            timestamp: 0
        )
        XCTAssertEqual(scrollRelease?.touched, false)
        XCTAssertEqual(scrollRelease?.scrollMode, true)
    }

    func testRejectsShortReports() {
        XCTAssertNil(RawTouchFrame(reportBytes: [], timestamp: 0))
        XCTAssertNil(RawTouchFrame(reportBytes: [0x00, 0x01], timestamp: 0))
        XCTAssertNil(RawTouchFrame(reportBytes: [0, 0, 0, 0, 0, 0], timestamp: 0))
    }

    /// A 7-byte frame is malformed, never reinterpreted in some shorter
    /// layout.
    func testRejectsSevenByteFrames() {
        XCTAssertNil(
            RawTouchFrame(
                reportBytes: [0x00, 0x03, 0x04, 0x01, 0x02, 0x2A, 0x03],
                timestamp: 0
            ))
    }

    func testIgnoresTrailingPadding() {
        let frame = RawTouchFrame(
            reportBytes: v3FrameBytes(x: 1027, seq: 7) + [0x00, 0x00],
            timestamp: 0
        )
        XCTAssertEqual(frame?.x, 1027)
        XCTAssertEqual(frame?.seq, 7)
    }
}

final class RawTouchDeviceClockTests: XCTestCase {
    func testAnchorsToArrivalTimeAndAdvancesByDeviceDeltas() {
        var clock = RawTouchDeviceClock()

        // Anchor: first frame maps to its arrival time.
        XCTAssertEqual(clock.reconstruct(ticks: 1000, arrival: 100.0), 100.0)

        // 100 ticks = 10 ms of device time, regardless of arrival jitter.
        XCTAssertEqual(clock.reconstruct(ticks: 1100, arrival: 100.0401), 100.010, accuracy: 1e-9)
        // A batched frame arriving in the same callback burst still advances
        // by its true device-side sampling interval.
        XCTAssertEqual(clock.reconstruct(ticks: 1200, arrival: 100.0402), 100.020, accuracy: 1e-9)
    }

    func testHandlesTimestampWrap() {
        var clock = RawTouchDeviceClock()

        _ = clock.reconstruct(ticks: 0xFFFF, arrival: 50.0)
        // (0x0063 - 0xFFFF) mod 0x10000 = 100 ticks = 10 ms.
        XCTAssertEqual(clock.reconstruct(ticks: 0x0063, arrival: 50.012), 50.010, accuracy: 1e-9)
    }

    func testLargeDeviceDeltaReAnchorsToArrival() {
        var clock = RawTouchDeviceClock()

        _ = clock.reconstruct(ticks: 0, arrival: 10.0)
        // 30000 ticks = 3 s > the ~2 s discontinuity threshold: distrust the
        // wrapped delta and re-anchor to arrival.
        XCTAssertEqual(clock.reconstruct(ticks: 30_000, arrival: 13.1), 13.1)
    }

    func testLongArrivalSilenceReAnchorsDespiteSmallDeviceDelta() {
        var clock = RawTouchDeviceClock()

        _ = clock.reconstruct(ticks: 500, arrival: 10.0)
        // The device counter wraps every 6.5536 s, so after ~7 s of silence
        // a small wrapped delta (here 20 ms) is a lie; the arrival gap
        // exposes it.
        XCTAssertEqual(clock.reconstruct(ticks: 700, arrival: 17.0), 17.0)
    }

    func testReAnchoringNeverMovesBackwards() {
        var clock = RawTouchDeviceClock()

        _ = clock.reconstruct(ticks: 0, arrival: 20.0)
        let advanced = clock.reconstruct(ticks: 10_000, arrival: 21.05)  // +1 s device time
        XCTAssertEqual(advanced, 21.0, accuracy: 1e-9)

        // A discontinuity whose arrival time sits behind the reconstructed
        // timeline clamps to the timeline instead of stepping backwards.
        XCTAssertGreaterThanOrEqual(clock.reconstruct(ticks: 40_000, arrival: 20.9), advanced)
    }

    // MARK: - Anchor tightening

    func testTighteningSnapsTheTimelineToAFasterDelivery() {
        var clock = RawTouchDeviceClock()

        // The anchor frame waited a 15 ms BLE interval; the next two were
        // sampled 10 and 20 ms later but arrive in the same burst, and the
        // third right after its own sample.
        XCTAssertEqual(clock.reconstruct(ticks: 0, arrival: 10.015), 10.015)
        XCTAssertEqual(clock.reconstruct(ticks: 100, arrival: 10.015), 10.015, "10.025 would post-date its arrival")
        XCTAssertEqual(clock.reconstruct(ticks: 200, arrival: 10.021), 10.021, accuracy: 1e-9)
        // From here the anchor lag is 1 ms and exact deltas resume.
        XCTAssertEqual(clock.reconstruct(ticks: 300, arrival: 10.045), 10.031, accuracy: 1e-9)
        XCTAssertEqual(clock.reconstruct(ticks: 400, arrival: 10.045), 10.041, accuracy: 1e-9)
    }

    func testTighteningNeverStepsBackwards() {
        var tight = RawTouchDeviceClock()
        var last = tight.reconstruct(ticks: 0, arrival: 20.015)
        var ticks: UInt16 = 0
        var arrival = 20.015
        for step in 1...50 {
            ticks &+= 100
            // Arrivals: batched in twos, each batch 15 ms after the last.
            if step % 2 == 0 {
                arrival += 0.015
            }
            let next = tight.reconstruct(ticks: ticks, arrival: arrival)
            XCTAssertGreaterThanOrEqual(next, last)
            XCTAssertLessThanOrEqual(next, arrival, "a sample never post-dates its arrival")
            last = next
        }
    }
}
