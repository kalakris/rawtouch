// MIT License
// Copyright (c) 2026 RawTouch contributors

import AppKit
import ApplicationServices
import Combine
import Foundation
import RawTouchCore
import SwiftUI
import os.log

/// The menubar app's model: drives the service lifecycle through
/// `RawTouchService` — the instance lock, `RawTouchDeviceManager` and the
/// config watcher — and republishes everything the views render as
/// `@Published` state.
///
/// What it adds to the service, all deliberate:
/// - Firmware without RawTouch-mode support and a lost instance lock
///   **surface** instead of stopping the app: one that silently vanishes
///   explains nothing.
/// - Missing Accessibility is *surfaced* — the icon and onboarding flip to
///   granted on their own. The polling itself is not this model's job: it
///   lives in `RawTouchService`, where the result decides the host lease.
///   This model only mirrors it into `axTrusted` for the views.
/// - Config edits made in the UI apply to the manager immediately but reach
///   disk on a short debounce, so a slider drag is one write, not hundreds.
///   The file stays the single source of truth: external edits flow back in
///   through the watcher, last write wins.
/// - The update check (`UpdateChecker`) keeps the latest releases it found;
///   what the menu offers is derived from them and the keyboards connected
///   now, so a keyboard plugged in later is judged without asking again.
///
/// Every system dependency is an injectable seam (trust check and request,
/// login items, manager factory, paths, intervals, release source, update
/// scheduler) so
/// the unit tests drive the whole model without IOKit, AX, launchd, the
/// network, or a running app.
///
/// All state is main-queue-only, like the manager it wraps.
public final class AppModel: ObservableObject {
    // MARK: - Published state

    /// Mirror of the manager's status snapshot.
    @Published public private(set) var status = RawTouchStatus() {
        didSet {
            regroupKeyboards()
        }
    }

    /// The current configuration — source of truth for the settings UI.
    /// Mutate through `updateConfig`/`updatePad`, never directly.
    @Published public private(set) var config = RawTouchConfiguration() {
        didSet {
            regroupKeyboards()
        }
    }

    /// The connected keyboards — one per physical keyboard, whatever it is
    /// connected by — for the menu and the settings window. Grouped once
    /// per change of `status` or `config`, the two things a grouping reads
    /// (endpoints and keys from one, names from the other); every view
    /// reads this rather than grouping again. Not published itself: it
    /// changes only together with one of them, which already is.
    public private(set) var settingsKeyboards: [RawTouchKeyboard] = []

    private func regroupKeyboards() {
        settingsKeyboards = RawTouchKeyboard.grouped(in: status, configuration: config)
    }

    /// Whether the injected Accessibility check last said we can post
    /// events — mirrored from `RawTouchService.postingReady`, which is what
    /// actually decides the host lease. Polled by the service (fast while
    /// missing, slow once granted, so a revoked grant is noticed too);
    /// refreshed on demand by onboarding.
    @Published public private(set) var axTrusted = true

    /// The product name of a connected keyboard whose firmware lacks
    /// RawTouch mode, or nil. Derived from the status, so it clears when
    /// that keyboard is unplugged — the condition is the keyboard's, not
    /// the process's.
    public var leaseUnsupportedProductName: String? {
        status.endpoints.first { $0.lease == .unsupportedFirmware }?.productName
    }

    /// Why `start()` returned false, for the alert the app shows before it
    /// terminates; nil otherwise.
    @Published public private(set) var startFailure: RawTouchService.StartFailure?

    /// Mirror of the login-item registration state: re-read after every
    /// change and on the readiness poll, since Login Items in System
    /// Settings can change it behind the app's back.
    @Published public private(set) var startAtLogin = false

    /// The last login-item registration failure, or nil — cleared once the
    /// registration state is what was asked for, however it got there.
    @Published public private(set) var loginItemError: String?

    /// What the user last asked Start at Login to be.
    private var requestedStartAtLogin = false

    /// Set by the app delegate when onboarding should open at launch; the
    /// menubar label view observes it and opens the window (only views can
    /// reach `openWindow`).
    @Published public var shouldShowOnboarding = false

    /// Where the configuration lives.
    public let configPath: URL

