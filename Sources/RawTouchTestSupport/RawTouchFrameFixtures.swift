// MIT License
// Copyright (c) 2026 RawTouch contributors
// Derived from LinearMouse — Copyright (c) 2021-2026 LinearMouse (MIT).

import CoreGraphics
import Foundation
import RawTouchCore

// Shared `RawTouchFrame` factories for the raw-touch tests and the offline
// bench, modeling a ~100 Hz Cirque frame stream. `endpoint` names the
// keyboard (well, the endpoint) a frame comes from; the default is the one
// `TouchScrollPipeline.configure(capabilities:...)` installs.

public func scrollFrame(
    x: Int = 1000,
    y: Int = 500,
    at timestamp: TimeInterval,
    pad: UInt8 = 0,
    leaseHeld: Bool = true,
    splitLink: RawTouchSplitLink? = nil,
    transport: RawTouchTransport = .unknown,
    endpoint: RawTouchEndpointID = .default
) -> RawTouchFrame {
    .init(
        padID: pad,
        x: x,
        y: y,
        z: 40,
        touched: true,
        scrollMode: true,
        leaseHeld: leaseHeld,
        splitLink: splitLink,
        transport: transport,
        endpoint: endpoint,
        timestamp: timestamp
    )
}

public func pointerFrame(
    x: Int = 1000,
    y: Int = 500,
    at timestamp: TimeInterval,
    pad: UInt8 = 0,
    leaseHeld: Bool = true,
    splitLink: RawTouchSplitLink? = nil,
    transport: RawTouchTransport = .unknown,
    endpoint: RawTouchEndpointID = .default
) -> RawTouchFrame {
    .init(
        padID: pad,
        x: x,
        y: y,
        z: 40,
        touched: true,
        scrollMode: false,
        leaseHeld: leaseHeld,
        splitLink: splitLink,
        transport: transport,
        endpoint: endpoint,
        timestamp: timestamp
    )
}

public func releaseFrame(
    at timestamp: TimeInterval,
    scrollMode: Bool,
    pad: UInt8 = 0,
    leaseHeld: Bool = true,
    splitLink: RawTouchSplitLink? = nil,
    transport: RawTouchTransport = .unknown,
    endpoint: RawTouchEndpointID = .default
) -> RawTouchFrame {
    .init(
        padID: pad,
        touched: false,
        scrollMode: scrollMode,
        leaseHeld: leaseHeld,
        splitLink: splitLink,
        transport: transport,
        endpoint: endpoint,
        timestamp: timestamp
    )
}

// MARK: - Raw wire payloads

/// A raw protocol-4 input-report payload (11 bytes: pad, contact, x LE, y LE, z,
/// flags, seq, timestamp LE in 100 µs ticks).
///
/// The default flags are touched + scroll mode + lease held: the lease
/// is what RawTouch requires before it synthesizes anything.
public func v3FrameBytes(
    pad: UInt8 = 0,
    contact: UInt8 = 0,
    x: UInt16 = 1000,
    y: UInt16 = 500,
    z: UInt8 = 40,
    flags: UInt8 = 0b111,
    seq: UInt8 = 0,
    timestampTicks: UInt16 = 0
) -> [UInt8] {
    [
        pad,
        contact,
        UInt8(x & 0xFF), UInt8(x >> 8),
        UInt8(y & 0xFF), UInt8(y >> 8),
        z,
        flags,
        seq,
        UInt8(timestampTicks & 0xFF), UInt8(timestampTicks >> 8),
    ]
}

// MARK: - Test doubles

/// A `TimerScheduling` that records timers instead of running a run loop, so
/// the momentum tick and the stale-touch watchdog can be fired on demand.
public final class FakeTimerScheduler: TimerScheduling {
    public final class Timer: ScheduledTimer {
        public let interval: TimeInterval
        public let repeats: Bool
        public let handler: () -> Void
        public private(set) var invalidated = false

        init(interval: TimeInterval, repeats: Bool, handler: @escaping () -> Void) {
            self.interval = interval
            self.repeats = repeats
            self.handler = handler
        }

        public func invalidate() {
            invalidated = true
        }

        public func fire() {
            guard !invalidated else {
                return
            }
            if !repeats {
                invalidated = true
            }
            handler()
        }
    }

    public private(set) var timers: [Timer] = []

    public init() {}

    public func scheduleTimer(
        interval: TimeInterval,
        repeats: Bool,
        handler: @escaping () -> Void
    ) -> ScheduledTimer? {
        let timer = Timer(interval: interval, repeats: repeats, handler: handler)
        timers.append(timer)
        return timer
    }

    public var liveTimers: [Timer] {
        timers.filter { !$0.invalidated }
    }

    /// Fires every currently live one-shot timer (the stale-touch watchdog).
    public func fireOneShots() {
        for timer in liveTimers where !timer.repeats {
            timer.fire()
        }
    }

