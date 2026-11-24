// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchTestSupport
import XCTest

@testable import RawTouchCore

/// The config-file watcher against a real temp directory: creation,
/// in-place modification, atomic replace, debounce coalescing, malformed
/// content, and unchanged-content suppression. Deliveries land on the main
/// queue, which `wait(for:)` services.
final class ConfigFileWatcherTests: XCTestCase {
    private var directory: URL!
    private var watcher: ConfigFileWatcher?
    private var results: [Result<RawTouchConfiguration, Error>] = []

    private var path: URL {
        directory.appendingPathComponent("config.json")
    }

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rawtouch-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        results = []
    }

    override func tearDown() {
        watcher?.stop()
        watcher = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// Starts a watcher with a short debounce that records every delivery
    /// and fulfills `expectation` per delivery.
    private func startWatcher(fulfilling expectation: XCTestExpectation) {
        let watcher = ConfigFileWatcher(path: path, debounceInterval: 0.05) { [weak self] result in
            self?.results.append(result)
            expectation.fulfill()
        }
        self.watcher = watcher
        watcher.start()
    }

    private var deliveredConfigurations: [RawTouchConfiguration] {
        results.compactMap { try? $0.get() }
    }

    // MARK: - Content changes that must be delivered

    func testAFileAppearingAfterStartIsDelivered() throws {
        let delivered = expectation(description: "created file delivered")
        startWatcher(fulfilling: delivered)

        try Data(#"{"scale": 0.5}"#.utf8).write(to: path)

        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(deliveredConfigurations.last?.scale, 0.5)
    }

    func testAnInPlaceModificationIsDelivered() throws {
        // In-place writes never touch the parent directory's mtime — this is
        // what the re-armed file source exists for.
        try Data(#"{"scale": 0.5}"#.utf8).write(to: path)
        let delivered = expectation(description: "modification delivered")
        startWatcher(fulfilling: delivered)

        let handle = try FileHandle(forWritingTo: path)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(#"{"scale": 0.75}"#.utf8))
        try handle.close()

        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(deliveredConfigurations.last?.scale, 0.75)
    }

    func testAnAtomicReplaceIsDelivered() throws {
        // The editor/Foundation save pattern: write a temp file, rename it
        // over the target. The old inode dies; the watcher must survive.
        try Data(#"{"scale": 0.5}"#.utf8).write(to: path)
        let delivered = expectation(description: "replaced file delivered")
        startWatcher(fulfilling: delivered)

        let temp = directory.appendingPathComponent("config.json.tmp")
        try Data(#"{"reverseScrolling": true}"#.utf8).write(to: temp)
        XCTAssertEqual(rename(temp.path, path.path), 0)

        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(deliveredConfigurations.last?.reverseScrolling, true)
    }

    func testSaveThenWatchRoundTrips() throws {
        let delivered = expectation(description: "saved configuration delivered")
        startWatcher(fulfilling: delivered)

        var configuration = RawTouchConfiguration()
        configuration.scale = 0.4
        configuration.acceleration.enabled = true
        configuration[pad: "1"] = .init(scale: 0.5, invert: true)
        try configuration.save(to: path)

        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(deliveredConfigurations.last, configuration)
    }

    // MARK: - Debounce

    func testABurstOfWritesCoalescesIntoOneDelivery() throws {
        let delivered = expectation(description: "burst delivered once")
        startWatcher(fulfilling: delivered)

        // An editor-style burst: several writes well inside the debounce
        // window must load once, with the final content.
        try Data(#"{"scale": 0.1}"#.utf8).write(to: path)
        try Data(#"{"scale": 0.2}"#.utf8).write(to: path)
        try Data(#"{"scale": 0.3}"#.utf8).write(to: path)

        wait(for: [delivered], timeout: 2)
        // Let any (wrong) extra deliveries drain before counting.
        let drained = expectation(description: "drained")
        drained.isInverted = true
        wait(for: [drained], timeout: 0.3)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(deliveredConfigurations.last?.scale, 0.3)
    }

    // MARK: - Failures and non-changes

    func testMalformedContentDeliversTheError() throws {
        let delivered = expectation(description: "error delivered")
        startWatcher(fulfilling: delivered)

        try Data("{ not json".utf8).write(to: path)

        wait(for: [delivered], timeout: 2)
        guard case .failure = results.last else {
            XCTFail("expected a failure for malformed JSON, got \(String(describing: results.last))")
            return
        }
    }

    func testRewritingIdenticalContentDeliversNothing() throws {
        try Data(#"{"scale": 0.5}"#.utf8).write(to: path)
        let delivered = expectation(description: "no delivery for identical content")
        delivered.isInverted = true
        startWatcher(fulfilling: delivered)

        try Data(#"{"scale": 0.5}"#.utf8).write(to: path)

        wait(for: [delivered], timeout: 0.4)
        XCTAssertTrue(results.isEmpty)
    }

    /// The watcher's own writes are not news: their echo would otherwise
    /// arrive a debounce later, when the writer may have moved on. An
    /// outside edit after one is still delivered.
    func testASaveThroughTheWatcherIsNotDeliveredBack() throws {
        let watcher = ConfigFileWatcher(path: path, debounceInterval: 0.05) { [weak self] result in
            self?.results.append(result)
        }
        self.watcher = watcher
        watcher.start()

        var saved = RawTouchConfiguration()
        saved.scale = 0.4
        try watcher.save(saved)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))

        XCTAssertTrue(results.isEmpty, "our own save must not come back")
        XCTAssertEqual(try RawTouchConfiguration.load(from: path), saved, "and it was written")

        try Data(#"{"scale": 0.6}"#.utf8).write(to: path)
        let deadline = Date().addingTimeInterval(2)
        while results.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(deliveredConfigurations.map(\.scale), [0.6])
    }
}
