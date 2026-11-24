// MIT License
// Copyright (c) 2026 RawTouch contributors

import ApplicationServices
import Foundation
import os.log

/// The service lifecycle, once: single-instance lock → configuration →
/// device manager → live-reload watcher → posting-readiness poll → shutdown
/// that releases the host lease.
///
/// It sits below the app's `AppModel` rather than inside it, so that what
/// RawTouch *is* — the lease, the stream, the configuration and their
/// lifetimes — can be read and tested without a window, a menu or a run
/// loop full of SwiftUI. What the app decides stays in the app, expressed
/// as the outcome `start()` returns and the callbacks it reports through.
///
/// Posting readiness lives here for the same reason: the host lease must not
/// be held by a process that cannot post events. Without Accessibility every
/// synthesized scroll is dropped by the window server, and a lease held
/// through that suppresses the firmware's own wheel scrolling — a fresh
/// install would *take away* the scrolling the keyboard already did on its
/// own. So the trust check is polled here, and its result is pushed into
/// the manager as `setPostingReady(_:)`; the user's `enabled` preference is
/// never touched. Polling continues after the grant lands
/// (slower), because a grant can be revoked in System Settings at any time
/// and the lease has to be released when it is.
///
/// Everything is injectable — paths, the manager factory, the trust check and
/// its cadences — so the tests drive the whole thing against a fake manager
/// without touching IOKit or the Accessibility API.
///
/// Main-queue only, like the manager and the watcher it owns.
public final class RawTouchService {
    /// Why `start()` brought nothing up: the single-instance lock could not
    /// be had.
    public enum StartFailure: Error, Equatable {
        /// Another instance holds the lock: two processes consuming the
        /// frames would each synthesize a full set of gestures (double
        /// scroll). The PID is whatever the lock file records, when it
        /// records one — informational only.
        case alreadyRunning(holderPID: pid_t?)
        /// The lock file could not be opened at all: a permissions problem
        /// to fix, not a copy of the app to go and quit.
        case lockUnavailable(String)
    }

    /// What a successful `start()` has to report.
    public struct Started {
        /// The configuration file failed to load: the defaults are running
        /// instead and the manager has already been told (so `status`
        /// carries the error), and nothing is written to the file until a
        /// reload decodes it (see `save(_:)`). The app surfaces it.
        public let configurationError: Error?
    }

    public typealias ManagerFactory = (_ configuration: RawTouchConfiguration) -> RawTouchDeviceManaging

    /// How often the posting-readiness check runs while it is false: often
    /// enough that granting Accessibility feels like it took effect at once.
    public static let defaultUntrustedPollInterval: TimeInterval = 1

    /// How often it runs once posting is ready. Slower — the answer rarely
    /// changes — but never zero: a grant revoked in System Settings has to
    /// release the keyboard's lease, or the pads go dead.
    public static let defaultTrustedPollInterval: TimeInterval = 5

    /// Where the configuration lives (and is watched).
    public let configPath: URL

    private let lockPath: URL
    private let makeManager: ManagerFactory
    private let onStatusChange: (RawTouchStatus) -> Void
    private let onConfigurationChange: (RawTouchConfiguration) -> Void
    private let onConfigurationError: (Error) -> Void

    /// Whether scroll events can be posted. `AXIsProcessTrusted()` by
    /// default — never the prompting variant, which would bind the grant to
    /// whatever binary raised it (the "accessibility loop"; see CONTRIBUTING.md).
    private let trustCheck: () -> Bool
    private let untrustedPollInterval: TimeInterval
    private let trustedPollInterval: TimeInterval
    private let onPostingReadyChange: (Bool) -> Void
    /// Called on every tick of the readiness poll, changed or not, for a
    /// caller with other system state to re-read at the same cadence.
    private let onReadinessPoll: () -> Void

    private var instanceLock: InstanceLock?
    private var watcher: ConfigFileWatcher?
    /// Why the file on disk could not be decoded, while it cannot. The
    /// configuration in memory is then the defaults (or the last good
    /// file) plus any edits since, not what the user wrote, so nothing is
    /// saved over it — see `save(_:)`.
    private var unreadableFile: String?
    private var readinessTimer: DispatchSourceTimer?
    private var didLogMissingPostingReadiness = false
    private var didShutdown = false

    /// Whether RawTouch can post the scroll events it synthesizes, as of the
    /// last check. False before `start()`. While it is false the manager is
    /// told not to acquire a lease, so the keyboard keeps scrolling on its own.
    public private(set) var postingReady = false

    /// The device manager, once started.
    private var manager: RawTouchDeviceManaging?

    /// The configuration in effect — what was loaded at start, plus every
    /// edit applied since, from the file or from a UI.
    public private(set) var configuration = RawTouchConfiguration()