    /// Which keyboard the Keyboards tab is pointed at. Held here rather
    /// than in the view so the Advanced tab's latency row can show that
    /// keyboard's connections and no one else's: with two keyboards
    /// connected, a row listing every connection of both is a list, not an
    /// answer. Seeded each time the settings window opens
    /// (`seedKeyboardsSelection`) and in between moved only by the user.
    @Published public var keyboardsSelection: KeyboardsTabSelection?

    /// When the last gesture's touch lifted — the readout's age. A coast
    /// finishing updates the same gesture and leaves this alone.
    @Published public private(set) var lastGestureAt: Date?

    /// A status snapshot from the service: published, then stamped with
    /// the time when it carries a new gesture.
    private func receive(_ newStatus: RawTouchStatus) {
        let previous = status
        status = newStatus
        if let gesture = newStatus.lastGesture,
            previous.lastGesture.map({ gesture.isSameTouch(as: $0) }) != true
        {
            lastGestureAt = now()
        }
    }

    /// Pushes a status snapshot without a manager behind it, for tests of
    /// what the views derive from one.
    func receiveForTesting(_ newStatus: RawTouchStatus) {
        receive(newStatus)
    }

    // MARK: - Updates

    /// What the last successful update check found.
    @Published public private(set) var latestReleases = LatestReleases()

    /// A check the user asked for is in flight: the menu item says so and
    /// waits, should they reopen the menu before the answer is back.
    @Published public private(set) var isCheckingForUpdates = false

    /// What the menu offers to update, for this build and the keyboards
    /// connected now.
    public var updateNotices: [UpdateNotice] {
        UpdateNotice.notices(
            installedAppVersion: appVersion.shortVersion,
            releases: latestReleases,
            keyboards: settingsKeyboards
        )
    }

    /// The menu's "Check for Updates…": asks now, whatever
    /// `updates.checkAutomatically` says, and hands the answer to `present`
    /// (the app shows it as an alert).
    public func checkForUpdates(then present: @escaping (UpdateCheckReport) -> Void) {
        guard let updateChecker else {
            return
        }
        presentUpdateCheckReport = present
        isCheckingForUpdates = true
        updateChecker.check(.manual)
    }

    /// A finished check: what it found replaces what the last one did, and
    /// a failure keeps the last answer (automatic failures go no further
    /// than the log). A manual check also gets its answer.
    private func receiveUpdateCheck(_ result: Result<LatestReleases, Error>, kind: UpdateChecker.Kind) {
        switch result {
        case .success(let releases):
            os_log(
                "Latest releases: app %{public}@, module %{public}@", log: RawTouchLog.updates, type: .info,
                releases.app.map { "\($0.version)" } ?? "none", releases.module.map { "\($0.version)" } ?? "none")
            if releases != latestReleases {
                latestReleases = releases
            }
        case .failure(let error):
            os_log(
                "Update check failed: %{public}@", log: RawTouchLog.updates, type: .error, String(describing: error))
        }
        guard kind == .manual else {
            return
        }
        isCheckingForUpdates = false
        let present = presentUpdateCheckReport
        presentUpdateCheckReport = nil
        present?(
            UpdateCheckReport.report(
                for: result,
                notices: updateNotices,
                installedAppVersion: appVersion.shortVersion,
                keyboards: settingsKeyboards
            ))
    }

    /// Whether the Accessibility explainer has been shown on its own
    /// (app state, kept out of config.json: not a setting). It opens by
    /// itself on the first launch without the grant and never again,
    /// except when a grant is lost; the menu keeps the way back: a
    /// permission request repeated at every launch is nagging.
    public var onboardingWasShown: Bool {
        get { defaults.bool(forKey: Self.onboardingShownKey) }
        set { defaults.set(newValue, forKey: Self.onboardingShownKey) }
    }

    private static let onboardingShownKey = "onboardingShown"

    /// The launch-time decision, for the app delegate to call once the
    /// stack is up: open the explainer when the grant is missing and that
    /// is news, either because this is the first launch or because the app
    /// had the grant the last time it ran. The second case is a grant lost
    /// while the app was not running to notice it, such as an update that
    /// macOS treats as a different app. Someone who chose "Not Now" and
    /// never granted gets a quiet launch: the icon and the menu say it.
    public func openOnboardingAtLaunchIfNeeded() {
        guard !axTrusted, !onboardingWasShown || hadGrantAtLastRun else {
            return
        }
        onboardingWasShown = true
        shouldShowOnboarding = true
    }

