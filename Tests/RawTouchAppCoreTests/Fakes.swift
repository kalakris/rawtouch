// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation
import RawTouchCore
import RawTouchTestSupport

@testable import RawTouchAppCore

/// A `LoginItemManaging` that records registrations and can be told to fail.
final class FakeLoginItems: LoginItemManaging {
    struct RegistrationError: Error, LocalizedError {
        var errorDescription: String? { "registration refused" }
    }

    var isEnabled = false
    var shouldThrow = false
    private(set) var setEnabledCalls: [Bool] = []

    func setEnabled(_ enabled: Bool) throws {
        setEnabledCalls.append(enabled)
        if shouldThrow {
            throw RegistrationError()
        }
        isEnabled = enabled
    }
}

/// A mutable box for the injected trust check, so a test can flip the
/// "granted" state under a live model.
final class TrustBox {
    var trusted: Bool

    init(_ trusted: Bool) {
        self.trusted = trusted
    }
}

/// A `ReleaseSource` answering from canned results, synchronously by
/// default. With `holdsCompletions` it keeps them instead, so a test can
/// answer while another check is asked for.
final class FakeReleaseSource: ReleaseSource {
    struct Unreachable: Error {}

    var results: [ReleaseRepository: Result<LatestRelease?, Error>] = [:]
    var holdsCompletions = false
    private(set) var requests: [ReleaseRepository] = []
    private(set) var heldCompletions: [(ReleaseRepository, (Result<LatestRelease?, Error>) -> Void)] = []

    func latestRelease(
        of repository: ReleaseRepository,
        completion: @escaping (Result<LatestRelease?, Error>) -> Void
    ) {
        requests.append(repository)
        guard !holdsCompletions else {
            heldCompletions.append((repository, completion))
            return
        }
        completion(results[repository] ?? .success(nil))
    }

    /// Answers every held request from `results`.
    func answerHeld() {
        let held = heldCompletions
        heldCompletions = []
        for (repository, completion) in held {
            completion(results[repository] ?? .success(nil))
        }
    }
}

/// A release at `version` (a tag), with a page URL to match.
func publishedRelease(_ tag: String, repository: ReleaseRepository = .app) -> LatestRelease {
    LatestRelease(
        version: ReleaseVersion(tag: tag)!,
        url: URL(string: "https://github.com/\(repository.path)/releases/tag/\(tag)")!
    )
}