    /// The manager's current status snapshot, or an empty one before start.
    public var status: RawTouchStatus {
        manager?.status ?? RawTouchStatus()
    }

    /// Whether the stack is up (`start()` succeeded and no shutdown yet).
    public var isRunning: Bool {
        manager != nil && !didShutdown
    }

    public init(
        configPath: URL = RawTouchConfiguration.defaultPath,
        lockPath: URL = InstanceLock.defaultPath,
        makeManager: @escaping ManagerFactory = { RawTouchDeviceManager(configuration: $0) },
        trustCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
        untrustedPollInterval: TimeInterval = defaultUntrustedPollInterval,
        trustedPollInterval: TimeInterval = defaultTrustedPollInterval,
        onStatusChange: @escaping (RawTouchStatus) -> Void = { _ in },
        onConfigurationChange: @escaping (RawTouchConfiguration) -> Void = { _ in },
        onConfigurationError: @escaping (Error) -> Void = { _ in },
        onReadinessPoll: @escaping () -> Void = {},
        onPostingReadyChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.configPath = configPath
        self.lockPath = lockPath
        self.makeManager = makeManager
        self.trustCheck = trustCheck
        self.untrustedPollInterval = untrustedPollInterval
        self.trustedPollInterval = trustedPollInterval
        self.onStatusChange = onStatusChange
        self.onConfigurationChange = onConfigurationChange
        self.onConfigurationError = onConfigurationError
        self.onReadinessPoll = onReadinessPoll
        self.onPostingReadyChange = onPostingReadyChange
    }

    deinit {
        shutdown()
    }

    // MARK: - Lifecycle

    /// Brings the stack up: lock → configuration → manager → watcher.
    ///
    /// Throws a `StartFailure` when another instance holds the lock or the
    /// lock file cannot be opened, and nothing at all has been started in
    /// either case. A configuration that
    /// fails to load is *not* fatal here — the defaults run, the manager is
    /// told, and the error comes back in `Started` for the caller to act on.
    @discardableResult
    public func start() throws(StartFailure) -> Started {
        guard manager == nil, !didShutdown else {
            return Started(configurationError: nil)
        }

        let acquired: InstanceLock?
        do {
            acquired = try InstanceLock.acquire(at: lockPath)
        } catch {
            throw StartFailure.lockUnavailable(String(describing: error))
        }
        guard let lock = acquired else {
            throw StartFailure.alreadyRunning(holderPID: InstanceLock.holderPID(at: lockPath))
        }
        instanceLock = lock

        var configurationError: Error?
        do {
            configuration = try RawTouchConfiguration.load(from: configPath)
        } catch {
            configurationError = error
            unreadableFile = String(describing: error)
            os_log(
                "config.json could not be read; running on defaults and saving nothing until it is fixed: %{public}@",
                log: RawTouchLog.configuration, type: .error, String(describing: error)
            )
        }

        let manager = makeManager(configuration)
        // Set before start() per the manager's contract: `onStatusChange`
        // does not replay the initial snapshot.
        manager.onStatusChange = { [weak self] status in
            self?.onStatusChange(status)
        }
        self.manager = manager

        // Readiness before start(), for the same reason: a device that is
        // already plugged in is validated the moment the HID manager opens,
        // and a process that cannot post must not acquire its lease.
        postingReady = trustCheck()
        manager.setPostingReady(postingReady)
        if !postingReady {
            logMissingPostingReadinessOnce()
        }

        manager.start()

        if let unreadableFile {
            manager.reportConfigurationError(.unreadable(unreadableFile))
        }

        // Live reload: edits apply without a restart. A malformed edit is
        // reported (and surfaced through the manager's status) while the last
        // good configuration stays in effect.
        let watcher = ConfigFileWatcher(path: configPath) { [weak self] result in
            self?.handleConfigurationReload(result)
        }
        self.watcher = watcher
        watcher.start()

        startReadinessPolling()

        return Started(configurationError: configurationError)
    }

    /// Tears the stack down before the process exits: stops the watcher,
    /// releases the host lease (the manager waits for the release write), and
    /// drops the instance lock. Idempotent, and called from `deinit`.
    public func shutdown() {
        guard !didShutdown else {
            return
        }
        didShutdown = true

        watcher?.stop()
        watcher = nil
        readinessTimer?.cancel()
        readinessTimer = nil
        manager?.shutdown()
        instanceLock?.release()
        instanceLock = nil
    }

    // MARK: - Posting readiness (Accessibility)

