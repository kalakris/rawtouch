// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation

/// SplitMix64: a tiny deterministic generator, so the jitter in a test or a
/// bench run is reproducible without seeding the system generator. The
/// resampler tests and the offline bench both model relay jitter with it.
public struct SplitMix64 {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
