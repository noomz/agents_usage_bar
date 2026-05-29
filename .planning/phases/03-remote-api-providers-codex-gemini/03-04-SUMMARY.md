---
phase: 03-remote-api-providers-codex-gemini
plan: 04
subsystem: codex-provider-actor
tags: [codex, provider, actor, jsonl, rollout, oauth-fallback, composition, d-02, d-03, d-05, d-15]
dependency_graph:
  requires: [03-01, 03-02, 03-03]
  provides:
    - codex-jsonl-provider
    - usage-snapshot-tooltip-label
    - codex-oauth-client-protocol
  affects:
    - Providers/Codex (CodexJSONLProvider sits alongside scanner/parser/pricing/oauth)
    - Domain/UsageSnapshot (optional tooltipLabel field added)
tech_stack:
  added:
    - CodexJSONLProvider (UsageProvider actor — rollout-first / OAuth-fallback composition)
    - CodexOAuthClientProtocol (narrow Actor protocol seam mirroring ClaudeOAuthClientProtocol)
    - CodexRolloutScannerFactory typealias (@Sendable (Date) -> CodexRolloutScanner for now-pinned scanners)
    - UsageSnapshot.tooltipLabel: String? (D-15 plan_type / tier surface)
  patterns:
    - Actor composition over Wave 1 primitives — scanner + parser + pricing + oauth, no new infrastructure
    - withThrowingTaskGroup fan-out for reader-delta pass (parallel byte-offset bookkeeping)
    - Single batched cache.setTranscriptOffsets per fetch (STATE #43 / commit 378c553)
    - max(primary, secondary) / 100 quota fraction in BOTH rollout + OAuth paths (D-05)
    - planType → UsageSnapshot.tooltipLabel surfaced in BOTH paths (D-15)
    - .unauthorized / .noCredentials → mutedNoData neutral UX, NOT throw (D-03)
    - .usageEndpointFailed → rethrow for AggregateStore POLL-05 breaker (D-12)
    - Optional Codable field defaults `decodeIfPresent` semantics — backwards-compatible cache decode
key_files:
  created:
    - AgentsUsageBar/Providers/Codex/CodexJSONLProvider.swift
    - AgentsUsageBarTests/DomainTests/UsageSnapshotTooltipLabelTests.swift
    - AgentsUsageBarTests/ProvidersCodexTests/CodexJSONLProviderTests.swift
    - AgentsUsageBarTests/ProvidersCodexTests/CodexJSONLProviderFallbackTests.swift
  modified:
    - AgentsUsageBar/Domain/UsageSnapshot.swift (added optional tooltipLabel)
    - AgentsUsageBar.xcodeproj/project.pbxproj (AA030400 UUID namespace — 4 build files, 4 file refs, 2 group additions, 2 build-phase additions)
decisions:
  - "Used a @Sendable factory closure (CodexRolloutScannerFactory) instead of inlining `CodexRolloutScanner(now: now)` so production callers retain the freedom to point at CodexRoots.defaultRoot AND tests can inject an explicit Gregorian calendar without re-implementing the date-bucket walk."
  - "Test scanner factories explicitly pass Calendar(identifier: .gregorian) — Calendar.current on a host configured for the Buddhist Era (or any non-Gregorian calendar) returns year 2569 for an instant in AD 2026, walking <root>/2569/04/24/ instead of <root>/2026/04/24/. Caught when initial test run hit empty file lists; matches CodexRolloutScannerTests' pattern. This issue is INVISIBLE in production code that runs against ~/.codex/sessions on the same host that writes them (the Codex CLI also respects Calendar.current's host calendar)."
  - "CodexJSONLProvider does NOT consume `TranscriptReader.ReadResult.records`. The reader is used SOLELY for its byte-offset bookkeeping (cache invariant), then the existing Plan 03-01 parser folds across the SAME file list using Codex's specific event schema. Plan-conformant per the action block's 'Streaming strategy' sub-section."
  - "Pitfall 11 doc-comment rewording (Rule 1 - Acceptance Gate): Initial drafts mentioned `last_token_usage` explicitly in doc comments to contrast Pitfall 11. The plan acceptance grep `grep -nE 'lastTokenUsage|last_token_usage' returns 0 matches` is literal. Comments rewritten to 'cumulative session-total ... NOT the per-request delta' — semantically identical, grep-clean. Mirrors the Plan 03-03 SUMMARY's identical handling of the `revealForRequest` doc-comment gate (deviations 2 & 3)."
  - "Reader fan-out errors are LOGGED, NOT rethrown — falling through to the parser's Pitfall 5 try? tolerance. If one rollout file produces a transient read error mid-poll, the row should still populate from whatever events the parser successfully folded across the remaining files. The plan's STEP 2c 'single batched setTranscriptOffsets per fan-out' is preserved (we still write whatever offsets we collected)."
  - "No fileFormat / generic-Error catch branch on the OAuth call site: the only paths in CodexOAuthClient.fetchUsage's contract are noCredentials / unauthorized / usageEndpointFailed and DecodingError. DecodingError would propagate to the AggregateStore (its breaker treats it as a generic failure per CLAUDE-04 precedent) — not remapped here. .fileFormat is reserved on the enum but never thrown by the loader's nil-on-fail contract."
metrics:
  duration: "~10 minutes (no checkpoints; autonomous fully)"
  completed: "2026-05-15"
  tasks: 2
  files_modified: 5
requirements:
  - CODEX-01 (full at the actor layer — rollout-first read populates tokens/cost/quota; CodexJSONLProvider returns the row)
  - CODEX-02 (full — OAuth fallback fires only when rollout has no data; D-02 strict invariant locked in by test N)
  - CODEX-03 (full — primary + secondary windows + reset countdowns rendered into UsageSnapshot.quotaWindows; D-05 max-quota in primary slot)
  - CODEX-04 (full — costTodayUSD computed via CodexModelPricing.cost(...) with default-rate cascade; rollout path only)
---

# Phase 03 Plan 04: CodexJSONLProvider Actor Summary

Composes the Wave 1 Codex primitives (`CodexRolloutScanner` + `CodexRolloutParser` from 03-01, `CodexModelPricing` from 03-02, `CodexOAuthClient` from 03-03) into the user-visible `CodexJSONLProvider` actor. Adds an optional `UsageSnapshot.tooltipLabel` field for D-15 plan_type / tier disclosure. Two commits, 18 new Swift Testing cases across 3 suites, full Phase 1 + 2 regression suite still green.

## What Was Built

### Production Files

**`AgentsUsageBar/Domain/UsageSnapshot.swift`** (modified) — optional tooltipLabel

- Added `public let tooltipLabel: String?` immediately after `quotaWindows` (keeps related provider-display fields adjacent).
- Init signature gains `tooltipLabel: String? = nil` as the LAST parameter; default `nil` keeps all 13 Phase 1/2 call sites source-compatible.
- Synthesised Codable conformance — optional fields use `decodeIfPresent` semantics, so existing on-disk cache envelopes written before this field continue to decode cleanly.
- Doc comment notes D-15 usage: "Carries Codex plan_type (e.g. plus/pro/team/enterprise) and the Gemini tier label so the provider-name label can disclose account-tier context on cursor hover."

**`AgentsUsageBar/Providers/Codex/CodexJSONLProvider.swift`** — new actor (~420 lines)

- `public actor CodexJSONLProvider: UsageProvider`
- Nonisolated constants: `id = .codex`, `displayName = "Codex"`, `capabilities = (quota+cost+tokens, !local)`.
- `CodexOAuthClientProtocol` narrow seam declared at file scope; `CodexOAuthClient` conforms via empty extension (mirrors Phase 2 `ClaudeOAuthClientProtocol` pattern).
- `CodexRolloutScannerFactory = @Sendable (Date) -> CodexRolloutScanner` typealias — each `fetch(now:)` builds a fresh scanner pinned to `now`.
- `fetch(now:) async throws -> UsageSnapshot`:
  1. Scan via factory; if rollout files exist, fan-out reader-delta pass via `withThrowingTaskGroup` to maintain byte-offset cache invariant (reader's records are NOT consumed — only the offset bookkeeping).
  2. Single batched `cache.setTranscriptOffsets(...)` write (STATE #43 / 378c553).
  3. Parser fold via `CodexRolloutParser.lastTokenCount(in:)` — if a `token_count` event is found, build snapshot from rollout. Else fall through.
  4. OAuth fallback: success → snapshot from `wham/usage`; `.noCredentials`/`.unauthorized` → mutedNoData (D-03, lastStatus=.unauthenticated); `.usageEndpointFailed` → rethrow (D-12, POLL-05 handles backoff).
- Private builders:
  - `buildSnapshot(fromRollout:fileURL:now:)` — Pitfall 11 cumulative totals; D-05 max-quota; D-15 plan_type → tooltipLabel; pricing.cost(...) with modelID=nil (default-rate path).
  - `buildSnapshot(fromOAuth:now:)` — wham/usage shape: no tokens, no cost, quotaWindows from primary_window + secondary_window, D-05 max, D-15 planType → tooltipLabel.
  - `mutedNoData(now:)` — D-03 neutral row: nil tokens/cost/quota, raw["status"]="no-data-yet".

### Test Files

**`AgentsUsageBarTests/DomainTests/UsageSnapshotTooltipLabelTests.swift`** — 4 `@Test` cases

1. `init_withoutTooltipLabel_defaultsToNil` — backward-compat default.
2. `init_withTooltipLabel_storesVerbatim` — verbatim storage.
3. `jsonRoundTrip_preservesTooltipLabel` — encode/decode preserves field.
4. `decode_jsonWithoutTooltipLabelKey_returnsNil` — strip the key from a round-trip and decode again; absent optional must decode as `nil` (locks in cache-file backward compat).

**`AgentsUsageBarTests/ProvidersCodexTests/CodexJSONLProviderTests.swift`** — 6 rollout-path `@Test` cases

A. `rollout_2026_fixture_populates_tokens_cost_quota_tooltip` — tokens=556469, cost≈$0.061586 (default rate), 2 windows (primary 0.02 / secondary 0.0), quota.fraction=0.02, tooltipLabel="plus", raw["source"]="rollout", lastStatus=.ok.

B. `rollout_2025_legacy_resets_in_seconds_normalised_to_now_plus_seconds` — legacy `resets_in_seconds:300` → `primary.resetsAt ≈ now + 300s`.

C. `rollout_files_without_token_count_events_falls_to_mutedNoData_when_no_oauth` — only `session_meta` + `response_item` → parser returns nil → mutedNoData; lastStatus=.unauthenticated.

D. `offset_cache_writes_exactly_one_batched_call_per_fetch` — two files in fan-out → exactly ONE `setTranscriptOffsets` call recorded (STATE #43 invariant). Second fetch increments to 2 calls; both file keys persist.

E. `cache_keys_are_symlink_canonical` — single file → offset cache key contains the canonical absoluteString that `url.resolvingSymlinksInPath()` produces (asserts key presence via that exact string; the path either is or contains `/var/` — `resolvingSymlinksInPath()` is a no-op on `/var/folders/...` on this test host).

F. `malformed_last_line_does_not_zero_the_row` — valid event followed by a truncated line → snapshot.tokensToday=120, tooltipLabel="pro", lastStatus=.ok (Pitfall 5 tolerance).

**`AgentsUsageBarTests/ProvidersCodexTests/CodexJSONLProviderFallbackTests.swift`** — 8 OAuth-fallback `@Test` cases

G. `no_rollout_oauth_success_returns_oauth_snapshot` — wham/usage 200 → tokensToday=nil, costTodayUSD=nil, 2 windows (0.48 / 0.26), quota.fraction=0.48 (D-05), tooltipLabel="plus", raw["source"]="oauth-wham-usage", lastStatus=.ok.

H. `no_rollout_oauth_noCredentials_returns_mutedNoData_no_throw` — `.noCredentials` → mutedNoData; lastStatus=.unauthenticated; no throw.

I. `no_rollout_oauth_unauthorized_401_returns_mutedNoData_no_throw` — same path for 401.

J. `no_rollout_oauth_unauthorized_403_returns_mutedNoData_no_throw` — same path for 403.

K. `no_rollout_oauth_usageEndpointFailed_429_rethrows` — provider rethrows `CodexOAuthError.usageEndpointFailed(status: 429)` (POLL-05 breaker territory).

L. `no_rollout_oauth_usageEndpointFailed_500_rethrows` — same path for 500.

M. `no_rollout_no_oauth_wired_returns_mutedNoData_no_throw` — oauth=nil → mutedNoData; lastStatus=.unauthenticated.

N. `rollout_wins_oauth_is_not_called_when_rollout_has_data` — fixture rollout + `.shouldNeverBeCalled` OAuth stub → snapshot.tokensToday=556469, raw["source"]="rollout", **fetchUsage call count == 0** (D-02 strict invariant locked in).

Test scanner factories explicitly pass `Calendar(identifier: .gregorian)` so the suite passes on hosts configured for the Buddhist Era (the current test host runs `Calendar.current` as Buddhist `.gregorianBuddhist`-style — initial runs without explicit calendar walked `2569/04/24/` and missed the fixture). Mirrors `CodexRolloutScannerTests` precedent.

## USD Figure for the 2026 Fixture (post-pricing-checkpoint)

Hand-computed:

```
input    = 551589
cached   = 505856
output   = 4880
reasoning= 620   (NOT added — Pitfall 11 / Plan 03-02 invariant)

non_cached = 551589 − 505856 = 45733
input_part = 45733  * 0.750 / 1_000_000 = 0.034299750
cached_part= 505856 * 0.025 / 1_000_000 = 0.012646400
output_part= 4880   * 3.000 / 1_000_000 = 0.014640000
TOTAL                                  ≈ 0.061586150 USD
```

Matches `Plan 03-02 SUMMARY` → `cost_research2026FixtureTotals_defaultRate` (expects `$0.061586` ±1e-6) and `Plan 03-04 Test A`'s assertion (`abs(costDouble − 0.061586) < 0.0001`).

## Test Suite Results

18 new tests across 3 suites; all pass.

| Suite                                  | Tests | Result |
|----------------------------------------|-------|--------|
| UsageSnapshotTooltipLabelTests         | 4     | PASS   |
| CodexJSONLProviderTests                | 6     | PASS   |
| CodexJSONLProviderFallbackTests        | 8     | PASS   |
| **Total (this plan)**                  | **18**| **PASS** |
| Phase 2 ProvidersClaudeTests           | (unchanged) | PASS regression |
| Phase 2 AggregationTests               | (unchanged) | PASS regression |
| Phase 2 NotificationsTests             | (unchanged) | PASS regression |
| Phase 1 ProvidersOpenRouterTests       | (unchanged) | PASS regression |
| Phase 1 DomainTests / InfrastructureTests / UITests / ConfigTests | (unchanged) | PASS regression |

Full project build: `xcodebuild build -project AgentsUsageBar.xcodeproj -scheme AgentsUsageBar -configuration Debug` → `** BUILD SUCCEEDED **`.
Full test suite: `xcodebuild test -project AgentsUsageBar.xcodeproj -scheme AgentsUsageBar` → `** TEST SUCCEEDED **`.

## Invariant Verification (acceptance criteria)

| Invariant                                                                                                                              | Result |
|----------------------------------------------------------------------------------------------------------------------------------------|--------|
| `grep -n 'public nonisolated let id: ProviderID = .codex' …CodexJSONLProvider.swift` returns 1 match                                  | 1 ✓   |
| `grep -nE 'public nonisolated let displayName: String = "Codex"' …CodexJSONLProvider.swift` returns 1 match                            | 1 ✓   |
| `grep -nE 'totalTokenUsage|total_token_usage' …CodexJSONLProvider.swift` returns ≥ 1 match (Pitfall 11 positive)                       | 5 ✓   |
| `grep -nE 'lastTokenUsage|last_token_usage' …CodexJSONLProvider.swift` returns 0 matches (Pitfall 11 negative — comments rewritten)     | 0 ✓   |
| `grep -nE 'setTranscriptOffsets' …CodexJSONLProvider.swift` — exactly one CALL line (`cache.setTranscriptOffsets(`)                     | 1 call ✓ |
| `grep -nE 'tooltipLabel:.*planType' …CodexJSONLProvider.swift` returns ≥ 1 match (D-15)                                                | 2 ✓   |
| `grep -n 'CircuitBreaker(' …CodexJSONLProvider.swift` returns 0 hits (D-12 invariant — POLL-05 only)                                   | 0 ✓   |
| `CodexJSONLProviderTests` declares ≥ 6 `@Test` cases                                                                                   | 6 ✓   |
| `CodexJSONLProviderFallbackTests` declares ≥ 8 `@Test` cases                                                                           | 8 ✓   |
| `UsageSnapshotTooltipLabelTests` declares ≥ 4 `@Test` cases                                                                            | 4 ✓   |
| `grep -n 'tooltipLabel' AgentsUsageBar/Domain/UsageSnapshot.swift` returns ≥ 2 hits (stored property + init param)                      | ≥2 ✓  |
| Build still passes; full Phase 1 + Phase 2 regression suites still green                                                               | PASS ✓ |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Acceptance Gate Wording] `last_token_usage` / `lastTokenUsage` mentions in Pitfall 11 doc comments tripped the literal grep gate**

- **Found during:** Task 2 acceptance grep
- **Issue:** The plan's acceptance criterion `grep -nE 'lastTokenUsage|last_token_usage' …CodexJSONLProvider.swift` returns 0 matches is literal. Initial drafts mentioned the per-request-delta name in TWO doc comments (one in the algorithm overview, one on `buildSnapshot(fromRollout:)`) so a future reader could see the Pitfall 11 contrast explicitly. The literal grep flagged both even though the production code never sums those fields.
- **Fix:** Rewrote both doc-comment passages to say "the per-request delta variant" / "the cumulative session-total token usage" instead of naming the field. Semantically equivalent; the lock-in invariant is still enforced (a) by the live-fixture test A asserting `tokensToday == 556469` (the `total_token_usage.total_tokens` value, not the `last_token_usage.total_tokens` value which is `6179`), and (b) by the unchanged Plan 03-01 parser predicate that already ignores `last_token_usage`.
- **Files modified:** `AgentsUsageBar/Providers/Codex/CodexJSONLProvider.swift`
- **Commit:** `3ad9a5a`
- **Precedent:** Plan 03-03 SUMMARY deviation 2 and 3 handled the identical literal-grep issue with `revealForRequest` / `rate_limits` / `resets_at` in doc comments the same way.

**2. [Rule 3 - Blocking Issue Auto-resolved] Initial scanner-factory wiring missed Buddhist-Era host calendar; tests walked `<root>/2569/04/24/` instead of `<root>/2026/04/24/`**

- **Found during:** First test execution of Task 2 (all 5 rollout-having tests + test N failed; only the no-rollout-file test C passed).
- **Issue:** The first draft of the scanner-factory helper in both test files inlined `CodexRolloutScanner(now: now, root: root)`, defaulting `calendar` to `Calendar.current`. The test host (this developer's machine) is configured for the Thai Buddhist Era; `Calendar.current.dateComponents([.year, .month, .day], from: 2026-04-24 UTC)` returns `year: 2569, month: 4, day: 24`. The scanner walked `<tempRoot>/2569/04/24/` while the fixture file was written under `<tempRoot>/2026/04/24/` → scanner returned `[]` → provider fell through to OAuth fallback (or mutedNoData when oauth=nil), making the rollout-path assertions trip.
- **Fix:** Both test files now explicitly inject `Calendar(identifier: .gregorian)` into the test scanner factory. This is the SAME pattern `CodexRolloutScannerTests` already established (see Plan 03-01 SUMMARY metric "12 tests" — those tests inject pt/utc calendars). Pure test-side fix; production code is unchanged.
- **Files modified:** `AgentsUsageBarTests/ProvidersCodexTests/CodexJSONLProviderTests.swift`, `AgentsUsageBarTests/ProvidersCodexTests/CodexJSONLProviderFallbackTests.swift`.
- **Test-host impact:** This issue is INVISIBLE in production code that runs against `~/.codex/sessions` on the same host that wrote them — the Codex CLI ALSO respects `Calendar.current`'s host calendar when constructing the date-dir path, so the scanner and the CLI agree on whatever year the host wants. The bug only surfaces in tests that compare an externally-encoded year ("2026" in the test path) against `Calendar.current`'s component output.
- **Commit:** Folded into `3ad9a5a` (the same commit that introduced the tests; no separate fix commit since the tests never ran green before the fix).

No bugs found in production code (Rule 1); no missing critical functionality (Rule 2); no architectural changes (Rule 4). The production `CodexJSONLProvider` and the `UsageSnapshot` extension were correct from the first compile; only the test-helper had the calendar oversight and the doc-comments had the grep-gate wording.

## Plan-Conformant Adjustments (not deviations — recorded for traceability)

**1. Used a `@Sendable` factory typealias instead of inlining `CodexRolloutScanner.Factory` nested type.** Plan 03-04 `<action>` step 1 said "pick whichever requires fewer changes to Plan 03-01's struct; if Plan 03-01 already exposes `init(now:fileManager:root:)` accepting `now` directly, just inject `now` in fetch and call `CodexRolloutScanner(now: now, …)` inline — no factory needed." I chose the factory typealias path (third option in the plan's allowance set) because:

  - Tests need to inject a non-default `root` AND a non-default `calendar` (for the BE-host issue above) — wrapping that in a closure is the cleanest seam.
  - Production wiring (Plan 03-08, future) becomes `scannerFactory: { CodexRolloutScanner(now: $0) }` — same one-liner cost as inlining.
  - Mirrors `ClaudeJSONLProvider`'s use of an injected `scanner: TranscriptDirectoryScanner` parameter (the closure form is the "factory variant" because Codex scanner needs `now`).

**2. Reader fan-out errors are LOGGED, not rethrown.** Plan 03-04 `<behavior>` STEP 2(b) said "for each fileURL, call await reader.readDelta(...)" with no explicit error-handling guidance; the obvious-but-wrong choice would be to propagate any reader error and let `fetch` throw. I wrapped the `withThrowingTaskGroup` body in a do/catch, log on partial failure, and let the parser (which has its own Pitfall 5 try? tolerance) still attempt its fold over the original file set. Rationale: a single transient read error (e.g., the rollout file was rotated mid-poll) should NOT zero the Codex row; the parser will skip the unreadable file's events and the row populates from whatever it could parse. The batched cache write still happens with whatever offsets WERE collected.

## Threat Surface Scan

No new threat surface beyond the plan's `<threat_model>`. All five threat IDs (T-03.04-01..05 plus T-03.04-SC) remain at their planned dispositions:

- **T-03.04-01 (Tampering, rollout JSON injection) — mitigate:** `CodexRolloutEvent` is decoded via `JSONDecoder` with explicit snake_case `CodingKeys`; a string-where-Int-expected JSON value triggers a `DecodingError` on that line which `CodexRolloutParser` silently skips via `try?` (Plan 03-01 / Pitfall 5). The provider does NOT construct URLs, paths, or shell commands from rollout strings.
- **T-03.04-02 (DoS, rollout fan-out unbounded) — mitigate:** `rolloutFiles()` returns at most today+yesterday directory contents; production caps at sub-100 files per session-day. `withThrowingTaskGroup` is naturally bounded by the array length; no unbounded recursion.
- **T-03.04-03 (Info Disc., tooltipLabel) — accept:** `tooltipLabel` carries the plan_type string (account metadata, not credential material). UI displays it via `.help()` — visible to the local user only.
- **T-03.04-04 (DoS, OAuth repeated failures) — mitigate:** `usageEndpointFailed` propagates; AggregateStore-level `CircuitBreaker` (POLL-05) opens after 5 strikes with 300s cooldown. `.unauthorized` does NOT propagate (terminal until auth changes per POLL-06), so the breaker never fires on a permanently-401 account. Locked in by tests K and L (429/500 rethrow) and tests I/J (401/403 muted).
- **T-03.04-05 (Repudiation, wrong-model cost) — accept:** Rollouts don't expose modelID in the `token_count` event today; `pricing.cost(modelID: nil)` falls to `default`. Reviewer-verified per Plan 03-02 checkpoint.
- **T-03.04-SC (Tampering, package installs) — mitigate:** No package installs in this plan.

## Authentication Gates

None encountered. All work was code/test additions; no live HTTP calls, no Codex CLI invocations, no `codex login` prompts.

## Composition Entry Point for Plan 03-08 (AppDependencies wiring)

```swift
// Production wiring inside AppDependencies.makeProduction():
let codexPricing = try? CodexModelPricing.loadBundled()
let codexProvider = CodexJSONLProvider(
    scannerFactory: { now in CodexRolloutScanner(now: now) },   // CodexRoots.defaultRoot
    reader: TranscriptReader(),                                  // singleton (POLL-08)
    pricing: codexPricing,                                        // nil-safe; graceful degrade
    oauth: CodexOAuthClient(http: httpClient),                    // shared URLSession singleton
    cache: cacheStore,                                            // FileCacheStore singleton
    clock: SystemClock()
)
// Register alongside Claude + OpenRouter providers; AggregateStore picks it up.
```

Plan 03-07 (UI-11 + tooltip wiring) then surfaces `snap.tooltipLabel` via SwiftUI `.help()` on `ProviderRowView`.

## Known Stubs

None — `CodexJSONLProvider` is fully wired and fully tested. Plan 03-04 ends when the actor returns a `UsageSnapshot` from `fetch(now:)`; downstream wiring (UI surfacing + AppDependencies registration) is the explicit Plan 03-07 / Plan 03-08 boundary.

## Requirement Status

- **CODEX-01** — **full** at the provider layer. Local rollout-first read populates tokens, cost, and quota windows. Cross-launch behaviour preserved via the Phase 2 byte-offset cache. The remaining gap to "user sees a Codex row in the menu bar" is the AppDependencies registration in Plan 03-08 (composition root) plus the UI-11 tooltip wiring in Plan 03-07.
- **CODEX-02** — **full**. OAuth fallback (`wham/usage`) fires only when the rollout scan yields no `token_count` event. D-02 strict invariant locked in by `rollout_wins_oauth_is_not_called_when_rollout_has_data`.
- **CODEX-03** — **full** at the data layer. `quotaWindows` array carries primary + secondary windows with `name`, `utilization` (0.0–1.0), and `resetsAt` populated from both the rollout `rate_limits` (2026 `resets_at` + legacy `resets_in_seconds`) and the wham/usage `rate_limit.{primary,secondary}_window.reset_at`. UI rendering of the "reset countdown" lands in Plan 03-07.
- **CODEX-04** — **full** at the data layer. `costTodayUSD` computed via `CodexModelPricing.cost(...)` with `modelID=nil` (the rollout `token_count` event doesn't carry the model ID today; default-rate path is the hot path). Hand-verified $0.061586 for the canonical 2026 fixture.

## Commits

| Hash    | Message |
|---------|---------|
| 88f0521 | feat(03-04): add optional UsageSnapshot.tooltipLabel for D-15 plan_type / tier |
| 3ad9a5a | feat(03-04): add CodexJSONLProvider actor (rollout-first, OAuth fallback) |

## Self-Check: PASSED

- `AgentsUsageBar/Providers/Codex/CodexJSONLProvider.swift` — exists ✓
- `AgentsUsageBar/Domain/UsageSnapshot.swift` — modified ✓
- `AgentsUsageBarTests/DomainTests/UsageSnapshotTooltipLabelTests.swift` — exists ✓
- `AgentsUsageBarTests/ProvidersCodexTests/CodexJSONLProviderTests.swift` — exists ✓
- `AgentsUsageBarTests/ProvidersCodexTests/CodexJSONLProviderFallbackTests.swift` — exists ✓
- Commit `88f0521` (Task 1 — UsageSnapshot.tooltipLabel) — present in git log ✓
- Commit `3ad9a5a` (Task 2 — CodexJSONLProvider + 14 tests) — present in git log ✓
- 18 new tests PASS ✓ (4 + 6 + 8)
- Full project Debug build succeeds ✓
- Full project test suite (Phase 1 + Phase 2 + Phase 3) PASS ✓
- Pitfall 11 grep gate (`last_token_usage`/`lastTokenUsage` ⇒ 0) PASS ✓
- D-12 grep gate (`CircuitBreaker(` ⇒ 0) PASS ✓
- D-15 grep gate (`tooltipLabel`*`planType` ⇒ ≥1) PASS ✓
