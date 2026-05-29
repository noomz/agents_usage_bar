import Foundation
import os

// MARK: - GeminiOAuthClientProtocol
//
// Narrow protocol seam for the OAuth refresh state machine. The
// concrete `GeminiOAuthClient` (Plan 03-05) conforms via an empty
// extension. Tests inject a stub (`FakeGeminiOAuthClient`) without
// touching the concrete actor.
//
// Mirrors the Phase 2 `ClaudeOAuthClientProtocol` / Phase 3 Plan 03-04
// `CodexOAuthClientProtocol` patterns.

public protocol GeminiOAuthClientProtocol: Actor {
    func freshAccessToken(now: Date) async throws -> Secret
    func retryAfter401(now: Date) async throws -> Secret
}

extension GeminiOAuthClient: GeminiOAuthClientProtocol {}

// MARK: - GeminiOAuthProvider
//
// The user-visible Gemini provider. Composes the Wave 1 primitives:
//   - Plan 03-05: GeminiOAuthClient (D-09 eager-pre-check / lazy-401)
//   - Plan 03-06: GeminiQuotaResponse + GeminiLoadCodeAssistResponse
//                 (this plan)
//
// Algorithm (RESEARCH §"Gemini OAuth Refresh State Machine"):
//   STEP 0 — Resolve bearer via `oauth.freshAccessToken(now:)`.
//            .notSignedIn (Pitfall 9) → muted "No data yet" row.
//            .refreshFailed             → RETHROW (POLL-05 breaker).
//            any other GeminiOAuthError → degraded UX (D-11).
//   STEP 1 — Build quota body `{ "project": "<lastProjectId or empty>" }`.
//   STEP 2 — Concurrent fetch of quota + tier via `async let` (STATE #25
//            OpenRouterProvider pattern). Each helper internally catches
//            transport errors and returns a Result so tier failure
//            never aborts quota (Pitfall 8 invariant — tier is advisory).
//   STEP 3 — Process quota:
//            success → fold buckets by `modelId` keeping the LOWEST
//                      `remainingFraction` per model. Primary quota =
//                      max utilisation across all windows (D-06).
//            401      → lazy-retry once via `oauth.retryAfter401`; if
//                      it still fails enter degraded UX (D-11).
//            other 4xx/5xx / transport → degraded UX (D-11).
//   STEP 4 — Process tier independently:
//            success → tooltipLabel from RESEARCH correction #6
//                      tier-id mapping. Capture cloudaicompanionProject
//                      for the NEXT poll's quota body.
//            failure → tooltipLabel = nil (Pitfall 8 cold-start
//                      mitigation — never blocks quota).
//   STEP 5 — Build the snapshot:
//            happy   → fresh tokens=nil + costUSD=nil (D-07) snapshot
//                      with windows + primaryQuota + tooltipLabel.
//            degraded with prior snapshot (D-11) → reuse last
//                      windows/quota/tooltipLabel; stamp raw["note"]
//                      and raw["degraded"]; lastStatus=.stale(...).
//            degraded no prior snapshot → mutedNoData(now:) with
//                      raw["note"] set; lastStatus=.error(...).
//
// Invariants enforced:
//   - D-07: tokensToday=nil + costTodayUSD=nil EVERY poll. Today-total
//           exclusion + footnote rendering happens downstream (Plan
//           03-07 + 03-08); this actor emits the keying shape.
//   - D-11: degraded snapshots stamp raw["note"]="usage-temporarily-
//           unavailable" — Plan 03-08 ThresholdEngine filtering keys
//           on that constant to suppress notifications while
//           degraded.
//   - D-12: NO new CircuitBreaker — POLL-05 at AggregateStore level is
//           sufficient.
//   - GEMINI-04 cross-provider isolation: fetch(now:) does NOT throw
//           for transient v1internal flakiness. Only
//           GeminiOAuthError.refreshFailed propagates (the refresh
//           endpoint is on a different host — oauth2.googleapis.com —
//           and a sustained refresh failure justifies breaker opening).
//   - SEC-01: this file does NOT call the credential reveal accessor.
//           The bearer is wrapped in `Secret` and handed to
//           `URLSessionHTTPClient.postJSON(...,bearer:)` where the
//           single sanctioned reveal site lives.
public actor GeminiOAuthProvider: UsageProvider {

    // MARK: - UsageProvider nonisolated constants

    public nonisolated let id: ProviderID = .gemini
    public nonisolated let displayName: String = "Gemini"
    public nonisolated let capabilities: ProviderCapabilities = ProviderCapabilities(
        hasQuota: true,
        hasCost: false,
        hasTokens: false,
        isLocal: false
    )

    // MARK: - URLs

    public static let quotaURL = URL(
        string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
    )!
    public static let tierURL = URL(
        string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    )!

    /// D-11 degraded-UX marker. raw["note"]=degradedNote is a tagging seam
    /// read by Plan 03-08 ThresholdEngine filtering (`ThresholdEngine.degradedTag`)
    /// to suppress notifications while the provider is in the degraded state.
    ///
    /// Plan 03-08 makes this constant a thin alias of `ThresholdEngine.degradedTag`
    /// so the literal `"usage-temporarily-unavailable"` is single-sourced — the
    /// engine, provider, and UI (Plan 03-07) all read the same constant.
    public static let degradedNote = ThresholdEngine.degradedTag

    // MARK: - Actor-isolated state

    private let http: any HTTPClient
    private let oauth: any GeminiOAuthClientProtocol
    private let clock: any Clock
    private let logger = AppLogger.logger(category: "gemini")

    /// Last successful snapshot — used to build the dimmed cached row
    /// when the next poll lands in degraded UX (D-11).
    private var lastSnapshot: UsageSnapshot?

    /// Last operational status — returned by `status()` to the
    /// AggregateStore without a fetch.
    private var lastStatus: ProviderStatus = .error(ProviderError.notYetFetched)

    /// Captured from loadCodeAssist on the prior poll; sent to
    /// retrieveUserQuota on the NEXT poll so the API can scope quotas
    /// to the right cloudaicompanion project.
    private var lastProjectId: String?

    // MARK: - Init

    /// - Parameters:
    ///   - http: Shared `URLSessionHTTPClient` singleton (POLL-08).
    ///   - oauth: `GeminiOAuthClient` actor (Plan 03-05) — provides
    ///     freshAccessToken + retryAfter401.
    ///   - clock: Wired for parity with Phase 2 providers. The `now`
    ///     parameter passed to `fetch(now:)` is authoritative.
    public init(
        http: any HTTPClient,
        oauth: any GeminiOAuthClientProtocol,
        clock: any Clock = SystemClock()
    ) {
        self.http = http
        self.oauth = oauth
        self.clock = clock
    }

    // MARK: - UsageProvider

    public func status() -> ProviderStatus {
        lastStatus
    }

    public func fetch(now: Date) async throws -> UsageSnapshot {
        // STEP 0 — Resolve bearer.
        let bearer: Secret
        do {
            bearer = try await oauth.freshAccessToken(now: now)
        } catch GeminiOAuthError.notSignedIn,
                GeminiOAuthError.noCredentials {
            lastStatus = .unauthenticated
            // Pitfall 9: muted no-data row, never an error.
            return mutedNoData(now: now, tagged: false)
        } catch let err as GeminiOAuthError where isRefreshFailed(err) {
            // Refresh endpoint lives on a different host
            // (oauth2.googleapis.com). A sustained failure there
            // justifies opening the AggregateStore-level breaker
            // (POLL-05). RETHROW per the GEMINI-04 carve-out.
            let pe = ProviderError.from(err)
            lastStatus = .error(pe)
            throw err
        } catch {
            // Any other OAuth failure (transport, decode) — degrade
            // rather than throw (GEMINI-04 cross-provider isolation).
            logger.notice("oauth resolution failed; entering degraded UX: \(String(describing: error), privacy: .public)")
            return degradedSnapshot(now: now, underlying: error)
        }

        // STEP 1 — Build request bodies.
        let quotaBody = QuotaRequest(project: lastProjectId ?? "")
        let tierBody = TierRequest(
            metadata: .init(ideType: "GEMINI_CLI", pluginType: "GEMINI")
        )

        // STEP 2 — Concurrent fetch.
        async let quotaResult = tryFetchQuota(bearer: bearer, body: quotaBody, now: now)
        async let tierResult = tryFetchTier(bearer: bearer, body: tierBody)
        let quotaR = await quotaResult
        let tierR = await tierResult

        // STEP 3 — Process quota.
        let resolvedQuota: Result<GeminiQuotaResponse, Error>
        switch quotaR {
        case .success(let response):
            resolvedQuota = .success(response)
        case .failure(let err):
            // Lazy-401 retry — single shot.
            if isHTTP401(err) {
                do {
                    let retryBearer = try await oauth.retryAfter401(now: now)
                    let retryBody = QuotaRequest(project: lastProjectId ?? "")
                    let retried: GeminiQuotaResponse = try await http.postJSON(
                        Self.quotaURL,
                        body: retryBody,
                        bearer: retryBearer,
                        extraHeaders: [
                            "Accept": "application/json",
                            "User-Agent": "Agents-Usage-Bar/1.0",
                        ],
                        as: GeminiQuotaResponse.self
                    )
                    resolvedQuota = .success(retried)
                } catch let err2 as GeminiOAuthError where isRefreshFailed(err2) {
                    // Retry's refresh failed — same propagation rule
                    // as STEP 0 (refresh endpoint sustained failure).
                    let pe = ProviderError.from(err2)
                    lastStatus = .error(pe)
                    throw err2
                } catch {
                    resolvedQuota = .failure(error)
                }
            } else {
                resolvedQuota = .failure(err)
            }
        }

        // STEP 4 — Process tier (advisory; never blocks quota).
        let tooltipLabel: String?
        switch tierR {
        case .success(let response):
            tooltipLabel = GeminiLoadCodeAssistResponse.tierDisplayName(
                forID: response.currentTier?.id
            )
            if let project = response.cloudaicompanionProject, !project.isEmpty {
                lastProjectId = project
            }
        case .failure:
            // Pitfall 8 cold-start tolerance — silently omit tooltip,
            // never block quota.
            tooltipLabel = nil
        }

        // STEP 5 — Build snapshot.
        switch resolvedQuota {
        case .success(let response):
            let windows = windows(from: response.buckets)
            let primaryQuota: Quota? = computePrimaryQuota(from: windows)
            let snap = UsageSnapshot(
                providerID: id,
                asOf: now,
                tokensToday: nil,        // D-07
                costTodayUSD: nil,       // D-07
                balanceUSD: nil,
                quota: primaryQuota,
                raw: ["source": "v1internal"],
                quotaWindows: windows.isEmpty ? nil : windows,
                tooltipLabel: tooltipLabel
            )
            lastStatus = .ok(lastSuccess: now)
            lastSnapshot = snap
            return snap

        case .failure(let err):
            logger.notice("quota fetch failed; entering degraded UX: \(String(describing: err), privacy: .public)")
            return degradedSnapshot(now: now, underlying: err)
        }
    }

    // MARK: - Concurrent fetch helpers (each returns Result so neither
    //         aborts the sibling `async let`).

    private func tryFetchQuota(
        bearer: Secret,
        body: QuotaRequest,
        now: Date
    ) async -> Result<GeminiQuotaResponse, Error> {
        do {
            let response: GeminiQuotaResponse = try await http.postJSON(
                Self.quotaURL,
                body: body,
                bearer: bearer,
                extraHeaders: [
                    "Accept": "application/json",
                    "User-Agent": "Agents-Usage-Bar/1.0",
                ],
                as: GeminiQuotaResponse.self
            )
            return .success(response)
        } catch {
            return .failure(error)
        }
    }

    private func tryFetchTier(
        bearer: Secret,
        body: TierRequest
    ) async -> Result<GeminiLoadCodeAssistResponse, Error> {
        do {
            let response: GeminiLoadCodeAssistResponse = try await http.postJSON(
                Self.tierURL,
                body: body,
                bearer: bearer,
                extraHeaders: [
                    "Accept": "application/json",
                    "User-Agent": "Agents-Usage-Bar/1.0",
                ],
                as: GeminiLoadCodeAssistResponse.self
            )
            return .success(response)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Per-model bucket fold (RESEARCH §"Gemini Quota")

    /// Folds the response buckets by `modelId`, keeping the bucket with
    /// the LOWEST `remainingFraction` per model (multi-bucket-per-model
    /// disambiguation rule). Returns a stably-sorted `[QuotaWindow]`.
    private func windows(from buckets: [GeminiQuotaResponse.Bucket]?) -> [QuotaWindow] {
        guard let buckets else { return [] }
        var lowestByModel: [String: GeminiQuotaResponse.Bucket] = [:]
        for b in buckets {
            guard let modelId = b.modelId, let frac = b.remainingFraction else { continue }
            if let existing = lowestByModel[modelId],
               let existingFrac = existing.remainingFraction,
               existingFrac <= frac
            {
                continue
            }
            lowestByModel[modelId] = b
        }
        return lowestByModel.values.compactMap { b -> QuotaWindow? in
            guard let model = b.modelId, let frac = b.remainingFraction else { return nil }
            return QuotaWindow(
                name: model,
                utilization: 1.0 - frac,
                resetsAt: b.resetTimeAsDate()
            )
        }.sorted(by: { $0.name < $1.name })  // stable order for tests
    }

    /// D-06: primary quota fraction = max utilisation across all
    /// per-model windows.
    private func computePrimaryQuota(from windows: [QuotaWindow]) -> Quota? {
        let maxUtil = windows.compactMap(\.utilization).max()
        guard let maxUtil, !windows.isEmpty else { return nil }
        return Quota(
            used: maxUtil,
            limit: 1.0,
            remaining: max(0.0, 1.0 - maxUtil)
        )
    }

    // MARK: - Degraded-UX snapshot (D-11)

    /// Builds the degraded snapshot. With a prior `lastSnapshot`,
    /// reuses quota / quotaWindows / tooltipLabel from it (cached-dim
    /// behaviour); stamps `raw["note"]` so Plan 03-08 can suppress
    /// threshold notifications. Without a prior snapshot, returns a
    /// muted no-data row tagged identically.
    private func degradedSnapshot(now: Date, underlying: Error) -> UsageSnapshot {
        let pe = ProviderError.from(underlying)
        if let cached = lastSnapshot {
            let snap = UsageSnapshot(
                providerID: id,
                asOf: now,
                tokensToday: nil,        // D-07
                costTodayUSD: nil,       // D-07
                balanceUSD: cached.balanceUSD,
                quota: cached.quota,
                raw: [
                    "source": "v1internal",
                    "note": Self.degradedNote,
                    "degraded": "true",
                ],
                quotaWindows: cached.quotaWindows,
                tooltipLabel: cached.tooltipLabel
            )
            lastStatus = .stale(lastSuccess: cached.asOf, error: pe)
            return snap
        }
        // No prior snapshot — muted row + degraded tag.
        lastStatus = .error(pe)
        return mutedNoData(now: now, tagged: true)
    }

    /// "No data yet" muted snapshot — used by Pitfall 9 (no creds)
    /// and the no-prior-snapshot degraded path. When `tagged` is true,
    /// stamps the D-11 `raw["note"]` marker so downstream Plan 03-08
    /// can suppress notifications.
    private func mutedNoData(now: Date, tagged: Bool) -> UsageSnapshot {
        var raw: [String: String] = ["status": "no-data-yet"]
        if tagged {
            raw["note"] = Self.degradedNote
        }
        return UsageSnapshot(
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
    }

    // MARK: - Predicate helpers

    private func isRefreshFailed(_ err: GeminiOAuthError) -> Bool {
        if case .refreshFailed = err { return true }
        return false
    }

    private func isHTTP401(_ err: Error) -> Bool {
        if let httpErr = err as? HTTPError, httpErr.status == 401 { return true }
        return false
    }

    // MARK: - Request bodies (Encodable & Sendable for postJSON)

    private struct QuotaRequest: Encodable, Sendable {
        let project: String
    }

    private struct TierRequest: Encodable, Sendable {
        let metadata: Metadata

        struct Metadata: Encodable, Sendable {
            let ideType: String
            let pluginType: String

            private enum CodingKeys: String, CodingKey {
                case ideType
                case pluginType
            }
        }

        private enum CodingKeys: String, CodingKey {
            case metadata
        }
    }
}
