// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation

/// A silence deadline that activity pushes back without a timer per event:
/// activity only records its time, one one-shot timer is armed for the
/// whole timeout, and a firing that finds recent activity re-arms itself
/// for what remains. The deadline expires once `timeout` has passed with no
/// activity at all.
struct LazyDeadline {
    let timeout: TimeInterval

    /// Host time of the latest activity.
    var lastActivity: TimeInterval = 0

    private var timer: ScheduledTimer?

    init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    var isArmed: Bool {
        timer != nil
    }

    /// Arms the one-shot for the whole timeout. `handler` runs when it
    /// fires and must call `fire(now:scheduler:handler:)` with itself.
    mutating func arm(on scheduler: TimerScheduling, handler: @escaping () -> Void) {
        timer = scheduler.scheduleTimer(interval: timeout, repeats: false, handler: handler)
    }

    mutating func disarm() {
        timer?.invalidate()
        timer = nil
    }

    /// The one-shot fired. Returns how long the silence has lasted once it
    /// has reached `timeout`; otherwise re-arms for the remainder and
    /// returns nil.
    mutating func fire(
        now: TimeInterval,
        scheduler: TimerScheduling,
        handler: @escaping () -> Void
    ) -> TimeInterval? {
        timer = nil
        let silence = now - lastActivity
        guard silence >= timeout else {
            timer = scheduler.scheduleTimer(interval: timeout - silence, repeats: false, handler: handler)
            return nil
        }
        return silence
    }
}
