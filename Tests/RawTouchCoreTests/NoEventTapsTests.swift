// MIT License
// Copyright (c) 2026 RawTouch contributors

import XCTest

/// RawTouch's Accessibility grant is broad enough to read keystrokes; the
/// README promises that it does not. This test makes that promise
/// checkable rather than asserted: no file under `Sources/` may name an
/// event-tap, keyboard-event or device-seize API. The shipped binary can
/// be checked the same way without the source:
///
///     nm -u RawTouch.app/Contents/MacOS/RawTouch | grep CGEventTap
///
/// prints nothing. Comments are stripped before matching so the API can
/// still be *mentioned*, e.g. to say it is not used.
final class NoEventTapsTests: XCTestCase {
    private static let forbidden = [
        "tapCreate",  // CGEvent.tapCreate (Swift)
        "CGEventTap",  // CGEventTapCreate, CGEventTapEnable, ... (C)
        "CGEventCreateKeyboardEvent",
        "keyboardEventSource",  // CGEvent(keyboardEventSource:...)
        "kIOHIDOptionsTypeSeizeDevice",
    ]

    func testSourcesNameNoEventTapAPI() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // RawTouchCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10, "expected to find the Swift sources under \(sources.path)")

        var hits: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                for pattern in Self.forbidden where code.contains(pattern) {
                    hits.append("\(file.lastPathComponent):\(index + 1): \(pattern)")
                }
            }
        }
        XCTAssertTrue(
            hits.isEmpty, "event-tap or keyboard-input API named in Sources/:\n" + hits.joined(separator: "\n"))
    }
}
