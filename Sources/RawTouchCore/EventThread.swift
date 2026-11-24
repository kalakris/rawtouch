// MIT License
// Copyright (c) 2026 RawTouch contributors
// Derived from LinearMouse — Copyright (c) 2021-2026 LinearMouse (MIT).
// Trimmed: no `onWillStop` hook (nothing restarts the thread here) and the
// singleton is replaced by an owned instance.

import Foundation

/// A timer that can be cancelled from any thread.
public protocol ScheduledTimer: AnyObject {
    func invalidate()
}

/// Schedules work on the thread that owns the scroll pipeline. Injectable so
/// the pipeline's timer-driven behavior (momentum ticks, the stale-touch
/// watchdog) is unit-testable without a run loop.
public protocol TimerScheduling: AnyObject {
    func scheduleTimer(
        interval: TimeInterval,
        repeats: Bool,
        handler: @escaping () -> Void
    ) -> ScheduledTimer?
}

private final class EventThreadResultBox<Value> {
    var value: Value?
}

/// Manages a dedicated background thread with its own RunLoop for CGEvent
/// processing.
///
/// All pipeline state access happens on this thread. Use ``perform(_:)`` to
/// dispatch work from other threads — any thread, while the owner starts or
/// stops it: the thread and its run loop are read under a lock — and
/// ``scheduleTimer(interval:repeats:handler:)`` to create timers that fire on
/// it. The IOHIDManager is scheduled on this thread's run loop too, so the
/// ~100 Hz input-report callback lands directly where the state lives.
public final class EventThread: TimerScheduling {
    /// The RunLoop of the background thread. Nil when the thread is not
    /// running. Exposed so the IOHIDManager can be scheduled on it.
    public var runLoop: RunLoop? {
        lock.lock()
        defer { lock.unlock() }
        return lockedRunLoop
    }

    /// Written on the event thread as it starts and stops, read from any
    /// thread that hands work over — the display link's among them.
    private let lock = NSLock()
    private var lockedRunLoop: RunLoop?
    private var lockedThread: Thread?
    private let runLoopReady = DispatchSemaphore(value: 0)

    public init() {}

    /// Whether the current thread is the event processing thread.
    public var isCurrent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return Thread.current === lockedThread
    }

    private func setThread(_ thread: Thread?, runLoop: RunLoop?) {
        lock.lock()
        lockedThread = thread
        lockedRunLoop = runLoop
        lock.unlock()
    }

    // MARK: - Lifecycle

    public func start() {
        guard runLoop == nil else {
            return
        }

        let thread = Thread { [weak self] in
            guard let self else {
                return
            }
            let rl = RunLoop.current
            // Keep the RunLoop alive even without event sources.
            rl.add(Port(), forMode: .common)
            self.setThread(Thread.current, runLoop: rl)
            self.runLoopReady.signal()
            CFRunLoopRun()
        }
        thread.name = "io.github.kalakris.RawTouch.event-thread"
        thread.qualityOfService = .userInteractive
        thread.start()

        runLoopReady.wait()
    }

    /// Stop the event thread synchronously: all previously queued blocks
    /// (e.g. timer invalidations, the gesture-close on shutdown) complete
    /// first.
    public func stop() {
        precondition(!isCurrent, "EventThread.stop() must not be called from the event thread")

        guard let cfRunLoop = runLoop?.getCFRunLoop() else {
            return
        }

        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(cfRunLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            Thread.current.cancel()
            self?.setThread(nil, runLoop: nil)
        }
        CFRunLoopPerformBlock(cfRunLoop, CFRunLoopMode.commonModes.rawValue) {
            CFRunLoopStop(cfRunLoop)
            done.signal()
        }
        CFRunLoopWakeUp(cfRunLoop)

        done.wait()
    }

    // MARK: - Dispatch

    /// Schedule a block to run on the event thread.
    /// Returns `false` if the event thread is not running (block is not enqueued).
    @discardableResult
    public func perform(_ block: @escaping () -> Void) -> Bool {
        guard let cfRunLoop = runLoop?.getCFRunLoop() else {
            return false
        }
        CFRunLoopPerformBlock(cfRunLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(cfRunLoop)
        return true
    }

    /// Execute a block on the event thread and wait for the result.
    /// Returns `nil` if the event thread is not running.
    public func performAndWait<T>(_ block: @escaping () -> T) -> T? {
        if isCurrent {
            return block()
        }

        guard let cfRunLoop = runLoop?.getCFRunLoop() else {
            return nil
        }

        let done = DispatchSemaphore(value: 0)
        let result = EventThreadResultBox<T>()
        CFRunLoopPerformBlock(cfRunLoop, CFRunLoopMode.commonModes.rawValue) {
            result.value = block()
            done.signal()
        }
        CFRunLoopWakeUp(cfRunLoop)
        done.wait()
        return result.value
    }

    // MARK: - Timer

    /// Create a repeating or one-shot timer on the event thread's RunLoop.
    /// Returns `nil` if the event thread is not running.
    public func scheduleTimer(
        interval: TimeInterval,
        repeats: Bool,
        handler: @escaping () -> Void
    ) -> ScheduledTimer? {
        if isCurrent {
            return scheduleTimerOnCurrentThread(interval: interval, repeats: repeats, handler: handler)
        }

        guard
            let timer = performAndWait({
                self.scheduleTimerOnCurrentThread(interval: interval, repeats: repeats, handler: handler)
            })
        else {
            return nil
        }
        return timer
    }

    private func scheduleTimerOnCurrentThread(
        interval: TimeInterval,
        repeats: Bool,
        handler: @escaping () -> Void
    ) -> ScheduledTimer? {
        guard let runLoop else {
            return nil
        }

        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in
            handler()
        }
        runLoop.add(timer, forMode: .common)
        return EventThreadTimer(timer: timer, eventThread: self)
    }
}

// MARK: - EventThreadTimer

/// Lightweight wrapper around `Timer` that ensures invalidation happens on the
/// correct thread. On `deinit` the timer is invalidated automatically.
public final class EventThreadTimer: ScheduledTimer {
    private var timer: Timer?
    private weak var eventThread: EventThread?

    init(timer: Timer, eventThread: EventThread) {
        self.timer = timer
        self.eventThread = eventThread
    }

    deinit {
        invalidate()
    }

    /// Invalidate the underlying timer. Safe to call from any thread and
    /// idempotent.
    public func invalidate() {
        guard let timer else {
            return
        }
        self.timer = nil

        if let eventThread, eventThread.isCurrent {
            timer.invalidate()
        } else if let eventThread {
            eventThread.perform {
                timer.invalidate()
            }
        }
        // If eventThread is nil (already deallocated), the RunLoop is gone
        // and the timer is implicitly dead.
    }

}
