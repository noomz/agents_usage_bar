import Foundation
import os

/// LM Studio local-runtime provider actor.
///
/// Probes `GET http://localhost:<port>/api/v0/models` first (LM Studio 0.3.5+ extended schema
/// with `state` field). On any non-2xx response (including 404 from older builds) falls back to
/// `GET /v1/models` (OpenAI-compatible, no state — assume all listed models are loaded).
///
/// **Probe strategy (RESEARCH §2.2 + OQ-2 disposition):**
/// 1. `GET /api/v0/models` → filter `state == "loaded"` for running set.
/// 2. On ANY non-2xx (404, 500, etc.) → fallback to `GET /v1/models` (treat all listed as loaded).
/// 3. URLError on primary → `.notRunning` (connection-refused LOCAL-05); v1 fallback NOT attempted.
///
/// **D-03 row states:**
/// - **A. Not running** — URLError on primary probe. `lastStatus = .notRunning`. Never throws.
/// - **B. Idle — 0 models loaded** — server up, no loaded models. `raw["modelCount"]="0"`.
/// - **C. Single model** — one loaded model. `raw["modelName"]`, `raw["modelCount"]="1"`.
/// - **D. Multi-model** — N>1 loaded. `raw["modelName"]`=first, `raw["modelCount"]="\(N)"`.
///
/// **Invariants:**
/// - `tokensToday = nil` / `costTodayUSD = nil` — LOCAL-06 anti-feature, NEVER set.
/// - Never throws for transient localhost-down or 5xx — Phase 3 STATE #82 Gemini precedent.
/// - No `CircuitBreaker` — D-12 (POLL-05 AggregateStore-level breaker is sufficient).
/// - `bearer: nil` on every `http.get` call — SEC-01 (localhost has no auth).
/// - Port injected at init (LOCAL-02 configurable port); default 1234 from `AppConfig.defaults`.
public actor LMStudioProvider: UsageProvider {

    // MARK: - UsageProvider nonisolated constants

    public nonisolated let id: ProviderID = .lmstudio
    public nonisolated let displayName: String = "LM Studio"

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
    private let logger = AppLogger.logger(category: "lmstudio")

    /// Cold-launch presumes not running until proven otherwise (RESEARCH §4.1).
    private var lastStatus: ProviderStatus = .notRunning

    /// Preserved for degraded-UX reuse when a subsequent poll hits an HTTP error.
    private var lastSnapshot: UsageSnapshot?

    // MARK: - Init

    public init(http: any HTTPClient, clock: any Clock = SystemClock(), port: Int) {
        self.http = http
        self.clock = clock
        self.port = port
    }

    // MARK: - URL builders (dynamic — port is injected at construction)

    private var v0URL: URL {
        URL(string: "http://localhost:\(port)/api/v0/models")!
    }

    private var v1URL: URL {
        URL(string: "http://localhost:\(port)/v1/models")!
    }

    // MARK: - UsageProvider

    public func status() -> ProviderStatus {
        lastStatus
    }

    /// Fetches LM Studio usage and returns a snapshot.
    ///
    /// **Algorithm:**
    /// - STEP 0: probe `/api/v0/models` (extended endpoint).
    /// - STEP 1: on URLError → classify as `.notRunning` or `.error`; return immediately.
    ///           on non-2xx HTTP → fallback to `/v1/models` (STEP 2).
    ///           on success → use v0 loaded-state filtering (STEP 3).
    /// - STEP 2: probe `/v1/models` fallback; treat all entries as loaded.
    /// - STEP 3: compute D-03 row state from loaded model list.
    /// - STEP 4: build and return `UsageSnapshot`.
    ///
    /// Never throws for transient flakiness (GEMINI-04 STATE #82 cross-provider isolation).
    public func fetch(now: Date) async throws -> UsageSnapshot {

        // STEP 0 — Probe extended endpoint.
        let v0Result = await tryFetchV0()

        // STEP 1 — Classify v0 result.
        switch v0Result {
        case .success(let v0Response):
            // v0 success — compute row state directly from extended response.
            return buildSnapshot(
                loadedModels: v0Response.loadedModels.map { m in
                    LoadedModel(id: m.id, arch: m.arch, quantization: m.quantization)
                },
                installedCount: v0Response.data?.count ?? 0,
                now: now
            )

        case .failure(let err):
            // URLError → classify; never fall through to v1 for URLErrors
            // (if we can't connect at all, the fallback endpoint would also fail).
            if let urlErr = err as? URLError {
                let classified = ProviderStatus.classifyLocalhost(
                    error: urlErr,
                    lastSuccess: lastStatusLastSuccess
                )
                if case .notRunning = classified {
                    lastStatus = .notRunning
                    let snap = mutedNotRunningSnapshot(now: now)
                    lastSnapshot = snap
                    return snap
                }
                // Other URLError (TLS, malformed, etc.) → degraded.
                return degradedSnapshot(now: now, underlying: err)
            }

            // Non-URLError (HTTPError from non-2xx including 404, 500, DecodingError)
            // → fall through to v1 fallback per RESEARCH §2.2 + OQ-2 disposition.
            // Any non-2xx triggers the /v1/models retry.
        }

        // STEP 2 — Fallback to OpenAI-compatible endpoint.
        let v1Result = await tryFetchV1()

        switch v1Result {
        case .success(let v1Response):
            // v1 success — all listed models treated as loaded (no state field).
            let allModels = (v1Response.data ?? []).map { m in
                LoadedModel(id: m.id, arch: nil, quantization: nil)
            }
            return buildSnapshot(
                loadedModels: allModels,
                installedCount: allModels.count,
                now: now
            )

        case .failure(let err):
            // v1 also failed — classify and return degraded.
            if let urlErr = err as? URLError {
                let classified = ProviderStatus.classifyLocalhost(
                    error: urlErr,
                    lastSuccess: lastStatusLastSuccess
                )
                if case .notRunning = classified {
                    lastStatus = .notRunning
                    let snap = mutedNotRunningSnapshot(now: now)
                    lastSnapshot = snap
                    return snap
                }
            }
            return degradedSnapshot(now: now, underlying: err)
        }
    }

    // MARK: - Private fetch helpers

    private func tryFetchV0() async -> Result<LMStudioV0ModelsResponse, Error> {
        do {
            let response: LMStudioV0ModelsResponse = try await http.get(
                v0URL,
                bearer: nil,
                extraHeaders: [:],
                useSnakeCaseConversion: false,
                as: LMStudioV0ModelsResponse.self
            )
            return .success(response)
        } catch {
            return .failure(error)
        }
    }

    private func tryFetchV1() async -> Result<LMStudioV1ModelsResponse, Error> {
        do {
            let response: LMStudioV1ModelsResponse = try await http.get(
                v1URL,
                bearer: nil,
                extraHeaders: [:],
                useSnakeCaseConversion: false,
                as: LMStudioV1ModelsResponse.self
            )
            return .success(response)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Row-state computation (STEP 3 + STEP 4)

    /// Minimal model descriptor used in row-state computation.
    private struct LoadedModel {
        let id: String
        let arch: String?
        let quantization: String?
    }

    /// Builds a `UsageSnapshot` from a list of loaded models (D-03 states B/C/D).
    private func buildSnapshot(
        loadedModels: [LoadedModel],
        installedCount: Int,
        now: Date
    ) -> UsageSnapshot {
        var raw: [String: String] = [
            "source": "lmstudio",
            "port": "\(port)"
        ]
        var tooltipLabel: String?

        if loadedModels.isEmpty {
            // State B — server up, zero models loaded.
            raw["modelCount"] = "0"
            raw["installedCount"] = "\(installedCount)"
        } else if loadedModels.count == 1 {
            // State C — exactly one model loaded.
            let m = loadedModels[0]
            raw["modelName"] = m.id
            raw["modelCount"] = "1"
            raw["allModels"] = m.id
            // Tooltip: arch · quantization when both present.
            var parts: [String] = []
            if let a = m.arch { parts.append(a) }
            if let q = m.quantization { parts.append(q) }
            if !parts.isEmpty {
                tooltipLabel = parts.joined(separator: " · ")
            }
        } else {
            // State D — multiple models loaded.
            raw["modelName"] = loadedModels[0].id
            raw["modelCount"] = "\(loadedModels.count)"
            raw["allModels"] = loadedModels.map(\.id).joined(separator: "|")
            // Tooltip: all model names, one per line.
            tooltipLabel = loadedModels.map(\.id).joined(separator: "\n")
        }

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
            raw: ["modelCount": "0", "source": "lmstudio", "port": "\(port)", "providerStatus": "notRunning"],
            quotaWindows: nil,
            tooltipLabel: nil
        )
    }

    /// Snapshot for HTTP-error / decode-error path — reuses last snapshot when available.
    /// Never throws — GEMINI-04 cross-provider isolation (STATE #82).
    private func degradedSnapshot(now: Date, underlying: Error) -> UsageSnapshot {
        logger.warning("lmstudio fetch error (degraded): \(underlying.localizedDescription, privacy: .public)")
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
            raw: ["modelCount": "0", "source": "lmstudio", "port": "\(port)", "note": "degraded"],
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
