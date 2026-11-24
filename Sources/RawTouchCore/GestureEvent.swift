// MIT License
// Copyright (c) 2026 RawTouch contributors
// Derived from LinearMouse's GestureKit module —
// Copyright (c) 2021-2026 LinearMouse (MIT). Trimmed to the scroll-gesture
// pieces the poster needs (zoom / navigation-swipe dropped).

import CoreGraphics

/// - SeeAlso:
/// https://github.com/WebKit/WebKit/blob/ab59722dc517c798f7d88bfe4dcb7b33b8473e7e/Tools/TestRunnerShared/spi/CoreGraphicsTestSPI.h#L39
extension CGEventField {
    static let gestureHIDType = Self(rawValue: 110)!
    static let gestureStartEndSeriesType = Self(rawValue: 117)!
    static let gestureScrollX = Self(rawValue: 118)!
    static let gestureScrollY = Self(rawValue: 119)!
    static let gesturePhase = Self(rawValue: 132)!
    static let scrollGestureFlagBits = Self(rawValue: 135)!
}

/// - SeeAlso:
/// https://github.com/WebKit/WebKit/blob/ab59722dc517c798f7d88bfe4dcb7b33b8473e7e/Tools/TestRunnerShared/spi/CoreGraphicsTestSPI.h#L87
public enum CGSGesturePhase: UInt8 {
    case none = 0
    case began = 1
    case changed = 2
    case ended = 4
    case cancelled = 8
    case mayBegin = 128
}

/// - SeeAlso:
/// https://github.com/WebKit/WebKit/blob/52d85940c6acce0f6b25fe1f8155c25283058e27/Source/WebCore/PAL/pal/spi/mac/IOKitSPIMac.h#L74
enum IOHIDEventType: UInt32 {
    case scroll = 6
    case gestureStarted = 61
    case gestureEnded = 62
}

extension CGEventType {
    /// `NSEvent.EventType.gesture`, as a raw value so the library needs no
    /// AppKit.
    static let gesture = Self(rawValue: 29)!
}

/// A gesture-scroll event: the companion a real trackpad sends alongside
/// each phased scroll-wheel event. Nil only if CoreGraphics refuses to
/// create an event.
func makeScrollGestureEvent(
    phase: CGSGesturePhase,
    deltaX: Double,
    deltaY: Double,
    flags: CGEventFlags,
    timestamp: CGEventTimestamp
) -> CGEvent? {
    guard let event = CGEvent(source: nil) else {
        return nil
    }

    event.type = .gesture
    event.flags = flags
    event.timestamp = timestamp
    event.setIntegerValueField(.gestureHIDType, value: Int64(IOHIDEventType.scroll.rawValue))
    event.setIntegerValueField(.gesturePhase, value: Int64(phase.rawValue))
    event.setIntegerValueField(.scrollGestureFlagBits, value: 1)
    event.setDoubleValueField(.gestureScrollX, value: deltaX)
    event.setDoubleValueField(.gestureScrollY, value: deltaY)
    return event
}

/// The event that opens (`started`) or closes a gesture series.
func makeGestureSeriesEvent(started: Bool, flags: CGEventFlags, timestamp: CGEventTimestamp) -> CGEvent? {
    guard let event = CGEvent(source: nil) else {
        return nil
    }

    event.type = .gesture
    event.flags = flags
    event.timestamp = timestamp
    event.setIntegerValueField(
        .gestureHIDType,
        value: Int64((started ? IOHIDEventType.gestureStarted : .gestureEnded).rawValue)
    )
    event.setIntegerValueField(.gestureStartEndSeriesType, value: Int64(IOHIDEventType.scroll.rawValue))
    return event
}
