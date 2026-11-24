// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchTestSupport
import XCTest

@testable import RawTouchCore

/// The per-source latency estimator: seeded until it has seen enough,
/// measuring lateness against each epoch's own baseline, forgetting with
/// the window, and settling where the recorded delivery traces say.
final class RawTouchLatencyEstimatorTests: XCTestCase {
    private let samplePeriod: TimeInterval = 0.010

    /// Feeds `count` frames sampled every 10 ms from `start`, each arriving
    /// `lateness(index)` after its sample time (plus `offset`, a constant
    /// transport delay).
    private func feed(
        _ estimator: inout RawTouchLatencyEstimator,
        from start: TimeInterval = 0,
        count: Int,
        offset: TimeInterval = 0.001,
        lateness: (Int) -> TimeInterval = { _ in 0 }
    ) {
        for index in 0..<count {
            let t = start + Double(index) * samplePeriod
            estimator.observe(ticks: deviceTicks(at: t), arrival: t + offset + lateness(index))
        }
    }

    /// Frames held until the next 15 ms connection event, as Bluetooth
    /// delivers them: on the 10 ms sample grid the lateness cycles through
    /// 15, 5, 10 ms — 10, 0, 5 ms above the fastest.
    private func batched(_ index: Int) -> TimeInterval {
        let t = Double(index) * samplePeriod
        let event = ((t + 0.0005) / 0.015).rounded(.up) * 0.015
        return event - t
    }

    // MARK: - Seed and window

    func testTheSeedStandsUntilEnoughFramesHaveBeenSeen() {
        var estimator = RawTouchLatencyEstimator()
        XCTAssertNil(estimator.measuredLatency)
        XCTAssertEqual(estimator.latency, RawTouchLatencyEstimator.seed)

        feed(&estimator, count: RawTouchLatencyEstimator.minimumSamples - 1)
        XCTAssertNil(estimator.measuredLatency)
        XCTAssertEqual(estimator.latency, RawTouchLatencyEstimator.seed)

        feed(&estimator, from: 1, count: 1)
        XCTAssertNotNil(estimator.measuredLatency)
        XCTAssertEqual(estimator.sampleCount, RawTouchLatencyEstimator.minimumSamples)
    }

    func testCleanDeliveryMeasuresOnlyTheHeadroom() {
        var estimator = RawTouchLatencyEstimator()
        feed(&estimator, count: 100)
        XCTAssertEqual(estimator.measuredLatency!, RawTouchLatencyEstimator.headroom, accuracy: 1e-9)
    }

    func testAConstantTransportDelayIsInvisible() {
        var fast = RawTouchLatencyEstimator()
        var slow = RawTouchLatencyEstimator()
        feed(&fast, count: 100, offset: 0.001)
        feed(&slow, count: 100, offset: 0.5)
        XCTAssertEqual(fast.measuredLatency!, slow.measuredLatency!, accuracy: 1e-9)
    }

    func testBatchedDeliveryMeasuresTheBatch() {
        var estimator = RawTouchLatencyEstimator()
        feed(&estimator, count: 150, lateness: batched)
        // A third of the frames are a full 10 ms behind the fastest: p90
        // is that, plus the headroom.
        XCTAssertEqual(estimator.measuredLatency!, 0.010 + RawTouchLatencyEstimator.headroom, accuracy: 1e-6)
        XCTAssertEqual(estimator.latency, estimator.measuredLatency)
    }

    func testTheWindowForgetsOldDelivery() {
        var estimator = RawTouchLatencyEstimator()
        feed(&estimator, count: RawTouchLatencyEstimator.windowSize, lateness: batched)
        XCTAssertGreaterThan(estimator.measuredLatency!, 0.010)

        // A whole window of clean frames later, the batches are gone.
        feed(&estimator, from: 3, count: RawTouchLatencyEstimator.windowSize)
        XCTAssertEqual(estimator.sampleCount, RawTouchLatencyEstimator.windowSize)
        XCTAssertEqual(estimator.measuredLatency!, RawTouchLatencyEstimator.headroom, accuracy: 1e-9)
    }

    func testTheEstimateIsClampedToTheLatencyRange() {
        var estimator = RawTouchLatencyEstimator()
        feed(&estimator, count: 100) { $0 % 2 == 0 ? 0 : 0.040 }
        XCTAssertEqual(estimator.measuredLatency!, RawTouchLatencyEstimator.range.upperBound)
    }

    // MARK: - Epochs

    /// A gap re-anchors the device clock, and the offsets after it are not
    /// comparable with those before: measured against the old baseline, a
    /// clean epoch with a different constant delay would read as lateness.
    func testAGapStartsANewBaseline() {
        var estimator = RawTouchLatencyEstimator()
        feed(&estimator, count: 50, offset: 0.001)
        feed(&estimator, from: 5, count: 50, offset: 0.101)
        XCTAssertEqual(estimator.measuredLatency!, RawTouchLatencyEstimator.headroom, accuracy: 1e-9)

        // And the other way round: a *faster* epoch must not make the
        // earlier one look late either.
        feed(&estimator, from: 10, count: 50, offset: 0.0002)
        XCTAssertEqual(estimator.measuredLatency!, RawTouchLatencyEstimator.headroom, accuracy: 1e-9)
    }

