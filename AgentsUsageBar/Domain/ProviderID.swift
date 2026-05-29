/// Strongly-typed provider identifier.
/// Downstream plans (01.04, 01.05, 01.07) depend on the exact `rawValue` strings
/// defined as static constants — do not change them without a migration plan.
public struct ProviderID: Sendable, Hashable, RawRepresentable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension ProviderID {
    /// OpenRouter — https://openrouter.ai
    /// Plans 01.04 and 01.05 use this constant as the key for HTTP fetching and cache storage.
    public static let openrouter = ProviderID(rawValue: "openrouter")
}
