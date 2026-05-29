import Foundation

/// A typed error produced by a provider fetch.
///
/// `ProviderError` is `Codable` so it can be stored in `ProviderStatus` in the disk cache
/// (allowing stale-error state to survive app restarts).
public struct ProviderError: Sendable, Equatable, Codable, Error {

    public enum Kind: String, Sendable, Codable {
        case auth
        case paymentRequired
        case http
        case decode
        case network
        case notYetFetched
        case unknown
    }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    /// Sentinel used by `ProviderStatus.unauthenticated` and cold-launch paths
    /// where no fetch has been attempted yet.
    public static let notYetFetched = ProviderError(kind: .notYetFetched, message: "Not yet fetched")

    /// Converts any `Error` into a `ProviderError`, preserving as much detail as possible.
    public static func from(_ error: Error) -> ProviderError {
        if let pe = error as? ProviderError { return pe }
        if let http = error as? HTTPError {
            switch http.status {
            case 401, 403: return ProviderError(kind: .auth, message: "HTTP \(http.status)")
            case 402:      return ProviderError(kind: .paymentRequired, message: "HTTP 402")
            default:       return ProviderError(kind: .http, message: "HTTP \(http.status)")
            }
        }
        let urlErr = error as? URLError
        if urlErr != nil {
            return ProviderError(kind: .network, message: error.localizedDescription)
        }
        if error is DecodingError {
            return ProviderError(kind: .decode, message: error.localizedDescription)
        }
        return ProviderError(kind: .unknown, message: error.localizedDescription)
    }
}
