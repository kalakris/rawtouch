// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation

/// Measures, per source, the display-sync latency its frames need — how
/// far behind each display tick the resampler should estimate the finger
/// so that the frame it needs has usually arrived.
///
/// Why measure: the lateness of a frame's arrival against its own device
/// timestamp depends on the whole path, and the host can see almost none
/// of it. Recorded on one keyboard (bench/captures/): about 1 ms for the
/// keyboard's own pad over USB, 5 ms for the pad relayed over its wired
/// split link, 10 ms for that pad when the halves talk over Bluetooth, and
/// 14–16 ms for either pad once the host link is Bluetooth. Whether the
/// halves are wired can change mid-session when the cable comes out, and
/// nothing on the wire says. So no per-transport constant is right, and
/// no configuration can be: the frames themselves are the only honest
/// source, and they say it within a few dozen frames.
///
/// What is measured: each touched frame's *offset*, arrival minus the
/// device timeline reconstructed from its timestamp, in a ring of the last
/// `windowSize` frames. A frame's *lateness* is its offset above the
/// smallest offset seen in its *epoch* — a run of frames on one continuous
/// device timeline, broken by the same 2 s discontinuity rule the device
/// clock re-anchors on (and, to keep crystal drift out of it, every
/// `epochSpan` of device time). The estimate is a high percentile of the
/// window's lateness plus a little headroom: the bench's latency sweep
/// over the recorded paths puts the knee of the stutter-versus-latency
/// curve at or within a millisecond below p90 on every one of them.
///
/// The percentile is taken over the window as it stands, so a frame's
/// lateness is always measured against the minimum its epoch eventually
/// found, not the running minimum at the time it arrived — which is why
/// the window errs low only while it is short, never high. Below
/// `minimumSamples` the estimate is the `seed`: a fresh source starts
/// slightly laggy rather than stuttery, once per connection. The window
/// is frames, not time, so it survives idle gaps (frames only come while
/// touching) and forgets nothing until the source itself goes away.
///
/// The pipeline reads the estimate at touch-down and holds it for the
/// gesture: raising latency mid-gesture would ask the resampler for an
/// earlier time than it last emitted, which its carry rule forbids.
///
/// Cost: a subtraction and a ring write per frame at ~100 Hz, a partial
/// sort of at most `windowSize` numbers per touch-down.
public struct RawTouchLatencyEstimator: Equatable {
    /// Frames kept: two seconds of touching, several gestures' worth, over
    /// which crystal drift between the halves' clocks stays under 0.1 ms.
    public static let windowSize = 200

    /// Frames needed (in epochs long enough to count) before the window is
    /// trusted over the seed.
    public static let minimumSamples = 20

    /// An epoch shorter than this — a tap, a brush — has not seen the
    /// path's fastest frame, so its frames would all read as on time and
    /// drag the percentile down. They stay in the window but are left out
    /// of the estimate until the epoch grows past this (the recorded
    /// traces the percentile was chosen on were cut the same way).
    public static let minimumEpochFrames = 10

    /// The lateness percentile the estimate covers.
    public static let percentile = 0.9

    /// Added to the percentile, seconds.
    public static let headroom: TimeInterval = 0.0005

    /// The estimate while the window is short: the Bluetooth level, so a
    /// cold start is smooth and the estimate only has to come down.
    public static let seed: TimeInterval = 0.015

    /// The estimate is clamped to this: 0 adds no lag at all, and the
    /// ceiling covers the latest delivery measured on any path (a
    /// Bluetooth host link: p95 lateness ≈ 15–17 ms, see bench/captures/)
    /// with room to spare.
    public static let range: ClosedRange<TimeInterval> = 0...0.025

    /// A gap in device time or in arrival beyond this starts a new epoch,
    /// as it re-anchors the device clock.
    public static let discontinuityThreshold = RawTouchDeviceClock.discontinuityThreshold

    /// Continuous device time after which an epoch is closed anyway, so
    /// clock drift (tens of ppm: ~0.5 ms over this span) never reads as
    /// lateness during a long uninterrupted touch.
    public static let epochSpan: TimeInterval = 10

    private struct Sample: Equatable {
        var epoch: Int
        var offset: TimeInterval
    }

    /// Oldest first.
    private var samples: [Sample] = []
    /// The smallest offset ever seen in each epoch still in the window.
    private var epochMinimum: [Int: TimeInterval] = [:]
    private var epochCount: [Int: Int] = [:]

    private var epoch = 0
    private var epochStart: TimeInterval = 0
    private var lastTicks: UInt16?
    private var lastArrival: TimeInterval = 0
    /// The current epoch's device timeline, advanced by exact device
    /// deltas from an arbitrary origin (only differences within an epoch
    /// matter).
    private var deviceTime: TimeInterval = 0

    public init() {}

    /// Frames in the window.
    public var sampleCount: Int {
        samples.count
    }

    /// Records a touched frame: its 16-bit device timestamp and its host
    /// arrival time (system uptime).
    public mutating func observe(ticks: UInt16, arrival: TimeInterval) {
        if let lastTicks {
            let delta = TimeInterval(ticks &- lastTicks) * RawTouchDeviceClock.tickDuration
            let discontinuous =
                delta > Self.discontinuityThreshold
                || arrival - lastArrival > Self.discontinuityThreshold
            if discontinuous || deviceTime + delta - epochStart > Self.epochSpan {
                epoch += 1
                deviceTime = arrival
                epochStart = arrival
            } else {
                deviceTime += delta
            }
        } else {
            deviceTime = arrival
            epochStart = arrival
        }
        self.lastTicks = ticks
        lastArrival = arrival

        let offset = arrival - deviceTime
        samples.append(Sample(epoch: epoch, offset: offset))
        epochCount[epoch, default: 0] += 1
        epochMinimum[epoch] = min(epochMinimum[epoch] ?? offset, offset)

        if samples.count > Self.windowSize {
            let evicted = samples.removeFirst()
            let remaining = (epochCount[evicted.epoch] ?? 1) - 1
            if remaining <= 0 {
                epochCount[evicted.epoch] = nil
                epochMinimum[evicted.epoch] = nil
            } else {
                epochCount[evicted.epoch] = remaining
            }
        }
    }

    /// What the window says the source needs, seconds — the lateness
    /// percentile plus headroom, clamped — or nil while fewer than
    /// `minimumSamples` frames sit in epochs of `minimumEpochFrames` or
    /// more.
    public var measuredLatency: TimeInterval? {
        let counted = samples.filter { (epochCount[$0.epoch] ?? 0) >= Self.minimumEpochFrames }
        guard counted.count >= Self.minimumSamples else {
            return nil
        }
        let latenesses =
            counted
            .map { $0.offset - (epochMinimum[$0.epoch] ?? $0.offset) }
            .sorted()
        let index = min(latenesses.count - 1, Int(Self.percentile * Double(latenesses.count)))
        return (latenesses[index] + Self.headroom).clamped(to: Self.range)
    }

    /// The latency to adopt at a touch-down: the measurement, or the seed
    /// until there is one.
    public var latency: TimeInterval {
        measuredLatency ?? Self.seed
    }
}
