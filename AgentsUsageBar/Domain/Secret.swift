import Foundation

/// SEC-01: A type-safe wrapper for sensitive string credentials (e.g. API keys).
///
/// The only sanctioned use of the underlying value is inside HTTP header construction:
///   `request.setValue("Bearer \(secret.revealForRequest())", forHTTPHeaderField: "Authorization")`
///
/// Calling `revealForRequest()` from a `Logger` interpolation is a Pitfall 11 / SEC-01 violation.
/// There is no syntactic gate — only convention, the CI grep (SEC-04), and the Swift Testing
/// assertion that `String(describing: Secret("test")) == "<redacted>"`.
///
/// `Secret` is intentionally NOT `Codable` — credentials must never be auto-serialised to disk
/// or network. Reconstruct from `String` at the call site (e.g., from env var or TOML config).
public struct Secret: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    private let value: String

    public init(_ value: String) {
        self.value = value
    }

    /// Returns the plaintext credential string.
    ///
    /// SEC-01: `revealForRequest()` may ONLY be called inside
    /// `URLRequest.setValue(_:forHTTPHeaderField:)`. Calling it from a Logger interpolation
    /// is a Pitfall 11 violation and will expose credentials in Console.app / crash logs.
    public func revealForRequest() -> String {
        value
    }

    /// Always returns `"<redacted>"` — safe for Logger interpolation and `String(describing:)`.
    public var description: String { "<redacted>" }

    /// Always returns `"<redacted>"` — safe for `String(reflecting:)` and LLDB po output.
    public var debugDescription: String { "<redacted>" }
}
