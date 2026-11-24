// MIT License
// Copyright (c) 2026 RawTouch contributors

import XCTest

@testable import RawTouchCore

/// The single-instance lock. flock(2) is held per *open file description*,
/// so two `InstanceLock.acquire` calls in one process genuinely contend —
/// no child process needed for an honest conflict test.
final class InstanceLockTests: XCTestCase {
    private var path: URL!

    override func setUp() {
        path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rawtouch-lock-\(UUID().uuidString)")
            .appendingPathComponent("rawtouch.pid")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
    }

    func testAcquireCreatesTheFileAndRecordsOurPID() throws {
        let lock = try XCTUnwrap(try InstanceLock.acquire(at: path))
        defer { lock.release() }

        XCTAssertEqual(InstanceLock.holderPID(at: path), getpid())
    }

    func testASecondAcquireFailsWhileTheLockIsHeld() throws {
        let lock = try XCTUnwrap(try InstanceLock.acquire(at: path))
        defer { lock.release() }

        XCTAssertNil(try InstanceLock.acquire(at: path))
        // The loser can still read who holds it, for the error message.
        XCTAssertEqual(InstanceLock.holderPID(at: path), getpid())
    }

    func testReleaseAllowsReacquiring() throws {
        let first = try XCTUnwrap(try InstanceLock.acquire(at: path))
        first.release()

        let second = try XCTUnwrap(try InstanceLock.acquire(at: path))
        second.release()
    }

    func testReleaseIsIdempotent() throws {
        let lock = try XCTUnwrap(try InstanceLock.acquire(at: path))
        lock.release()
        lock.release()

        XCTAssertNotNil(try InstanceLock.acquire(at: path)?.release())
    }

    func testAStalePIDFileDoesNotBlockAcquisition() throws {
        // A crash leaves the file behind but the lock dies with the process:
        // the content is informational, the flock is the lock.
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("99999\n".utf8).write(to: path)

        let lock = try XCTUnwrap(try InstanceLock.acquire(at: path))
        defer { lock.release() }
        XCTAssertEqual(InstanceLock.holderPID(at: path), getpid())
    }

    /// A lock file that cannot be opened is its own failure: reported as
    /// "another instance is running", it sent the user looking for a copy
    /// of the app that did not exist.
    func testALockFileThatCannotBeOpenedThrowsRatherThanReportingAHolder() throws {
        // A regular file where the lock's directory should be: open(2)
        // fails with ENOTDIR whoever runs the test.
        let directory = path.deletingLastPathComponent()
        try Data().write(to: directory)

        XCTAssertThrowsError(try InstanceLock.acquire(at: path)) { error in
            XCTAssertTrue(error is InstanceLock.Unavailable, "got \(error)")
        }
    }
}
