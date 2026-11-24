// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import RawTouchCore

/// A `DisplayTicking` driven by hand: tests and the offline bench call
/// `tick(at:)` to stand in for a vsync. Records starts and stops so the
/// pipeline's "run only while a gesture or momentum is active" rule can be
/// asserted. A link can also be made to die (`killLiveSource()`): it stays
/// subscribed but never ticks again, like the link of a display that was
/// unplugged or slept.
public final class ManualDisplayTicker: DisplayTicking {
    public final class Source: DisplayTickSource {
        fileprivate let handler: (TimeInterval) -> Void
        public private(set) var isInvalidated = false
        /// A dead source ignores `tick(at:)`; see `killLiveSource()`.
        public fileprivate(set) var isDead = false

        fileprivate init(handler: @escaping (TimeInterval) -> Void) {
            self.handler = handler
        }

        public func invalidate() {
            isInvalidated = true
        }

        /// Delivers a tick even after invalidation — a vsync that was
        /// already queued for the event thread when the subscription
        /// ended, which the pipeline must ignore.
        public func fire(at time: TimeInterval) {
            handler(time)
        }
    }

    /// Every source ever started, oldest first.
    public private(set) var sources: [Source] = []

    /// When set, `startTicks` fails like a display link that could not be
    /// created, so the fallback path can be exercised.
    public var refusesToStart = false

    /// Every `startTicks` call, refused ones included.
    public private(set) var startAttempts = 0

    public init() {}

    /// Successful starts.
    public var startCount: Int {
        sources.count
    }

    /// The source currently running, if any.
    public var liveSource: Source? {
        sources.last(where: { !$0.isInvalidated })
    }

    public var isTicking: Bool {
        liveSource != nil
    }

    public func startTicks(handler: @escaping (TimeInterval) -> Void) -> DisplayTickSource? {
        startAttempts += 1
        guard !refusesToStart else {
            return nil
        }
        let source = Source(handler: handler)
        sources.append(source)
        return source
    }

    /// Delivers one vsync at `time` to the live source. Returns false when
    /// nothing is ticking (the pipeline stopped it, or the link died), so a
    /// simulation loop can tell idle from active.
    @discardableResult
    public func tick(at time: TimeInterval) -> Bool {
        guard let source = liveSource, !source.isDead else {
            return false
        }
        source.handler(time)
        return true
    }

    /// The running link stops ticking without being invalidated.
    public func killLiveSource() {
        liveSource?.isDead = true
    }
}
