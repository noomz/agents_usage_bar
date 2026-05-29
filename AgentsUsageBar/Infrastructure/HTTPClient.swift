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
}
