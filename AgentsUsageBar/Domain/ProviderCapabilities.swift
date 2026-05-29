import Foundation

/// Static metadata describing what a provider can and cannot report.
///
/// Used by `ProviderRowView` and `ThresholdEngine` to decide which UI fields
/// to render and which quota paths to activate.
public struct ProviderCapabilities: Sendable, Equatable, Codable {

    /// Whether the provider exposes a credit/quota limit.
    public let hasQuota: Bool

    /// Whether the provider reports USD cost figures.
    public let hasCost: Bool

    /// Whether the provider reports token counts.
    public let hasTokens: Bool

    /// Whether the provider is a locally-running model (Ollama, LM Studio, etc.).
    public let isLocal: Bool

    public init(hasQuota: Bool, hasCost: Bool, hasTokens: Bool, isLocal: Bool) {
        self.hasQuota = hasQuota
        self.hasCost = hasCost
        self.hasTokens = hasTokens
        self.isLocal = isLocal
    }
}
