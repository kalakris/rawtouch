// MIT License
// Copyright (c) 2026 RawTouch contributors

import XCTest

@testable import RawTouchAppCore

/// GitHub's `releases/latest` answers, read without the network: the two
/// fields used, a 404 as "no release yet", and what the request carries.
final class ReleaseSourceTests: XCTestCase {
    private let url = URL(string: "https://api.github.com/repos/kalakris/rawtouch/releases/latest")!

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    /// A trimmed real answer: everything but the two fields is ignored.
    private let fixture = Data(
        #"""
        {
          "url": "https://api.github.com/repos/kalakris/rawtouch/releases/1",
          "html_url": "https://github.com/kalakris/rawtouch/releases/tag/v0.1.1",
          "id": 1,
          "tag_name": "v0.1.1",
          "name": "RawTouch 0.1.1",
          "draft": false,
          "prerelease": false,
          "published_at": "2026-10-01T12:00:00Z",
          "assets": [{ "name": "RawTouch-v0.1.1.dmg" }],
          "body": "Fixes."
        }
        """#.utf8)

    func testTheTagAndPageAreReadFromALatestReleaseBody() throws {
        let release = try GitHubReleaseSource.decode(fixture)

        XCTAssertEqual(release?.version, ReleaseVersion(major: 0, minor: 1, patch: 1))
        XCTAssertEqual(release?.url.absoluteString, "https://github.com/kalakris/rawtouch/releases/tag/v0.1.1")
    }

    func testATagThatIsNotAPlainVersionReadsAsNoRelease() throws {
        let body = Data(
            #"{"tag_name": "nightly", "html_url": "https://github.com/kalakris/rawtouch/releases/tag/nightly"}"#.utf8)

        XCTAssertNil(try GitHubReleaseSource.decode(body))
    }

    func testABodyWithoutTheFieldsIsAnError() {
        XCTAssertThrowsError(try GitHubReleaseSource.decode(Data(#"{"message": "Moved"}"#.utf8)))
        XCTAssertThrowsError(try GitHubReleaseSource.decode(Data("<html>".utf8)))
    }

    /// The menu opens the page in a browser, so it has to be one.
    func testAReleasePageThatIsNotHTTPSIsAnError() {
        let body = Data(#"{"tag_name": "v0.1.1", "html_url": "file:///Applications/Calculator.app"}"#.utf8)

        XCTAssertThrowsError(try GitHubReleaseSource.decode(body)) { error in
            XCTAssertEqual(
                error as? ReleaseSourceError, .untrustedReleaseURL("file:///Applications/Calculator.app"))
        }
    }

    /// And a GitHub one: an answer that points anywhere else is not a
    /// release page, however it is spelled.
    func testAReleasePageOffGitHubIsAnError() {
        for page in [
            "https://example.com/kalakris/rawtouch/releases/tag/v0.1.1",
            "https://github.com.example.com/releases/tag/v0.1.1",
            "http://github.com/kalakris/rawtouch/releases/tag/v0.1.1",
        ] {
            let body = Data(#"{"tag_name": "v0.1.1", "html_url": "\#(page)"}"#.utf8)
            XCTAssertThrowsError(try GitHubReleaseSource.decode(body), page) { error in
                XCTAssertEqual(error as? ReleaseSourceError, .untrustedReleaseURL(page))
            }
        }
        let github = Data(#"{"tag_name": "v0.1.1", "html_url": "https://GitHub.com/a/b/releases/tag/v0.1.1"}"#.utf8)
        XCTAssertNotNil(try GitHubReleaseSource.decode(github), "the host is case-insensitive")
    }

    func testA200IsTheRelease() throws {
        let result = GitHubReleaseSource.latestRelease(data: fixture, response: response(200), error: nil)

        XCTAssertEqual(try result.get()?.version, ReleaseVersion(major: 0, minor: 1, patch: 1))
    }

    /// What GitHub answers until a repository publishes its first release.
    func testA404IsNoReleaseRatherThanAFailure() throws {
        let body = Data(#"{"message": "Not Found"}"#.utf8)
        let result = GitHubReleaseSource.latestRelease(data: body, response: response(404), error: nil)

        XCTAssertNil(try result.get())
    }

    func testOtherStatusesAndTransportErrorsAreFailures() {
        let limited = GitHubReleaseSource.latestRelease(data: Data(), response: response(403), error: nil)
        XCTAssertThrowsError(try limited.get()) { error in
            XCTAssertEqual(error as? ReleaseSourceError, .unexpectedStatus(403))
        }

        let offline = GitHubReleaseSource.latestRelease(
            data: nil, response: nil, error: URLError(.notConnectedToInternet))
        XCTAssertThrowsError(try offline.get()) { error in
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    // MARK: - The request

    func testTheRequestIsAnAnonymousGETNamingTheAppVersion() {
        let source = GitHubReleaseSource(appVersion: AppVersion(shortVersion: "0.1.0", build: "42"))

        let request = source.request(for: .module)

        XCTAssertEqual(
            request.url?.absoluteString, "https://api.github.com/repos/kalakris/zmk-raw-touch/releases/latest")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertEqual(
            request.allHTTPHeaderFields,
            ["Accept": "application/vnd.github+json", "User-Agent": "RawTouch/0.1.0"]
        )
    }

    func testTheSessionKeepsNothingAndSendsNothingStored() {
        let configuration = GitHubReleaseSource.makeSession().configuration

        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testTheAppAndModuleRepositories() {
        XCTAssertEqual(
            ReleaseRepository.app.latestReleaseURL.absoluteString,
            "https://api.github.com/repos/kalakris/rawtouch/releases/latest"
        )
        XCTAssertEqual(
            ReleaseRepository.module.latestReleaseURL.absoluteString,
            "https://api.github.com/repos/kalakris/zmk-raw-touch/releases/latest"
        )
    }
}
