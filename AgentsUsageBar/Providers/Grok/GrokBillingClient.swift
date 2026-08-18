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

    /// Accepts either the proxy base (`…/v1`) or a full billing URL.
    public static func creditsURL(from baseURL: URL) -> URL {
        let path = baseURL.path
        if path.contains("/billing") {
            return baseURL
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        components.path = trimmed + "/billing"
        components.queryItems = [URLQueryItem(name: "format", value: "credits")]
        return components.url ?? baseURL.appending(path: "billing")
    }
}
