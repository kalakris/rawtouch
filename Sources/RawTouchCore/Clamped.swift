// MIT License
// Copyright (c) 2026 RawTouch contributors

extension Comparable {
    public func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(range.lowerBound, self), range.upperBound)
    }
}
