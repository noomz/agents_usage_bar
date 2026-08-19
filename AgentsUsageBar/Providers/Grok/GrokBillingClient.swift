import Foundation

/// Narrow protocol so tests inject a stub without touching HTTP.
public protocol GrokBillingClientProtocol: Actor {
    func fetchCredits() async throws -> GrokBillingResponse
}

/// `GET {base}/billing?format=credits` with the Grok CLI header set.
public actor GrokBillingClient: GrokBillingClientProtocol {

    public static let defaultBaseURL = URL(string: "https://cli-chat-proxy.grok.com/v1")!

    private let http: any HTTPClient
    private let bearer: Secret
    private let endpoint: URL

    public init(
        http: any HTTPClient,
        bearer: Secret,
        baseURL: URL = GrokBillingClient.defaultBaseURL
    ) {
        self.http = http
        self.bearer = bearer
        self.endpoint = Self.creditsURL(from: baseURL)
    }

    public func fetchCredits() async throws -> GrokBillingResponse {
        do {
            return try await http.get(
                endpoint,
                bearer: bearer,
                extraHeaders: [
                    "X-XAI-Token-Auth": "xai-grok-cli",
                    "x-grok-client-mode": "cli",
                ],
                useSnakeCaseConversion: false,
                as: GrokBillingResponse.self
            )
        } catch let httpErr as HTTPError {
            switch httpErr.status {
            case 401, 403:
                throw GrokBillingError.unauthorized(status: httpErr.status)
            default:
                throw GrokBillingError.billingEndpointFailed(status: httpErr.status)
            }
        } catch is DecodingError {
            throw GrokBillingError.decodeFailed
        }
    }

    /// SuperGrok weekly percent lives on `?format=credits`. Bare `/billing`
    /// returns a monthly `{val:0}` stub that looks like "no limit".
    public static let defaultCreditsURL = URL(
        string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
    )!

    /// Accepts the proxy base (`…/v1`) or a full billing URL. Always pins
    /// `format=credits` so we never silently fall back to the monthly stub.
    public static func creditsURL(from baseURL: URL) -> URL {
        let trimmed = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed == "https://cli-chat-proxy.grok.com/v1" {
            return defaultCreditsURL
        }
        var url = baseURL
        if !url.path.contains("/billing") {
            url = url.appending(path: "billing")
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return defaultCreditsURL
        }
        var items = (components.queryItems ?? []).filter { $0.name != "format" }
        items.append(URLQueryItem(name: "format", value: "credits"))
        components.queryItems = items
        return components.url ?? defaultCreditsURL
    }
}
