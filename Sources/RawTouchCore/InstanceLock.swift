// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation

/// Single-instance guard: two RawTouch processes consuming the same touch
/// stream would each synthesize a full set of scroll gestures — the
/// double-scroll this whole architecture exists to prevent — so a second
/// instance must refuse to start.
///
/// Built on `flock(2)`, chosen deliberately over `fcntl` locks: flock is
/// held by the *open file description*, not the process, so it survives
/// fork/exec cleanly, dies with the descriptor when the process dies (no
/// stale locks — a leftover PID file from a crash carries no lock and does
/// not block the next start), and two descriptors in one process genuinely
/// conflict, which keeps the unit tests honest.
///
/// This is **best-effort mutual exclusion for new instances**: a process
/// started before the lock existed (or one that skips it) holds no lock and
/// is invisible here. That is fine and expected — the lock's job is to stop
/// a second copy of the app from starting, not to detect arbitrary stream
/// consumers.
public final class InstanceLock {
    public static let defaultPath = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/rawtouch/rawtouch.pid")

    /// The lock file could not be opened at all (a file left owned by
    /// root, a directory that cannot be written): no exclusion can be
    /// promised, but no other instance is running either, so it is not
    /// reported as one.
    public struct Unavailable: Error, CustomStringConvertible {
        public let path: URL
        /// The system's reason, as `strerror` words it.
        public let reason: String

        public var description: String {
            "Cannot open the lock file \(path.path): \(reason)"
        }
    }

    private var descriptor: Int32
    private let path: URL

    private init(descriptor: Int32, path: URL) {
        self.descriptor = descriptor
        self.path = path
    }

    deinit {
        release()
    }

    /// Takes the exclusive lock and records our PID in the file. Returns nil
    /// when the lock is held by another live instance; throws `Unavailable`
    /// when the lock file cannot be opened at all.
    public static func acquire(at path: URL = InstanceLock.defaultPath) throws -> InstanceLock? {
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let descriptor = open(path.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            throw Unavailable(path: path, reason: String(cString: strerror(errno)))
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }

        // The PID is informational only (a friendly error message for the
        // losing instance); the flock, not the content, is the lock.
        let pidLine = Data("\(getpid())\n".utf8)
        ftruncate(descriptor, 0)
        pidLine.withUnsafeBytes { buffer in
            _ = pwrite(descriptor, buffer.baseAddress, buffer.count, 0)
        }

        return InstanceLock(descriptor: descriptor, path: path)
    }

    /// The PID recorded by whoever last acquired the lock, for error
    /// messages. Nil when the file is absent or unreadable. Says nothing
    /// about whether that process is still alive — after a crash the file
    /// lingers but the lock does not.
    public static func holderPID(at path: URL = InstanceLock.defaultPath) -> pid_t? {
        guard let content = try? String(contentsOf: path, encoding: .utf8),
            let pid = pid_t(content.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }
        return pid
    }

    /// Drops the lock. Idempotent; also runs on deinit. The PID file itself
    /// is left in place — unlinking it would race a concurrent acquirer that
    /// already opened it.
    public func release() {
        guard descriptor >= 0 else {
            return
        }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
