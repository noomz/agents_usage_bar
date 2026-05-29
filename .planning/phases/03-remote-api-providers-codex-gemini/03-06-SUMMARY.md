---
phase: 03-remote-api-providers-codex-gemini
plan: 06
subsystem: gemini-provider-actor
tags: [gemini, provider, actor, oauth, async-let, degraded-ux, d-07, d-11, d-12, gemini-02, gemini-03, gemini-04, cross-provider-isolation]
dependency_graph:
  requires: [03-05]
  provides:
    - gemini-quota-response
    - gemini-loadcodeassist-response
    - gemini-oauth-provider
    - http-client-post-json-bearer
    - gemini-oauth-client-protocol
  affects:
    - Providers/Gemini (GeminiOAuthProvider actor sits alongside settings gate / credential loader / OAuth client)
    - Providers/Gemini/Models (GeminiQuotaResponse + GeminiLoadCodeAssistResponse alongside OAuthCredentials + OAuthError + TokenRefreshResponse)
    - Domain/ProviderID (added .gemini constant — Rule-3 blocking fix; displayHint already returned "Gemini")
    - Infrastructure/HTTPClient (added postJSON(_:body:bearer:extraHeaders:as:) overload — the SEC-01-safe seam for bearer-authenticated JSON POST)
    - Infrastructure/URLSessionHTTPClient (implemented the new overload via shared performPostJSON; gated by useSnakeCaseConversion flag because Gemini loadCodeAssist requires camelCase wire keys)
    - AgentsUsageBarTests fakes (Claude + Codex + existing Gemini gain stub conformances for the new HTTPClient overload)
