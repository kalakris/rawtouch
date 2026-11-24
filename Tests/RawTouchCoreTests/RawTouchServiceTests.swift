// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchTestSupport
import XCTest

@testable import RawTouchCore

/// The service lifecycle: lock → configuration → manager → watcher →
/// shutdown. Driven against a fake manager, so nothing here opens IOKit,
/// leases a device or posts an event.
final class RawTouchServiceTests: XCTestCase {
    /// A mutable trust answer, so a test can revoke the grant under a
    /// running service. Never the real Accessibility API: the suite must not
    /// be able to raise a TCC prompt.
    private final class TrustBox {
        var trusted: Bool

        init(_ trusted: Bool) {
            self.trusted = trusted
        }
    }

    private var directory: URL!
    private var fake: FakeRawTouchDeviceManager!
    private var service: RawTouchService?
    private var trust: TrustBox!

    private var configPath: URL { directory.appendingPathComponent("config.json") }
    private var lockPath: URL { directory.appendingPathComponent("rawtouch.pid") }

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rawtouch-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fake = FakeRawTouchDeviceManager()
        trust = TrustBox(true)
    }

    override func tearDown() {
        service?.shutdown()
        service = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeService(
        onConfigurationChange: @escaping (RawTouchConfiguration) -> Void = { _ in },
        onConfigurationError: @escaping (Error) -> Void = { _ in },
        onStatusChange: @escaping (RawTouchStatus) -> Void = { _ in },
        onPostingReadyChange: @escaping (Bool) -> Void = { _ in }
    ) -> RawTouchService {
        let service = RawTouchService(
            configPath: configPath,
            lockPath: lockPath,
            makeManager: { [fake] _ in fake! },
            trustCheck: { [trust] in trust!.trusted },
            // Fast enough that the polls below finish inside a test.
            untrustedPollInterval: 0.02,
            trustedPollInterval: 0.02,
            onStatusChange: onStatusChange,
            onConfigurationChange: onConfigurationChange,
            onConfigurationError: onConfigurationError,
            onPostingReadyChange: onPostingReadyChange
        )
        self.service = service
        return service
    }

    /// Services the main run loop until `condition` holds (or fails the
    /// test) — the readiness poll runs on a main-queue timer.
    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 2,
        condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(label)")
    }

    // MARK: - Saving

    /// The trap: a file that is valid JSON but does not decode leaves the
    /// service on defaults. Saving then would write the defaults over the
    /// user's settings, so nothing is saved until the file decodes.
    func testAFileThatFailedToDecodeIsNeverRewritten() throws {
        let json = #"{"scale": "fast", "acceleration": {"exponent": 1.2}}"#
        try Data(json.utf8).write(to: configPath)
        let service = makeService()

        let started = try service.start()

        XCTAssertNotNil(started.configurationError)
        XCTAssertFalse(service.save(service.configuration))
        XCTAssertEqual(try String(contentsOf: configPath, encoding: .utf8), json, "the file is left exactly as it was")
    }

    /// A file broken by an edit made while running stops saves too, until
    /// a reload decodes again.
    func testABadReloadStopsSavesUntilAGoodOne() throws {
        struct Malformed: Error {}
        let service = makeService()
        try service.start()

        service.handleConfigurationReload(.failure(Malformed()))
        XCTAssertFalse(service.save(RawTouchConfiguration()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath.path))

        service.handleConfigurationReload(.success(RawTouchConfiguration()))
        XCTAssertTrue(service.save(RawTouchConfiguration()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: configPath.path))
    }

    // MARK: - Start

    func testStartBringsTheStackUpInOrder() throws {
        try Data(#"{"scale": 0.75}"#.utf8).write(to: configPath)
        let service = makeService()

        let started = try service.start()

        XCTAssertNil(started.configurationError)
        XCTAssertEqual(service.configuration.scale, 0.75, "the file is loaded before the manager is built")
        XCTAssertEqual(fake.startCount, 1)
        XCTAssertTrue(fake.hadStatusHookAtStart, "the status hook must be installed before start()")
        XCTAssertTrue(service.isRunning)
        XCTAssertNil(try InstanceLock.acquire(at: lockPath), "the lock is held while running")
    }

    func testStartIsIdempotent() throws {
        let service = makeService()
        try service.start()
        try service.start()
        XCTAssertEqual(fake.startCount, 1)
    }

    func testAMalformedConfigurationRunsOnDefaultsAndIsReported() throws {
        try Data("{ not json".utf8).write(to: configPath)
        let service = makeService()

        let started = try service.start()

        XCTAssertNotNil(started.configurationError, "the caller decides whether that is fatal")
        XCTAssertEqual(service.configuration, RawTouchConfiguration())
        XCTAssertEqual(fake.reportedErrors.count, 1, "the manager carries it in its status")
        guard case .unreadable = fake.status.configError else {
            return XCTFail(
                "reported as a file that could not be read, got \(String(describing: fake.status.configError))")
        }
        XCTAssertEqual(fake.startCount, 1, "and the stack still came up")
    }

    /// A save that fails on a file that reads fine — here, a directory the
    /// service may not write to — is reported as a failed save, not as a
    /// file that could not be read, and does not stop the next save.
    func testAFailedSaveIsReportedAsUnsavedNotUnreadable() throws {
        let service = makeService()
        try service.start()
        let writable = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: writable ?? 0o755], ofItemAtPath: directory.path)
        }

        XCTAssertFalse(service.save(RawTouchConfiguration()))
        guard case .unsaved = fake.status.configError else {
            return XCTFail("reported as a failed save, got \(String(describing: fake.status.configError))")
        }

        try FileManager.default.setAttributes([.posixPermissions: writable ?? 0o755], ofItemAtPath: directory.path)
        XCTAssertTrue(
            service.save(RawTouchConfiguration()), "a failed save is not a broken file: the next one goes through")
    }

    func testALockConflictThrowsAndStartsNothing() throws {
        let holder = try XCTUnwrap(try InstanceLock.acquire(at: lockPath))
        defer { holder.release() }

        let service = makeService()
        XCTAssertThrowsError(try service.start()) { error in
            XCTAssertEqual(error as? RawTouchService.StartFailure, .alreadyRunning(holderPID: getpid()))
        }
        XCTAssertEqual(fake.startCount, 0, "no manager may be built without the lock")
        XCTAssertFalse(service.isRunning)
    }

    // MARK: - Status

    func testStatusChangesReachTheCaller() throws {
        var published: [RawTouchStatus] = []
        let service = makeService(onStatusChange: { published.append($0) })
        try service.start()

        let connected = RawTouchStatus(endpoints: [.keyboard(lease: .pending)])
        fake.push(connected)

        XCTAssertEqual(published, [connected])
        XCTAssertEqual(service.status, connected)
    }

    // MARK: - Configuration

    func testApplyForwardsToTheManagerAndBecomesTheEffectiveConfiguration() throws {
        let service = makeService()
        try service.start()

        var edited = RawTouchConfiguration()
        edited.scale = 2
        service.apply(configuration: edited)

        XCTAssertEqual(fake.appliedConfigurations, [edited])
        XCTAssertEqual(service.configuration, edited)
    }

    func testAGoodReloadAppliesAndCallsBack() throws {
        var delivered: [RawTouchConfiguration] = []
        let service = makeService(onConfigurationChange: { delivered.append($0) })
        try service.start()

        var reloaded = RawTouchConfiguration()
        reloaded.reverseScrolling = true
        service.handleConfigurationReload(.success(reloaded))

        XCTAssertEqual(fake.appliedConfigurations, [reloaded])
        XCTAssertEqual(delivered, [reloaded])
        XCTAssertEqual(service.configuration, reloaded)
    }

    func testABadReloadIsReportedAndKeepsTheLastGoodConfiguration() throws {
        struct Malformed: Error {}
        var failures = 0
        let service = makeService(onConfigurationError: { _ in failures += 1 })
        try service.start()
        let before = service.configuration

        service.handleConfigurationReload(.failure(Malformed()))

        XCTAssertEqual(failures, 1)
        XCTAssertEqual(fake.reportedErrors.count, 1)
        XCTAssertTrue(fake.appliedConfigurations.isEmpty)
        XCTAssertEqual(service.configuration, before)
    }

    /// The watcher is wired by `start()`: an external edit reaches the
    /// manager without anyone calling the reload seam by hand.
    func testAnExternalEditFlowsThroughTheWatcher() throws {
        var delivered: [RawTouchConfiguration] = []
        let service = makeService(onConfigurationChange: { delivered.append($0) })
        try service.start()

        try Data(#"{"scale": 0.25}"#.utf8).write(to: configPath)

        let deadline = Date().addingTimeInterval(3)
        while delivered.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(delivered.last?.scale, 0.25)
        XCTAssertEqual(fake.appliedConfigurations.last?.scale, 0.25)
    }

    // MARK: - Shutdown

    func testShutdownReleasesTheLeaseAndTheLockAndIsIdempotent() throws {
        let service = makeService()
        try service.start()

        service.shutdown()
        service.shutdown()

        XCTAssertEqual(fake.shutdownCount, 1)
        XCTAssertFalse(service.isRunning)
        let reacquired = try InstanceLock.acquire(at: lockPath)
        XCTAssertNotNil(reacquired, "the lock is dropped on shutdown")
        reacquired?.release()
    }

    func testAServiceCannotBeRestartedAfterShutdown() throws {
        let service = makeService()
        try service.start()
        service.shutdown()

        try service.start()
        XCTAssertEqual(fake.startCount, 1)
        XCTAssertFalse(service.isRunning)
    }

    // MARK: - Posting readiness (Accessibility)

    /// The bug this guards: holding a lease while nothing can be posted
    /// silences the firmware's own wheel scrolling and puts nothing in its
    /// place, so a fresh install with no grant *removes* working scrolling.
    /// The manager must be told before it starts — a keyboard already
    /// plugged in validates the instant the HID manager opens.
    func testAnUntrustedStartTellsTheManagerNotToAcquireTheLeaseBeforeItStarts() throws {
        trust.trusted = false
        let service = makeService()

        try service.start()

        XCTAssertFalse(service.postingReady)
        XCTAssertEqual(fake.postingReadyCalls, [false])
        XCTAssertEqual(fake.startCount, 1)
    }

    /// The user's master switch is *their* preference and must survive a
    /// missing grant untouched — the lease follows the conjunction, not
    /// by rewriting the configuration.
    func testAnUntrustedStartLeavesTheEnabledPreferenceAlone() throws {
        trust.trusted = false
        var initialConfiguration: RawTouchConfiguration?
        let service = RawTouchService(
            configPath: configPath,
            lockPath: lockPath,
            makeManager: { [fake] configuration in
                initialConfiguration = configuration
                return fake!
            },
            trustCheck: { false }
        )
        self.service = service

        try service.start()

        XCTAssertEqual(initialConfiguration?.enabled, true)
        XCTAssertEqual(service.configuration.enabled, true)
        XCTAssertEqual(fake.lastPostingReady, false)
    }

    func testTheGrantArrivingOnAPollAcquiresTheLeaseWithoutARestart() throws {
        trust.trusted = false
        var reported: [Bool] = []
        let service = makeService(onPostingReadyChange: { reported.append($0) })
        try service.start()
        XCTAssertEqual(fake.lastPostingReady, false)

        trust.trusted = true
        waitUntil("the readiness poll to notice the grant") { service.postingReady }

        XCTAssertEqual(fake.lastPostingReady, true)
        XCTAssertEqual(reported, [true])
    }

    /// Polling does not stop once granted: a grant revoked in System
    /// Settings has to release the keyboard's lease, or the pads go dead
    /// until the firmware's lease expires.
    func testARevokedGrantReleasesTheLeaseOnALaterPoll() throws {
        let service = makeService()
        try service.start()
        XCTAssertTrue(service.postingReady)
        XCTAssertEqual(fake.lastPostingReady, true)

        trust.trusted = false
        waitUntil("the readiness poll to notice the revocation") { !service.postingReady }

        XCTAssertEqual(fake.lastPostingReady, false)
        XCTAssertEqual(fake.postingReadyCalls, [true, false])
    }

    /// Onboarding's "I just granted it" path: the answer must not wait for
    /// the next tick, and it must move the lease, not only the UI.
    func testRefreshingReadinessOnDemandPushesItThrough() throws {
        trust.trusted = false
        let service = makeService()
        try service.start()

        trust.trusted = true
        XCTAssertTrue(service.refreshPostingReadiness())

        XCTAssertTrue(service.postingReady)
        XCTAssertEqual(fake.postingReadyCalls, [false, true])
    }

    func testReadinessThatDidNotChangeIsNotRepublished() throws {
        var reported: [Bool] = []
        let service = makeService(onPostingReadyChange: { reported.append($0) })
        try service.start()

        service.refreshPostingReadiness()
        service.refreshPostingReadiness()

        XCTAssertEqual(fake.postingReadyCalls, [true], "the manager hears about transitions only")
        XCTAssertTrue(reported.isEmpty, "and so does the caller")
    }
}
