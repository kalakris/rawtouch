// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchTestSupport
import XCTest

@testable import RawTouchCore

/// Adaptive display-sync latency in the pipeline: seeded for a source's
/// first gesture, measured from its frames for the next, held for the
/// whole of each gesture, and reported in the gesture summary along with
/// the frames the resampler had to hold.
final class TouchScrollPipelineAdaptiveLatencyTests: XCTestCase {
    private let frameInterval: TimeInterval = 0.01
    private let displayPeriod: TimeInterval = 1.0 / 120.0

    /// Measured latency unless a test fixes it.
    private func makeHarness(fixedLatency: TimeInterval? = nil) -> PipelineHarness {
        PipelineHarness(resampling: true, fixedLatency: fixedLatency)
    }

    /// A touched scroll frame sampled at `t` and arriving `late` after.
    private func frame(
        seq: Int,
        x: Int,
        sampledAt t: TimeInterval,
        late: TimeInterval,
        pad: UInt8 = 0,
        transport: RawTouchTransport = .usb
    ) -> RawTouchFrame {
        RawTouchFrame(
            padID: pad, x: x, y: 500, z: 40, touched: true, scrollMode: true, leaseHeld: true,
            seq: UInt8(truncatingIfNeeded: seq), deviceTimestampTicks: deviceTicks(at: t),
            transport: transport, timestamp: t + late
        )
    }

    private func release(
        seq: Int,
        sampledAt t: TimeInterval,
        late: TimeInterval,
        pad: UInt8 = 0,
        transport: RawTouchTransport = .usb
    ) -> RawTouchFrame {
        RawTouchFrame(
            padID: pad, touched: false, scrollMode: true, leaseHeld: true,
            seq: UInt8(truncatingIfNeeded: seq), deviceTimestampTicks: deviceTicks(at: t),
            transport: transport, timestamp: t + late
        )
    }

    /// Frames held until the next 15 ms connection event, as Bluetooth
    /// delivers them.
    private func batched(_ t: TimeInterval) -> TimeInterval {
        ((t + 0.0005) / 0.015).rounded(.up) * 0.015 - t + 0.0005
    }

    /// A slow drag (no coast at lift-off) of `count` frames from `start`,
    /// one display tick after every frame arrival, then the release.
    /// Returns the next seq.
    @discardableResult
    private func drag(
        _ harness: PipelineHarness,
        from start: TimeInterval,
        count: Int,
        seq: Int,
        lateness: (TimeInterval) -> TimeInterval = { _ in 0.001 },
        pad: UInt8 = 0,
        transport: RawTouchTransport = .usb
    ) -> Int {
        var seq = seq
        for index in 0..<count {
            let t = start + Double(index) * frameInterval
            harness.pipeline.handle(
                wireFrame: frame(
                    seq: seq, x: 1000 + index * 2, sampledAt: t, late: lateness(t), pad: pad, transport: transport))
            harness.ticker.tick(at: t + lateness(t) + 0.004)
            seq += 1
        }
        let t = start + Double(count) * frameInterval
        harness.pipeline.handle(
            wireFrame: release(seq: seq, sampledAt: t, late: lateness(t), pad: pad, transport: transport))
        return seq + 1
    }

    func testTheFirstGestureRunsAtTheSeedAndTheNextAtTheMeasurement() {
        let harness = makeHarness()
        XCTAssertEqual(harness.pipeline.resamplerLatency, RawTouchLatencyEstimator.seed, "idle: the seed")

        let seq = drag(harness, from: 0, count: 30, seq: 0)
        XCTAssertEqual(
            harness.pipeline.resamplerLatency, RawTouchLatencyEstimator.seed, "the first gesture keeps the seed")

        harness.pipeline.handle(wireFrame: frame(seq: seq, x: 1000, sampledAt: 1, late: 0.001))
        XCTAssertEqual(
            harness.pipeline.resamplerLatency, RawTouchLatencyEstimator.headroom, accuracy: 1e-9,
            "clean delivery: only the headroom")
    }

    func testTheLatencyHoldsForTheWholeGesture() {
        let harness = makeHarness()
        var seq = 0
        for index in 0..<40 {
            let t = Double(index) * frameInterval
            harness.pipeline.handle(wireFrame: frame(seq: seq, x: 1000 + index * 2, sampledAt: t, late: 0.001))
            harness.ticker.tick(at: t + 0.005)
            seq += 1
            XCTAssertEqual(
                harness.pipeline.resamplerLatency, RawTouchLatencyEstimator.seed,
                "frame \(index): adopted at touch-down only")
        }
    }

