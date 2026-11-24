// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import RawTouchCore

/// When to ask, and asking: both repositories' latest releases, as one
/// result. Notify-only — nothing is downloaded or installed, and what to
/// show is `UpdateNotice.notices`, not this.
///
/// Automatic checks run `firstCheckDelay` after `start()` and then every
/// `checkInterval`, each one only if `checksAutomatically()` says so when it
/// comes due, so turning the setting off stops the next one without
/// rescheduling anything. A manual check always runs.
///
/// One check at a time: asking while one is in flight joins it (a manual
/// ask marks it manual, so its outcome is shown). Main-queue only.
public final class UpdateChecker {
    public enum Kind: Equatable {
        case automatic
        case manual
    }

    /// Long enough after launch to stay out of a login's way.
    public static let firstCheckDelay: TimeInterval = 10
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    private let source: ReleaseSource
    private let scheduler: TimerScheduling
    private let checksAutomatically: () -> Bool
    private let onResult: (Result<LatestReleases, Error>, Kind) -> Void

    private var timer: ScheduledTimer?
    private var inFlight: Kind?
    /// Bumped by `stop()`, so a check that answers afterwards is dropped.
    private var generation = 0

    public init(
        source: ReleaseSource,
        scheduler: TimerScheduling,
        checksAutomatically: @escaping () -> Bool,
        onResult: @escaping (Result<LatestReleases, Error>, Kind) -> Void
    ) {
        self.source = source
        self.scheduler = scheduler
        self.checksAutomatically = checksAutomatically
        self.onResult = onResult
    }

    public func start() {
        stop()
        timer = scheduler.scheduleTimer(interval: Self.firstCheckDelay, repeats: false) { [weak self] in
            guard let self else {
                return
            }
            automaticCheckDue()
            timer = scheduler.scheduleTimer(interval: Self.checkInterval, repeats: true) { [weak self] in
                self?.automaticCheckDue()
            }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        inFlight = nil
        generation += 1
    }

    private func automaticCheckDue() {
        guard checksAutomatically() else {
            return
        }
        check(.automatic)
    }

    public func check(_ kind: Kind) {
        guard inFlight == nil else {
            if kind == .manual {
                inFlight = .manual
            }
            return
        }
        inFlight = kind
        let generation = generation
        var app: Result<LatestRelease?, Error>?
        var module: Result<LatestRelease?, Error>?
        let finish = { [weak self] in
            guard let self, let app, let module, generation == self.generation, let joined = inFlight else {
                return
            }
            inFlight = nil
            onResult(Result { LatestReleases(app: try app.get(), module: try module.get()) }, joined)
        }
        source.latestRelease(of: .app) { result in
            app = result
            finish()
        }
        source.latestRelease(of: .module) { result in
            module = result
            finish()
        }
    }
}

/// `TimerScheduling` on the main run loop, for the update check's
/// day-long cadence. Timers are given a tenth of their interval as
/// tolerance: nothing about a daily check needs to be punctual, and the
/// system can then batch the wake-up with others.
public final class MainRunLoopTimerScheduler: TimerScheduling {
    private final class Handle: ScheduledTimer {
        let timer: Timer

        init(_ timer: Timer) {
            self.timer = timer
        }

        func invalidate() {
            timer.invalidate()
        }
    }

    public init() {}

    public func scheduleTimer(
        interval: TimeInterval,
        repeats: Bool,
        handler: @escaping () -> Void
    ) -> ScheduledTimer? {
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in handler() }
        timer.tolerance = interval / 10
        RunLoop.main.add(timer, forMode: .common)
        return Handle(timer)
    }
}
