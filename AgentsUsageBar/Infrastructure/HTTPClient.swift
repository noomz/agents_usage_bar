import Foundation

/// A non-200 HTTP response received from a provider API.
public struct HTTPError: Error, Equatable, Sendable {
    public let status: Int
    public let message: String?

    public init(status: Int, message: String? = nil) {
        self.status = status
        self.message = message
    }
}

/// Protocol seam for HTTP GET requests.
///
/// `URLSessionHTTPClient` is the production implementation.
/// Tests inject a stub conformance or use `URLProtocol` interception via the
/// `internal init(session:)` overload on `URLSessionHTTPClient`.
public protocol HTTPClient: Sendable {

    /// Performs a GET request to `url`, adds `Authorization: Bearer <secret>` and any
    /// `extraHeaders`, decodes the response JSON as `T`.
    ///
    /// `useSnakeCaseConversion` controls the response decoder:
    ///   - `true` (default) — applies `keyDecodingStrategy = .convertFromSnakeCase`.
    ///     The OpenRouter / Claude convention: response models use default camelCase
    ///     CodingKey rawValues and rely on the strategy.
    ///   - `false` — plain `JSONDecoder()`. Required for response models that declare
    ///     explicit snake_case CodingKey rawValues (e.g. `CodexUsageResponse`), which
    ///     would silently fail to match keys after `.convertFromSnakeCase` rewrites
    ///     incoming snake_case JSON keys to camelCase.
    ///
    /// - Throws: `HTTPError` for non-2xx responses; `DecodingError` for malformed JSON.
    func get<T: Decodable & Sendable>(
        _ url: URL,
        bearer: Secret,
        extraHeaders: [String: String],
        useSnakeCaseConversion: Bool,
        as type: T.Type
    ) async throws -> T

    /// Overload for unauthenticated probes (Phase 4 reuse; Phase 1 uses the bearer form).
    /// `useSnakeCaseConversion` semantics match the bearer-required variant.
    func get<T: Decodable & Sendable>(
        _ url: URL,
        bearer: Secret?,
        extraHeaders: [String: String],
        useSnakeCaseConversion: Bool,
        as type: T.Type
    ) async throws -> T

    /// Performs a POST request with a JSON-encoded body.
    ///
    /// CLAUDE-04 OAuth refresh use case: `ClaudeOAuthClient.refreshAccessToken()`
    /// posts `{grant_type, refresh_token, client_id}` to `platform.claude.com/v1/oauth/token`.
    ///
    /// POLL-08 invariant: Uses the shared `URLSession` singleton — do NOT bypass this
    /// method with a raw `URLSession.shared.data(for:)` call in provider code.
    ///
    /// SEC-02: Implementations must log only `url.path` + status, never the request body
    /// (the body contains the refresh token).
    ///
    /// - Parameters:
    ///   - url: The POST endpoint.
    ///   - body: Encodable payload. Keys are snake_case-encoded via `.convertToSnakeCase`.
    ///   - extraHeaders: Additional HTTP headers to include.
    ///   - type: The expected response `Decodable` type.
    /// - Throws: `HTTPError` for non-2xx responses; `EncodingError`/`DecodingError` for
    ///   malformed payloads.
    func postJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ url: URL,
        body: Body,
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T

    /// Bearer-authenticated `postJSON` overload. Adds
    /// `Authorization: Bearer <secret>` to the request via the SEC-01
    /// sanctioned reveal site (inside `URLSessionHTTPClient`).
    ///
    /// Plan 03-06 use case: Gemini's `v1internal:retrieveUserQuota` and
    /// `v1internal:loadCodeAssist` are JSON POSTs that REQUIRE a bearer.
    /// The bearer in this overload is on the **header**, not in the
    /// body — the SEC-01 invariant (one reveal call site total) holds.
    ///
    /// - Parameters:
    ///   - url: The POST endpoint.
    ///   - body: Encodable payload (JSON-encoded).
    ///   - bearer: `Secret` wrapping the access token.
    ///   - extraHeaders: Additional HTTP headers.
    ///   - type: The expected response `Decodable` type.
    /// - Throws: `HTTPError` for non-2xx; `EncodingError` / `DecodingError`.
    func postJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ url: URL,
        body: Body,
        bearer: Secret,
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T

    /// Performs a POST request with an `application/x-www-form-urlencoded`
    /// body. Used by Gemini's OAuth refresh path (`POST oauth2.googleapis.com/token`)
    /// which requires form-encoded credentials, not JSON.
    ///
    /// The request is **unauthenticated at the transport layer** — the body
    /// itself carries `refresh_token`. Do NOT add a `bearer:` parameter to
    /// this method; conflating "refresh credential in body" with "bearer in
    /// header" is exactly the SEC-01 pitfall the protocol shape is designed
    /// to prevent.
    ///
    /// Implementations MUST percent-encode each `formFields` value (keys
    /// are ASCII), join `key=value` pairs with `&`, set the Content-Type
    /// header, and never log the body (SEC-02; the body contains a
    /// long-lived refresh token).
    ///
    /// POLL-08 invariant: routed through the shared `URLSession` singleton.
    ///
    /// - Parameters:
    ///   - url: The form-POST endpoint.
    ///   - formFields: Key-value pairs (preserves caller-specified order).
    ///   - extraHeaders: Additional HTTP headers.
    ///   - type: The expected response `Decodable` type.
    /// - Throws: `HTTPError` for non-2xx; `DecodingError` for malformed JSON.
    func postFormURLEncoded<T: Decodable & Sendable>(
        _ url: URL,
        formFields: [(String, String)],
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T
}

// MARK: - Default-argument convenience overloads
//
// The required protocol methods carry the `useSnakeCaseConversion` flag without
// a default value (Swift protocols disallow parameter defaults). These extension
// shims preserve the pre-existing call-site ergonomics for OpenRouter / Claude
// (which want strategy = .convertFromSnakeCase) by forwarding with `true`.
//
// Callers that need plain decoding (e.g. Codex's wham/usage) MUST call the
// required method directly with `useSnakeCaseConversion: false`.
extension HTTPClient {
    public func get<T: Decodable & Sendable>(
        _ url: URL,
        bearer: Secret,
        extraHeaders: [String: String] = [:],
        as type: T.Type
    ) async throws -> T {
        try await get(
            url,
            bearer: bearer,
            extraHeaders: extraHeaders,
            useSnakeCaseConversion: true,
            as: type
        )
    }

    public func get<T: Decodable & Sendable>(
        _ url: URL,
        bearer: Secret?,
        extraHeaders: [String: String] = [:],
        as type: T.Type
    ) async throws -> T {
        try await get(
            url,
            bearer: bearer,
            extraHeaders: extraHeaders,
            useSnakeCaseConversion: true,
            as: type
        )
    }
}