    func testBatchedDeliveryEarnsABatchOfLatency() {
        let harness = makeHarness()
        let seq = drag(harness, from: 0, count: 60, seq: 0, lateness: batched, transport: .bluetooth)

        harness.pipeline.handle(
            wireFrame: frame(seq: seq, x: 1000, sampledAt: 2, late: batched(2), transport: .bluetooth))
        // On the 10 ms grid, 15 ms batches put a third of the frames a
        // full 10 ms behind the fastest.
        XCTAssertEqual(harness.pipeline.resamplerLatency, 0.010 + RawTouchLatencyEstimator.headroom, accuracy: 1e-6)
    }

    func testEachSourceMeasuresItsOwnDelivery() {
        let harness = makeHarness()
        // Pad 1 (a relayed pad, say) always 5 ms late; pad 0 clean.
        var seq = 0
        for index in 0..<30 {
            let t = Double(index) * frameInterval
            var late = frame(seq: seq, x: 1000 + index * 2, sampledAt: t, late: 0.006)
            late.padID = 1
            harness.pipeline.handle(wireFrame: late)
            harness.ticker.tick(at: t + 0.010)
            seq += 1
        }
        var lift = release(seq: seq, sampledAt: 0.3, late: 0.006)
        lift.padID = 1
        harness.pipeline.handle(wireFrame: lift)
        drag(harness, from: 1, count: 30, seq: 0)

        var padOne = frame(seq: 40, x: 1000, sampledAt: 3, late: 0.006)
        padOne.padID = 1
        harness.pipeline.handle(wireFrame: padOne)
        // Constant lateness is a constant offset — invisible. What
        // distinguishes the pads is that each has its own window: pad 1's
        // gesture started with 30 frames, enough to measure.
        XCTAssertEqual(harness.pipeline.resamplerLatency, RawTouchLatencyEstimator.headroom, accuracy: 1e-9)
    }

    func testTheSummaryCarriesTheGesturesTiming() {
        let harness = makeHarness()
        drag(harness, from: 0, count: 30, seq: 0)

        let summary = try? XCTUnwrap(harness.summaries.first)
        XCTAssertEqual(summary?.latencyMs, RawTouchLatencyEstimator.seed * 1000)
        XCTAssertEqual(summary?.measuredLatencyMs ?? -1, RawTouchLatencyEstimator.headroom * 1000, accuracy: 1e-6)
        XCTAssertEqual(summary?.displayFrames, 30, "one tick per frame")
        XCTAssertEqual(summary?.heldFrames, 0, "15 ms of latency covers 1 ms of delivery")
    }

    func testHeldFramesAreCountedWhenTheLatencyIsBelowTheDelivery() {
        // A fixed 0 ms against 15 ms batches: many ticks find the newest
        // frame too old to extrapolate from.
        let harness = makeHarness(fixedLatency: 0)
        var seq = 0
        var tick = 0.003
        for index in 0..<60 {
            let t = Double(index) * frameInterval
            let arrival = t + batched(t)
            while tick < arrival {
                harness.ticker.tick(at: tick)
                tick += displayPeriod
            }
            harness.pipeline.handle(
                wireFrame: frame(seq: seq, x: 1000 + index * 2, sampledAt: t, late: batched(t), transport: .usb))
            seq += 1
        }
        harness.pipeline.handle(wireFrame: release(seq: seq, sampledAt: 0.6, late: batched(0.6), transport: .usb))

        let summary = harness.summaries.first
        XCTAssertEqual(summary?.latencyMs, 0)
        XCTAssertGreaterThan(summary?.heldFrames ?? 0, 0)
        XCTAssertLessThan(summary?.heldFrames ?? 0, summary?.displayFrames ?? 0)
    }

    /// The engine's finished summary is re-read on every tick of the next
    /// gesture; tagging it from live state would re-deliver it per tick
    /// with the new gesture's running counts spliced in.
    func testASummaryIsDeliveredOncePerGestureNotPerTick() {
        let harness = makeHarness()
        let seq = drag(harness, from: 0, count: 30, seq: 0)
        XCTAssertEqual(harness.summaries.count, 1)

        drag(harness, from: 1, count: 40, seq: seq)
        XCTAssertEqual(harness.summaries.count, 2, "one delivery per (non-coasting) gesture")
        XCTAssertEqual(harness.summaries[0].displayFrames, 30, "the first gesture's counts are its own")
        XCTAssertEqual(harness.summaries[1].displayFrames, 40)
        XCTAssertEqual(
            harness.summaries[1].latencyMs, RawTouchLatencyEstimator.headroom * 1000, accuracy: 1e-6)
    }

