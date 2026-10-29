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
    /// Reloads Grok CLI / Pi OAuth / env candidates each request.
    private let loadCandidates: @Sendable () -> [GrokCredentialLoader.Result]

    public init(
        http: any HTTPClient,
        bearer: Secret,
        baseURL: URL = GrokBillingClient.defaultBaseURL
    ) {
        self.http = http
        self.endpoint = Self.creditsURL(from: baseURL)
        self.loadCandidates = { [GrokCredentialLoader.Result(token: bearer, source: .session)] }
    }

    public init(
        http: any HTTPClient,
        loadBearer: @escaping @Sendable () -> Secret?,
        baseURL: URL = GrokBillingClient.defaultBaseURL
    ) {
        self.http = http
        self.endpoint = Self.creditsURL(from: baseURL)
        self.loadCandidates = {
            loadBearer().map { [GrokCredentialLoader.Result(token: $0, source: .session)] } ?? []
        }
    }

    public init(
        http: any HTTPClient,
        loadCandidates: @escaping @Sendable () -> [GrokCredentialLoader.Result],
        baseURL: URL = GrokBillingClient.defaultBaseURL
    ) {
        self.http = http
        self.endpoint = Self.creditsURL(from: baseURL)
        self.loadCandidates = loadCandidates
    }

    public func fetchCredits() async throws -> GrokBillingResponse {
        let candidates = loadCandidates()
        guard !candidates.isEmpty else {
            throw GrokBillingError.noCredentials
        }
        var lastUnauthorized: GrokBillingError?
        for cred in candidates {
            do {
                return try await getCredits(cred)
            } catch let error as GrokBillingError {
                if case .unauthorized = error {
                    lastUnauthorized = error
                    continue
                }
                throw error
            }
        }
        throw lastUnauthorized ?? GrokBillingError.unauthorized(status: 401)
    }

    private func getCredits(_ cred: GrokCredentialLoader.Result) async throws -> GrokBillingResponse {
        var headers: [String: String] = ["Accept": "application/json"]
        if cred.usesGrokCLIHeaders {
            headers["X-XAI-Token-Auth"] = "xai-grok-cli"
            headers["x-grok-client-mode"] = "cli"
        }
        do {
            return try await http.get(
                endpoint,
                bearer: cred.token,
                extraHeaders: headers,
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
