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
    /// - Throws: `HTTPError` for non-2xx responses; `DecodingError` for malformed JSON.
    func get<T: Decodable & Sendable>(
        _ url: URL,
        bearer: Secret,
        extraHeaders: [String: String],
        as type: T.Type
    ) async throws -> T

    /// Overload for unauthenticated probes (Phase 4 reuse; Phase 1 uses the bearer form).
    func get<T: Decodable & Sendable>(
        _ url: URL,
        bearer: Secret?,
        extraHeaders: [String: String],
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
}
