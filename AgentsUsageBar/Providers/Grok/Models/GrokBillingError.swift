import Foundation

/// Typed errors from the Grok billing client. The provider maps these to
/// muted/degraded snapshots and does not rethrow transient failures
/// (Gemini GEMINI-04 isolation).
public enum GrokBillingError: Error, Sendable, Equatable {
    case noCredentials
    case unauthorized(status: Int)
    case billingEndpointFailed(status: Int)
    case decodeFailed
}
