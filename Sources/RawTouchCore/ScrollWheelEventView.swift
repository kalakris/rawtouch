// MIT License
// Copyright (c) 2026 RawTouch contributors
// Derived from LinearMouse — Copyright (c) 2021-2026 LinearMouse (MIT).
// Trimmed to the fields the scroll poster writes and the tests read;
// LinearMouse's matrix `transform`/`swapXY`/`negate`/`scale` helpers (and
// their SceneKit dependency) are dropped.

import CoreGraphics
import Foundation

/// Typed accessors for the fields of a scroll-wheel `CGEvent`.
public final class ScrollWheelEventView {
    public let event: CGEvent

    public init(_ event: CGEvent) {
        assert(event.type == .scrollWheel)
        self.event = event
    }

    public var continuous: Bool {
        get { event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 }
        set { event.setIntegerValueField(.scrollWheelEventIsContinuous, value: newValue ? 1 : 0) }
    }

    public var scrollPhase: CGScrollPhase? {
        get {
            let rawValue = UInt32(event.getIntegerValueField(.scrollWheelEventScrollPhase))
            guard rawValue != 0 else {
                return nil
            }
            return .init(rawValue: rawValue)
        }
        set {
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(newValue?.rawValue ?? 0))
        }
    }

    public var momentumPhase: CGMomentumScrollPhase {
        get {
            .init(rawValue: UInt32(event.getIntegerValueField(.scrollWheelEventMomentumPhase))) ?? .none
        }
        set {
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(newValue.rawValue))
        }
    }

    // Axis 1 is vertical, axis 2 horizontal — CoreGraphics' own numbering.

    public var deltaY: Int64 {
        get { event.getIntegerValueField(.scrollWheelEventDeltaAxis1) }
        set { event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: newValue) }
    }

    public var deltaYFixedPt: Double {
        get { event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) }
        set { event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: newValue) }
    }

    public var deltaYPt: Double {
        get { event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1) }
        set { event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: newValue) }
    }

    public var deltaX: Int64 {
        get { event.getIntegerValueField(.scrollWheelEventDeltaAxis2) }
        set { event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: newValue) }
    }

    public var deltaXFixedPt: Double {
        get { event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) }
        set { event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: newValue) }
    }

    public var deltaXPt: Double {
        get { event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2) }
        set { event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: newValue) }
    }
}

/// Subpixel remainder accumulation for the integer point-delta field of
/// one axis (the poster keeps one per axis). The field holds whole points
/// — a fraction written to it reads back truncated, and so does AppKit's
/// `scrollingDeltaY`, which it backs — so each event carries the whole
/// points of its delta plus the fractions carried so far.
///
/// Derived from LinearMouse's `SmoothedScrollPointDeltaAccumulator`
/// (`SmoothedScrollingTransformer.swift`).
public struct ScrollPointDeltaAccumulator {
    private var remainder = 0.0

    public init() {}

    public mutating func reset() {
        remainder = 0
    }

    public mutating func pointDelta(for value: Double) -> Double {
        let combinedValue = value + remainder
        let pointDelta = truncatedPointDelta(for: combinedValue)
        remainder = combinedValue - pointDelta

        return pointDelta
    }

    private func truncatedPointDelta(for value: Double) -> Double {
        Double(Int64(value.rounded(.towardZero)))
    }
}

extension CGEvent {
    /// Marks events RawTouch synthesized, so its own diagnostics (and any
    /// future tap) can tell them apart from real hardware scrolling. The
    /// magic value is RawTouch's own, distinct from LinearMouse's.
    public static let rawTouchSyntheticEventUserData: Int64 = 0x5241_5754_4348  // "RAWTCH"

    public var isRawTouchSyntheticEvent: Bool {
        get {
            getIntegerValueField(.eventSourceUserData) == Self.rawTouchSyntheticEventUserData
        }
        set {
            setIntegerValueField(
                .eventSourceUserData,
                value: newValue ? Self.rawTouchSyntheticEventUserData : 0
            )
        }
    }
}
