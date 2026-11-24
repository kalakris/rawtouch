// MIT License
// Copyright (c) 2026 RawTouch contributors

import Foundation

/// Where the update check learns the latest releases. A seam so the tests
/// answer with canned results instead of the network.
public protocol ReleaseSource {
    /// The repository's latest published release, or nil when it has none.
    /// Completes on the main queue.
    func latestRelease(
        of repository: ReleaseRepository,
        completion: @escaping (Result<LatestRelease?, Error>) -> Void
    )
}

/// Why a check could not tell.
public enum ReleaseSourceError: Error, Equatable, CustomStringConvertible {
    case notHTTP
    /// Anything but 200 and 404 — a rate limit, an outage.
    case unexpectedStatus(Int)
    /// A release page that is not on `https://github.com`, which the menu
    /// will not open.
    case untrustedReleaseURL(String)

    public var description: String {
        switch self {
        case .notHTTP:
            return "not an HTTP response"
        case .unexpectedStatus(let status):
            return "HTTP \(status)"
        case .untrustedReleaseURL(let url):
            return "release page is not on https://github.com: \(url)"
        }
    }
}

/// GitHub's REST API, anonymously: one GET per repository, with no cookies,
/// no cache and no credentials, so the request carries nothing beyond the
/// standard headers and a `User-Agent` naming the app version (which
/// GitHub requires). Of the answer, only `tag_name` and `html_url` are read.
public final class GitHubReleaseSource: ReleaseSource {
    public static let timeout: TimeInterval = 15

    private let userAgent: String
    private let session: URLSession

    public init(appVersion: AppVersion = .current) {
        userAgent = "RawTouch/\(appVersion.shortVersion)"
        session = Self.makeSession()
    }

    /// An ephemeral session: nothing persists between checks, and nothing
    /// the system keeps for other apps (cookies, cached responses, stored
    /// credentials) is sent.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }

    func request(for repository: ReleaseRepository) -> URLRequest {
        var request = URLRequest(
            url: repository.latestReleaseURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: Self.timeout
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    public func latestRelease(
        of repository: ReleaseRepository,
        completion: @escaping (Result<LatestRelease?, Error>) -> Void
    ) {
        session.dataTask(with: request(for: repository)) { data, response, error in
            let result = Self.latestRelease(data: data, response: response, error: error)
            DispatchQueue.main.async {
                completion(result)
            }
        }.resume()
    }

    /// What a response says. A 404 is the answer for a repository with no
    /// published release — every repository before its first tag — so it
    /// is "none", not a failure.
    static func latestRelease(data: Data?, response: URLResponse?, error: Error?) -> Result<LatestRelease?, Error> {
        if let error {
            return .failure(error)
        }
        guard let response = response as? HTTPURLResponse else {
            return .failure(ReleaseSourceError.notHTTP)
        }
        switch response.statusCode {
        case 200:
            return Result { try decode(data ?? Data()) }
        case 404:
            return .success(nil)
        default:
            return .failure(ReleaseSourceError.unexpectedStatus(response.statusCode))
        }
    }

    private struct Payload: Decodable {
        var tagName: String
        var htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    /// The release a `releases/latest` body describes. A tag that is not a
    /// plain `vX.Y.Z` is no release to compare against, so it reads as
    /// none, the same as a repository without releases. The page is opened
    /// in the user's browser, so it must be a GitHub page over https:
    /// anything else is an error, never a link.
    static func decode(_ data: Data) throws -> LatestRelease? {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.htmlURL.scheme == "https", payload.htmlURL.host?.lowercased() == "github.com" else {
            throw ReleaseSourceError.untrustedReleaseURL(payload.htmlURL.absoluteString)
        }
        return ReleaseVersion(tag: payload.tagName).map { LatestRelease(version: $0, url: payload.htmlURL) }
    }
}