    /// The grant as the previous run last saw it, read before this run
    /// records its own.
    private let hadGrantAtLastRun: Bool

    private static let accessibilityGrantedKey = "accessibilityGranted"

    // MARK: - Seams

    private let lockPath: URL
    private let saveDebounceInterval: TimeInterval
    private let trustCheck: () -> Bool
    private let trustRequest: () -> Void
    private let openAccessibilitySettings: () -> Void
    private let trustPollInterval: TimeInterval
    private let trustedPollInterval: TimeInterval
    private let loginItems: LoginItemManaging
    private let makeManager: RawTouchService.ManagerFactory
    private let defaults: UserDefaults
    private let now: () -> Date
    private let appVersion: AppVersion
    private let releaseSource: ReleaseSource
    private let updateScheduler: TimerScheduling

    // MARK: - Owned lifecycle

    /// The service lifecycle (lock, manager, watcher). Built by
    /// `start()`, because its callbacks close over this model.
    private var service: RawTouchService?
    private var updateChecker: UpdateChecker?
    private var presentUpdateCheckReport: ((UpdateCheckReport) -> Void)?
    private var pendingSave: DispatchWorkItem?
    private var didShutdown = false

    public init(
        configPath: URL = RawTouchConfiguration.defaultPath,
        lockPath: URL = InstanceLock.defaultPath,
        saveDebounceInterval: TimeInterval = 0.3,
        trustCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
        trustRequest: @escaping () -> Void = AppModel.promptForAccessibility,
        openAccessibilitySettings: @escaping () -> Void = AppModel.openAccessibilityPane,
        trustPollInterval: TimeInterval = RawTouchService.defaultUntrustedPollInterval,
        trustedPollInterval: TimeInterval = RawTouchService.defaultTrustedPollInterval,
        loginItems: LoginItemManaging = MainAppLoginItem(),
        makeManager: @escaping RawTouchService.ManagerFactory = { RawTouchDeviceManager(configuration: $0) },
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        appVersion: AppVersion = .current,
        releaseSource: ReleaseSource = GitHubReleaseSource(),
        updateScheduler: TimerScheduling = MainRunLoopTimerScheduler()
    ) {
        self.defaults = defaults
        self.now = now
        self.appVersion = appVersion
        self.releaseSource = releaseSource
        self.updateScheduler = updateScheduler
        self.configPath = configPath
        self.lockPath = lockPath
        self.saveDebounceInterval = saveDebounceInterval
        self.trustCheck = trustCheck
        self.trustRequest = trustRequest
        self.openAccessibilitySettings = openAccessibilitySettings
        self.accessibilityWasRequested = defaults.bool(forKey: Self.accessibilityRequestedKey)
        self.hadGrantAtLastRun = defaults.bool(forKey: Self.accessibilityGrantedKey)
        self.trustPollInterval = trustPollInterval
        self.trustedPollInterval = trustedPollInterval
        self.loginItems = loginItems
        self.makeManager = makeManager
    }

    // MARK: - Lifecycle

