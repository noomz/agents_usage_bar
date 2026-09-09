import Foundation
import os

/// Placeholder row seeded when a provider is enabled but not registered.
public struct PlaceholderSeed: Sendable, Equatable {
    public let providerID: ProviderID
    public let displayName: String
    public let placeholderMessage: String?
    public let status: ProviderStatus

    public init(
        providerID: ProviderID,
        displayName: String,
        placeholderMessage: String? = nil,
        status: ProviderStatus
    ) {
        self.providerID = providerID
        self.displayName = displayName
        self.placeholderMessage = placeholderMessage
        self.status = status
    }
}

/// Live `UsageProvider` actors plus the placeholder rows the GUI seeds on cold launch.
public struct ProviderRegistry {
    public let providers: [any UsageProvider]
    public let placeholders: [PlaceholderSeed]
}

/// Shared composition of the provider registry for the menu-bar app and `aub`.
@MainActor
public enum ProviderRegistryFactory {

    public static func build(
        config: AppConfig,
        preferences: UserPreferencesStore,
        http: any HTTPClient,
        localhostHTTP: any HTTPClient,
        cache: any CacheStore,
        clock: any Clock
    ) -> ProviderRegistry {
        var registry: [any UsageProvider] = []
        var placeholders: [PlaceholderSeed] = []
        let logger = os.Logger(subsystem: "app.agents-usage-bar", category: "composition")

        if config.openrouter.enabled, let apiKey = config.openrouter.apiKey {
            let endpoint = OpenRouterEndpoint(baseURL: config.openrouter.apiURL)
            let client = HTTPOpenRouterClient(
                http: http,
                endpoint: endpoint,
                bearer: apiKey,
                httpReferer: config.openrouter.httpReferer,
                xTitle: config.openrouter.xTitle
            )
            registry.append(OpenRouterProvider(client: client, cache: cache, clock: clock))
        }
        if config.openrouter.enabled, config.openrouter.apiKey == nil {
            placeholders.append(PlaceholderSeed(
                providerID: .openrouter,
                displayName: "OpenRouter",
                status: .unauthenticated
            ))
        }

        let claudeEnabled = preferences.providerEnabled[.claude] ?? true
        let credLoader = ClaudeCredentialLoader()
        let oauthClient: (any ClaudeOAuthClientProtocol)?
        if claudeEnabled, credLoader.loadCredentials() != nil {
            oauthClient = ClaudeOAuthClient(http: http, credentials: credLoader, clock: clock)
        } else {
            oauthClient = nil
        }

        if claudeEnabled {
            let claudePricing: ClaudeModelPricing
            do {
                claudePricing = try ClaudeModelPricing.loadBundled()
            } catch {
                logger.error("Claude pricing load failed: \(error.localizedDescription, privacy: .public)")
                claudePricing = ClaudeModelPricing(
                    schemaVersion: 1,
                    lastUpdated: "fallback",
                    default: .init(
                        inputPer1M: 3.00,
                        outputPer1M: 15.00,
                        cacheWritePer1M: 3.75,
                        cacheReadPer1M: 0.30
                    ),
                    models: [:]
                )
            }
            let claudeProvider = ClaudeJSONLProvider(
                reader: TranscriptReader(),
                scanner: TranscriptDirectoryScanner(),
                pricing: claudePricing,
                oauth: oauthClient,
                cache: cache,
                clock: clock
            )
            registry.append(ClaudeSwitchableProvider(
                jsonl: claudeProvider,
                hookProvider: ClaudeHookProvider()
            ))
            let claudeRoots = ClaudeRoots.defaultRoots
            let hasTranscripts = claudeRoots.contains { FileManager.default.fileExists(atPath: $0.path) }
            if oauthClient == nil, !hasTranscripts {
                placeholders.append(PlaceholderSeed(
                    providerID: .claude,
                    displayName: "Claude",
                    status: .unauthenticated
                ))
            }
        }

        let codexRegistered: Bool
        if config.codex.enabled {
            let codexCredsLoader = CodexCredentialLoader()
            let codexCreds = codexCredsLoader.loadCredentials()
            let codexSessionsExists = FileManager.default.fileExists(
                atPath: NSHomeDirectory() + "/.codex/sessions"
            )
            if codexCreds != nil || codexSessionsExists {
                let codexPricing: CodexModelPricing?
                do {
                    codexPricing = try CodexModelPricing.loadBundled()
                } catch {
                    logger.error("Codex pricing load failed: \(error.localizedDescription, privacy: .public)")
                    codexPricing = nil
                }
                let codexOAuth: (any CodexOAuthClientProtocol)?
                if codexCreds != nil {
                    codexOAuth = CodexOAuthClient(
                        http: http,
                        credentialLoader: codexCredsLoader,
                        clock: clock
                    )
                } else {
                    codexOAuth = nil
                }
                registry.append(CodexJSONLProvider(
                    scannerFactory: { now in CodexRolloutScanner(now: now) },
                    reader: TranscriptReader(),
                    pricing: codexPricing,
                    oauth: codexOAuth,
                    cache: cache,
                    clock: clock
                ))
                codexRegistered = true
            } else {
                codexRegistered = false
            }
        } else {
            codexRegistered = false
        }
        if config.codex.enabled, !codexRegistered {
            placeholders.append(PlaceholderSeed(
                providerID: .codex,
                displayName: "Codex",
                status: .unauthenticated
            ))
        }

        let geminiRegistered: Bool
        if config.gemini.enabled,
           GeminiSettingsGate.isOAuthPersonal(),
           GeminiCredentialLoader().loadCredentials() != nil
        {
            let geminiPublicCreds = GeminiCLIPublicCreds.fromEnvironment(ProcessInfo.processInfo.environment)
            let geminiOAuth = GeminiOAuthClient(
                http: http,
                clock: clock,
                publicCreds: geminiPublicCreds
            )
            registry.append(GeminiOAuthProvider(http: http, oauth: geminiOAuth, clock: clock))
            geminiRegistered = true
        } else {
            geminiRegistered = false
        }
        if config.gemini.enabled, !geminiRegistered {
            placeholders.append(PlaceholderSeed(
                providerID: .gemini,
                displayName: "Gemini",
                status: .unauthenticated
            ))
        }

        let grokRegistered: Bool
        if config.grok.enabled {
            let grokLoader = GrokCredentialLoader()
            let grokCreds = grokLoader.loadCredentials() ?? config.grok.apiKey.map {
                GrokCredentialLoader.Result(token: $0, source: .apiKey)
            }
            if grokCreds != nil {
                let grokAPIKey = config.grok.apiKey
                let grokClient = GrokBillingClient(
                    http: http,
                    loadBearer: {
                        GrokCredentialLoader().loadCredentials()?.token ?? grokAPIKey
                    },
                    baseURL: config.grok.apiURL
                )
                registry.append(GrokBillingProvider(client: grokClient, clock: clock))
                grokRegistered = true
            } else {
                grokRegistered = false
            }
        } else {
            grokRegistered = false
        }
        if config.grok.enabled, !grokRegistered {
            placeholders.append(PlaceholderSeed(
                providerID: .grok,
                displayName: "Grok",
                status: .unauthenticated
            ))
        }

        if config.ollama.enabled {
            registry.append(OllamaProvider(http: localhostHTTP, clock: clock))
            placeholders.append(PlaceholderSeed(
                providerID: .ollama,
                displayName: "Ollama",
                status: .notRunning
            ))
        }

        if config.lmstudio.enabled {
            registry.append(LMStudioProvider(
                http: localhostHTTP,
                clock: clock,
                port: config.lmstudio.port
            ))
            placeholders.append(PlaceholderSeed(
                providerID: .lmstudio,
                displayName: "LM Studio",
                status: .notRunning
            ))
        }

        let llamacppRegistered: Bool
        if config.llamacpp.enabled, let port = config.llamacpp.port {
            registry.append(LlamaCppProvider(http: localhostHTTP, clock: clock, port: port))
            llamacppRegistered = true
        } else {
            llamacppRegistered = false
        }
        if config.llamacpp.enabled, !llamacppRegistered {
            placeholders.append(PlaceholderSeed(
                providerID: .llamacpp,
                displayName: "llama.cpp",
                placeholderMessage: "Set [llamacpp] port in config.toml to enable",
                status: .notRunning
            ))
        }

        return ProviderRegistry(providers: registry, placeholders: placeholders)
    }
}
