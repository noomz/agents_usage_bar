import Foundation

/// Protocol seam for OpenRouter HTTP calls.
///
/// `HTTPOpenRouterClient` is the production implementation.
/// Tests inject `FakeOpenRouterClient` for deterministic, network-free assertions.
public protocol OpenRouterClient: Sendable {

    /// Fetches current credit balance from `GET /api/v1/credits`.
    func getCredits() async throws -> OpenRouterCreditsResponse

    /// Fetches key metadata and quota from `GET /api/v1/key`.
    func getKey() async throws -> OpenRouterKeyResponse
}

/// Production `OpenRouterClient` backed by the shared `HTTPClient`.
///
/// SEC-01 / T-01.04-01: `bearer` (a `Secret`) is NEVER logged or persisted.
/// The only place it is revealed is inside `HTTPClient.get(_:bearer:extraHeaders:as:)`,
/// which is the single sanctioned `revealForRequest()` call site (Plan 01.02 invariant).
///
/// ROUTER-04: Optional `HTTP-Referer` and `X-Title` headers are forwarded when set.
public final class HTTPOpenRouterClient: OpenRouterClient, @unchecked Sendable {

    private let http: any HTTPClient
    private let endpoint: OpenRouterEndpoint
    private let bearer: Secret
    private let extraHeaders: [String: String]

    /// Creates a production OpenRouter client.
    ///
    /// - Parameters:
    ///   - http: The shared `HTTPClient` (one per app — POLL-08).
    ///   - endpoint: URL builder; defaults to production `openrouter.ai/api/v1` (ROUTER-04).
    ///   - bearer: API key wrapped in `Secret` — never revealed except at request-build site.
    ///   - httpReferer: Optional `HTTP-Referer` header value (ROUTER-04).
    ///   - xTitle: Optional `X-Title` header value (ROUTER-04). Defaults to "Agents Usage Bar".
    public init(
        http: any HTTPClient,
        endpoint: OpenRouterEndpoint,
        bearer: Secret,
        httpReferer: String?,
        xTitle: String
    ) {
        self.http = http
        self.endpoint = endpoint
        self.bearer = bearer

        var headers: [String: String] = [:]
        if let referer = httpReferer, !referer.isEmpty {
            headers["HTTP-Referer"] = referer
        }
        if !xTitle.isEmpty {
            headers["X-Title"] = xTitle
        }
        self.extraHeaders = headers
    }

    public func getCredits() async throws -> OpenRouterCreditsResponse {
        try await http.get(endpoint.credits, bearer: bearer, extraHeaders: extraHeaders, as: OpenRouterCreditsResponse.self)
    }

    public func getKey() async throws -> OpenRouterKeyResponse {
        try await http.get(endpoint.key, bearer: bearer, extraHeaders: extraHeaders, as: OpenRouterKeyResponse.self)
    }
}
