// MIT License
// Copyright (c) 2026 RawTouch contributors

import Combine
import RawTouchCore
import RawTouchTestSupport
import XCTest

@testable import RawTouchAppCore

/// `AppModel` end to end against the fakes: lifecycle wiring, the
/// lock-conflict path, debounced saves, watcher echoes, external edits,
/// lease-unsupported surfacing, trust polling and the login-item mirror. Nothing
/// here opens IOKit, posts an event, prompts for AX, or touches launchd.
final class AppModelTests: XCTestCase {
    private var directory: URL!
    private var model: AppModel?
    private var fakeManager: FakeRawTouchDeviceManager!
    private var fakeLoginItems: FakeLoginItems!
    private var trustBox: TrustBox!
    private var managerFactoryCalls = 0
    /// Calls to the prompting trust request. Never the real API: a test
    /// must not be able to raise the system's Accessibility prompt.
    private var trustRequests = 0
    /// Calls to the Accessibility pane opener — never the real pane.
    private var paneOpens = 0
    /// A private defaults suite, so app state the model persists stays
    /// inside the test.
    private var defaults: UserDefaults!
    private var defaultsSuite = ""
    private var cancellables: Set<AnyCancellable> = []
    private var releaseSource: FakeReleaseSource!
    private var updateScheduler: FakeTimerScheduler!

    private var configPath: URL {
        directory.appendingPathComponent("config.json")
    }

