import Foundation

/// Narrow protocol so tests inject a stub without touching HTTP.
public protocol GrokBillingClientProtocol: Actor {
    func fetchCredits() async throws -> GrokBillingResponse
}

/// `GET {base}/billing?format=credits` with the Grok CLI header set.
public actor GrokBillingClient: GrokBillingClientProtocol {

    public static let defaultBaseURL = URL(string: "https://cli-chat-proxy.grok.com/v1")!

    private let http: any HTTPClient
    private let endpoint: URL
    /// Reloads `~/.grok/auth.json` (or env fallback) each request so a CLI token
    /// rotation is picked up without restarting the menu bar app.
    private let loadBearer: @Sendable () -> Secret?
    private var bearer: Secret?

    public init(
        http: any HTTPClient,
        bearer: Secret,
        baseURL: URL = GrokBillingClient.defaultBaseURL
    ) {
        self.http = http
        self.endpoint = Self.creditsURL(from: baseURL)
        self.loadBearer = { bearer }
        self.bearer = bearer
    }

    public init(
        http: any HTTPClient,
        loadBearer: @escaping @Sendable () -> Secret?,
        baseURL: URL = GrokBillingClient.defaultBaseURL
    ) {
        self.http = http
        self.endpoint = Self.creditsURL(from: baseURL)
        self.loadBearer = loadBearer
        self.bearer = loadBearer()
    }

    public func fetchCredits() async throws -> GrokBillingResponse {
        if let fresh = loadBearer() {
            bearer = fresh
        }
        guard let token = bearer else {
            throw GrokBillingError.noCredentials
        }
        do {
            return try await getCredits(bearer: token)
        } catch GrokBillingError.unauthorized {
            // Grok CLI rewrites auth.json in the background; retry once with a
            // freshly loaded key before giving up.
            if let retried = loadBearer(), retried != token {
                bearer = retried
                return try await getCredits(bearer: retried)
            }
            throw GrokBillingError.unauthorized(status: 401)
        }
    }

    private func getCredits(bearer: Secret) async throws -> GrokBillingResponse {
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
