// MIT License
// Copyright (c) 2026 RawTouch contributors

import RawTouchTestSupport
import XCTest

@testable import RawTouchAppCore

/// When the update check asks, and what it hands back: against a fake
/// source and a scheduler whose timers fire on demand, so no test waits a
/// day, or ten seconds, or touches the network.
final class UpdateCheckerTests: XCTestCase {
    private var source: FakeReleaseSource!
    private var scheduler: FakeTimerScheduler!
    private var checksAutomatically = true
    private var results: [(Result<LatestReleases, Error>, UpdateChecker.Kind)] = []
    private var checker: UpdateChecker!

    override func setUp() {
        source = FakeReleaseSource()
        scheduler = FakeTimerScheduler()
        checksAutomatically = true
        results = []
        checker = UpdateChecker(
            source: source,
            scheduler: scheduler,
            checksAutomatically: { [unowned self] in checksAutomatically },
            onResult: { [unowned self] result, kind in results.append((result, kind)) }
        )
    }

    private var kinds: [UpdateChecker.Kind] {
        results.map(\.1)
    }

    func testTheFirstCheckComesShortlyAfterStartThenDaily() {
        checker.start()
        XCTAssertEqual(scheduler.liveTimers.map(\.interval), [UpdateChecker.firstCheckDelay])
        XCTAssertEqual(source.requests, [], "nothing is asked at launch itself")

        scheduler.fireOneShots()
        XCTAssertEqual(source.requests, [.app, .module])
        XCTAssertEqual(kinds, [.automatic])
        XCTAssertEqual(scheduler.liveTimers.map(\.interval), [UpdateChecker.checkInterval])
        XCTAssertEqual(scheduler.liveTimers.first?.repeats, true)

        scheduler.fireRepeating(count: 2)
        XCTAssertEqual(kinds, [.automatic, .automatic, .automatic])
    }

    func testWithTheSettingOffNoAutomaticCheckAsksAnything() {
        checksAutomatically = false
        checker.start()

        scheduler.fireOneShots()
        scheduler.fireRepeating(count: 3)

        XCTAssertEqual(source.requests, [])
        XCTAssertTrue(results.isEmpty)
    }

    /// The setting is read when a check comes due, so switching it on needs
    /// no rescheduling: the next daily check runs.
    func testTheSettingIsReadWhenEachCheckComesDue() {
        checksAutomatically = false
        checker.start()
        scheduler.fireOneShots()

        checksAutomatically = true
        scheduler.fireRepeating(count: 1)

        XCTAssertEqual(kinds, [.automatic])
    }

    func testAManualCheckRunsWhateverTheSettingSays() {
        checksAutomatically = false

        checker.check(.manual)

        XCTAssertEqual(source.requests, [.app, .module])
        XCTAssertEqual(kinds, [.manual])
    }

    func testBothReleasesComeBackAsOneResult() throws {
        source.results = [
            .app: .success(publishedRelease("v0.1.1")),
            .module: .success(publishedRelease("v0.2.0", repository: .module)),
        ]

        checker.check(.manual)

        XCTAssertEqual(
            try results.first?.0.get(),
            LatestReleases(app: publishedRelease("v0.1.1"), module: publishedRelease("v0.2.0", repository: .module))
        )
    }

    func testEitherRepositoryFailingFailsTheCheck() {
        source.results = [
            .app: .success(publishedRelease("v0.1.1")), .module: .failure(FakeReleaseSource.Unreachable()),
        ]

        checker.check(.automatic)

        XCTAssertThrowsError(try results.first?.0.get())
    }

    /// One check at a time: a manual ask during an automatic check joins it
    /// rather than asking twice, and is answered as manual.
    func testAskingDuringACheckJoinsIt() {
        source.holdsCompletions = true
        checker.check(.automatic)
        checker.check(.manual)
        XCTAssertEqual(source.requests, [.app, .module])

        source.answerHeld()
        XCTAssertEqual(kinds, [.manual])

        checker.check(.automatic)
        XCTAssertEqual(source.requests.count, 4, "a finished check does not block the next")
    }

    func testStoppingCancelsTheScheduleAndDropsALateAnswer() {
        checker.start()
        source.holdsCompletions = true
        checker.check(.manual)

        checker.stop()
        source.answerHeld()

        XCTAssertTrue(scheduler.liveTimers.isEmpty)
        XCTAssertTrue(results.isEmpty)
    }
}