    private var lockPath: URL {
        directory.appendingPathComponent("rawtouch.pid")
    }

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rawtouch-appmodel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fakeManager = FakeRawTouchDeviceManager()
        fakeLoginItems = FakeLoginItems()
        trustBox = TrustBox(true)
        managerFactoryCalls = 0
        trustRequests = 0
        paneOpens = 0
        defaultsSuite = "rawtouch-appmodel-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        cancellables = []
        releaseSource = FakeReleaseSource()
        updateScheduler = FakeTimerScheduler()
    }

    override func tearDown() {
        model?.shutdownForQuit()
        model = nil
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: defaultsSuite)
    }

    /// Builds a model wired to the fakes with fast intervals. Does not call
    /// `start()` — tests that need the stack up call it themselves.
    private func makeModel(saveDebounce: TimeInterval = 0.05) -> AppModel {
        let model = AppModel(
            configPath: configPath,
            lockPath: lockPath,
            saveDebounceInterval: saveDebounce,
            trustCheck: { [trustBox] in trustBox!.trusted },
            trustRequest: { [weak self] in self?.trustRequests += 1 },
            openAccessibilitySettings: { [weak self] in self?.paneOpens += 1 },
            trustPollInterval: 0.02,
            // Fast in both directions: the granted cadence is what notices a
            // grant being revoked, and a test cannot wait out the real 5 s.
            trustedPollInterval: 0.02,
            loginItems: fakeLoginItems,
            makeManager: { [weak self] _ in
                self!.managerFactoryCalls += 1
                return self!.fakeManager
            },
            defaults: defaults,
            appVersion: AppVersion(shortVersion: "0.1.0", build: "1"),
            releaseSource: releaseSource,
            updateScheduler: updateScheduler
        )
        self.model = model
        return model
    }

    /// Services the main run loop until `condition` holds (or fails the
    /// test), for the debounce timers and watcher deliveries.
    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 2,
        condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(label)")
    }

    private func loadSavedConfiguration() throws -> RawTouchConfiguration {
        try JSONDecoder().decode(RawTouchConfiguration.self, from: Data(contentsOf: configPath))
    }

    // MARK: - Startup wiring

    func testStartBringsUpManagerAndMirrorsStatus() {
        let model = makeModel()
        XCTAssertTrue(model.start())
        XCTAssertEqual(fakeManager.startCount, 1)
        XCTAssertEqual(model.status, fakeManager.status)

        let connected = RawTouchStatus(endpoints: [.keyboard(lease: .held)])
        fakeManager.push(connected)
        XCTAssertEqual(model.status, connected)
    }

    /// The keyboards are grouped once per change, so they must follow every
    /// change of what a grouping reads: the endpoints in the status, and
    /// the names in the configuration.
    func testTheKeyboardsFollowTheStatusAndTheConfiguration() {
        let model = makeModel()
        XCTAssertTrue(model.start())
        XCTAssertEqual(model.settingsKeyboards, [])

        var endpoint = RawTouchStatus.Endpoint.keyboard("Go60 Right", lease: .held)
        endpoint.deviceKey = "id:AAAA"
        fakeManager.push(RawTouchStatus(endpoints: [endpoint]))
        XCTAssertEqual(model.settingsKeyboards.map(\.name), ["Go60 Right"])

        model.updateConfig { $0.devices["id:AAAA"] = .init(name: "Desk") }
        XCTAssertEqual(model.settingsKeyboards.map(\.name), ["Desk"])
        XCTAssertEqual(
            model.settingsKeyboards, RawTouchKeyboard.grouped(in: model.status, configuration: model.config))

        fakeManager.push(RawTouchStatus())
        XCTAssertEqual(model.settingsKeyboards, [])
    }

    func testStartIsIdempotent() {
        let model = makeModel()
        XCTAssertTrue(model.start())
        XCTAssertTrue(model.start())
        XCTAssertEqual(fakeManager.startCount, 1)
        XCTAssertEqual(managerFactoryCalls, 1)
    }

    func testMalformedConfigAtStartRunsOnDefaultsAndReports() throws {
        try Data("{ not json".utf8).write(to: configPath)
        let model = makeModel()
        XCTAssertTrue(model.start())
        XCTAssertEqual(model.config, RawTouchConfiguration())
        XCTAssertEqual(fakeManager.reportedErrors.count, 1)
        XCTAssertNotNil(model.status.configError)
    }

    /// A file that could not be decoded is still the user's: the first
    /// edit made in Settings must not replace it with the defaults. The
    /// edit applies, the error stays up (it is how the menu says changes
    /// are not being kept), and saving resumes once the file is fixed.
    func testEditsAreNotSavedOverAFileThatCouldNotBeRead() throws {
        let malformed = Data("{ not json".utf8)
        try malformed.write(to: configPath)
        let model = makeModel()
        model.start()

        model.updateConfig { $0.scale = 0.5 }

        XCTAssertEqual(model.config.scale, 0.5)
        XCTAssertEqual(fakeManager.appliedConfigurations.last?.scale, 0.5, "the edit applies")
        XCTAssertNotNil(model.status.configError, "and the error stays up")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(try Data(contentsOf: configPath), malformed, "the file is left exactly as it was")

        try Data(#"{"scale": 0.75}"#.utf8).write(to: configPath)
        waitUntil("the fixed file to load") { self.model?.config.scale == 0.75 }
        XCTAssertNil(model.status.configError)

        model.updateConfig { $0.reverseScrolling = true }
        waitUntil("saving to resume") { (try? self.loadSavedConfiguration().reverseScrolling) == true }
        XCTAssertEqual(try loadSavedConfiguration().scale, 0.75)
    }

    // MARK: - Lock conflict

    func testLockConflictSurfacesTheHolderAndStartsNothing() throws {
        let holder = try XCTUnwrap(try InstanceLock.acquire(at: lockPath))
        defer { holder.release() }

        let model = makeModel()
        XCTAssertFalse(model.start())
        XCTAssertEqual(model.startFailure, .alreadyRunning(holderPID: getpid()))
        XCTAssertEqual(managerFactoryCalls, 0, "no manager may be built without the lock")
    }

    /// A lock file that cannot be opened is not another copy running, and
    /// the alert must not send the user looking for one.
    func testAnUnopenableLockFileIsReportedAsWhatItIs() throws {
        // A regular file where the lock's directory should be.
        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        let model = AppModel(
            configPath: configPath,
            lockPath: blocked.appendingPathComponent("rawtouch.pid"),
            loginItems: fakeLoginItems,
            makeManager: { [weak self] _ in
                self!.managerFactoryCalls += 1
                return self!.fakeManager
            }
        )
        self.model = model

        XCTAssertFalse(model.start())
        guard case .lockUnavailable(let reason)? = model.startFailure else {
            XCTFail("expected lockUnavailable, got \(String(describing: model.startFailure))")
            return
        }
        XCTAssertTrue(reason.contains("rawtouch.pid"), reason)
        XCTAssertEqual(managerFactoryCalls, 0)
    }

    // MARK: - Config editing and debounced saving

    func testEditAppliesImmediatelyButSavesDebounced() throws {
        let model = makeModel()
        model.start()

        model.updateConfig { $0.scale = 0.5 }

        XCTAssertEqual(model.config.scale, 0.5)
        XCTAssertEqual(fakeManager.appliedConfigurations.last?.scale, 0.5)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: configPath.path),
            "the save must wait out the debounce"
        )

        waitUntil("the debounced save") { FileManager.default.fileExists(atPath: self.configPath.path) }
        XCTAssertEqual(try loadSavedConfiguration().scale, 0.5)
    }

    func testDisplaySyncEditsApplyAndResetLikeEveryOtherSection() throws {
        let model = makeModel()
        model.start()

        model.updateConfig { $0.resampling.enabled = false }
        XCTAssertEqual(fakeManager.appliedConfigurations.last?.resampling, .init(enabled: false))

        waitUntil("the debounced save") { FileManager.default.fileExists(atPath: self.configPath.path) }
        XCTAssertEqual(try loadSavedConfiguration().resampling, .init(enabled: false))

        model.restoreAdvancedDefaults()
        XCTAssertEqual(model.config.resampling, .init())
        XCTAssertEqual(fakeManager.appliedConfigurations.last?.resampling, .init())
    }

    func testAnEditBurstSavesTheFinalValue() throws {
        let model = makeModel()
        model.start()

        model.updateConfig { $0.scale = 0.1 }
        model.updateConfig { $0.scale = 0.2 }
        model.updateConfig { $0.scale = 0.3 }

        waitUntil("the coalesced save") { FileManager.default.fileExists(atPath: self.configPath.path) }
        XCTAssertEqual(try loadSavedConfiguration().scale, 0.3)
        XCTAssertEqual(fakeManager.appliedConfigurations.count, 3, "every edit reaches the manager live")
    }

    func testNoOpEditChangesNothing() {
        let model = makeModel()
        model.start()

        model.updateConfig { _ in }

        XCTAssertTrue(fakeManager.appliedConfigurations.isEmpty)
        let settle = expectation(description: "no save lands")
        settle.isInverted = true
        wait(for: [settle], timeout: 0.2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath.path))
    }

    func testShutdownFlushesAPendingSave() throws {
        let model = makeModel(saveDebounce: 10)
        model.start()

        model.updateConfig { $0.reverseScrolling = true }
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath.path))

        model.shutdownForQuit()
        XCTAssertEqual(try loadSavedConfiguration().reverseScrolling, true)
        XCTAssertEqual(fakeManager.shutdownCount, 1)
    }

    // MARK: - Watcher deliveries

    func testAWatcherEchoDoesNotDirtyTheModel() {
        let model = makeModel()
        model.start()

        var configPublishes = 0
        model.$config.dropFirst().sink { _ in configPublishes += 1 }.store(in: &cancellables)

        // Our own save coming back through the watcher: same value.
        model.handleConfigFileChange(.success(model.config))

        XCTAssertEqual(configPublishes, 0, "an equal reload must not republish the configuration")
        XCTAssertEqual(fakeManager.appliedConfigurations.count, 1, "the harmless no-op apply is forwarded")

        let settle = expectation(description: "no save-back")
        settle.isInverted = true
        wait(for: [settle], timeout: 0.2)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: configPath.path),
            "a reload must never schedule a save of its own"
        )
    }

    /// The echo of a save arrives a watcher debounce (0.2 s) after it,
    /// which is time enough to make another edit. Reloading "A" then would
    /// snap B back in the UI and the manager, and B's own pending save
    /// would write A again.
    func testAnEditMadeBeforeTheLastSaveEchoesIsKept() throws {
        let model = makeModel(saveDebounce: 0.3)
        model.start()

        model.updateConfig { $0.scale = 0.5 }
        waitUntil("the first save") { FileManager.default.fileExists(atPath: self.configPath.path) }
        model.updateConfig { $0.reverseScrolling = true }

        // Past the echo (0.2 s after the first save) and the second save
        // (0.3 s after the second edit).
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))

        XCTAssertEqual(model.config.scale, 0.5)
        XCTAssertTrue(model.config.reverseScrolling, "the second edit survives the first one's echo")
        XCTAssertEqual(fakeManager.appliedConfigurations.last?.reverseScrolling, true)
        XCTAssertEqual(try loadSavedConfiguration().scale, 0.5)
        XCTAssertEqual(try loadSavedConfiguration().reverseScrolling, true)
    }

    func testAnExternalEditUpdatesConfigAndAppliesWithoutSavingBack() throws {
        let model = makeModel()
        model.start()

        try Data(#"{"scale": 0.75}"#.utf8).write(to: configPath)
        waitUntil("the external edit to land") { self.model?.config.scale == 0.75 }
        XCTAssertEqual(fakeManager.appliedConfigurations.last?.scale, 0.75)

        // Last write wins, and nothing rewrites the file behind the editor.
        let settle = expectation(description: "file left alone")
        settle.isInverted = true
        wait(for: [settle], timeout: 0.2)
        XCTAssertEqual(try Data(contentsOf: configPath), Data(#"{"scale": 0.75}"#.utf8))
    }

    func testAMalformedExternalEditIsReportedNotApplied() {
        let model = makeModel()
        model.start()

        struct Malformed: Error {}
        let before = model.config
        model.handleConfigFileChange(.failure(Malformed()))

        XCTAssertEqual(model.config, before)
        XCTAssertEqual(fakeManager.reportedErrors.count, 1)
        XCTAssertNotNil(model.status.configError)
    }

    // MARK: - Firmware without lease support

    func testFirmwareWithoutLeaseSupportSurfacesInsteadOfExiting() {
        let model = makeModel()
        model.start()

        var status = RawTouchStatus()
        status.endpoints = [
            .init(
                id: RawTouchEndpointID(rawValue: 1),
                productName: "Go60",
                transport: .usb,
                padIDs: [],
                lease: .unsupportedFirmware
            )
        ]
        fakeManager.push(status)

        XCTAssertEqual(model.leaseUnsupportedProductName, "Go60")
        XCTAssertEqual(
            iconState(
                for: model.status, axTrusted: model.axTrusted,
                leaseUnsupported: model.leaseUnsupportedProductName != nil),
            .needsAttention
        )

        // Unplugging that keyboard clears the condition: it was the
        // keyboard's, not the process's.
        fakeManager.push(RawTouchStatus())
        XCTAssertNil(model.leaseUnsupportedProductName)
        XCTAssertEqual(
            iconState(
                for: model.status, axTrusted: model.axTrusted,
                leaseUnsupported: model.leaseUnsupportedProductName != nil),
            .noDevice
        )
    }

    // MARK: - Accessibility trust

    func testTrustFlipsToGrantedViaPolling() {
        trustBox.trusted = false
        let model = makeModel()
        model.start()
        XCTAssertFalse(model.axTrusted)

        trustBox.trusted = true
        waitUntil("the trust poll to notice") { self.model?.axTrusted == true }
    }

    func testRefreshAccessibilityTrustReadsTheCheckOnDemand() {
        trustBox.trusted = false
        let model = makeModel()
        model.start()

        trustBox.trusted = true
        model.refreshAccessibilityTrust()
        XCTAssertTrue(model.axTrusted)
    }

    /// The system prompt is the user's to ask for: starting without the
    /// grant, the polls, and on-demand refreshes all use the silent check,
    /// and the first press of onboarding's button only asks, once — one
    /// dialog per press; every later press opens the pane instead.
    func testTheFirstPressOnlyAsksMacOSAndLaterPressesOpenThePane() {
        trustBox.trusted = false
        let model = makeModel()
        model.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))  // ten polls
        model.refreshAccessibilityTrust()
        XCTAssertEqual(trustRequests, 0, "never on its own")
        XCTAssertEqual(model.accessibilityGrantStep, .askSystem)

        model.grantAccessibility()
        XCTAssertEqual(trustRequests, 1)
        XCTAssertEqual(paneOpens, 0, "the system's alert has its own way to the pane")
        XCTAssertEqual(model.accessibilityGrantStep, .openSettings)

        model.grantAccessibility()
        model.grantAccessibility()
        XCTAssertEqual(trustRequests, 1, "macOS shows its alert once; asking again would do nothing")
        XCTAssertEqual(paneOpens, 2)
        XCTAssertFalse(model.axTrusted, "asking grants nothing by itself")
    }

    /// Before `start()` too: building the model and refreshing never ask.
    func testAnUnstartedModelNeverRaisesTheAccessibilityPrompt() {
        trustBox.trusted = false
        let model = makeModel()
        model.refreshAccessibilityTrust()
        XCTAssertEqual(trustRequests, 0)
        model.grantAccessibility()
        XCTAssertEqual(trustRequests, 1)
    }

    /// macOS remembers it was asked across launches, so the model does too:
    /// a press after a relaunch opens the pane rather than asking into the
    /// void.
    func testAnEarlierLaunchsRequestSendsTheNextPressToThePane() {
        trustBox.trusted = false
        makeModel().grantAccessibility()
        XCTAssertEqual(trustRequests, 1)

        let relaunched = makeModel()
        relaunched.start()
        XCTAssertEqual(relaunched.accessibilityGrantStep, .openSettings)
        relaunched.grantAccessibility()
        XCTAssertEqual(trustRequests, 1)
        XCTAssertEqual(paneOpens, 1)
    }

    /// A grant seen once means RawTouch is in the list: when it is revoked
    /// later, the switch is off but the entry is there, and the pane is
    /// the way back — even on an install whose button was never pressed.
    func testARevokedGrantSendsThePressToThePane() {
        trustBox.trusted = true
        let model = makeModel()
        model.start()
        XCTAssertEqual(model.accessibilityGrantStep, .openSettings)

        trustBox.trusted = false
        waitUntil("the poll to notice the revocation") { self.model?.axTrusted == false }
        model.grantAccessibility()
        XCTAssertEqual(trustRequests, 0)
        XCTAssertEqual(paneOpens, 1)
    }

    // MARK: - Onboarding at launch

    func testTheFirstLaunchWithoutTheGrantOpensOnboardingOnce() {
        trustBox.trusted = false
        let first = makeModel()
        first.start()
        first.openOnboardingAtLaunchIfNeeded()
        XCTAssertTrue(first.shouldShowOnboarding)
        first.shutdownForQuit()

        // "Not Now", never granted: the next launch is quiet.
        let second = makeModel()
        second.start()
        second.openOnboardingAtLaunchIfNeeded()
        XCTAssertFalse(second.shouldShowOnboarding)
    }

    func testALaunchWithTheGrantOpensNothing() {
        trustBox.trusted = true
        let model = makeModel()
        model.start()
        model.openOnboardingAtLaunchIfNeeded()
        XCTAssertFalse(model.shouldShowOnboarding)
        XCTAssertFalse(model.onboardingWasShown)
    }

    /// A grant lost while the app was not running (an update macOS treats
    /// as a different app) is news at the next launch, even though the
    /// explainer has been shown before.
    func testAGrantLostWhileQuitReopensOnboardingAtTheNextLaunch() {
        trustBox.trusted = false
        let first = makeModel()
        first.start()
        first.openOnboardingAtLaunchIfNeeded()
        trustBox.trusted = true
        first.refreshAccessibilityTrust()
        XCTAssertTrue(first.axTrusted)
        first.shutdownForQuit()

        trustBox.trusted = false
        let second = makeModel()
        second.start()
        second.openOnboardingAtLaunchIfNeeded()
        XCTAssertTrue(second.shouldShowOnboarding)
        second.shutdownForQuit()

        // Still ungranted at the launch after that: said once, not again.
        let third = makeModel()
        third.start()
        third.openOnboardingAtLaunchIfNeeded()
        XCTAssertFalse(third.shouldShowOnboarding)
    }

    // MARK: - Accessibility decides the lease

    /// Why readiness decides the lease: without a grant every posted scroll event is
    /// dropped, so holding the lease would silence the firmware's own
    /// wheel scrolling and put nothing in its place — a fresh install would
    /// *take away* scrolling that worked. The user's `enabled` preference is
    /// not the lever for that (it is theirs, and it has to come back intact
    /// when the grant lands); readiness is a separate input.
    func testAnUntrustedStartDoesNotAcquireTheLeaseButKeepsTheEnabledPreference() {
        trustBox.trusted = false
        var initialConfiguration: RawTouchConfiguration?
        let model = AppModel(
            configPath: configPath,
            lockPath: lockPath,
            saveDebounceInterval: 0.05,
            trustCheck: { [trustBox] in trustBox!.trusted },
            trustPollInterval: 0.02,
            trustedPollInterval: 0.02,
            loginItems: fakeLoginItems,
            makeManager: { [weak self] configuration in
                initialConfiguration = configuration
                return self!.fakeManager
            }
        )
        self.model = model

        XCTAssertTrue(model.start())

        XCTAssertFalse(model.axTrusted)
        XCTAssertEqual(fakeManager.lastPostingReady, false, "the manager must be told not to acquire the lease")
        XCTAssertEqual(initialConfiguration?.enabled, true, "the user's master switch is untouched")
        XCTAssertEqual(model.config.enabled, true)
        XCTAssertFalse(model.status.leaseHeld)
    }

    /// The grant landing mid-session acquires the lease on its own — no restart, no
    /// re-toggle.
    func testTheGrantArrivingOnAPollTellsTheManagerToAcquireTheLease() {
        trustBox.trusted = false
        let model = makeModel()
        model.start()
        XCTAssertEqual(fakeManager.lastPostingReady, false)

        trustBox.trusted = true
        waitUntil("the readiness poll to acquire the lease") { self.fakeManager.lastPostingReady == true }
        XCTAssertTrue(model.axTrusted)
    }

    /// And a grant revoked in System Settings has to release it again, which
    /// is why the poll keeps running (slower) once trusted.
    func testARevokedGrantReleasesTheLeaseOnALaterPoll() {
        let model = makeModel()
        model.start()
        XCTAssertTrue(model.axTrusted)
        XCTAssertEqual(fakeManager.lastPostingReady, true)

        trustBox.trusted = false
        waitUntil("the readiness poll to release") { self.fakeManager.lastPostingReady == false }
        XCTAssertFalse(model.axTrusted)
        XCTAssertEqual(fakeManager.postingReadyCalls, [true, false])
    }

    // MARK: - Start at login

    func testStartAtLoginMirrorsTheRegistrationState() {
        fakeLoginItems.isEnabled = true
        let model = makeModel()
        model.start()
        XCTAssertTrue(model.startAtLogin)

        model.setStartAtLogin(false)
        XCTAssertEqual(fakeLoginItems.setEnabledCalls, [false])
        XCTAssertFalse(model.startAtLogin)
        XCTAssertNil(model.loginItemError)
    }

    func testAFailedRegistrationKeepsTheRealStateAndRecordsTheError() {
        let model = makeModel()
        model.start()

        fakeLoginItems.shouldThrow = true
        model.setStartAtLogin(true)

        XCTAssertNotNil(model.loginItemError)
        XCTAssertFalse(model.startAtLogin, "the toggle must reflect what actually registered")
    }

    /// Login Items in System Settings can change the registration behind
    /// the app's back; the toggle follows it on the readiness poll.
    func testStartAtLoginFollowsAChangeMadeInSystemSettings() {
        let model = makeModel()
        model.start()
        XCTAssertFalse(model.startAtLogin)

        fakeLoginItems.isEnabled = true
        waitUntil("the poll to re-read it") { self.model?.startAtLogin == true }
    }

    /// A refused registration approved in System Settings afterwards is no
    /// longer a failure to report.
    func testALoginItemFailureClearsOnceTheStateIsWhatWasAskedFor() {
        let model = makeModel()
        model.start()

        fakeLoginItems.shouldThrow = true
        model.setStartAtLogin(true)
        XCTAssertNotNil(model.loginItemError)

        fakeLoginItems.isEnabled = true
        waitUntil("the error to clear") { self.model?.loginItemError == nil }
        XCTAssertTrue(model.startAtLogin)
    }

    // MARK: - Shutdown

    func testShutdownForQuitIsIdempotent() {
        let model = makeModel()
        model.start()

        model.shutdownForQuit()
        model.shutdownForQuit()
        XCTAssertEqual(fakeManager.shutdownCount, 1)
    }

    // MARK: - Update check

    /// A keyboard on USB whose one half reports `firmware`.
    private func keyboardStatus(firmware: RawTouchFirmwareVersion) -> RawTouchStatus {
        RawTouchStatus(endpoints: [
            .init(
                id: RawTouchEndpointID(rawValue: 1),
                productName: "Go60",
                transport: .usb,
                padIDs: [0],
                firmwareVersion: firmware,
                deviceKey: "id:AAAA",
                lease: .held
            )
        ])
    }

    func testTheAutomaticCheckFollowsTheSetting() {
        let model = makeModel()
        model.start()

        model.updateConfig { $0.updates.checkAutomatically = false }
        updateScheduler.fireOneShots()
        XCTAssertEqual(releaseSource.requests, [], "switched off: no automatic check")

        model.updateConfig { $0.updates.checkAutomatically = true }
        updateScheduler.fireRepeating(count: 1)
        XCTAssertEqual(releaseSource.requests, [.app, .module])
    }

    func testAnAutomaticCheckFindsTheUpdatesQuietly() {
        releaseSource.results = [.app: .success(publishedRelease("v0.1.1"))]
        let model = makeModel()
        model.start()

        updateScheduler.fireOneShots()

        XCTAssertEqual(model.updateNotices.map(\.menuTitle), ["RawTouch 0.1.1 Available\u{2026}"])
        XCTAssertFalse(model.isCheckingForUpdates, "an automatic check says nothing beyond its notices")
    }

    /// Notices come from the releases found and the keyboards connected
    /// now, so a keyboard plugged in after the check is judged without
    /// asking GitHub again.
    func testAKeyboardConnectedAfterTheCheckIsJudgedToo() {
        releaseSource.results = [.module: .success(publishedRelease("v0.2.0", repository: .module))]
        let model = makeModel()
        model.start()
        model.checkForUpdates { _ in }
        XCTAssertEqual(model.updateNotices, [])

        model.receiveForTesting(keyboardStatus(firmware: .init(major: 0, minor: 1)))

        XCTAssertEqual(model.updateNotices.map(\.menuTitle), ["Firmware 0.2.0 Available for Go60\u{2026}"])
        XCTAssertEqual(releaseSource.requests.count, 2)
    }

    /// The menu closes on the click, so the answer comes back once, as the
    /// report the app shows; until then the menu item says it is checking.
    func testAManualCheckIsAnsweredOnce() {
        let model = makeModel()
        model.start()
        releaseSource.holdsCompletions = true
        releaseSource.results[.app] = .success(publishedRelease("v0.1.0"))
        var reports: [UpdateCheckReport] = []

        model.checkForUpdates { reports.append($0) }
        XCTAssertTrue(model.isCheckingForUpdates)
        XCTAssertEqual(reports, [])

        releaseSource.answerHeld()
        XCTAssertFalse(model.isCheckingForUpdates)
        XCTAssertEqual(reports.map(\.title), ["RawTouch is up to date"])

        updateScheduler.fireOneShots()
        XCTAssertEqual(reports.count, 1, "a later automatic check answers nobody")
    }

    /// A failed check says so, and keeps what the last good one found.
    func testAFailedManualCheckKeepsTheLastAnswer() {
        releaseSource.results = [.app: .success(publishedRelease("v0.1.1"))]
        let model = makeModel()
        model.start()
        model.checkForUpdates { _ in }

        releaseSource.results[.app] = .failure(FakeReleaseSource.Unreachable())
        var report: UpdateCheckReport?
        model.checkForUpdates { report = $0 }

        XCTAssertEqual(report?.title, "Couldn\u{2019}t check for updates")
        XCTAssertEqual(model.latestReleases.app, publishedRelease("v0.1.1"))
    }

    func testAManualCheckReportsTheUpdateItFound() {
        releaseSource.results = [.app: .success(publishedRelease("v0.2.0"))]
        let model = makeModel()
        model.start()
        var report: UpdateCheckReport?

        model.checkForUpdates { report = $0 }

        XCTAssertEqual(
            report,
            UpdateCheckReport(
                title: "RawTouch 0.2.0 is available", message: "You have 0.1.0.",
                releasePages: [publishedRelease("v0.2.0").url]))
        XCTAssertEqual(model.updateNotices.count, 1, "and the menu keeps offering it")
    }

    func testTheUpdateSettingRestoresWithTheAdvancedTab() {
        let model = makeModel()
        model.start()
        model.updateConfig { $0.updates.checkAutomatically = false }

        model.restoreAdvancedDefaults()

        XCTAssertEqual(model.config.updates, .init())
    }

    func testQuittingStopsTheUpdateSchedule() {
        let model = makeModel()
        model.start()

        model.shutdownForQuit()

        XCTAssertTrue(updateScheduler.liveTimers.isEmpty)
    }
}