    /// Brings the whole stack up through `RawTouchService`: lock →
    /// configuration → manager → watcher. Returns false when the lock could
    /// not be taken, with `startFailure` saying why — the caller alerts and
    /// terminates; nothing else was started.
    @discardableResult
    public func start() -> Bool {
        guard service == nil, startFailure == nil else {
            return service != nil
        }

        let service = RawTouchService(
            configPath: configPath,
            lockPath: lockPath,
            makeManager: makeManager,
            trustCheck: trustCheck,
            untrustedPollInterval: trustPollInterval,
            trustedPollInterval: trustedPollInterval,
            onStatusChange: { [weak self] newStatus in
                self?.receive(newStatus)
            },
            onConfigurationChange: { [weak self] newConfig in
                // An external edit that decodes equal (the file only
                // reformatted, say) republishes nothing.
                guard let self, newConfig != config else {
                    return
                }
                config = newConfig
            },
            onReadinessPoll: { [weak self] in
                self?.refreshStartAtLogin()
            },
            onPostingReadyChange: { [weak self] ready in
                // The service owns the poll and the lease; this is only the
                // UI mirror (icon, onboarding, menu attention line). A grant
                // that was there and is gone (an update re-signed the app,
                // or the user revoked it) reopens the explainer: that is
                // the one moment its instructions are news.
                guard let self else {
                    return
                }
                if axTrusted, !ready {
                    shouldShowOnboarding = true
                }
                axTrusted = ready
                noteTrust(ready)
            }
        )

        do {
            // A configuration that failed to load is not fatal here: the
            // service is running on defaults and has already recorded the
            // error on the manager's status.
            _ = try service.start()
        } catch {
            startFailure = error
            return false
        }

        self.service = service
        config = service.configuration
        status = service.status

        requestedStartAtLogin = loginItems.isEnabled
        startAtLogin = requestedStartAtLogin
        axTrusted = service.postingReady
        noteTrust(axTrusted)

        // Read at each due time rather than now, so the setting stops the
        // next automatic check without anything being rescheduled.
        let updateChecker = UpdateChecker(
            source: releaseSource,
            scheduler: updateScheduler,
            checksAutomatically: { [weak self] in self?.config.updates.checkAutomatically ?? false },
            onResult: { [weak self] result, kind in self?.receiveUpdateCheck(result, kind: kind) }
        )
        updateChecker.start()
        self.updateChecker = updateChecker

        return true
    }

    /// Tears everything down before the process exits, on every quit path
    /// (menu item and `applicationWillTerminate` both call it; idempotent).
    /// Flushes any pending save, then releases the lease and the lock.
    public func shutdownForQuit() {
        guard !didShutdown else {
            return
        }
        didShutdown = true

        flushPendingSave()
        updateChecker?.stop()
        presentUpdateCheckReport = nil
        service?.shutdown()
    }

    // MARK: - Configuration editing

    /// The one mutation path for the settings UI: applies to the manager
    /// immediately (scrolling reflects the change on the next frame) and
    /// saves on a debounce (a slider drag becomes one disk write).
    public func updateConfig(_ mutate: (inout RawTouchConfiguration) -> Void) {
        var newConfig = config
        mutate(&newConfig)
        guard newConfig != config else {
            return
        }
        config = newConfig
        service?.apply(configuration: newConfig)
        scheduleSave()
    }

    /// A SwiftUI binding into the configuration, routed through
    /// `updateConfig` so every control edits, applies and saves the same way.
    public func binding<Value>(
        _ keyPath: WritableKeyPath<RawTouchConfiguration, Value>
    ) -> Binding<Value> {
        Binding(
            get: { self.config[keyPath: keyPath] },
            set: { newValue in self.updateConfig { $0[keyPath: keyPath] = newValue } }
        )
    }

    // MARK: - Config file watching

    /// Hands a watcher delivery to the service, which applies a good
    /// configuration to the manager or reports a bad one, and calls back
    /// into the `onConfigurationChange` closure installed in `start()` —
    /// which republishes `config` only when the decoded value actually
    /// differs. Our own saves never come back this way: the watcher wrote
    /// them and drops their echo. Internal so the tests can drive the
    /// reload path without the file system.
    func handleConfigFileChange(_ result: Result<RawTouchConfiguration, Error>) {
        service?.handleConfigurationReload(result)
    }