    /// Taps and brushes are epochs too short to have seen the path's
    /// fastest frame: every frame of one reads as on time. They must not
    /// drag the percentile down.
    func testShortEpochsAreLeftOutOfTheEstimate() {
        var estimator = RawTouchLatencyEstimator()
        // Sixty 3-frame taps, 3 s apart: 180 frames, all "on time".
        for tap in 0..<60 {
            feed(&estimator, from: Double(tap) * 3, count: 3)
        }
        XCTAssertEqual(estimator.sampleCount, 180)
        XCTAssertNil(estimator.measuredLatency, "nothing long enough to measure")

        // One 20-frame drag, one fast frame and nineteen 8 ms late.
        feed(&estimator, from: 200, count: 20) { $0 == 0 ? 0 : 0.008 }
        XCTAssertEqual(estimator.measuredLatency!, 0.008 + RawTouchLatencyEstimator.headroom, accuracy: 1e-9)
    }

    /// Lateness is measured against the minimum the epoch *eventually*
    /// finds, so early frames delivered before the fast one are not left
    /// reading as 0 while later ones read late.
    func testEarlyFramesAreMeasuredAgainstTheMinimumFoundLater() {
        var estimator = RawTouchLatencyEstimator()
        // 30 frames all 5 ms late, then one fast frame, then 30 more 5 ms
        // late: 60 of 61 frames are 5 ms late.
        feed(&estimator, count: 30) { _ in 0.005 }
        feed(&estimator, from: 0.3, count: 1)
        feed(&estimator, from: 0.31, count: 30) { _ in 0.005 }
        XCTAssertEqual(estimator.measuredLatency!, 0.005 + RawTouchLatencyEstimator.headroom, accuracy: 1e-9)
    }

    /// A long uninterrupted touch closes its epoch every `epochSpan` so
    /// crystal drift never accumulates into lateness: a device clock
    /// running 100 ppm slow over 30 s would otherwise read 3 ms late.
    func testALongTouchDoesNotAccumulateClockDrift() {
        var estimator = RawTouchLatencyEstimator()
        let drift = 100e-6
        for index in 0..<3000 {
            let t = Double(index) * samplePeriod
            // The device's ticks run slow: its timestamp says less time
            // has passed than the host saw.
            estimator.observe(ticks: deviceTicks(at: t * (1 - drift)), arrival: t + 0.001)
        }
        XCTAssertLessThan(estimator.measuredLatency!, RawTouchLatencyEstimator.headroom + 0.0015)
    }

    // MARK: - Recorded delivery

    private var capturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("bench/captures")
    }

    /// Replays a trace's runs into an estimator, each run its own epoch
    /// (3 s apart), returning the estimate after each run's first
    /// `minimumSamples` frames alongside the final one.
    private func replay(_ trace: CaptureTrace) -> (final: TimeInterval, early: [TimeInterval]) {
        var estimator = RawTouchLatencyEstimator()
        var early: [TimeInterval] = []
        var base: TimeInterval = 100
        // File order rather than longest-first: the runs happened in time.
        for run in trace.runs.sorted(by: { $0.frames.count < $1.frames.count }) {
            for (index, frame) in run.frames.enumerated() {
                let t = base + frame.deviceTime
                estimator.observe(ticks: deviceTicks(at: frame.deviceTime), arrival: t + frame.lateness)
                if index + 1 == RawTouchLatencyEstimator.minimumSamples, let measured = estimator.measuredLatency {
                    early.append(measured)
                }
            }
            base += run.span + 3
        }
        return (estimator.measuredLatency ?? .nan, early)
    }

    /// The recorded paths (bench/captures/README.md): the estimator has to
    /// settle at each trace's own p90 lateness, and while its window is
    /// short it may read low, never high.
    func testSettlesWhereTheRecordedTracesSay() throws {
        let expectations: [(file: String, pad: Int, low: Double, high: Double)] = [
            ("usb-host_wired-split.csv", 0, 0.5, 2.0),
            ("usb-host_wired-split.csv", 1, 3.5, 6.5),
            ("usb-host_ble-split.csv", 1, 8.0, 13.0),
            ("ble-host_wired-split.csv", 0, 12.0, 16.0),
            ("ble-host_wired-split.csv", 1, 13.0, 18.0),
            ("ble-host_ble-split.csv", 0, 12.0, 16.0),
            ("ble-host_ble-split.csv", 1, 12.5, 17.0),
        ]
        for expectation in expectations {
            let trace = try CaptureTrace.load(
                path: capturesDirectory.appendingPathComponent(expectation.file).path,
                pad: expectation.pad
            )
            let (final, early) = replay(trace)
            let p90 = trace.latenessPercentile(0.9) + RawTouchLatencyEstimator.headroom
            let label = "\(expectation.file) pad \(expectation.pad)"
            XCTAssertEqual(
                final * 1000, p90 * 1000, accuracy: 2,
                "\(label): settled at \(final * 1000) ms, trace p90 \(p90 * 1000) ms")
            XCTAssertGreaterThanOrEqual(final * 1000, expectation.low, label)
            XCTAssertLessThanOrEqual(final * 1000, expectation.high, label)
            for reading in early {
                XCTAssertLessThanOrEqual(reading, p90 + 0.0015, "\(label): an early reading came out high")
            }
        }
    }
}