tech_stack:
  added:
    - GeminiQuotaResponse (lenient Decodable; per-bucket dual-pass ISO8601 + nested Bucket type)
    - GeminiLoadCodeAssistResponse (custom init handles String OR Object cloudaicompanionProject; tier display mapping per RESEARCH correction #6)
    - GeminiOAuthProvider (UsageProvider actor; eager-pre-check + lazy-401 + concurrent async let + degraded UX)
    - GeminiOAuthClientProtocol (narrow Actor protocol seam; concrete client conforms via empty extension)
    - HTTPClient.postJSON(_:body:bearer:extraHeaders:as:) (bearer-authenticated JSON POST overload)
    - ProviderID.gemini static constant (.gemini rawValue "gemini")
  patterns:
    - async let concurrent quota + tier fetch (STATE #25 OpenRouterProvider pattern)
    - Per-bucket fold keeping LOWEST remainingFraction per modelId (D-06 / RESEARCH §"Gemini Quota")
    - Tier-failure tolerance — Result-returning helpers so tier 5xx never aborts quota (Pitfall 8 cold-start mitigation)
    - Lazy-401 single-shot retry — quota 401 invalidates cache via oauth.retryAfter401; second 401 enters degraded UX
    - Degraded UX caching — last good UsageSnapshot reused with raw["note"]="usage-temporarily-unavailable" + raw["degraded"]="true" markers; lastStatus=.stale(...) with typed error
    - No-prior-snapshot degraded path — muted "No data yet" + degraded tag; lastStatus=.error
    - Cross-provider isolation — only GeminiOAuthError.refreshFailed propagates (refresh on different host justifies AggregateStore breaker open); everything else converted to snapshot return (GEMINI-04)
    - D-07 today-total exclusion — tokensToday=nil + costTodayUSD=nil on EVERY snapshot (happy + degraded + muted)
    - D-15 tooltipLabel from tierDisplayName mapping — free-tier→"Free", legacy-tier→"Legacy", standard-tier→"Paid", future tiers verbatim, nil silent
    - lastProjectId capture — cloudaicompanionProject from prior poll feeds next poll's quota body project field
    - NSLock-protected fake — FakeProviderHTTPClient @unchecked Sendable wraps responses dict + calls array under NSLock to survive the actor's concurrent async let mutations (Rule-1 bug-fix)
    - useSnakeCaseConversion encoder flag — bearer-postJSON path uses PLAIN encoder so Gemini camelCase wire keys (ideType, pluginType) are preserved; legacy postJSON path retains .convertToSnakeCase for ClaudeOAuthClient refresh body
key_files:
  created:
    - AgentsUsageBar/Providers/Gemini/Models/GeminiQuotaResponse.swift
    - AgentsUsageBar/Providers/Gemini/Models/GeminiLoadCodeAssistResponse.swift
    - AgentsUsageBar/Providers/Gemini/GeminiOAuthProvider.swift
    - AgentsUsageBarTests/ProvidersGeminiTests/GeminiQuotaResponseTests.swift
    - AgentsUsageBarTests/ProvidersGeminiTests/GeminiLoadCodeAssistResponseTests.swift
    - AgentsUsageBarTests/ProvidersGeminiTests/GeminiOAuthProviderTests.swift
    - AgentsUsageBarTests/ProvidersGeminiTests/GeminiOAuthProviderDegradedTests.swift
    - AgentsUsageBarTests/ProvidersGeminiTests/Fixtures/gemini-quota-response-fixture.json
    - AgentsUsageBarTests/ProvidersGeminiTests/Fixtures/gemini-quota-response-multibucket-fixture.json
    - AgentsUsageBarTests/ProvidersGeminiTests/Fixtures/gemini-loadcodeassist-fixture.json
    - AgentsUsageBarTests/ProvidersGeminiTests/Fixtures/gemini-loadcodeassist-object-project-fixture.json
    - AgentsUsageBarTests/ProvidersGeminiTests/Fixtures/gemini-loadcodeassist-coldstart-fixture.json
  modified:
    - AgentsUsageBar/Domain/ProviderID.swift (added .gemini static constant; Rule-3 blocking issue)
    - AgentsUsageBar/Infrastructure/HTTPClient.swift (added postJSON bearer overload)
    - AgentsUsageBar/Infrastructure/URLSessionHTTPClient.swift (implemented overload via shared performPostJSON; useSnakeCaseConversion flag)
    - AgentsUsageBarTests/ProvidersClaudeTests/ClaudeOAuthClientTests.swift (FakeHTTPClient conformance stub for new bearer overload)
    - AgentsUsageBarTests/ProvidersCodexTests/CodexOAuthClientTests.swift (FakeCodexHTTPClient conformance stub)
    - AgentsUsageBarTests/ProvidersGeminiTests/GeminiOAuthClientTests.swift (FakeGeminiHTTPClient conformance stub)
    - AgentsUsageBar.xcodeproj/project.pbxproj (AA030600 UUID namespace — 7 build files, 12 file refs, additions to Gemini source group + Models subgroup + ProvidersGeminiTests group + Fixtures subgroup + both Sources build phases)
decisions:
  - "Bearer postJSON overload uses PLAIN JSON encoder (no convertToSnakeCase). Gemini's v1internal:loadCodeAssist requires camelCase request body keys (ideType, pluginType, metadata). The .convertToSnakeCase strategy would rewrite those to snake_case (ide_type, plugin_type) which the API rejects with 400. The unauthenticated postJSON path keeps .convertToSnakeCase for ClaudeOAuthClient's refresh body — gated by the useSnakeCaseConversion flag on performPostJSON. Decoder symmetry: bearer path uses plain JSONDecoder() (Gemini response types declare explicit snake_case CodingKeys — strategy would clobber them; same trap as Plan 03-05's postFormURLEncoded fix)."
  - "Cross-provider isolation carve-out for GeminiOAuthError.refreshFailed — propagates because the refresh endpoint (oauth2.googleapis.com) is on a DIFFERENT HOST from the v1internal calls (cloudcode-pa.googleapis.com). Sustained refresh failure justifies the AggregateStore-level breaker opening (POLL-05); v1internal flakiness should not. Every other error path inside fetch(now:) converts to a snapshot return — verified by test N (cross-provider isolation regression) and test L (refresh failure propagates)."
  - "Per-bucket-per-model fold rule from RESEARCH §\"Gemini Quota\" (CodexBar GeminiStatusProbe.parseAPIResponse): group by modelId, keep the bucket with the LOWEST remainingFraction per model. Test B locks in this invariant — multibucket fixture with 0.85 and 0.60 for gemini-2.5-pro yields windows[0].utilization = 1 - 0.60 = 0.40 (not 0.15)."
  - "lastProjectId captured from prior poll's loadCodeAssist response and threaded into NEXT poll's retrieveUserQuota body. Empty string sent on first poll (project not yet known) — the v1internal endpoint accepts this. Test G locks in the round-trip: first poll captures \"P-first\" from tier; second poll's quota body carries `\"project\": \"P-first\"` (asserted via JSONSerialization on the captured wire bytes)."
  - "Tier display mapping (RESEARCH correction #6) — free-tier→\"Free\", legacy-tier→\"Legacy\", standard-tier→\"Paid\", any other non-nil string returned verbatim (lenient — future tier IDs surface without code change), nil → nil silent (Pitfall 8 cold-start; never \"Unknown\"). Test E exercises all three known IDs + future-tier-XYZ verbatim case."
  - "Degraded UX (D-11) — caches last good UsageSnapshot. On the next fetch's failure, returns a NEW snapshot that reuses cached quota/quotaWindows/tooltipLabel but stamps raw[\"note\"]=\"usage-temporarily-unavailable\" + raw[\"degraded\"]=\"true\" and sets asOf=now. lastStatus becomes .stale(lastSuccess:cached.asOf, error:typedError). The constant is exposed as GeminiOAuthProvider.degradedNote for Plan 03-08 ThresholdEngine filtering. Test O locks the exact string."
  - "Today-total exclusion (D-07) literal-pair appears SIX times in GeminiOAuthProvider.swift across happy/degraded-with-cache/muted-no-data builders — Three snapshot constructors × (tokensToday: nil, costTodayUSD: nil) = 6. The acceptance grep gate requires ≥2; the actual count is 6 because every snapshot path enforces D-07."
  - "Pitfall 8 cold-start mitigation — tryFetchTier returns Result<>; on .failure, tooltipLabel is set to nil. The provider NEVER blocks quota on tier failure. Test C asserts quota still populates (3 windows) when tier returns 500; test D asserts the cold-start fixture (currentTier null) yields tooltipLabel nil."
  - "Lazy-401 single-shot retry — when quota returns 401, the provider calls oauth.retryAfter401 ONCE and re-issues ONLY the quota call (not tier). If the retry's response is also non-2xx, the provider enters degraded UX. If the retry itself throws GeminiOAuthError.refreshFailed, it propagates (same rule as STEP 0). Tier is NEVER retried (it's advisory)."
  - "Test fake race fix (Rule 1) — FakeProviderHTTPClient was @unchecked Sendable with unsynchronized mutable state (responses dict + calls array). The provider's `async let quotaResult / async let tierResult` issued concurrent postJSON calls against the same fake instance; the unprotected dictionary writes produced ~50% flakiness across xcodebuild's parallel test runners (verified reproducible across 5 sequential runs: 3 failed, 2 passed). Fix: NSLock around all mutations + defensive copy on getters. Verified deterministic across 5 sequential post-fix runs (5/5 passed)."
  - "ProviderID.gemini added (Rule-3 blocking fix). Phase 1 already declared .openrouter and .claude; Phase 3 Plan 03-01 added .codex. The displayHint switch already returned \"Gemini\" for the \"gemini\" rawValue but the static constant itself was missing. Plan 03-06 needed it as the actor's nonisolated id. Added with doc comment pointing to Plan 03-06 introduction."
  - "GeminiOAuthClientProtocol mirrors Phase 2 ClaudeOAuthClientProtocol / Plan 03-04 CodexOAuthClientProtocol — narrow Actor protocol seam with the two methods the provider consumes (freshAccessToken + retryAfter401). Concrete GeminiOAuthClient conforms via empty extension. Tests inject FakeProviderOAuthClient without touching the concrete actor."
metrics:
  duration: "~30 minutes (autonomous; 0 checkpoints; resumed after one ConnectionRefused interruption)"
  completed: "2026-05-18"
  tasks: 2
  files_modified: 19
  tests_added: 29
requirements:
  - GEMINI-02 (full — per-model remainingFraction + ISO resetTime decoded by GeminiQuotaResponse; provider folds buckets by modelId keeping lowest remainingFraction; rendered into UsageSnapshot.quotaWindows with utilization = 1 - remainingFraction)
  - GEMINI-03 (full — tier label sourced from loadCodeAssist.currentTier.id via tierDisplayName mapping per RESEARCH correction #6, threaded through UsageSnapshot.tooltipLabel; Plan 03-07 will surface via SwiftUI .help() on ProviderRowView)
  - GEMINI-04 (full at the actor layer — degraded UX with D-11 cached-dim row and "usage-temporarily-unavailable" marker; cross-provider isolation invariant locked in by test N; refresh-failure carve-out propagates per the threat model; Plan 03-08 ThresholdEngine filtering will key on the marker constant)
---

# Phase 03 Plan 06: GeminiOAuthProvider Actor Summary

Composes Plan 03-05's Gemini OAuth + credential layer with two new response Codable models into the user-visible `GeminiOAuthProvider` actor. Implements the eager-pre-check + lazy-401 + concurrent quota+tier fetch + D-11 degraded UX + D-07 today-total exclusion algorithm against `v1internal:retrieveUserQuota` and `v1internal:loadCodeAssist`. Adds a bearer-authenticated `postJSON` overload to the shared HTTP client (the SEC-01-safe seam for JSON POSTs requiring an Authorization header — Gemini's v1internal endpoints). Two atomic commits, 29 new Swift Testing cases across four new suites, full Phase 1+2+3 regression sweep green.

## What Was Built

### Production Files

**`AgentsUsageBar/Providers/Gemini/Models/GeminiQuotaResponse.swift`** (108 LOC)
- `struct GeminiQuotaResponse: Decodable, Sendable, Equatable` — lenient buckets[]
- Nested `struct Bucket` with `remainingFraction: Double?`, `resetTime: String?`, `modelId: String?`, `tokenType: String?`, `remainingAmount: String?`
- Explicit snake_case `CodingKeys` (never relies on `.convertFromSnakeCase`)
- `func resetTimeAsDate() -> Date?` — two-pass `ISO8601DateFormatter` (fractional first per Pitfall 3 / STATE #43)
- All fields optional via `decodeIfPresent` semantics — tolerates partial API states (Pitfall 7 lenient parsing)

**`AgentsUsageBar/Providers/Gemini/Models/GeminiLoadCodeAssistResponse.swift`** (131 LOC)
- `struct GeminiLoadCodeAssistResponse: Decodable, Sendable, Equatable`
- Nested `struct CurrentTier` with `id / name / hasAcceptedTos / hasOnboardedPreviously` (all optional)
- Custom `init(from decoder:)` handles the **dual shape** of `cloudaicompanionProject`:
  1. Try plain `String` form first (most common in production)
  2. Fall back to nested container with `id` then `projectId` sub-fields
  3. Absent → nil
  → `cloudaicompanionProject: String?` is normalised at decode time so callers never branch
- `static func tierDisplayName(forID id: String?) -> String?` — RESEARCH correction #6 mapping
  - `"free-tier"` → `"Free"`
  - `"legacy-tier"` → `"Legacy"`
  - `"standard-tier"` → `"Paid"`
  - other non-nil → verbatim (lenient for future tier IDs)
  - `nil` → `nil` (Pitfall 8 cold-start; silent — never "Unknown")

**`AgentsUsageBar/Providers/Gemini/GeminiOAuthProvider.swift`** (441 LOC)
- `public actor GeminiOAuthProvider: UsageProvider`
- Nonisolated: `id = .gemini`, `displayName = "Gemini"`, `capabilities = (hasQuota: true, hasCost: false, hasTokens: false, isLocal: false)`
- Static URLs: `quotaURL = .../v1internal:retrieveUserQuota`, `tierURL = .../v1internal:loadCodeAssist`
- Static constant: `degradedNote = "usage-temporarily-unavailable"` — Plan 03-08 ThresholdEngine filter keys on this
- Actor-isolated state: `lastSnapshot: UsageSnapshot?`, `lastStatus: ProviderStatus`, `lastProjectId: String?`
- Public protocol seam `GeminiOAuthClientProtocol` — narrow Actor protocol (freshAccessToken + retryAfter401); `GeminiOAuthClient` conforms via empty extension; tests inject `FakeProviderOAuthClient` without touching the concrete actor

**Algorithm** (matches RESEARCH §"Gemini OAuth Refresh State Machine"):
```
STEP 0 — bearer = oauth.freshAccessToken(now:)
         .notSignedIn / .noCredentials → muted "No data yet"; status=.unauthenticated; NO throw
         .refreshFailed                → RETHROW (different-host carve-out justifies AggregateStore breaker)
         other GeminiOAuthError        → degraded snapshot; NO throw

STEP 1 — Build request bodies
         QuotaRequest(project: lastProjectId ?? "")
         TierRequest(metadata: .init(ideType: "GEMINI_CLI", pluginType: "GEMINI"))

STEP 2 — Concurrent fetch (STATE #25 async let)
         async let quotaResult = tryFetchQuota(bearer:, body:, now:)
         async let tierResult  = tryFetchTier(bearer:, body:)
         Each helper internally catches errors → returns Result so tier failure NEVER aborts quota

STEP 3 — Process quota result
         .success      → buckets folded by modelId keeping LOWEST remainingFraction
         .failure(401) → lazy-retry once via oauth.retryAfter401 + re-issue ONLY quota call
                         retry's refreshFailed → RETHROW; any other failure → degraded
         .failure(*)   → degraded

STEP 4 — Process tier result (advisory; NEVER blocks quota)
         .success → tooltipLabel = tierDisplayName(forID: response.currentTier?.id)
                    lastProjectId = response.cloudaicompanionProject ?? lastProjectId
         .failure → tooltipLabel = nil (Pitfall 8 cold-start tolerance)

STEP 5 — Build snapshot
         happy            → tokensToday=nil + costTodayUSD=nil (D-07)
                            primary Quota = max utilisation across all windows (D-06)
                            raw["source"] = "v1internal"; lastStatus=.ok(lastSuccess: now)
                            lastSnapshot = snap
         degraded+cached  → reuses cached quota/quotaWindows/tooltipLabel
                            raw["note"] = degradedNote + raw["degraded"] = "true"
                            asOf = now; lastStatus=.stale(lastSuccess: cached.asOf, error:)
         degraded no-cache→ muted "No data yet" + raw["note"] = degradedNote
                            lastStatus=.error(typedError)
```

**Per-bucket fold** (`windows(from:)`):
```swift
// Multi-bucket-per-model disambiguation (RESEARCH §"Gemini Quota")
var lowestByModel: [String: Bucket] = [:]
for b in buckets {
    if let existing = lowestByModel[modelId],
       let existingFrac = existing.remainingFraction,
       existingFrac <= frac { continue }
    lowestByModel[modelId] = b
}
return lowestByModel.values.compactMap {
    QuotaWindow(name: modelId, utilization: 1.0 - frac, resetsAt: resetTimeAsDate())
}.sorted(by: { $0.name < $1.name })   // stable order for tests
```

**`AgentsUsageBar/Domain/ProviderID.swift`** (modified) — added `public static let gemini = ProviderID(rawValue: "gemini")` (Rule-3 blocking fix; `displayHint` already returned "Gemini" but the constant itself was missing).

**`AgentsUsageBar/Infrastructure/HTTPClient.swift`** (modified) — added bearer-authenticated overload:
```swift
func postJSON<Body: Encodable & Sendable, T: Decodable & Sendable>(
    _ url: URL,
    body: Body,
    bearer: Secret,
    extraHeaders: [String: String],
    as type: T.Type
) async throws -> T
```
Documented as the SEC-01-safe seam for JSON POSTs needing an Authorization header (the bearer is wrapped in `Secret`; the reveal accessor lives ONLY in `URLSessionHTTPClient.performPostJSON`).

**`AgentsUsageBar/Infrastructure/URLSessionHTTPClient.swift`** (modified) — implements the new overload via a shared `performPostJSON(url:body:bearer:extraHeaders:useSnakeCaseConversion:as:)` helper:
- Bearer-overload sets `useSnakeCaseConversion = false` — plain JSONEncoder so Gemini camelCase wire keys (`ideType`, `pluginType`) are preserved (the `.convertToSnakeCase` strategy would rewrite them to `ide_type`/`plugin_type` and the API rejects with 400)
- Decoder symmetry: bearer-path uses plain `JSONDecoder()` because Gemini response types declare explicit snake_case `CodingKeys` (the strategy would clobber them — same trap as Plan 03-05's `postFormURLEncoded` decoder fix)
- Unauthenticated path retains `.convertToSnakeCase` for `ClaudeOAuthClient`'s refresh body — gated by the flag
- SEC-01 invariant preserved — `bearer.revealForRequest()` is the only call site in the file

### Test Files

**`AgentsUsageBarTests/ProvidersGeminiTests/GeminiQuotaResponseTests.swift`** — 7 tests
1. `decodes_threeBucketFixture` — 3-bucket fixture decodes; per-bucket fields populated correctly
2. `resetTimeAsDate_parsesPlainISO8601` — `2026-05-16T00:00:00Z` → epoch 1778889600 (computed via `date -j -f`; initial draft had wrong epoch 1779148800, caught by RED-phase failure)
3. `resetTimeAsDate_parsesFractionalSeconds` — Pitfall 3 fractional formatter
4. `resetTimeAsDate_returnsNilWhenAbsent` — nil resetTime → nil Date
5. `decodes_emptyObjectAsNilBuckets` — empty `{}` → buckets nil
6. `decodes_withUnknownTopLevelField` — Pitfall 7 lenient parsing
7. `decodes_multiBucketFixture_keepsBothEntries` — both buckets decoded (fold happens in provider, not decoder)

**`AgentsUsageBarTests/ProvidersGeminiTests/GeminiLoadCodeAssistResponseTests.swift`** — 7 tests
1. `decodes_happyFixture_withStringProject` — free-tier + plain String project
2. `tierDisplayName_mapsKnownIDs` — RESEARCH correction #6 mapping table
3. `decodes_objectShapeProject_normalisesToString` — Object form `{ id: "..." }` → normalised String
4. `decodes_coldStartFixture_currentTierNil` — Pitfall 8; tierDisplayName(forID: nil) → nil
5. `decodes_unknownFieldsInsideCurrentTier` — lenient parsing inside nested type
6. `decodes_withoutProjectField` — absent project → nil
7. `decodes_objectShapeProject_projectIdOnly` — Object with only `projectId` sub-field

**`AgentsUsageBarTests/ProvidersGeminiTests/GeminiOAuthProviderTests.swift`** — 8 tests (A..H)
- A `happyPath_concurrentFetch_populatesQuotaAndTier` — full happy path; D-07 nil tokens/cost; 3 windows alphabetically sorted (`gemini-2.5-flash`, `flash-lite`, `pro`); `windows[2].utilization = 0.15` (pro: 1 - 0.85); primary `quota.used = 0.15` (max utilisation); `tooltipLabel == "Free"`; raw["source"]="v1internal"; no degraded markers; oauth fresh-call count 1, retry count 0
- B `multiBucketPerModel_keepsLowestRemainingFraction` — fold rule (2 buckets per `gemini-2.5-pro`: 0.85 + 0.60 → utilization = 1 - 0.60 = 0.40)
- C `tierFailure_quotaSucceeds_tooltipNil` — tier 500 → quota still 3 windows; tooltipLabel nil
- D `tierColdStart_tooltipNil` — cold-start fixture (currentTier null) → tooltipLabel nil
- E `tierIdMapping_standardTierAndLegacyTierAndUnknown` — three independent providers verifying "Paid", "Legacy", and verbatim future-tier-XYZ
- F `lazy401_singleShotRetry_succeedsOnSecondCall` — quota 401 → retryAfter401 (1 call) → quota 200; snapshot populated; status .ok
- G `projectId_capturedFromTier_propagatedToNextQuotaBody` — first poll captures "P-first"; second poll's quota body has `"project": "P-first"` (asserted via JSONSerialization on captured wire bytes)
- H `concurrentFetch_structuralInvariant` — source-grep ≥1 `async let quotaResult` + `async let tierResult`

**`AgentsUsageBarTests/ProvidersGeminiTests/GeminiOAuthProviderDegradedTests.swift`** — 7 tests (I..O)
- I `degraded_noPriorSnapshot_returnsTaggedMutedRow` — quota+tier 500 with no prior snapshot → muted shape + raw["note"]; status non-.ok
- J `degraded_priorSnapshot_reusesQuotaButTagsDegraded` — happy fetch then 503 → cached windows reused; raw["note"] + raw["degraded"] set; asOf=current poll time; status=.stale
- K `lazy401_retryAlsoFails_entersDegraded` — quota 401 → retry 401 → degraded; retryAfter401 call count = 1 (single-shot)
- L `oauthRefreshFailed_propagates_doesNotConvertToDegraded` — STEP 0 throws .refreshFailed → fetch THROWS GeminiOAuthError.refreshFailed; status .error
- M `notSignedIn_returnsMutedNoData` — STEP 0 throws .notSignedIn → muted shape with raw["status"]="no-data-yet"; raw["note"] absent (this is NOT degraded, this is "configure me"); status=.unauthenticated
- N `crossProviderIsolation_arbitrary5xxNeverThrows` — quota+tier 500 → fetch does NOT throw → degraded snapshot returned
- O `degradedSnapshot_carriesExactSuppressionMarker` — raw["note"] == "usage-temporarily-unavailable" (literal); also == GeminiOAuthProvider.degradedNote (constant reference)

### Test Fixtures (loaded via `#filePath`, not bundle)

- `gemini-quota-response-fixture.json` — 3 buckets (pro / flash / flash-lite, INPUT_TOKEN, single-bucket-per-model)
- `gemini-quota-response-multibucket-fixture.json` — 2 buckets for `gemini-2.5-pro` (0.85 INPUT_TOKEN + 0.60 OUTPUT_TOKEN) for the fold test
- `gemini-loadcodeassist-fixture.json` — happy path, free-tier, plain-String project
- `gemini-loadcodeassist-object-project-fixture.json` — standard-tier, Object-shape project with both `id` and `projectId`
- `gemini-loadcodeassist-coldstart-fixture.json` — currentTier null + cloudaicompanionProject null (Pitfall 8)

### Test Doubles (modified for protocol widening)

- `ClaudeOAuthClientTests.swift::FakeHTTPClient` — added bearer-postJSON conformance stub (mechanical; not exercised by Claude suite)
- `CodexOAuthClientTests.swift::FakeCodexHTTPClient` — added bearer-postJSON conformance stub (mechanical; not exercised by Codex suite)
- `GeminiOAuthClientTests.swift::FakeGeminiHTTPClient` — added bearer-postJSON conformance stub (not exercised; OAuth client uses postFormURLEncoded path)

### New Test Doubles (Plan 03-06)

- `FakeProviderOAuthClient` (Gemini provider tests) — actor conforming to `GeminiOAuthClientProtocol`; scripts freshAccessToken + retryAfter401 results; tracks call counts so tests can verify the lazy-401 single-shot retry rule
- `FakeProviderHTTPClient` (Gemini provider tests) — NSLock-protected `@unchecked Sendable` HTTPClient stub; scripts postJSON responses keyed by `url.path` so quota + tier stubs are independent; records most recent request body bytes per path for the project-id propagation assertion (test G); plain JSONDecoder matches production bearer-postJSON behavior

## Primary Quota Fraction for the 3-Bucket Fixture

```
buckets:
  gemini-2.5-pro       remainingFraction = 0.85  → utilization = 0.15
  gemini-2.5-flash     remainingFraction = 0.92  → utilization = 0.08
  gemini-2.5-flash-lite remainingFraction = 0.98 → utilization = 0.02

D-06: primary quota = max utilisation across all windows
                    = max(0.15, 0.08, 0.02)
                    = 0.15
```

Test A asserts `quota.used == 0.15 ± 1e-9` and `quota.limit == 1.0`.

## Test Suite Results

29 new tests across 4 new suites; all pass deterministically.

| Suite                                  | Tests | Result |
|----------------------------------------|-------|--------|
| GeminiQuotaResponseTests               | 7     | PASS   |
| GeminiLoadCodeAssistResponseTests      | 7     | PASS   |
| GeminiOAuthProviderTests               | 8     | PASS   |
| GeminiOAuthProviderDegradedTests       | 7     | PASS   |
| **Total (this plan)**                  | **29**| **PASS** |
| **Cross-suite combo (Gemini + Claude + Codex)** | (all suites green) | PASS   |
| **Full regression (Phase 1 + 2 + 3)**  | (all suites green) | PASS   |

Post-NSLock-fix flakiness verification:
- Pre-fix: 5 sequential runs → 3 failed, 2 passed (~60% flake rate)
- Post-fix: 5 sequential runs → 5/5 passed (deterministic)

Full project build: `xcodebuild build -project AgentsUsageBar.xcodeproj -scheme AgentsUsageBar -configuration Debug` → `** BUILD SUCCEEDED **`.

## Invariant Verification (acceptance criteria)

| Invariant                                                                                                              | Result |
|------------------------------------------------------------------------------------------------------------------------|--------|
| `grep -nE 'remaining_fraction\|remainingFraction' …GeminiQuotaResponse.swift` ≥ 1                                       | 6 ✓    |
| `grep -nE 'free-tier\|standard-tier\|legacy-tier' …GeminiLoadCodeAssistResponse.swift` ≥ 3                              | 6 ✓    |
| `grep -nE 'tierDisplayName' …GeminiLoadCodeAssistResponse.swift` ≥ 1                                                    | 2 ✓    |
| `grep -n 'async let.*[Qq]uota' …GeminiOAuthProvider.swift` ≥ 1                                                          | 1 ✓ (line 182) |
| `grep -n 'async let.*[Tt]ier' …GeminiOAuthProvider.swift` ≥ 1                                                           | 1 ✓ (line 183) |
| `grep -nE 'tooltipLabel.*tier\|tier.*tooltipLabel\|tierDisplayName' …GeminiOAuthProvider.swift` ≥ 1                     | 1 ✓ (line 227) |
| `grep -nE 'usage-temporarily-unavailable' …GeminiOAuthProvider.swift` ≥ 1                                               | 2 ✓    |
| `grep -nE 'tokensToday: nil\|costTodayUSD: nil' …GeminiOAuthProvider.swift` ≥ 2                                         | 6 ✓    |
| `grep -n 'CircuitBreaker(' …GeminiOAuthProvider.swift` == 0                                                             | 0 ✓    |
| `grep -n 'revealForRequest' …GeminiOAuthProvider.swift` == 0                                                            | 0 ✓    |
| `GeminiQuotaResponseTests` declares ≥ 6 `@Test` cases                                                                   | 7 ✓    |
| `GeminiLoadCodeAssistResponseTests` declares ≥ 6 `@Test` cases                                                          | 7 ✓    |
| `GeminiOAuthProviderTests` declares ≥ 7 `@Test` cases                                                                   | 8 ✓    |
| `GeminiOAuthProviderDegradedTests` declares ≥ 7 `@Test` cases                                                           | 7 ✓    |
| Build still passes; Phase 1+2+3 regression remains green                                                                | PASS ✓ |
| SEC-04 sweep `grep -rnE 'sk-proj-\|sk-admin-\|sk-or-\|AIza' .../Gemini/ .../ProvidersGeminiTests/` (ex GeminiOAuthClient) | 0 ✓    |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Test Race] FakeProviderHTTPClient was unsynchronized under the provider's concurrent `async let` calls**
- **Found during:** Task 2 GREEN verification — initial test runs passed in isolation but flaked ~60% under xcodebuild's parallel test runners (3 of 5 runs failed; different test cases failed in each failing run — `happyPath_concurrentFetch`, `crossProviderIsolation_arbitrary5xxNeverThrows`, `degradedSnapshot_carriesExactSuppressionMarker` all surfaced as flaky depending on scheduler).
- **Root cause:** The fake was `@unchecked Sendable` with an unprotected `var responses: [String: [Result<Data, Error>]] = [:]` dictionary and `private(set) var calls: [Call] = []` array. The provider's `async let quotaResult = tryFetchQuota(...)` and `async let tierResult = tryFetchTier(...)` issue both helpers' `postJSON` calls CONCURRENTLY against the same fake instance. Both calls race to mutate `responses` (different keys — quotaPath vs tierPath — but the dict itself) and `calls.append(...)`. Swift dictionaries are NOT thread-safe; the race produced undefined behaviour intermittently visible as wrong response decoding, missing call records, or duplicate response consumption.
- **Fix:** Wrapped the fake's mutations in `NSLock`. Added `private let lock = NSLock()` + private backing storage `_responses` / `_calls`; the public `responses` / `calls` accessors take the lock and return defensive copies; mutation entry-points (`recordCall` and `takeResponse`) take the lock on the critical section. Mirrors STATE #19's pattern (`.serialized` trait + NSLock-protected static).
- **Files modified:** `AgentsUsageBarTests/ProvidersGeminiTests/GeminiOAuthProviderTests.swift` (FakeProviderHTTPClient class)
- **Verified:** 5 sequential post-fix runs all pass (vs 3-fail/2-pass pre-fix).
- **Commit:** `2e76a5e` (Task 2 — folded into the same commit since the fake and the actor ship together)

**2. [Rule 3 - Blocking] ProviderID.gemini constant missing**
- **Found during:** First compile of GeminiOAuthProvider.swift
- **Issue:** Phase 1 declared `.openrouter` and `.claude` static constants on `ProviderID`; Phase 3 Plan 03-01 added `.codex`. The `displayHint` switch already returned `"Gemini"` for the `"gemini"` rawValue, but the static constant itself was never added. The actor needs `id: ProviderID = .gemini` as a nonisolated constant — without the constant, compile fails.
- **Fix:** Added `public static let gemini = ProviderID(rawValue: "gemini")` to `ProviderID.swift` with doc comment pointing to Plan 03-06 introduction.
- **Files modified:** `AgentsUsageBar/Domain/ProviderID.swift`
- **Commit:** `8187562` (folded into Task 1 commit since both Task 1 model types and Task 2 actor depend on the constant)

**3. [Rule 1 - Production decoder strategy bug] `.convertToSnakeCase` would corrupt Gemini's camelCase wire keys**
- **Found during:** Designing the bearer-postJSON overload
- **Issue:** The existing `URLSessionHTTPClient.postJSON(...)` sets `keyEncodingStrategy = .convertToSnakeCase` on the encoder. Gemini's `v1internal:loadCodeAssist` request body requires literal camelCase keys (`ideType`, `pluginType`, `metadata`). A naive copy of the encoder for the bearer-overload would have rewritten those to `ide_type` / `plugin_type` and the API would have rejected with 400. Symmetric concern on the decoder side: Gemini response types declare explicit snake_case CodingKeys (`remaining_fraction`, `model_id`); the `.convertFromSnakeCase` strategy would rewrite incoming JSON keys to camelCase BEFORE matching against the explicit mapping (same trap as Plan 03-05's `postFormURLEncoded` decoder fix — the lesson recurred).
- **Fix:** Refactored `URLSessionHTTPClient.postJSON` into a shared `performPostJSON(...,useSnakeCaseConversion: Bool, ...)`. The bearer-overload passes `false` (plain encoder + plain decoder); the legacy unauthenticated path passes `true` (preserves Claude OAuth refresh body behaviour). Decision documented inline in both files. No existing tests broke (the Claude OAuth path still uses `.convertToSnakeCase`).
- **Files modified:** `AgentsUsageBar/Infrastructure/URLSessionHTTPClient.swift`, `AgentsUsageBar/Infrastructure/HTTPClient.swift`
- **Commit:** `2e76a5e` (folded into Task 2)

### Plan-Conformant Adjustments (not deviations — recorded for traceability)

**FakeHTTPClient at the HTTPClient protocol seam (NOT URLProtocol stubs).** The plan's Task 2 action says "URLProtocol stubs + STATE #19 `.serialized` trait + NSLock-protected static". Plan 03-04 / 03-05 established the convention of stubbing at the `HTTPClient` protocol seam instead — equivalent semantics, less boilerplate, no URLSession instantiation in tests. `FakeProviderHTTPClient` follows the convention. NSLock + `.serialized` trait still preserved per the spirit of STATE #19. Same plan-vs-repo wording resolution recorded in Plans 03-03 STATE #69 and 03-04.

**Bearer-postJSON overload added (plan-permitted route).** The plan's Task 2 action explicitly authorised two routes for bearer threading: (a) add an overload, or (b) pass the bearer via extraHeaders. Chose (a) — keeps the SEC-01 invariant of "one reveal call site in URLSessionHTTPClient" by adding the bearer-overload SIDE BY SIDE with the existing unauthenticated postJSON instead of mutating its signature.

**Plan-A timing-based concurrent-fetch test rejected.** The plan's Task 2 test H suggested either a timing measurement (~100ms vs ~200ms when stubs are delayed by 100ms) OR a structural source-grep. Chose the structural grep — timing tests are inherently flaky in CI, and the grep gate produces a much sharper assertion. Plan-permitted fallback.

## Threat Surface Scan

No new surface beyond the plan's `<threat_model>`. All six threat IDs (T-03.06-01..06 plus T-03.06-SC) remain at their planned dispositions:

- **T-03.06-01 (Spoofing, MITM on v1internal) — mitigate:** HTTPS to `cloudcode-pa.googleapis.com`; default ATS; Hardened Runtime stays on.
- **T-03.06-02 (Info Disc., bearer leak via logs) — mitigate:** `Secret` wrapper on the bearer; `revealForRequest()` not called in any Gemini source file (grep-verified — count 0 in GeminiOAuthProvider.swift); logger interpolations carry only `url.path` + HTTP status (SEC-02).
- **T-03.06-03 (DoS, v1internal flakiness blocks other providers) — mitigate:** GEMINI-04 cross-provider isolation invariant locked in by test N (arbitrary 5xx never throws — converts to degraded snapshot return). AggregateStore-level breaker does NOT increment because no throw occurs. Phase 2 STATE #56 invariant remains intact. Exception: `GeminiOAuthError.refreshFailed` does propagate so the breaker can respond to sustained refresh-endpoint failure (test L).
- **T-03.06-04 (Repudiation, stale data presented as fresh) — mitigate:** D-11 degraded snapshot stamps `raw["note"] = "usage-temporarily-unavailable"` + `raw["degraded"] = "true"` so the UI (Plan 03-07) can dim the row and append the "temporarily unavailable" subtitle. Snapshot's `asOf` is the current poll time; cached values explicitly tagged stale.
- **T-03.06-05 (Tampering, tooltipLabel forged via tier response) — accept:** tooltipLabel is display-only; the worst-case is a misleading tier label appearing in a tooltip on the local user's machine. The OAuth bearer authenticates the user-to-Google channel; a forged loadCodeAssist response would require an MITM on HTTPS to googleapis.com — out of scope.
- **T-03.06-06 (Elevation, retryAfter401 abuse) — mitigate:** Single-shot per fetch — the provider's lazy-401 path issues `oauth.retryAfter401` exactly once (verified by test F asserting `retryCallCount == 1` after a successful retry, and test K asserting `retryCallCount == 1` after a retry that also failed). No unbounded refresh loop.
- **T-03.06-SC (Tampering, npm/pip/cargo installs) — mitigate:** No package installs in this plan.

## Authentication Gates

None encountered. All work was code/test additions; no live HTTP calls, no Gemini CLI invocations, no Google OAuth consent flows.

## Composition Entry Point for Plan 03-08 (AppDependencies wiring)

```swift
// Production wiring inside AppDependencies.makeProduction():
let geminiHTTP = httpClient                                  // shared singleton (POLL-08)
let geminiOAuth = GeminiOAuthClient(http: geminiHTTP)        // from Plan 03-05
let geminiProvider: (any UsageProvider)? = {
    guard GeminiSettingsGate.isOAuthPersonal() else {
        return nil   // settings gate closed — don't register at all (D-09 / Plan 03-05 contract)
    }
    return GeminiOAuthProvider(
        http: geminiHTTP,
        oauth: geminiOAuth,
        clock: SystemClock()
    )
}()
```

Plan 03-07 (UI-11 + tooltip wiring) then surfaces `snap.tooltipLabel` via SwiftUI `.help()` on `ProviderRowView`. Plan 03-08 additionally wires the ThresholdEngine filter that suppresses notifications for any snapshot where `raw["note"] == GeminiOAuthProvider.degradedNote` (the D-11 marker constant exposed on the actor).

## Known Stubs

None — `GeminiOAuthProvider` is fully wired and fully tested. Plan 03-06 ends when the actor returns a `UsageSnapshot` from `fetch(now:)`; downstream wiring (UI surfacing + AppDependencies registration + ThresholdEngine suppression) is the explicit Plan 03-07 / Plan 03-08 boundary.

## Requirement Status

- **GEMINI-02** — **full** at the actor layer. `v1internal:retrieveUserQuota` decoded into `GeminiQuotaResponse`; per-model `remainingFraction` + ISO `resetTime` folded into `UsageSnapshot.quotaWindows` with `utilization = 1 - remainingFraction`; multi-bucket-per-model fold rule (keep LOWEST remainingFraction) implemented and tested. Primary quota fraction = max utilisation (D-06) rendered into `UsageSnapshot.quota`.
- **GEMINI-03** — **full** at the data layer. `v1internal:loadCodeAssist` decoded into `GeminiLoadCodeAssistResponse`; `tierDisplayName(forID: currentTier?.id)` maps RESEARCH correction #6 IDs to display strings; threaded into `UsageSnapshot.tooltipLabel`. UI rendering via SwiftUI `.help()` on `ProviderRowView` is the explicit Plan 03-07 boundary.
- **GEMINI-04** — **full** at the actor layer. Degraded UX (D-11) cached-dim row implemented with `raw["note"]="usage-temporarily-unavailable"` + `raw["degraded"]="true"` markers. Cross-provider isolation invariant — `fetch(now:)` never throws for v1internal flakiness — locked in by test N. Refresh-failure carve-out (different-host) propagates per the threat model (test L). ThresholdEngine notification suppression that keys on the marker constant lands in Plan 03-08 composition.

## Commits

| Hash    | Message                                                                                          |
|---------|--------------------------------------------------------------------------------------------------|
| 8187562 | feat(03-06): add GeminiQuotaResponse + GeminiLoadCodeAssistResponse Codable + .gemini ProviderID |
| 2e76a5e | feat(03-06): add GeminiOAuthProvider actor (eager pre-check + lazy-401 + degraded UX)            |

## Self-Check: PASSED

- `AgentsUsageBar/Providers/Gemini/Models/GeminiQuotaResponse.swift` — exists ✓
- `AgentsUsageBar/Providers/Gemini/Models/GeminiLoadCodeAssistResponse.swift` — exists ✓
- `AgentsUsageBar/Providers/Gemini/GeminiOAuthProvider.swift` — exists ✓
- `AgentsUsageBarTests/ProvidersGeminiTests/GeminiQuotaResponseTests.swift` — exists ✓
- `AgentsUsageBarTests/ProvidersGeminiTests/GeminiLoadCodeAssistResponseTests.swift` — exists ✓
- `AgentsUsageBarTests/ProvidersGeminiTests/GeminiOAuthProviderTests.swift` — exists ✓
- `AgentsUsageBarTests/ProvidersGeminiTests/GeminiOAuthProviderDegradedTests.swift` — exists ✓
- `AgentsUsageBarTests/ProvidersGeminiTests/Fixtures/gemini-quota-response-fixture.json` — exists ✓
- `AgentsUsageBarTests/ProvidersGeminiTests/Fixtures/gemini-quota-response-multibucket-fixture.json` — exists ✓
- `AgentsUsageBarTests/ProvidersGeminiTests/Fixtures/gemini-loadcodeassist-fixture.json` — exists ✓
- `AgentsUsageBarTests/ProvidersGeminiTests/Fixtures/gemini-loadcodeassist-object-project-fixture.json` — exists ✓
- `AgentsUsageBarTests/ProvidersGeminiTests/Fixtures/gemini-loadcodeassist-coldstart-fixture.json` — exists ✓
- Commit `8187562` (Task 1) — present in git log ✓
- Commit `2e76a5e` (Task 2) — present in git log ✓
- 29 new tests PASS ✓ (7 + 7 + 8 + 7)
- Full project Debug build succeeds ✓
- Full project test suite (Phase 1 + Phase 2 + Phase 3) PASS ✓
- Async-let concurrent-fetch grep gate PASS ✓
- D-07 token/cost nil grep gate PASS ✓
- D-11 degraded marker grep gate PASS ✓
- D-12 / SEC-01 negative grep gates PASS ✓ (0 CircuitBreaker, 0 revealForRequest in provider source)
- SEC-04 secret-scan PASS ✓ (0 matches across Gemini sources + tests, excluding allow-listed GeminiOAuthClient.swift)
- NSLock-fix flakiness verification PASS ✓ (5/5 deterministic post-fix vs 2/5 pre-fix)
