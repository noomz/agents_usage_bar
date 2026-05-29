import Foundation
import os.log

/// Production `HTTPClient` implementation backed by a single shared `URLSession`.
///
/// POLL-08 / CLAUDE.md: One `URLSession` instance per app. The session is configured
/// once in `init()` and is immutable thereafter (`@unchecked Sendable` is safe).
///
/// Configuration (per CLAUDE.md "Concurrency & Polling Pattern"):
/// - `timeoutIntervalForRequest = 8`      — per-request timeout
/// - `timeoutIntervalForResource = 30`    — overall resource timeout
/// - `waitsForConnectivity = false`       — fail-fast when offline
/// - `httpMaximumConnectionsPerHost = 6`  — matches HTTP/1.1 concurrency ceiling
/// - `requestCachePolicy = .reloadIgnoringLocalCacheData` — always fresh from server
///
/// SEC-02 / Pitfall 11: Log lines contain ONLY `url.path` and HTTP status — never
/// `url.absoluteString`, `url.query`, request headers, or response body.
public final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {

    private let session: URLSession
    private let logger = AppLogger.logger(category: "http")

    // MARK: - Production initializer

    /// Creates the URLSession singleton with the locked POLL-08 configuration.
    public init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Test seam initializer

    /// Initialises with a pre-configured `URLSession` (e.g. one with `StubURLProtocol`).
    ///
    /// Internal access — only used from `AgentsUsageBarTests`.
    internal init(session: URLSession) {
        self.session = session
    }

    // MARK: - Configuration inspection (test support)

    /// Returns the configuration of the underlying URLSession.
    /// Internal access — used by `URLSessionHTTPClientTests` to verify POLL-08 settings.
    internal func configurationSnapshot() -> URLSessionConfiguration {
        session.configuration
    }

    // MARK: - HTTPClient conformance

    public func get<T: Decodable & Sendable>(
        _ url: URL,
        bearer: Secret,
        extraHeaders: [String: String] = [:],
        as type: T.Type
    ) async throws -> T {
        try await performGet(url: url, bearer: bearer, extraHeaders: extraHeaders, as: type)
    }

    public func get<T: Decodable & Sendable>(
        _ url: URL,
        bearer: Secret?,
        extraHeaders: [String: String] = [:],
        as type: T.Type
    ) async throws -> T {
        try await performGet(url: url, bearer: bearer, extraHeaders: extraHeaders, as: type)
    }

    // MARK: - HTTPClient POST conformance

    /// `application/x-www-form-urlencoded` POST — Gemini OAuth refresh.
    ///
    /// SEC-02: the request body contains a long-lived refresh_token; the
    /// log line carries only `url.path` + status, never the body.
    public func postFormURLEncoded<T: Decodable & Sendable>(
        _ url: URL,
        formFields: [(String, String)],
        extraHeaders: [String: String] = [:],
        as type: T.Type
    ) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (key, value) in extraHeaders {
            req.setValue(value, forHTTPHeaderField: key)
        }

        // Percent-encode each value (keys are always ASCII tokens by
        // RFC 6749 §A.x). `.urlQueryAllowed` is the standard char set for
        // application/x-www-form-urlencoded.
        let encoded = formFields
            .map { key, value -> String in
                let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
                return "\(key)=\(v)"
            }
            .joined(separator: "&")
        req.httpBody = encoded.data(using: .utf8)

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1

        // SEC-02 / Pitfall 11: log path + status ONLY. Never log the
        // form body (it carries the refresh credential).
        logger.info("POST \(url.path, privacy: .public) → \(status, privacy: .public)")

        guard (200..<300).contains(status) else {
            throw HTTPError(status: status, message: nil)
        }

        // Plan 03-05: response decoders that use `postFormURLEncoded`
        // (currently only `GeminiTokenRefreshResponse`) declare explicit
        // snake_case `CodingKeys`. A `convertFromSnakeCase` strategy would
        // pre-rewrite the JSON keys to camelCase before key lookup and
        // miss the explicit `"access_token"` mapping. Plain `JSONDecoder()`
        // matches the Codex precedent.
        return try JSONDecoder().decode(T.self, from: data)
    }

    public func postJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ url: URL,
        body: Body,
        extraHeaders: [String: String] = [:],
        as type: T.Type
    ) async throws -> T {
        try await performPostJSON(
            url: url,
            body: body,
            bearer: nil,
            extraHeaders: extraHeaders,
            useSnakeCaseConversion: true,
            as: type
        )
    }

    /// Bearer-authenticated JSON POST — Plan 03-06 entry point for the
    /// Gemini `v1internal` calls.
    ///
    /// Plan 03-06 invariant: the body uses **plain JSON encoding** (no
    /// `convertToSnakeCase` strategy). The Gemini `v1internal:loadCodeAssist`
    /// endpoint requires camelCase keys (`ideType`, `pluginType`) in the
    /// request body. The `.convertToSnakeCase` strategy would rewrite
    /// those to `ide_type` / `plugin_type` (which the API rejects).
    /// Plain encoding preserves the explicit CodingKey strings.
    public func postJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ url: URL,
        body: Body,
        bearer: Secret,
        extraHeaders: [String: String] = [:],
        as type: T.Type
    ) async throws -> T {
        try await performPostJSON(
            url: url,
            body: body,
            bearer: bearer,
            extraHeaders: extraHeaders,
            useSnakeCaseConversion: false,
            as: type
        )
    }

    private func performPostJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        url: URL,
        body: Body,
        bearer: Secret?,
        extraHeaders: [String: String],
        useSnakeCaseConversion: Bool,
        as type: T.Type
    ) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // SEC-01: the reveal-accessor is permitted ONLY inside URL
        // request construction in this file. Adding the bearer here on
        // the JSON-POST path preserves the single-call-site invariant.
        if let bearer {
            req.setValue("Bearer \(bearer.revealForRequest())", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in extraHeaders {
            req.setValue(value, forHTTPHeaderField: key)
        }

        let encoder = JSONEncoder()
        if useSnakeCaseConversion {
            encoder.keyEncodingStrategy = .convertToSnakeCase
        }
        req.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1

        // SEC-02 / Pitfall 11: log path + status ONLY. Never log request body
        // (it contains the refresh token — SEC-NOTE from ClaudeOAuthClient).
        logger.info("POST \(url.path, privacy: .public) → \(status, privacy: .public)")

        guard (200..<300).contains(status) else {
            throw HTTPError(status: status, message: nil)
        }

        // Gemini quota/tier responses declare explicit snake_case
        // CodingKeys (matches Codex / Plan 03-05 precedent). Plain
        // JSONDecoder reads them correctly; a convertFromSnakeCase
        // strategy would clobber the explicit mappings — same trap as
        // Plan 03-05's URLSessionHTTPClient.postFormURLEncoded fix.
        let decoder = JSONDecoder()
        if useSnakeCaseConversion {
            decoder.keyDecodingStrategy = .convertFromSnakeCase
        }
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Private

    private func performGet<T: Decodable & Sendable>(
        url: URL,
        bearer: Secret?,
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"

        // SEC-01: revealForRequest() is the ONLY sanctioned call site in the entire
        // Phase 1 codebase. Do not add additional call sites elsewhere.
        if let bearer {
            req.setValue("Bearer \(bearer.revealForRequest())", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in extraHeaders {
            req.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1

        // SEC-02 / Pitfall 11: log path + status ONLY. Never log absoluteString or query.
        logger.info("GET \(url.path, privacy: .public) → \(status, privacy: .public)")

        guard (200..<300).contains(status) else {
            throw HTTPError(status: status, message: nil)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}
