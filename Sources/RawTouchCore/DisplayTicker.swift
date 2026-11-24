// MIT License
// Copyright (c) 2026 RawTouch contributors

import CoreGraphics
import CoreVideo
import Foundation
import os.log

/// A running display-tick subscription. `invalidate()` stops it; it is
/// idempotent and safe to call after the ticker delivered its last tick.
public protocol DisplayTickSource: AnyObject {
    func invalidate()
}

/// Vsync-locked ticks for the display the cursor is on — the clock the
/// pipeline resamples touch frames and drives momentum with. Injectable so
/// the pipeline's display-paced behavior is unit-testable without a
/// display: `CVDisplayLinkTicker` (below) wraps a real `CVDisplayLink`, and
/// `RawTouchTestSupport.ManualDisplayTicker` is the hand-driven double the
/// tests and the offline bench drive.
public protocol DisplayTicking: AnyObject {
    /// Starts ticking for the display under the cursor *now* (the pipeline
    /// calls this at touch-down, so a gesture keeps the display it started
    /// on). `handler` runs on the pipeline's thread — the event thread —
    /// with the tick's vsync timestamp in host uptime seconds, the same
    /// clock as frame arrival times. Returns nil when no tick source can be
    /// made (no display, display-link failure); the pipeline then falls
    /// back to its timers for the gesture.
    func startTicks(handler: @escaping (TimeInterval) -> Void) -> DisplayTickSource?
}

// MARK: - CVDisplayLink ticker

/// The real tick source: a `CVDisplayLink` per display, created on first
/// use and cached, started at gesture start for the display under the
/// cursor and stopped when the pipeline goes idle — no idle wakeups.
///
/// `CVDisplayLink` is used rather than `CADisplayLink` because the latter
/// only reached macOS in 14 (via `NSScreen`/`NSView`) and this package's
/// floor is 13; the CV API still works on current releases.
///
/// Threading: the display link fires its callback on its own high-priority
/// thread. The callback only reads the tick's timestamp and hops to the
/// event thread (`EventThread.perform`), where the handler — and all
/// pipeline state — lives. The timestamp is the callback's own vsync time
/// (`inNow`), converted from Mach host time to the uptime seconds the
/// pipeline uses for frame arrival — not the moment the block eventually
/// runs, so ticks stay phase-locked whatever the scheduling jitter.
/// `startTicks`/`invalidate` are called on the event thread.
public final class CVDisplayLinkTicker: DisplayTicking {
    /// One cached display link. The handler is swapped per gesture under
    /// the lock, which is also what stops a late callback from reaching a
    /// handler that was invalidated.
    private final class Link {
        let displayLink: CVDisplayLink
        let eventThread: EventThread
        let lock = NSLock()
        var handler: ((TimeInterval) -> Void)?

        init(displayLink: CVDisplayLink, eventThread: EventThread) {
            self.displayLink = displayLink
            self.eventThread = eventThread
        }

        deinit {
            CVDisplayLinkStop(displayLink)
        }

        /// Called on the display link's thread.
        func fire(at timestamp: TimeInterval) {
            lock.lock()
            let handler = self.handler
            lock.unlock()
            guard let handler else {
                return
            }
            eventThread.perform {
                handler(timestamp)
            }
        }
    }

    private final class Subscription: DisplayTickSource {
        private let link: Link
        private var active = true

        init(link: Link) {
            self.link = link
        }

        func invalidate() {
            guard active else {
                return
            }
            active = false
            link.lock.lock()
            link.handler = nil
            link.lock.unlock()
            CVDisplayLinkStop(link.displayLink)
        }
    }

    private let eventThread: EventThread
    private var links: [CGDirectDisplayID: Link] = [:]

    public init(eventThread: EventThread) {
        self.eventThread = eventThread
    }

    public func startTicks(handler: @escaping (TimeInterval) -> Void) -> DisplayTickSource? {
        let displayID = DisplayGeometry.displayUnderCursor()
        guard let link = link(for: displayID) else {
            return nil
        }

        link.lock.lock()
        link.handler = handler
        link.lock.unlock()

        let result = CVDisplayLinkStart(link.displayLink)
        guard result == kCVReturnSuccess else {
            link.lock.lock()
            link.handler = nil
            link.lock.unlock()
            os_log(
                "CVDisplayLinkStart failed for display %{public}u (%{public}d); using timers for this gesture",
                log: RawTouchLog.scroll,
                type: .error,
                displayID,
                result
            )
            return nil
        }
        return Subscription(link: link)
    }

    private func link(for displayID: CGDirectDisplayID) -> Link? {
        if let link = links[displayID] {
            return link
        }

        var displayLink: CVDisplayLink?
        let created = CVDisplayLinkCreateWithCGDisplay(displayID, &displayLink)
        guard created == kCVReturnSuccess, let displayLink else {
            os_log(
                "CVDisplayLinkCreateWithCGDisplay failed for display %{public}u (%{public}d)",
                log: RawTouchLog.scroll,
                type: .error,
                displayID,
                created
            )
            return nil
        }

        let link = Link(displayLink: displayLink, eventThread: eventThread)
        let context = Unmanaged.passUnretained(link).toOpaque()
        let installed = CVDisplayLinkSetOutputCallback(
            displayLink,
            { _, now, _, _, _, context in
                guard let context else {
                    return kCVReturnSuccess
                }
                let link = Unmanaged<Link>.fromOpaque(context).takeUnretainedValue()
                link.fire(at: HostClock.seconds(fromHostTime: now.pointee.hostTime))
                return kCVReturnSuccess
            }, context)
        guard installed == kCVReturnSuccess else {
            return nil
        }

        // The cache keeps `link` alive for as long as its callback can fire
        // (the link is stopped in `deinit` before it can go away).
        links[displayID] = link
        return link
    }

}

// MARK: - Host clock

/// Mach host time ↔ the uptime seconds the pipeline runs on.
/// `ProcessInfo.systemUptime` is `mach_absolute_time` scaled by the
/// timebase, so a display link's `hostTime` converts to the same axis as
/// frame arrival stamps and posted event timestamps. Pinned by a test.
public enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func seconds(fromHostTime hostTime: UInt64) -> TimeInterval {
        Double(hostTime) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }

    /// The current host time in the same seconds.
    public static func now() -> TimeInterval {
        seconds(fromHostTime: mach_absolute_time())
    }
}
