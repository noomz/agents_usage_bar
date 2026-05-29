import Foundation

/// The operational status of a provider at any given point in time.
///
/// `ProviderStatus` is `Codable` so it can be persisted in the disk cache alongside
/// `ProviderState` and restored on cold launch (D-06, D-07).
///
/// **Phase 4 addition — `.notRunning` (Plan 04-01 / D-01):**
/// Localhost-specific muted-gray state — the server process is not listening at the
/// well-known port. MUST remain NON-terminal so the next 5-min poll re-probes; deliberately
/// omitted from the POLL-06 skip match in `AggregateStore.performRefresh` so that the row
/// flips to `.ok(...)` the moment the user runs `ollama serve`.
public enum ProviderStatus: Sendable, Equatable, Codable {

    /// Last fetch succeeded at `lastSuccess`.
    case ok(lastSuccess: Date)

    /// Last fetch failed but a prior success exists; data is stale.
    case stale(lastSuccess: Date, error: ProviderError)

    /// No API key configured or the key was rejected (HTTP 401/403).
    ///
    /// **POLL-06 (Plan 02.06):** This status is TERMINAL until provider config changes —
    /// the AggregateStore skips refreshing any provider in `.unauthenticated` state until
    /// the composition root is rebuilt (typically requires app restart). 4xx responses
    /// other than 429 (e.g. 401/402/403) map to this case via `ProviderError.from(_:)`.
    case unauthenticated

    /// Localhost-runtime-specific muted state: the server process is not listening at the
    /// well-known port (ECONNREFUSED / NXDOMAIN / TCP RST / 2s-timeout on the localhost tier).
    ///
    /// **NON-terminal (D-01 / LOCAL-04):** deliberately absent from the POLL-06 terminal-skip
    /// block in `AggregateStore.performRefresh` — every 5-min tick re-probes the port so the
    /// row flips to `.ok(...)` as soon as the user starts the runtime.
    /// Maps to `.gray` via `StatusDot.dotColor` (LOCAL-04 muted-never-red).
    case notRunning

    /// Provider is explicitly disabled by the user in config.
    case disabled

    /// Last fetch failed and no prior success is available.
    case error(ProviderError)
}

// MARK: - Localhost error classifier (Plan 04-01 / LOCAL-05)

extension ProviderStatus {

    /// Localhost-tier error classifier (Phase 4 / LOCAL-05).
    ///
    /// Returns `.notRunning` for the four `URLError.Code` values consistent with
    /// "server process not listening" (ECONNREFUSED + NXDOMAIN + RST + 2s-timeout).
    /// All other errors map via `ProviderError.from(_:)` to `.stale` (when prior
    /// success exists) or `.error` (cold start).
    ///
    /// HTTP 5xx never maps to `.notRunning` — the server IS running, it's just
    /// unhealthy. Composed by `OllamaProvider` / `LMStudioProvider` /
    /// `LlamaCppProvider` in Plans 04-04..06.
    ///
    /// - Parameters:
    ///   - error: The error thrown by the localhost HTTP probe.
    ///   - lastSuccess: The most recent successful fetch date, if any.
    /// - Returns: `.notRunning` for connection-refused codes; `.stale` or `.error` otherwise.
    public static func classifyLocalhost(error: Error, lastSuccess: Date?) -> ProviderStatus {
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .cannotConnectToHost, .cannotFindHost,
                 .networkConnectionLost, .timedOut:
                return .notRunning
            default:
                break
            }
        }
        let pe = ProviderError.from(error)
        if let ls = lastSuccess {
            return .stale(lastSuccess: ls, error: pe)
        }
        return .error(pe)
    }
}
