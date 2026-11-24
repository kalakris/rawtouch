// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import RawTouchCore

/// The display density the pipeline tests pin: `scale` is a gain relative
/// to physical 1:1, so a display of 0.25 × the pad's 38 counts/mm points
/// per millimetre turns the default gain 1.0 into 0.25 points per count —
/// the mapping the delta assertions are written in.
public let testPointsPerMM = 0.25 * RawTouchCapabilities.Pad.fallbackCountsPerMM

/// A device timestamp for host time `t`, in the wire's 100 µs ticks.
public func deviceTicks(at t: TimeInterval) -> UInt16 {
    UInt16(truncatingIfNeeded: Int((t / RawTouchDeviceClock.tickDuration).rounded()))
}

/// Vsync times every `period` from `start` up to and including `end`.
public func vsyncTimes(
    from start: TimeInterval,
    until end: TimeInterval,
    period: TimeInterval = PipelineHarness.displayPeriod
) -> [TimeInterval] {
    var result: [TimeInterval] = []
    var t = start
    while t <= end {
        result.append(t)
        t += period
    }
    return result
}

/// A `TouchScrollPipeline` wired to doubles: every event it posts is
/// captured, timers are fired by hand, vsyncs are delivered by hand, and the
/// host clock is whatever the test sets. Nothing is posted, so no test can
/// raise an Accessibility prompt.
///
/// Ballistics are always off: a velocity-dependent gain would fold the
/// synthetic finger's speed into every delta, and these tests are about the
/// pipeline (`TouchScrollEngineTests` owns the curve). With the default
/// `testPointsPerMM`, every delta is the plain `counts × 0.25`.
public final class PipelineHarness {
    /// The pad's ~100 Hz frame cadence.
    public static let frameInterval: TimeInterval = 0.01
    /// A 120 Hz display.
    public static let displayPeriod: TimeInterval = 1.0 / 120.0

    public let pipeline: TouchScrollPipeline
    public let captured = CapturedScrollEvents()
    public let scheduler = FakeTimerScheduler()
    /// Injected as the pipeline's display ticker unless the harness was
    /// made unpaced.
    public let ticker = ManualDisplayTicker()

    private final class Recorder {
        var now: TimeInterval = 0
        var summaries: [RawTouchGestureSummary] = []
        var tapConfirms: [RawTouchSourceID] = []
    }

    private let recorder = Recorder()

    /// The host clock the pipeline reads, unless `now` was injected.
    public var now: TimeInterval {
        get { recorder.now }
        set { recorder.now = newValue }
    }

    /// Every gesture summary the pipeline delivered, in order.
    public var summaries: [RawTouchGestureSummary] {
        recorder.summaries
    }

    /// Every tap confirm the pipeline asked for, in order.
    public var tapConfirms: [RawTouchSourceID] {
        recorder.tapConfirms
    }

    /// - Parameters:
    ///   - resampling: overrides `configuration.resampling.enabled`.
    ///   - paced: whether a display ticker is injected at all.
    ///   - fixedLatency: the display-sync latency by hand; nil measures it.
    ///   - endpoints: the admitted endpoints; nil installs `capabilities`
    ///     as the single default endpoint under `deviceKey`.
    ///   - now: the host clock; nil reads the harness's own `now`.
    public init(
        configuration: RawTouchConfiguration = .init(),
        resampling: Bool? = nil,
        paced: Bool = true,
        fixedLatency: TimeInterval? = 0,
        endpoints: [RawTouchEndpointDescriptor]? = nil,
        capabilities: RawTouchCapabilities = .go60(),
        deviceKey: String? = nil,
        now: (() -> TimeInterval)? = nil,
        pointsPerMM: @escaping () -> Double = { testPointsPerMM }
    ) {
        var configuration = configuration
        configuration.acceleration.enabled = false
        if let resampling {
            configuration.resampling.enabled = resampling
        }
        let recorder = recorder
        pipeline = TouchScrollPipeline(
            configuration: configuration,
            poster: captured.makePoster(),
            scheduler: scheduler,
            displayTicker: paced ? ticker : nil,
            now: now ?? { recorder.now },
            pointsPerMM: pointsPerMM
        )
        pipeline.fixedLatency = fixedLatency
        if let endpoints {
            pipeline.configure(endpoints: endpoints, systemPrefersNatural: false)
        } else {
            pipeline.configure(capabilities: capabilities, deviceKey: deviceKey, systemPrefersNatural: false)
        }
        pipeline.onGestureSummary = { recorder.summaries.append($0) }
        pipeline.onTapConfirm = { recorder.tapConfirms.append($0) }
    }

    /// Hands one frame to the pipeline as if it came off the wire.
    public func handle(_ frame: RawTouchFrame) {
        pipeline.handle(wireFrame: frame)
    }

    /// A flick on one source into a coasting momentum tail: twelve frames
    /// 10 ms apart, 25 counts each, the release 10 ms later, then three
    /// momentum-timer ticks. Returns the release time.
    @discardableResult
    public func flickIntoMomentum(
        pad: UInt8 = 0,
        on endpoint: RawTouchEndpointID = .default,
        from start: TimeInterval = 0
    ) -> TimeInterval {
        Self.flickIntoMomentum(pipeline, scheduler, pad: pad, on: endpoint, from: start)
    }

    /// `flickIntoMomentum` for a pipeline held without its harness.
    @discardableResult
    public static func flickIntoMomentum(
        _ pipeline: TouchScrollPipeline,
        _ scheduler: FakeTimerScheduler,
        pad: UInt8 = 0,
        on endpoint: RawTouchEndpointID = .default,
        from start: TimeInterval = 0
    ) -> TimeInterval {
        var timestamp = start
        for step in 0..<12 {
            timestamp = start + Double(step) * frameInterval
            pipeline.handle(wireFrame: scrollFrame(x: 1000 + step * 25, at: timestamp, pad: pad, endpoint: endpoint))
        }
        timestamp += frameInterval
        pipeline.handle(wireFrame: releaseFrame(at: timestamp, scrollMode: true, pad: pad, endpoint: endpoint))
        scheduler.fireRepeating(count: 3)
        return timestamp
    }
}