    /// Fires the live repeating timer (the momentum tick) `count` times.
    public func fireRepeating(count: Int) {
        for _ in 0..<count {
            guard let timer = liveTimers.first(where: \.repeats) else {
                return
            }
            timer.fire()
        }
    }
}

/// Captures the CGEvents a poster would post. **Nothing is ever posted**, so
/// the tests never touch the event system and never raise a TCC prompt.
/// A stand-in for the window server: says whether the pointer is over one
/// of our own windows, and counts how often it was asked — the check is
/// meant to happen once per gesture, never per frame.
public final class FakePointerWindowOwnership: PointerWindowOwnership {
    public var isOverOwnWindow: Bool
    public private(set) var callCount = 0

    public init(isOverOwnWindow: Bool = false) {
        self.isOverOwnWindow = isOverOwnWindow
    }

    public func pointerIsOverOwnWindow() -> Bool {
        callCount += 1
        return isOverOwnWindow
    }
}

public final class CapturedScrollEvents {
    public private(set) var events: [CGEvent] = []

    public init() {}

    /// A poster wired to this capture, with static (empty) modifier flags so
    /// tests never read global keyboard state, and a pointer that is never
    /// over RawTouch's own window (`windowOwnership` states otherwise where
    /// that is the subject).
    public func makePoster(
        windowOwnership: PointerWindowOwnership = FakePointerWindowOwnership()
    ) -> RawTouchScrollPoster {
        RawTouchScrollPoster(
            eventSink: { [weak self] event in
                self?.events.append(event.copy() ?? event)
            },
            modifierFlags: { [] },
            windowOwnership: windowOwnership
        )
    }

    public var scrollWheelViews: [ScrollWheelEventView] {
        events.filter { $0.type == .scrollWheel }.map(ScrollWheelEventView.init)
    }

    /// (scroll phase, momentum phase, fixed-point deltaX, fixed-point
    /// deltaY) per scroll event.
    public var phases: [(scroll: CGScrollPhase?, momentum: CGMomentumScrollPhase, deltaX: Double, deltaY: Double)] {
        scrollWheelViews.map { ($0.scrollPhase, $0.momentumPhase, $0.deltaXFixedPt, $0.deltaYFixedPt) }
    }

    public var scrollPhases: [CGScrollPhase?] {
        phases.map(\.scroll)
    }

    /// The vertical (axis 1) fixed-point deltas.
    public var deltas: [Double] {
        phases.map(\.deltaY)
    }

    /// The horizontal (axis 2) fixed-point deltas.
    public var horizontalDeltas: [Double] {
        phases.map(\.deltaX)
    }

    public func reset() {
        events.removeAll()
    }
}

// MARK: - Endpoints

/// A Go60-shaped endpoint descriptor for multi-keyboard tests: host
/// lease supported, `padsPresent` pads (both by default), rotate-90 +
/// y-invert (⇒ vertical from raw X, old-school direction). Vary the
/// orientation to model a differently mounted pad on another keyboard.
public func endpointDescriptor(
    id: UInt64,
    padsPresent: UInt8 = 0x03,
    countsPerMM: Int = 38,
    rotate90: Bool = true,
    invertX: Bool = false,
    invertY: Bool = true,
    transport: RawTouchTransport = .unknown,
    productName: String = "Go60 Right",
    deviceKey: String? = nil
) -> RawTouchEndpointDescriptor {
    RawTouchEndpointDescriptor(
        id: RawTouchEndpointID(rawValue: id),
        capabilities: RawTouchCapabilities(
            padsPresent: padsPresent,
            capabilityBits: RawTouchCapabilities.Capability.hostLease,
            countsPerMM: countsPerMM,
            rotate90: rotate90,
            invertX: invertX,
            invertY: invertY
        ),
        transport: transport,
        productName: productName,
        deviceKey: deviceKey
    )
}

extension RawTouchStatus.Endpoint {
    /// A two-pad USB endpoint as the status reports it, for tests that only
    /// need a keyboard to be present with some lease outcome.
    public static func keyboard(
        _ productName: String = "Go60",
        id: UInt64 = 1,
        lease: Lease
    ) -> RawTouchStatus.Endpoint {
        RawTouchStatus.Endpoint(
            id: RawTouchEndpointID(rawValue: id),
            productName: productName,
            transport: .usb,
            padIDs: [0, 1],
            lease: lease
        )
    }
}

/// The device key the single-endpoint test pipelines register under, so a
/// test can write per-pad settings the way the configuration keeps them —
/// under one keyboard — without spelling the key out every time.
public let testDeviceKey = "usb:test"

extension RawTouchConfiguration {
    /// Test shorthand for `devices[testDeviceKey].pads[id]`: the per-pad
    /// settings of the one keyboard a single-endpoint test has.
    public subscript(pad id: String) -> Pad? {
        get {
            devices[testDeviceKey]?.pads[id]
        }
        set {
            var device = devices[testDeviceKey] ?? .init()
            device.pads[id] = newValue
            devices[testDeviceKey] = device
        }
    }
}
