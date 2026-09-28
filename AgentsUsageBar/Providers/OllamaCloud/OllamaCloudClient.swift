import Foundation

/// The credential the Ollama Cloud row fetches with (SPEC V1).
public enum OllamaCloudCredential: Sendable {
    /// Explicit key from `OLLAMA_API_KEY` or `[ollama] api_key`; sent as Bearer.
    case apiKey(Secret, source: OllamaCloudConfig.CredentialSource)
    /// `ollama signin` device key; requests are signed per `OllamaDeviceSigner`.
    case device(OllamaDeviceSigner)

    /// `OLLAMA_API_KEY` env > `[ollama] api_key` > device key. `nil` → no row (V2).
    public static func resolve(
        config: OllamaCloudConfig,
        loadDevice: () -> OllamaDeviceSigner? = { OllamaDeviceSigner.load() }
    ) -> OllamaCloudCredential? {
        if let key = config.apiKey {
            return .apiKey(key, source: config.apiKeySource ?? .config)
        }
        return loadDevice().map(OllamaCloudCredential.device)
    }

    /// `--json` raw value: `env` | `config` | `device` (V14).
    public var sourceKey: String {
        switch self {
        case .apiKey(_, let source): return source.rawValue
        case .device: return "device"
        }
    }

    /// Tooltip line (V13). Names the source, never key material.
    public var sourceLabel: String {
        switch self {
        case .apiKey(_, .env): return "via OLLAMA_API_KEY"
        case .apiKey(_, .config): return "via config"
        case .device: return "via ollama signin"
        }
    }

    /// Hint shown when ollama.com rejects this credential (V5).
    public var rejectedHint: String {
        switch self {
        case .apiKey(_, .env): return "check OLLAMA_API_KEY"
        case .apiKey(_, .config): return "check [ollama] api_key"
        case .device: return "run ollama signin"
        }
    }
}

/// Calls ollama.com's usage and account endpoints with one credential.
public struct OllamaCloudClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://ollama.com")!

    private let http: any HTTPClient
    public let credential: OllamaCloudCredential
    private let baseURL: URL

    public init(http: any HTTPClient, credential: OllamaCloudCredential, baseURL: URL = defaultBaseURL) {
        self.http = http
        self.credential = credential
        self.baseURL = baseURL
    }

    public func usage(now: Date) async throws -> OllamaUsageResponse {
        let url = baseURL.appending(path: "api/usage")
        switch credential {
        case .apiKey(let key, _):
            return try await http.get(url, bearer: key, extraHeaders: [:],
                                      useSnakeCaseConversion: false, as: OllamaUsageResponse.self)
        case .device(let signer):
            let signed = try signer.sign(URLRequest(url: url), now: now)
            return try await http.get(signed.url ?? url, bearer: nil, extraHeaders: Self.authorization(signed),
                                      useSnakeCaseConversion: false, as: OllamaUsageResponse.self)
        }
    }

    /// Plan slug from `POST /api/me` (lowercase, open-ended), or `nil` when absent.
    public func plan(now: Date) async throws -> String? {
        let url = baseURL.appending(path: "api/me")
        let response: OllamaMeResponse
        switch credential {
        case .apiKey(let key, _):
            response = try await http.postJSON(url, body: EmptyBody(), bearer: key, extraHeaders: [:],
                                               as: OllamaMeResponse.self)
        case .device(let signer):
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            let signed = try signer.sign(request, now: now)
            response = try await http.postJSON(signed.url ?? url, body: EmptyBody(),
                                               extraHeaders: Self.authorization(signed), as: OllamaMeResponse.self)
        }
        return response.plan.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func authorization(_ signed: URLRequest) -> [String: String] {
        signed.value(forHTTPHeaderField: "Authorization").map { ["Authorization": $0] } ?? [:]
    }

    private struct EmptyBody: Encodable, Sendable {}
}
