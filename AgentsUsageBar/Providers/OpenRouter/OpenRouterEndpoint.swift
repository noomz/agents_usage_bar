import Foundation

/// URL builder for OpenRouter API endpoints.
///
/// ROUTER-04: `baseURL` is overridable via `OPENROUTER_API_URL` env var (handled by `ConfigStore`).
/// The default points to the production OpenRouter v1 API.
public struct OpenRouterEndpoint: Sendable, Equatable {

    /// The base URL for all OpenRouter API calls.
    /// Default: `https://openrouter.ai/api/v1`
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Production endpoint using the canonical OpenRouter base URL.
    public static let `default` = OpenRouterEndpoint(
        baseURL: URL(string: "https://openrouter.ai/api/v1")!
    )

    /// `GET /api/v1/credits` — returns `total_credits` and `total_usage` (in USD).
    public var credits: URL {
        baseURL.appending(path: "credits")
    }

    /// `GET /api/v1/key` — returns quota limits, usage breakdown, and account tier.
    public var key: URL {
        baseURL.appending(path: "key")
    }
}
