import Foundation
import os

/// Ollama local-runtime provider actor.
///
/// Probes `GET http://localhost:11434/api/ps` (running models) and
/// `GET /api/tags` (installed models) concurrently via `async let`,
/// folds the responses into one of five D-03 row states, and returns
/// a `UsageSnapshot` with structured `raw[String:String]` payload.
///
/// **D-03 row states:**
/// - **A. Not running** — connection refused (`URLError.cannotConnectToHost` etc.).
///   `lastStatus = .notRunning`. Never throws — GEMINI-04 isolation.
/// - **B. Idle — 0 models loaded** — server up, `/api/ps` empty, `/api/tags` non-empty.
///   `raw["modelCount"]="0"`, `raw["installedCount"]="\(n)"`.
/// - **B'. Idle — no models installed** — server up, both endpoints empty.
///   `raw["modelCount"]="0"`, `raw["installedCount"]="0"`.
/// - **C. Single model** — one model loaded.
///   `raw["modelName"]`, `raw["modelCount"]="1"`, `raw["vramBytes"]`.
/// - **D. Multi-model** — N>1 loaded.
///   `raw["modelName"]`=first, `raw["modelCount"]="\(N)"`,
///   `raw["allModels"]`=pipe-joined.
///
/// **Invariants:**
/// - `tokensToday = nil` / `costTodayUSD = nil` — LOCAL-06 anti-feature, NEVER set.
/// - Never throws for transient localhost-down or 5xx — Phase 3 STATE #82 Gemini precedent.
/// - No `CircuitBreaker` — D-12 (POLL-05 AggregateStore-level breaker is sufficient).
/// - `bearer: nil` on every `http.get` call — SEC-01 (localhost has no auth).
public actor OllamaProvider: UsageProvider {

    // MARK: - UsageProvider nonisolated constants

    public nonisolated let id: ProviderID = .ollama
    public nonisolated let displayName: String = "Ollama"

    /// LOCAL-06: `hasTokens: false` auto-excludes from D-07 rollup;
    /// `isLocal: true` keys ProviderRowView secondary-line branching (Plan 04-07).
    public nonisolated let capabilities: ProviderCapabilities = ProviderCapabilities(
        hasQuota: false,
        hasCost: false,
        hasTokens: false,
        isLocal: true
    )

    // MARK: - URL constants (LOCAL-01)

    public static let psURL = URL(string: "http://localhost:11434/api/ps")!
    public static let tagsURL = URL(string: "http://localhost:11434/api/tags")!

    // MARK: - Actor-isolated state

    private let http: any HTTPClient
    private let clock: any Clock
    private let logger = AppLogger.logger(category: "ollama")

    /// Cold-launch presumes not running until proven otherwise (RESEARCH §4.1).
    private var lastStatus: ProviderStatus = .notRunning

    /// Preserved for degraded-UX reuse when a subsequent poll hits an HTTP error.
    private var lastSnapshot: UsageSnapshot?

    // MARK: - Init

    public init(http: any HTTPClient, clock: any Clock = SystemClock()) {
        self.http = http
        self.clock = clock
    }

    // MARK: - UsageProvider

    public func status() -> ProviderStatus {
        lastStatus
    }

    /// Fetches Ollama usage and returns a snapshot.
    ///
    /// Never throws for `.notRunning` or transient HTTP errors (GEMINI-04 cross-provider
    /// isolation precedent — STATE #82). Only a programmer error (e.g. malformed URL)
    /// would cause an unrecoverable panic, which cannot happen here given the static URLs.
    public func fetch(now: Date) async throws -> UsageSnapshot {
        // STEP 0 — Concurrent probe (Phase 1 STATE #25 OpenRouterProvider pattern).
        async let psResult = tryFetchPs()
        async let tagsResult = tryFetchTags()
        let psR = await psResult
        let tagsR = await tagsResult

        // STEP 1 — Classify psResult (load-bearing signal).
        let psModels: [OllamaPsResponse.Model]
        switch psR {
        case .success(let response):
            psModels = response.models ?? []
        case .failure(let err):
            let classified = ProviderStatus.classifyLocalhost(
                error: err,
                lastSuccess: lastStatusLastSuccess
            )
            if case .notRunning = classified {
                lastStatus = .notRunning
                let snap = mutedNotRunningSnapshot(now: now)
                lastSnapshot = snap
                return snap
            }
            // HTTP 5xx, DecodingError, other URLError → degraded, never throw.
            return degradedSnapshot(now: now, underlying: err)
        }

        // STEP 2 — Process tagsResult INDEPENDENTLY (informative-only per RESEARCH §2.4).
        // Any failure degrades to "no extra detail" — NEVER to .error.
        let installedCount: Int
        switch tagsR {
        case .success(let response):
            installedCount = response.models?.count ?? 0
        case .failure:
            // Silently ignore — tags is advisory only.
            installedCount = 0
        }

        // STEP 3 — Compute D-03 row state.
        var raw: [String: String] = ["source": "ollama"]
        var tooltipLabel: String?

        if psModels.isEmpty {
            raw["modelCount"] = "0"
            raw["installedCount"] = "\(installedCount)"
        } else if psModels.count == 1 {
            let m = psModels[0]
            raw["modelName"] = m.name
            raw["modelCount"] = "1"
            raw["vramBytes"] = "\(m.sizeVram ?? 0)"
            raw["allModels"] = m.name
            if let d = m.details {
                var parts: [String] = []
                if let f = d.family { parts.append(f) }
                if let p = d.parameterSize { parts.append(p) }
                if let q = d.quantizationLevel { parts.append(q) }
                if !parts.isEmpty {
                    tooltipLabel = parts.joined(separator: " · ")
                }
            }
        } else {
            // D — multiple models loaded.
            let firstName = psModels[0].name
            raw["modelName"] = firstName
            raw["modelCount"] = "\(psModels.count)"
            raw["allModels"] = psModels.map(\.name).joined(separator: "|")
            // Tooltip: all model names, one per line.
            tooltipLabel = psModels.map(\.name).joined(separator: "\n")
        }

        // STEP 4 — Build snapshot.
        // LOCAL-06: tokensToday, costTodayUSD, balanceUSD, quota, quotaWindows all nil.
        let snap = UsageSnapshot(
            providerID: id,
            asOf: now,
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: nil,
            raw: raw,
            quotaWindows: nil,
            tooltipLabel: tooltipLabel
        )

        lastStatus = .ok(lastSuccess: now)
        lastSnapshot = snap
        return snap
    }

    // MARK: - Private helpers

    private func tryFetchPs() async -> Result<OllamaPsResponse, Error> {
        do {
            let response: OllamaPsResponse = try await http.get(
                Self.psURL,
                bearer: nil,
                extraHeaders: [:],
                useSnakeCaseConversion: false,
                as: OllamaPsResponse.self
            )
            return .success(response)
        } catch {
            return .failure(error)
        }
    }

    private func tryFetchTags() async -> Result<OllamaTagsResponse, Error> {
        do {
            let response: OllamaTagsResponse = try await http.get(
                Self.tagsURL,
                bearer: nil,
                extraHeaders: [:],
                useSnakeCaseConversion: false,
                as: OllamaTagsResponse.self
            )
            return .success(response)
        } catch {
            return .failure(error)
        }
    }

    /// Snapshot for the "not running" state A — empty payload, all nils.
    private func mutedNotRunningSnapshot(now: Date) -> UsageSnapshot {
        UsageSnapshot(
            providerID: id,
            asOf: now,
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: nil,
            raw: ["modelCount": "0", "source": "ollama"],
            quotaWindows: nil,
            tooltipLabel: nil
        )
    }

    /// Snapshot for HTTP-error / decode-error path — reuses last snapshot when available.
    /// Never throws — GEMINI-04 cross-provider isolation (STATE #82).
    private func degradedSnapshot(now: Date, underlying: Error) -> UsageSnapshot {
        logger.warning("ollama fetch error (degraded): \(underlying.localizedDescription, privacy: .public)")
        let pe = ProviderError.from(underlying)
        if let last = lastSnapshot {
            lastStatus = .stale(lastSuccess: now, error: pe)
            var raw = last.raw
            raw["note"] = "degraded"
            return UsageSnapshot(
                providerID: id,
                asOf: now,
                tokensToday: nil,
                costTodayUSD: nil,
                balanceUSD: nil,
                quota: nil,
                raw: raw,
                quotaWindows: nil,
                tooltipLabel: last.tooltipLabel
            )
        }
        lastStatus = .error(pe)
        return UsageSnapshot(
            providerID: id,
            asOf: now,
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: nil,
            raw: ["modelCount": "0", "source": "ollama", "note": "degraded"],
            quotaWindows: nil,
            tooltipLabel: nil
        )
    }

    /// Extracts the last success date from `lastStatus` for `classifyLocalhost`.
    private var lastStatusLastSuccess: Date? {
        switch lastStatus {
        case .ok(let d): return d
        case .stale(let d, _): return d
        default: return nil
        }
    }
}
