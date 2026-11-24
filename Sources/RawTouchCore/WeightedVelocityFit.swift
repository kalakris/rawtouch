// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation

/// The recency-weighted least-squares velocity estimator shared by the
/// engine's lift-off momentum seed and the display-rate resampler's
/// extrapolation.
///
/// Fits a straight line through `(timestamp, position)` samples, weighting
/// each sample by `exp(-age / weightTimeConstant)` relative to the newest
/// one, and returns its slope. The weighting puts the estimate at the
/// newest sample's speed with roughly one time constant of effective lag,
/// while fitting every retained sample (rather than differencing two
/// endpoints) keeps the estimate robust to single-frame noise. The fit is
/// exact for constant velocity whatever the weights, so a steady drag is
/// never biased.
public enum WeightedVelocityFit {
    /// One input sample: a position (any unit) at a timestamp (seconds).
    public typealias Sample = (position: Double, timestamp: TimeInterval)

    /// The recency-weighting time constant both callers use: a sample's
    /// weight is `exp(-age / this)`, so ~3 frames at the pad's 100 Hz
    /// cadence carry most of the estimate.
    public static let defaultWeightTimeConstant: TimeInterval = 0.03

    /// The slope of the weighted fit, in position units per second, or
    /// `nil` when the samples cannot support one: fewer than two, a span
    /// shorter than `minimumSpan`, or all effective weight on one instant.
    /// Samples must be in timestamp order (the last one is the newest).
    public static func slope(
        through samples: [Sample],
        weightTimeConstant: TimeInterval = defaultWeightTimeConstant,
        minimumSpan: TimeInterval = 0.005
    ) -> Double? {
        guard let first = samples.first, let last = samples.last,
            last.timestamp - first.timestamp >= minimumSpan
        else {
            return nil
        }

        // Times are taken relative to the newest sample: it keeps the math
        // well-conditioned and makes each sample's age the natural weight
        // input. Two passes (weighted means, then moments) over ≤ ~11
        // samples.
        var weightSum = 0.0
        var meanAge = 0.0
        var meanPosition = 0.0
        for sample in samples {
            let age = last.timestamp - sample.timestamp
            let weight = exp(-age / weightTimeConstant)
            weightSum += weight
            meanAge += weight * age
            meanPosition += weight * sample.position
        }
        meanAge /= weightSum
        meanPosition /= weightSum

        var covariance = 0.0
        var variance = 0.0
        for sample in samples {
            let age = last.timestamp - sample.timestamp
            let weight = exp(-age / weightTimeConstant)
            let dt = meanAge - age  // age runs opposite to time
            covariance += weight * dt * (sample.position - meanPosition)
            variance += weight * dt * dt
        }

        // Degenerate spread (all effective weight on one instant): no
        // meaningful slope.
        guard variance > 1e-9 else {
            return nil
        }

        return covariance / variance
    }

    /// The recency-weighted least-squares *quadratic* through the samples:
    /// the velocity and acceleration at the newest sample — what the
    /// engine's lift-off check reads to tell a braking finger from a
    /// flick. Nil with fewer than three samples or a degenerate spread.
    public static func quadratic(
        through samples: [Sample],
        weightTimeConstant: TimeInterval = defaultWeightTimeConstant,
        minimumSpan: TimeInterval = 0.005
    ) -> (velocity: Double, acceleration: Double)? {
        guard samples.count >= 3, let first = samples.first, let last = samples.last,
            last.timestamp - first.timestamp >= minimumSpan
        else {
            return nil
        }
        // Normal equations for p(dt) = c0 + c1 dt + c2 dt^2, dt = t - newest.
        var m = [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
        var b = [0.0, 0.0, 0.0]
        for sample in samples {
            let dt = sample.timestamp - last.timestamp
            let w = exp(dt / weightTimeConstant)
            let row = [1.0, dt, dt * dt]
            for i in 0..<3 {
                b[i] += w * row[i] * sample.position
                for j in 0..<3 {
                    m[i][j] += w * row[i] * row[j]
                }
            }
        }
        // Gaussian elimination with partial pivoting.
        for i in 0..<3 {
            var pivot = i
            for r in i + 1..<3 where abs(m[r][i]) > abs(m[pivot][i]) {
                pivot = r
            }
            m.swapAt(i, pivot)
            b.swapAt(i, pivot)
            guard abs(m[i][i]) > 1e-12 else {
                return nil
            }
            for r in 0..<3 where r != i {
                let f = m[r][i] / m[i][i]
                for c in 0..<3 {
                    m[r][c] -= f * m[i][c]
                }
                b[r] -= f * b[i]
            }
        }
        return (velocity: b[1] / m[1][1], acceleration: 2 * b[2] / m[2][2])
    }
}
