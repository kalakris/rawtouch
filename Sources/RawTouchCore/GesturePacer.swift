// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import os.log

/// Where the gesture in flight gets its clock from: the display link of the
/// display under the cursor while one runs, or else frames as they arrive
/// and a free-running momentum timer for the coast.
///
/// The link runs from a gesture's first paced frame until the pipeline says
/// there is nothing left to pace (`stopIfIdle`). A gesture that could not
/// start a link, or whose link went silent for `displayTickTimeout`, runs
/// without one until it ends; the next gesture tries again. Ticks and
/// watchdog firings that belong to a subscription that has since ended are
/// ignored on arrival.
///
/// Event-thread state, like the pipeline that owns it.
final class GesturePacer {
    /// A link that goes this long without a tick has stopped — its display
    /// was unplugged, slept, or closed — and the gesture stops waiting for
    /// it. Six frames even at 60 Hz, and short enough that a coast or a
    /// drag stalls no longer than a dropped frame burst.
    static let displayTickTimeout: TimeInterval = 0.100

    private static let momentumTimerInterval: TimeInterval = 1.0 / 120.0

    private enum Pacing {
        /// Nothing is being paced; the next paced frame starts the link.
        case off
        /// The display link paces the gesture: its scroll frames are
        /// resampled onto the ticks, and its coast rides them.
        case ticking(DisplayTickSource)
        /// This gesture could not start a link, or its link stopped
        /// ticking: frames go to the engine as they arrive and the coast
        /// runs on the momentum timer, until the gesture ends.
        case unavailable
    }

    private let displayTicker: DisplayTicking?
    private let scheduler: TimerScheduling
    private let now: () -> TimeInterval

    private var pacing = Pacing.off

    /// Bumped per subscription so a tick (or a watchdog) belonging to a
    /// subscription that ended meanwhile is ignored on arrival.
    private var generation = 0

    /// The running link's watchdog: each tick (and the link's start) is
    /// its activity.
    private var watchdog = LazyDeadline(timeout: GesturePacer.displayTickTimeout)
    private var momentumTimer: ScheduledTimer?

    /// One vsync of the running link, with its timestamp.
    var onTick: ((TimeInterval) -> Void)?
    /// The running link went silent and was let go; the gesture continues
    /// unpaced.
    var onLinkLost: (() -> Void)?
    /// One step of the free-running momentum timer.
    var onMomentumTimer: (() -> Void)?

    /// `displayTicker` nil means never paced.
    init(displayTicker: DisplayTicking?, scheduler: TimerScheduling, now: @escaping () -> TimeInterval) {
        self.displayTicker = displayTicker
        self.scheduler = scheduler
        self.now = now
    }

    var isDisplayPaced: Bool {
        if case .ticking = pacing {
            return true
        }
        return false
    }

    /// Whether this gesture's scroll frames are paced by the display link,
    /// starting it at the gesture's first scroll frame. False — no ticker,
    /// the link could not be started, or it stopped ticking — means the
    /// caller feeds the engine directly and momentum runs on its timer; a
    /// gesture that found no link does not ask again before it ends.
    func startIfNeeded() -> Bool {
        guard case .off = pacing, let displayTicker else {
            return isDisplayPaced
        }

        generation += 1
        let generation = generation
        guard
            let source = displayTicker.startTicks(handler: { [weak self] timestamp in
                guard let self, self.generation == generation, isDisplayPaced else {
                    return
                }
                watchdog.lastActivity = now()
                onTick?(timestamp)
            })
        else {
            os_log(
                "No display link for this gesture; feeding the engine per sample with timer-driven momentum",
                log: RawTouchLog.scroll,
                type: .info
            )
            pacing = .unavailable
            return false
        }
        pacing = .ticking(source)
        watchdog.lastActivity = now()
        watchdog.arm(on: scheduler, handler: watchdogHandler(generation: generation))
        return true
    }

    private func watchdogHandler(generation: Int) -> () -> Void {
        { [weak self] in
            self?.handleWatchdog(generation: generation)
        }
    }

    /// The display link's watchdog: while ticks keep coming it re-arms for
    /// the remainder. A link silent for `displayTickTimeout` is let go and
    /// the gesture carries on without it (`onLinkLost`).
    private func handleWatchdog(generation: Int) {
        guard generation == self.generation, isDisplayPaced,
            let silence = watchdog.fire(
                now: now(), scheduler: scheduler, handler: watchdogHandler(generation: generation))
        else {
            return
        }
        os_log(
            "Display link silent for %{public}.0f ms; finishing the gesture on timers",
            log: RawTouchLog.scroll,
            type: .info,
            silence * 1000
        )
        stopTicks()
        pacing = .unavailable
        onLinkLost?()
    }

    private func stopTicks() {
        if case .ticking(let source) = pacing {
            source.invalidate()
        }
        watchdog.disarm()
        pacing = .off
    }

    /// Pacing lasts only while there is something to pace. The display
    /// link runs while it has a tracked touch or a coast to drive — no idle
    /// wakeups; a gesture that went without it stays without it until the
    /// gesture is over.
    func stopIfIdle(tracking: Bool, coasting: Bool, gestureActive: Bool) {
        switch pacing {
        case .ticking where !tracking && !coasting,
            .unavailable where !gestureActive:
            stopTicks()
        case .off, .ticking, .unavailable:
            break
        }
    }

    /// Momentum rides the display ticks while they run; the free-running
    /// timer is the fallback for gestures without a display link (and for
    /// resampling off).
    func updateMomentumTimer(coasting: Bool) {
        if coasting, !isDisplayPaced {
            guard momentumTimer == nil else {
                return
            }
            momentumTimer = scheduler.scheduleTimer(
                interval: Self.momentumTimerInterval,
                repeats: true
            ) { [weak self] in
                self?.onMomentumTimer?()
            }
        } else {
            momentumTimer?.invalidate()
            momentumTimer = nil
        }
    }

    /// The gesture is over: the momentum timer and the display link stop.
    func stop() {
        momentumTimer?.invalidate()
        momentumTimer = nil
        stopTicks()
    }
}
