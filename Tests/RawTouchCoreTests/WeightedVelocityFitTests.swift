// MIT License
// Copyright (c) 2026 RawTouch contributors

import XCTest

@testable import RawTouchCore

final class WeightedVelocityFitTests: XCTestCase {
    private func samples(_ positions: [Double], interval: TimeInterval = 0.01) -> [WeightedVelocityFit.Sample] {
        positions.enumerated().map { (position: $0.element, timestamp: Double($0.offset) * interval) }
    }

    func testConstantVelocityIsRecoveredExactlyWhateverTheWeights() throws {
        // 25 units per 10 ms = 2500 units/s; recency weighting must not bias
        // a steady series.
        let series = samples((0..<12).map { Double($0) * 25 })

        XCTAssertEqual(try XCTUnwrap(WeightedVelocityFit.slope(through: series)), 2500, accuracy: 1e-9)
        XCTAssertEqual(
            try XCTUnwrap(WeightedVelocityFit.slope(through: series, weightTimeConstant: 1)),
            2500,
            accuracy: 1e-9
        )
    }

    func testTooFewSamplesOrTooShortASpanYieldsNoSlope() {
        XCTAssertNil(WeightedVelocityFit.slope(through: []))
        XCTAssertNil(WeightedVelocityFit.slope(through: [(position: 1, timestamp: 0)]))
        // Two samples 1 ms apart: under the 5 ms minimum span.
        XCTAssertNil(
            WeightedVelocityFit.slope(through: [(position: 0, timestamp: 0), (position: 10, timestamp: 0.001)]))
        XCTAssertNotNil(
            WeightedVelocityFit.slope(
                through: [(position: 0, timestamp: 0), (position: 10, timestamp: 0.001)],
                minimumSpan: 0
            ))
    }

    func testAllWeightOnOneInstantIsDegenerate() {
        // An ancient sample carries no effective weight next to two at the
        // same instant: the variance collapses and no slope is reported.
        let series: [WeightedVelocityFit.Sample] = [
            (position: 0, timestamp: 0),
            (position: 5, timestamp: 10),
            (position: 9, timestamp: 10),
        ]
        XCTAssertNil(WeightedVelocityFit.slope(through: series, weightTimeConstant: 0.001))
    }

    func testRecencyWeightingFavoursTheNewestSamples() throws {
        // Velocity rising 500 → 5000 units/s over 100 ms: the weighted slope
        // must sit well above the whole-window average and at or below the
        // final instantaneous speed.
        var positions = [0.0]
        for step in 1...10 {
            positions.append(positions[step - 1] + Double(step) * 5)
        }
        let series = samples(positions)
        let windowAverage = (positions.last! - positions.first!) / 0.1

        let slope = try XCTUnwrap(WeightedVelocityFit.slope(through: series))
        XCTAssertGreaterThan(slope, windowAverage * 1.15)
        XCTAssertLessThanOrEqual(slope, 5000)

        // A very long time constant degenerates to the unweighted fit, which
        // for a linear ramp is the window average.
        let unweighted = try XCTUnwrap(WeightedVelocityFit.slope(through: series, weightTimeConstant: 1e6))
        XCTAssertEqual(unweighted, windowAverage, accuracy: 1)
    }

    func testAStationaryTailOutweighsAnEarlierDrag() throws {
        // Drag at 2500 units/s for 50 ms, then hold still: the stationary
        // tail dominates the weighting, so the slope collapses well below
        // the drag speed after 50 ms of rest and under a tenth of it after a
        // full 100 ms — what keeps a stop-then-lift from coasting.
        let shortRest = samples([0, 25, 50, 75, 100, 125, 125, 125, 125, 125, 125])
        XCTAssertLessThan(abs(try XCTUnwrap(WeightedVelocityFit.slope(through: shortRest))), 2500 * 0.3)

        let longRest = samples([0, 25, 50, 75, 100, 125] + Array(repeating: 125.0, count: 10))
        XCTAssertLessThan(abs(try XCTUnwrap(WeightedVelocityFit.slope(through: longRest))), 2500 * 0.1)
    }

    /// The quadratic on the data the engine's lift-off check gives it:
    /// seconds as the time unit, so its normal equations carry dt⁴-sized
    /// terms (1e-8 s⁴ per sample). A known motion — 2500 counts/s,
    /// braking at 20000 counts/s² — is recovered from 10 ms samples over
    /// the 100 ms window, and from the fewest samples it accepts (three
    /// over its 5 ms minimum span) at display rates too: the elimination's
    /// smallest pivot there is ~2e-11, clear of its 1e-12 floor.
    func testTheQuadraticRecoversAKnownMotionOnRealisticSpans() throws {
        let velocity = 2500.0
        let acceleration = -20000.0
        func motion(_ times: [TimeInterval]) -> [WeightedVelocityFit.Sample] {
            let newest = times.last!
            return times.map { t in
                let age: Double = t - newest
                let position: Double = 1000 + velocity * age + 0.5 * acceleration * age * age
                return (position: position, timestamp: t)
            }
        }
        func every(_ period: TimeInterval, count: Int, from start: TimeInterval = 0) -> [TimeInterval] {
            (0..<count).map { start + Double($0) * period }
        }
        let spans: [[TimeInterval]] = [
            every(0.01, count: 11),  // the pad's 100 Hz over the window
            every(1.0 / 120, count: 13),  // resampled at 120 Hz
            every(1.0 / 60, count: 7),  // and at 60 Hz
            every(0.0025, count: 3),  // three samples over the minimum span
            every(0.01, count: 3, from: 5),  // late in a long touch
        ]
        for times in spans {
            let fit = try XCTUnwrap(WeightedVelocityFit.quadratic(through: motion(times)), "\(times)")
            XCTAssertEqual(fit.velocity, velocity, accuracy: velocity * 1e-6, "\(times)")
            XCTAssertEqual(fit.acceleration, acceleration, accuracy: abs(acceleration) * 1e-4, "\(times)")
        }
    }
}