    /// A finger catching its own pad's coast starts a new gesture for the
    /// engine, and adopts the latest measurement like any touch-down.
    func testASamePadCatchAdoptsTheLatestMeasurement() {
        let harness = makeHarness()
        var seq = 0
        for index in 0..<30 {
            let t = Double(index) * frameInterval
            harness.pipeline.handle(wireFrame: frame(seq: seq, x: 1000 + index * 25, sampledAt: t, late: 0.001))
            harness.ticker.tick(at: t + 0.005)
            seq += 1
        }
        harness.pipeline.handle(wireFrame: release(seq: seq, sampledAt: 0.3, late: 0.001))
        XCTAssertTrue(harness.pipeline.activeSource?.padID != nil, "a fast lift coasts")
        XCTAssertEqual(harness.pipeline.resamplerLatency, RawTouchLatencyEstimator.seed)

        harness.pipeline.handle(wireFrame: frame(seq: seq + 1, x: 1750, sampledAt: 0.35, late: 0.001))
        XCTAssertEqual(harness.pipeline.resamplerLatency, RawTouchLatencyEstimator.headroom, accuracy: 1e-9)
    }

    /// A lease that lapses mid-series drops the source's clock and
    /// sequence bookkeeping, not what its delivery measured.
    func testALeaseLapseKeepsTheMeasurement() {
        let harness = makeHarness()
        let seq = drag(harness, from: 0, count: 30, seq: 0)

        harness.pipeline.handle(wireFrame: frame(seq: seq, x: 1000, sampledAt: 1, late: 0.001))
        var lapsed = frame(seq: seq + 1, x: 1010, sampledAt: 1.01, late: 0.001)
        lapsed.leaseHeld = false
        harness.pipeline.handle(wireFrame: lapsed)
        XCTAssertNil(harness.pipeline.activeSource?.padID, "the series was canceled")

        harness.pipeline.handle(wireFrame: frame(seq: seq + 2, x: 1000, sampledAt: 2, late: 0.001))
        XCTAssertEqual(harness.pipeline.resamplerLatency, RawTouchLatencyEstimator.headroom, accuracy: 1e-9)
    }

    /// The measurement belongs to the *source*, not the connection: on a
    /// split keyboard one pad's frames are relayed from the other half and
    /// arrive later, and the settings window has to be able to say both at
    /// once rather than flip between them as the user alternates pads.
    func testEachPadMeasuresItsOwnDelivery() {
        let harness = makeHarness()
        var reports: [[RawTouchSourceID: Double]] = []
        harness.pipeline.onMeasuredLatencies = { reports.append($0) }

        // Pad 0 is the wired half's: its frames arrive one by one. Pad 1
        // is relayed over a link that delivers them in batches, which is
        // what the estimator measures — a *spread* in arrival, not a
        // constant offset every frame shares.
        var seq = drag(harness, from: 0, count: 40, seq: 0, pad: 0)
        seq = drag(harness, from: 1, count: 40, seq: seq, lateness: batched, pad: 1)

        let source0 = RawTouchSourceID(endpoint: .default, padID: 0)
        let source1 = RawTouchSourceID(endpoint: .default, padID: 1)
        let measured = harness.pipeline.measuredLatencyMs
        XCTAssertEqual(measured.keys.sorted { $0.padID < $1.padID }, [source0, source1])
        XCTAssertLessThan(measured[source0] ?? .infinity, 1.0, "the wired pad measured itself prompt")
        XCTAssertGreaterThan(measured[source1] ?? 0, 5.0, "the relayed one measured its own path")

        // The hook carries every source, not just the one that scrolled:
        // that is what a row showing them all needs.
        XCTAssertEqual(reports.last?.count, 2)
        XCTAssertEqual(reports.last, measured)
    }

    /// The bench's seam: a stated latency is never overruled by what the
    /// frames measure.
    func testAFixedLatencyStandsAgainstTheMeasurement() {
        let harness = makeHarness(fixedLatency: 0.003)
        drag(harness, from: 0, count: 30, seq: 0)
        harness.pipeline.handle(wireFrame: frame(seq: 31, x: 1000, sampledAt: 1, late: 0.001))
        XCTAssertEqual(harness.pipeline.resamplerLatency, 0.003)
    }
}
