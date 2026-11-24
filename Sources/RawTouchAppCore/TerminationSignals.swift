// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import RawTouchCore

/// Turns SIGTERM, SIGINT and SIGHUP into an ordinary quit. The default
/// action for those signals ends the process on the spot, so the lease is
/// never released and the keyboard stays out of Standard mode until the
/// firmware's lease timeout; `killall`, `kill`, launchd stopping a login
/// item and uninstallers all send SIGTERM. Routed through `terminate`
/// instead, the app runs the same bounded shutdown as Quit.
///
/// SIGKILL cannot be caught, so a `kill -9` still leaves the lease to time
/// out on the keyboard.
public final class TerminationSignals {
    public static let handled: [Int32] = [SIGTERM, SIGINT, SIGHUP]

    private let terminate: () -> Void
    private var sources: [DispatchSourceSignal] = []
    private var terminating = false

    /// `terminate` runs on the main queue, at most once.
    public init(terminate: @escaping () -> Void) {
        self.terminate = terminate
    }

    /// Replaces the default action of every handled signal with a main-queue
    /// call to `handle`. The disposition is set to SIG_IGN first: a dispatch
    /// source only observes a signal, and without the ignore the default
    /// action would still kill the process. Call once, from the main thread.
    public func install() {
        guard sources.isEmpty else {
            return
        }
        for signo in Self.handled {
            signal(signo, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signo, queue: .main)
            source.setEventHandler { [weak self] in
                self?.handle(signo)
            }
            source.resume()
            sources.append(source)
        }
    }

    /// Starts the quit for the first signal; any later one does nothing, so
    /// a repeated `killall` cannot re-enter or extend the shutdown, which
    /// stays bounded by the lease-release timeout. Main queue only.
    public func handle(_ signo: Int32) {
        guard !terminating else {
            return
        }
        terminating = true
        let name = String(cString: strsignal(signo))
        RawTouchLog.note("Received signal \(signo) (\(name)); quitting and releasing the lease")
        terminate()
    }
}
