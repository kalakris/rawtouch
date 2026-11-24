// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import os.log

/// Watches a configuration file and delivers freshly loaded configurations
/// as its content changes, so edits apply without a restart.
///
/// Two dispatch sources cooperate, because neither alone sees everything:
///
/// - A **parent-directory** source (`.write` on the directory) fires when an
///   entry is added, removed or renamed — which is how atomic saves land
///   (editors and `Data.write(options: .atomic)` write a temp file and
///   rename it over the target, replacing the inode), and how a file that
///   did not exist yet appears.
/// - A **file** source on the config file itself fires on in-place writes,
///   which never touch the directory. It is re-armed on every reload since
///   an atomic replace leaves the old descriptor watching a dead inode.
///
/// Events are debounced (default 200 ms) so an editor's
/// write-truncate-write burst or an atomic save's temp-then-rename pair
/// loads once. The callback runs on the main queue with the result of
/// `RawTouchConfiguration.load`; identical file content is suppressed by a
/// byte compare, so touching the file without changing it delivers nothing
/// — and neither does a write made through `save(_:)`, whose bytes the
/// watcher records as already seen. A missing file counts as content (the
/// defaults), matching `load`.
///
/// All state is main-queue-only, like `RawTouchDeviceManager`'s device state.
public final class ConfigFileWatcher {
    public static let defaultDebounceInterval: TimeInterval = 0.2

    private let path: URL
    private let directory: URL
    private let debounceInterval: TimeInterval
    private let onChange: (Result<RawTouchConfiguration, Error>) -> Void

    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

    /// The file bytes behind the last delivery (nil = file absent), used to
    /// suppress deliveries when the content did not actually change.
    private var lastContent: Data?

    private var started = false

    public init(
        path: URL = RawTouchConfiguration.defaultPath,
        debounceInterval: TimeInterval = ConfigFileWatcher.defaultDebounceInterval,
        onChange: @escaping (Result<RawTouchConfiguration, Error>) -> Void
    ) {
        self.path = path
        directory = path.deletingLastPathComponent()
        self.debounceInterval = debounceInterval
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle (main queue)

    /// Begins watching. The current content is taken as the baseline — only
    /// changes *after* this call are delivered (the caller has just loaded
    /// the file itself and does not want an echo).
    public func start() {
        guard !started else {
            return
        }
        started = true

        // The directory must exist to be watched; creating it is harmless
        // (`RawTouchConfiguration.save` would create it anyway).
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        lastContent = try? Data(contentsOf: path)

        directorySource = makeSource(watching: directory, eventMask: .write)
        armFileSource()

        if directorySource == nil {
            os_log(
                "Cannot watch %{public}@; configuration changes will need a restart",
                log: RawTouchLog.configuration,
                type: .error,
                directory.path
            )
        }
    }

    public func stop() {
        guard started else {
            return
        }
        started = false

        pendingReload?.cancel()
        pendingReload = nil
        directorySource?.cancel()
        directorySource = nil
        fileSource?.cancel()
        fileSource = nil
    }

    // MARK: - Writing (main queue)

    /// Saves `configuration` to the watched file and records the bytes as
    /// already seen, so the write's own echo stops at the byte compare in
    /// `reload()`. The echo arrives a debounce later, and by then the
    /// writer may have moved on: a reload of an older save must never land
    /// on top of a newer edit.
    public func save(_ configuration: RawTouchConfiguration) throws {
        try configuration.save(to: path)
        lastContent = try? Data(contentsOf: path)
    }

    // MARK: - Sources

    private func makeSource(
        watching url: URL,
        eventMask: DispatchSource.FileSystemEvent
    ) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            return nil
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: eventMask,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        return source
    }

    /// (Re-)arms the file source. Called at start and after every reload:
    /// an atomic replace swaps the inode out from under the old descriptor,
    /// and a file that was absent may exist now.
    private func armFileSource() {
        fileSource?.cancel()
        fileSource = makeSource(
            watching: path,
            eventMask: [.write, .extend, .delete, .rename]
        )
    }

    // MARK: - Reload

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reload()
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func reload() {
        pendingReload = nil
        armFileSource()

        // One read serves both the change check and the decode, so what is
        // delivered is exactly the content that was compared.
        let exists = FileManager.default.fileExists(atPath: path.path)
        let read = Result { try Data(contentsOf: path) }
        let content = try? read.get()
        guard content != lastContent else {
            return
        }
        lastContent = content

        // As `RawTouchConfiguration.load`: a missing file is the defaults,
        // an unreadable or malformed one an error.
        onChange(
            Result {
                exists ? try RawTouchConfiguration.decode(fileContents: read.get()) : RawTouchConfiguration()
            })
    }
}
