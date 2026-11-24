// MIT License
// Copyright (c) 2026 RawTouch contributors
// Derived from LinearMouse — Copyright (c) 2021-2026 LinearMouse (MIT).

import CoreGraphics
import Foundation

/// Emits the companion gesture events that make a synthetic phased scroll
/// stream look like a real trackpad gesture series to apps: a
/// mayBegin + series-start pair before the first `began` scroll gesture, a
/// scroll gesture per phased event, and a series-end after `ended`/
/// `cancelled` — tracking whether a series is currently open so interrupted
/// gestures can be closed out cleanly.
///
/// The ordering of emitted events is part of the contract and is pinned by
/// the poster's tests.
public final class GestureScrollSeriesPoster {
    private let eventSink: (CGEvent) -> Void

    /// Whether a gesture scroll series is currently open.
    public private(set) var seriesActive = false

    public init(eventSink: @escaping (CGEvent) -> Void) {
        self.eventSink = eventSink
    }

    /// Posts the gesture companions for one phased scroll event. Events
    /// without a scroll phase (momentum) have no gesture companions.
    public func postCompanionsIfNeeded(
        scrollPhase: CGScrollPhase?,
        deltaX: Double,
        deltaY: Double,
        flags: CGEventFlags,
        timestamp: CGEventTimestamp
    ) {
        guard let scrollPhase, let gesturePhase = CGSGesturePhase(scrollPhase: scrollPhase) else {
            return
        }

        if scrollPhase == .began {
            openSeriesIfNeeded(flags: flags, timestamp: timestamp)
        }

        post(
            makeScrollGestureEvent(
                phase: gesturePhase, deltaX: deltaX, deltaY: deltaY, flags: flags, timestamp: timestamp))

        if scrollPhase == .ended || scrollPhase == .cancelled {
            post(makeGestureSeriesEvent(started: false, flags: flags, timestamp: timestamp))
            seriesActive = false
        }
    }

    /// Opens a series — mayBegin + series start — without a scroll gesture,
    /// mirroring a real trackpad's fingers-resting event at touch-down; the
    /// began gesture follows with the first movement. No-op while a series
    /// is open.
    public func openSeriesIfNeeded(flags: CGEventFlags, timestamp: CGEventTimestamp) {
        guard !seriesActive else {
            return
        }

        post(makeScrollGestureEvent(phase: .mayBegin, deltaX: 0, deltaY: 0, flags: flags, timestamp: timestamp))
        post(makeGestureSeriesEvent(started: true, flags: flags, timestamp: timestamp))
        seriesActive = true
    }

    /// Cancels an open gesture series (on teardown, when a gesture was
    /// interrupted).
    public func endSeriesIfNeeded(flags: CGEventFlags, timestamp: CGEventTimestamp) {
        guard seriesActive else {
            return
        }

        post(makeScrollGestureEvent(phase: .cancelled, deltaX: 0, deltaY: 0, flags: flags, timestamp: timestamp))
        post(makeGestureSeriesEvent(started: false, flags: flags, timestamp: timestamp))
        seriesActive = false
    }

    private func post(_ event: CGEvent?) {
        if let event {
            eventSink(event)
        }
    }
}

extension CGSGesturePhase {
    init?(scrollPhase: CGScrollPhase) {
        guard let rawValue = UInt8(exactly: scrollPhase.rawValue) else {
            return nil
        }
        self.init(rawValue: rawValue)
    }
}