    // MARK: - Saving (debounced)

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            pendingSave = nil
            persist()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDebounceInterval, execute: work)
    }

    private func flushPendingSave() {
        guard let pendingSave else {
            return
        }
        pendingSave.cancel()
        self.pendingSave = nil
        persist()
    }

    /// Through the service, never straight to the file: the watcher has to
    /// know these bytes as ours, or their echo would land on top of an edit
    /// made in the meantime.
    private func persist() {
        service?.save(config)
    }

    // MARK: - Accessibility trust

    /// Re-runs the trust check now, out of turn with the service's poll.
    /// Called by onboarding's own heartbeat while its window is visible, so
    /// the "Granted" state appears the instant the user comes back from
    /// System Settings rather than up to a second later.
    ///
    /// Goes through the service so the lease moves with it — mirroring
    /// `axTrusted` alone would leave the keyboard without a lease under a UI
    /// saying everything is fine. Before `start()` there is no service and
    /// nothing to lease, so it is just the check.
    public func refreshAccessibilityTrust() {
        guard let service else {
            let trusted = trustCheck()
            if trusted != axTrusted {
                axTrusted = trusted
            }
            noteTrust(trusted)
            return
        }
        let ready = service.refreshPostingReadiness()
        if ready != axTrusted {
            axTrusted = ready
        }
        noteTrust(ready)
    }

    /// The production `trustRequest`: the prompting form of the trust check.
    public static func promptForAccessibility() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    /// What onboarding's button does next: ask macOS, or open the
    /// Accessibility pane. One dialog per press either way — the system's
    /// alert carries its own "Open System Settings" button, and macOS shows
    /// that alert only once per app: after it, RawTouch is in the list, and
    /// asking again does nothing visible.
    public enum AccessibilityGrantStep: Equatable {
        case askSystem
        case openSettings
    }

    public var accessibilityGrantStep: AccessibilityGrantStep {
        accessibilityWasRequested ? .openSettings : .askSystem
    }

    /// Whether macOS has already been asked — persisted, because the system
    /// remembers across launches too. Set by the first press, and by any
    /// sighting of the grant (a trusted app is in the list, so asking later
    /// would be a press that does nothing). Never cleared: a grant revoked
    /// with the switch leaves RawTouch in the list, where the pane is the
    /// way back. An entry removed from the list altogether is the one case
    /// where asking would work again; the pane still opens, and the window
    /// says how to add RawTouch with +.
    @Published public private(set) var accessibilityWasRequested: Bool {
        didSet {
            if accessibilityWasRequested != oldValue {
                defaults.set(accessibilityWasRequested, forKey: Self.accessibilityRequestedKey)
            }
        }
    }

    private static let accessibilityRequestedKey = "accessibilityRequested"

    /// Onboarding's button: the step `accessibilityGrantStep` names. The
    /// first press only asks macOS (`trustRequest`): the system shows its
    /// own alert and lists RawTouch in Privacy & Security → Accessibility
    /// with a switch, so the user does not have to find the app and add it.
    /// Every later press opens the pane — so a press whose system alert did
    /// not appear is followed by a button that now says where it goes.
    ///
    /// The only caller of `trustRequest`, and only for an explicit action
    /// of the user's: never at launch, never from a poll, never from the
    /// menu merely showing that the permission is missing — a prompt nobody
    /// asked for is nagging, and a prompt raised by a test or
    /// build-directory copy binds the grant to that copy. Every poll uses
    /// the non-prompting `trustCheck`.
    public func grantAccessibility() {
        switch accessibilityGrantStep {
        case .askSystem:
            accessibilityWasRequested = true
            trustRequest()
        case .openSettings:
            openAccessibilitySettings()
        }
    }

    /// The production `openAccessibilitySettings`.
    public static func openAccessibilityPane() {
        let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(pane)
    }

    /// A trusted app is in the Accessibility list, so macOS has nothing
    /// left to ask: remember that for any later loss of the grant.
    private func noteTrust(_ trusted: Bool) {
        if trusted, !accessibilityWasRequested {
            accessibilityWasRequested = true
        }
        if defaults.bool(forKey: Self.accessibilityGrantedKey) != trusted {
            defaults.set(trusted, forKey: Self.accessibilityGrantedKey)
        }
    }

    // MARK: - Start at login

    /// Registers or unregisters the login item, then mirrors what actually
    /// happened rather than the intent: a registration can succeed and
    /// still wait for approval in System Settings.
    public func setStartAtLogin(_ enabled: Bool) {
        requestedStartAtLogin = enabled
        do {
            try loginItems.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        refreshStartAtLogin()
    }

    /// Re-reads the registration state. A failure stops being news once
    /// the state is what was asked for — approved in System Settings after
    /// all, say.
    private func refreshStartAtLogin() {
        let enabled = loginItems.isEnabled
        if startAtLogin != enabled {
            startAtLogin = enabled
        }
        if loginItemError != nil, enabled == requestedStartAtLogin {
            loginItemError = nil
        }
    }
}