    /// Re-runs the trust check now and reconciles everything that depends on
    /// it. Called by the poll timer, and on demand by a UI that has just sent
    /// the user to System Settings. Returns the fresh value.
    ///
    /// A change pushes into the manager (which releases or acquires the lease
    /// and interrupts the pipeline), tells the caller, and re-cadences the
    /// poll — fast while blocked, slow while healthy.
    @discardableResult
    public func refreshPostingReadiness() -> Bool {
        // Nothing to reconcile before `start()` or after `shutdown()` — and
        // re-cadencing the poll from here would resurrect a timer on a
        // service that is meant to be dead.
        guard isRunning else {
            return postingReady
        }

        let ready = trustCheck()
        guard ready != postingReady else {
            return ready
        }
        postingReady = ready

        if ready {
            didLogMissingPostingReadiness = false
            RawTouchLog.note(
                "Accessibility granted; acquiring the lease on the keyboard's touch stream (RawTouch mode)."
            )
        } else {
            logMissingPostingReadinessOnce()
        }

        manager?.setPostingReady(ready)
        onPostingReadyChange(ready)
        startReadinessPolling()
        return ready
    }

    /// (Re)schedules the readiness poll at the cadence the current state
    /// wants. Cancelling and rebuilding is fine: the source is only ever
    /// touched from the main queue, including from its own handler.
    private func startReadinessPolling() {
        readinessTimer?.cancel()

        let interval = postingReady ? trustedPollInterval : untrustedPollInterval
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.refreshPostingReadiness()
            self?.onReadinessPoll()
        }
        timer.resume()
        readinessTimer = timer
    }

    /// Says it once per outage: the menu is not always open, and the log is
    /// where a user who is already looking will look. No "restart
    /// RawTouch" — the poll picks the grant up on its own.
    private func logMissingPostingReadinessOnce() {
        guard !didLogMissingPostingReadiness else {
            return
        }
        didLogMissingPostingReadiness = true
        RawTouchLog.note(
            """
            Accessibility permission is not granted, so scroll events cannot be posted. RawTouch is not acquiring \
            a lease on the keyboard's touch stream — it keeps scrolling on its own (Standard mode) rather than \
            being silenced by a host that can do nothing with the frames. Grant it in System Settings → Privacy & \
            Security → Accessibility; RawTouch takes over within a second of the grant landing, no restart needed.
            """
        )
    }

    // MARK: - Configuration

    /// Applies an edit made *here* (a settings UI): straight to the manager,
    /// so scrolling reflects it on the next frame. Writing it is `save(_:)`,
    /// which the caller does on its own schedule (a slider drag is one
    /// write, not hundreds).
    public func apply(configuration newConfiguration: RawTouchConfiguration) {
        configuration = newConfiguration
        manager?.apply(configuration: newConfiguration)
        // The manager clears its error on any apply, but an edit made here
        // does not fix the file: only a reload that decodes does.
        if let unreadableFile {
            manager?.reportConfigurationError(.unreadable(unreadableFile))
        }
    }

    /// Writes a configuration to the file — every write RawTouch makes goes
    /// through here. The watcher does the writing, so it knows the bytes as
    /// its own and drops their echo: a reload of an older save, arriving a
    /// debounce later, must not undo an edit made since. Returns whether it
    /// was written; a failure is reported as one, not as a file that could
    /// not be read — the file is intact, the edit is what was lost.
    ///
    /// Nothing is written while the file could not be decoded: what is in
    /// memory then is not what the user wrote, and saving it would replace
    /// their settings with the defaults. Edits still apply, and the status
    /// keeps the error, which is how the app says they are not being kept.
    @discardableResult
    public func save(_ newConfiguration: RawTouchConfiguration) -> Bool {
        guard unreadableFile == nil, let watcher else {
            return false
        }
        do {
            try watcher.save(newConfiguration)
            return true
        } catch {
            os_log(
                "Could not save config.json: %{public}@", log: RawTouchLog.configuration, type: .error,
                String(describing: error))
            manager?.reportConfigurationError(.unsaved(String(describing: error)))
            onConfigurationError(error)
            return false
        }
    }

    /// Handles one delivery from the config-file watcher — an edit made
    /// outside, since the watcher drops the echoes of `save(_:)`: applies a
    /// good configuration to the manager (which also clears any recorded
    /// error), reports a bad one, and tells the caller either way. Also the
    /// seam the app's tests drive the reload path through.
    public func handleConfigurationReload(_ result: Result<RawTouchConfiguration, Error>) {
        switch result {
        case .success(let newConfiguration):
            let recovered = unreadableFile != nil
            unreadableFile = nil
            configuration = newConfiguration
            manager?.apply(configuration: newConfiguration)
            onConfigurationChange(newConfiguration)
            if recovered {
                os_log("config.json is readable again; saving resumes", log: RawTouchLog.configuration, type: .default)
            }
        case .failure(let error):
            let message = String(describing: error)
            unreadableFile = message
            os_log(
                "config.json could not be read; keeping the last good configuration and saving nothing until it is fixed: %{public}@",
                log: RawTouchLog.configuration, type: .error, message
            )
            manager?.reportConfigurationError(.unreadable(message))
            onConfigurationError(error)
        }
    }
}
