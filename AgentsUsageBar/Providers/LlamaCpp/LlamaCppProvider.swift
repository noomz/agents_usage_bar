import Foundation
import os

/// llama.cpp / llamafile local-runtime provider actor.
///
/// Probes `GET /health` (drives status), `GET /v1/models` (drives model name) concurrently
/// via `async let`, and issues an opportunistic `GET /slots` probe (tooltip enrichment only —
/// failures silently ignored).
///
/// **Port-required (LOCAL-03 no-scanning invariant):** this actor is only constructed when
/// `config.llamacpp.enabled && config.llamacpp.port != nil`. When unconfigured, the
/// composition root (Plan 04-08) seeds the D-04 discoverability placeholder row instead.
///
/// **D-03 row states:**
/// - **A. Not running** — URLError connection-refused on `/health`. `lastStatus = .notRunning`. Never throws.
/// - **B. Idle / server ready** — `/health` ok + `/v1/models` empty. `raw["modelCount"]="0"`.
/// - **C. Single model** — `/health` ok + model basename from `/v1/models`. `raw["modelName"]`.
/// - **E. Running — loading…** — `/health` `"loading model"` during warmup.
///   `lastStatus = .ok(lastSuccess: now)`, `raw["loadingModel"]="true"` (NOT `.error`).
///
/// **State E rationale (RESEARCH §5.1):** `"loading model"` is documented transient warmup.
/// Mapping it to `.error` would false-alarm; mapping to `.notRunning` is wrong because the
/// server IS up. Treat as a sub-state of `.ok(...)` — keyed by `raw["loadingModel"]=="true"`.
/// Plan 04-07 `ProviderRowView` branches on this key before the model-name branch.
///
/// **OQ-3 lenient interpretation:** unknown `/health` status → `.ok` (best effort) to prevent
/// llamafile-version-drift from flashing false-alarm red rows.
///
/// **Invariants:**
/// - `tokensToday = nil` / `costTodayUSD = nil` — LOCAL-06 anti-feature, NEVER set.
/// - Never throws for transient localhost-down or 5xx — Phase 3 STATE #82 Gemini precedent.
/// - No `CircuitBreaker` — D-12 (POLL-05 AggregateStore-level breaker is sufficient).
/// - `bearer: nil` on every `http.get` call — SEC-01 (localhost has no auth).
/// - Port injected at init (LOCAL-03 port REQUIRED); composition root gates on `port != nil`.
public actor LlamaCppProvider: UsageProvider {

    // MARK: - UsageProvider nonisolated constants

    public nonisolated let id: ProviderID = .llamacpp
    public nonisolated let displayName: String = "llama.cpp"

    /// LOCAL-06: `hasTokens: false` auto-excludes from D-07 rollup;
    /// `isLocal: true` keys ProviderRowView secondary-line branching (Plan 04-07).
    public nonisolated let capabilities: ProviderCapabilities = ProviderCapabilities(
        hasQuota: false,
        hasCost: false,
        hasTokens: false,
        isLocal: true
    )

    // MARK: - Actor-isolated state

    private let http: any HTTPClient
    private let clock: any Clock
    private let port: Int
    private let logger = AppLogger.logger(category: "llamacpp")

    /// Cold-launch presumes not running until proven otherwise (RESEARCH §4.1).
    private var lastStatus: ProviderStatus = .notRunning

    /// Preserved for degraded-UX reuse when a subsequent poll hits an HTTP error.
    private var lastSnapshot: UsageSnapshot?

    // MARK: - Init

    /// Port is non-optional here — composition root gates registration on `config.llamacpp.port != nil`.
    /// The actor itself never sees nil (LOCAL-03).
    public init(http: any HTTPClient, clock: any Clock = SystemClock(), port: Int) {
        self.http = http
        self.clock = clock
        self.port = port
    }

    // MARK: - URL builders (dynamic — port is injected at construction)

    private var healthURL: URL {
        URL(string: "http://localhost:\(port)/health")!
    }

    private var modelsURL: URL {
        URL(string: "http://localhost:\(port)/v1/models")!
    }

    private var slotsURL: URL {
        URL(string: "http://localhost:\(port)/slots")!
    }

    // MARK: - UsageProvider

    public func status() -> ProviderStatus {
        lastStatus
    }

    /// Fetches llama.cpp usage and returns a snapshot.
    ///
    /// **Algorithm:**
    /// - STEP 0: concurrent fan-out for /health + /v1/models (Phase 1 STATE #25).
    /// - STEP 1: classify healthResult (drives status).
    ///   - isLoading → state E (.ok sub-state); loadingModel="true".
    ///   - isErrorStatus → degradedSnapshot; lastStatus = .error.
    ///   - isOK / hasNoSlot / unknown → continue (server running per OQ-3).
    ///   - URLError → classifyLocalhost; notRunning → return mutedNotRunningSnapshot.
    /// - STEP 2: process modelsResult (drives model name — basename via Apple URL API).
    /// - STEP 3: opportunistic /slots probe (failures silently ignored — RESEARCH §2.3).
    /// - STEP 4: build UsageSnapshot.
    ///
    /// Never throws for transient flakiness (GEMINI-04 STATE #82 cross-provider isolation).
    public func fetch(now: Date) async throws -> UsageSnapshot {

        // STEP 0 — Concurrent probe of load-bearing endpoints (Phase 1 STATE #25).
        async let healthResult = tryFetchHealth()
        async let modelsResult = tryFetchModels()
        let healthR = await healthResult
        let modelsR = await modelsResult

        // STEP 1 — Process healthResult (load-bearing signal, drives status).
        var raw: [String: String] = [
            "source": "llamacpp",
            "port": "\(port)"
        ]

        switch healthR {
        case .success(let health):
            if health.isLoading {
                // State E — server up but model still warming up.
                // lastStatus = .ok (NOT .error — state E is a success-class outcome per RESEARCH §5.1).
                lastStatus = .ok(lastSuccess: now)
                raw["loadingModel"] = "true"
                raw["modelCount"] = "0"
                let snap = UsageSnapshot(
                    providerID: id,
                    asOf: now,
                    tokensToday: nil,
                    costTodayUSD: nil,
                    balanceUSD: nil,
                    quota: nil,
                    raw: raw,
                    quotaWindows: nil,
                    tooltipLabel: nil
                )
                lastSnapshot = snap
                return snap
            } else if health.isErrorStatus {
                // Server reports explicit error (model failed to load).
                return degradedSnapshot(now: now, underlying: ProviderError(kind: .http, message: "llamacpp /health status: error"))
            }
            // isOK, hasNoSlot, or unknown status → server is RUNNING per OQ-3 lenient interpretation.
            // Fall through to STEP 2.

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
            // Other error (HTTP 5xx, DecodingError, non-connection URLError) → degraded.
            return degradedSnapshot(now: now, underlying: err)
        }

        // STEP 2 — Process modelsResult (informative — drives model name).
        switch modelsR {
        case .success(let models):
            if let basename = models.modelBasename, !basename.isEmpty {
                raw["modelName"] = basename
                raw["modelCount"] = "1"
                raw["allModels"] = basename
            } else {
                // Server up, no model listed (empty data).
                raw["modelCount"] = "0"
            }
        case .failure(let err):
            // Informative-only failure — log at notice level and treat as no model name.
            logger.notice("llamacpp /v1/models failure (informative): \(err.localizedDescription, privacy: .public)")
            raw["modelCount"] = "0"
        }

        // STEP 3 — Opportunistic /slots probe (tooltip enrichment; failures silently ignored).
        let slotsR = await tryFetchSlots()
        var tooltipLabel: String?
        switch slotsR {
        case .success(let slotsResponse):
            let total = slotsResponse.slots.count
            if total > 0 {
                let idle = slotsResponse.slots.filter { ($0.state ?? "") == "idle" }.count
                let busy = total - idle
                tooltipLabel = "\(total) slot\(total == 1 ? "" : "s"), \(idle) idle / \(busy) busy"
            }
        case .failure:
            // Silently ignored — /slots is optional (Pitfall 7 / RESEARCH §2.3).
            break
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

    // MARK: - Private fetch helpers

    private func tryFetchHealth() async -> Result<LlamaCppHealthResponse, Error> {
        do {
            let response: LlamaCppHealthResponse = try await http.get(
                healthURL,
                bearer: nil,
                extraHeaders: [:],
                useSnakeCaseConversion: false,
                as: LlamaCppHealthResponse.self
            )
            return .success(response)
        } catch {
            return .failure(error)
        }
    }

    private func tryFetchModels() async -> Result<LlamaCppV1ModelsResponse, Error> {
        do {
            let response: LlamaCppV1ModelsResponse = try await http.get(
                modelsURL,
                bearer: nil,
                extraHeaders: [:],
                useSnakeCaseConversion: false,
                as: LlamaCppV1ModelsResponse.self
            )
            return .success(response)
        } catch {
            return .failure(error)
        }
    }

    private func tryFetchSlots() async -> Result<LlamaCppSlotsResponse, Error> {
        do {
            let response: LlamaCppSlotsResponse = try await http.get(
                slotsURL,
                bearer: nil,
                extraHeaders: [:],
                useSnakeCaseConversion: false,
                as: LlamaCppSlotsResponse.self
            )
            return .success(response)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Snapshot helpers

    /// Snapshot for the "not running" state A — empty payload, all nils.
    ///
    /// Plan 04 hotfix H-02: encode `providerStatus = "notRunning"` so `ProviderState.applying`
    /// overrides the default `.ok` status — UI renders state A "Not running" + gray dot.
    private func mutedNotRunningSnapshot(now: Date) -> UsageSnapshot {
        UsageSnapshot(
            providerID: id,
            asOf: now,
            tokensToday: nil,
            costTodayUSD: nil,
            balanceUSD: nil,
            quota: nil,
            raw: ["modelCount": "0", "source": "llamacpp", "port": "\(port)", "providerStatus": "notRunning"],
            quotaWindows: nil,
            tooltipLabel: nil
        )
    }

    /// Snapshot for HTTP-error / decode-error path — reuses last snapshot when available.
    /// Never throws — GEMINI-04 cross-provider isolation (STATE #82).
    private func degradedSnapshot(now: Date, underlying: Error) -> UsageSnapshot {
        logger.warning("llamacpp fetch error (degraded): \(underlying.localizedDescription, privacy: .public)")
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
            raw: ["modelCount": "0", "source": "llamacpp", "port": "\(port)", "note": "degraded"],
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
