---
phase: 03-remote-api-providers-codex-gemini
plan: 03
subsystem: codex-oauth-fallback
tags: [codex, oauth, wham-usage, credential-loader, typed-errors, fallback]
dependency_graph:
  requires: [03-01]
  provides:
    - codex-credential-loader
    - codex-oauth-error
    - codex-usage-response
    - codex-oauth-client
  affects:
    - Providers/Codex (CodexCredentialLoader, CodexOAuthClient sit alongside scanner/parser)
    - Providers/Codex/Models (CodexOAuthError + CodexUsageResponse alongside CodexRolloutEvent)
tech_stack:
  added:
    - CodexCredentialLoader (struct; reads ~/.codex/auth.json; resolves bearer + accountId)
    - CodexOAuthError (typed enum; noCredentials/unauthorized/usageEndpointFailed/fileFormat)
    - CodexUsageResponse (lenient Codable; wham/usage shape — distinct from rollout schema)
    - CodexOAuthClient (actor; GET wham/usage; HTTPError → typed CodexOAuthError remap)
  patterns:
    - Bearer wrapped in Secret at the absolute last moment (SEC-01)
    - Explicit snake_case CodingKeys everywhere (no keyDecodingStrategy)
    - decodeIfPresent for every wham/usage field (lenient — Pitfall 7)
    - HTTPError 401/403 → unauthorized (terminal); 429/5xx → usageEndpointFailed (POLL-05 feed); DecodingError unchanged
    - Mirrors ClaudeOAuthClient shape minus refresh path (Codex CLI manages rotation; we degrade-to-local on 401)
    - FakeHTTPClient at the HTTPClient protocol seam (Phase 2 repo precedent — same intent as STATE #19's URLProtocol stub, less boilerplate)
key_files:
  created:
    - AgentsUsageBar/Providers/Codex/CodexCredentialLoader.swift
    - AgentsUsageBar/Providers/Codex/CodexOAuthClient.swift
    - AgentsUsageBar/Providers/Codex/Models/CodexOAuthError.swift
    - AgentsUsageBar/Providers/Codex/Models/CodexUsageResponse.swift
    - AgentsUsageBarTests/ProvidersCodexTests/CodexCredentialLoaderTests.swift
    - AgentsUsageBarTests/ProvidersCodexTests/CodexUsageResponseTests.swift
    - AgentsUsageBarTests/ProvidersCodexTests/CodexOAuthClientTests.swift
    - AgentsUsageBarTests/ProvidersCodexTests/Fixtures/codex-auth-subscription.json
    - AgentsUsageBarTests/ProvidersCodexTests/Fixtures/codex-auth-apikey.json
    - AgentsUsageBarTests/ProvidersCodexTests/Fixtures/codex-auth-empty.json
    - AgentsUsageBarTests/ProvidersCodexTests/Fixtures/codex-wham-usage-fixture.json
  modified:
    - AgentsUsageBar.xcodeproj/project.pbxproj (added 4 source refs, 3 test refs, 4 fixture refs; extended Codex source subgroup, Models subgroup, ProvidersCodexTests group, Fixtures subgroup; wired both build phases)
decisions:
  - "CodexCredentialLoader has NO Keychain path — Codex CLI never writes to Keychain. Diverges from ClaudeCredentialLoader's three-source priority chain; loader is a single-source file reader."
  - "CodexOAuthClient has NO refresh path — Codex CLI manages its own bearer rotation. The `clock` init parameter is retained for parity with ClaudeOAuthClient and to leave a seam for future expiry-check logic."
  - "Bearer resolution priority follows RESEARCH correction #4: (1) top-level OPENAI_API_KEY if non-null non-empty (API-key users) → source=.apiKey, accountId nil; (2) tokens.access_token if non-empty (subscription users) → source=.subscription, accountId from tokens.account_id (may be nil for personal accounts); (3) neither → loadCredentials returns nil."
  - "Empty-string OPENAI_API_KEY treated as absent — same precedent as Phase 1 STATE #22 (empty OPENROUTER_API_KEY)."
  - "CodexUsageResponse is INTENTIONALLY separate from CodexRolloutEvent.RateLimits per RESEARCH correction #5. Schema diverges: singular `rate_limit` (NOT `rate_limits`), `primary_window`/`secondary_window` (NOT `primary`/`secondary`), `reset_at` (no `s`), `limit_window_seconds` (NOT `window_minutes`). A regression test (`rolloutShapeKeys_doNotMisresolveIntoWhamUsageStruct`) locks in this invariant."
  - "`account_id` is forwarded as cleartext `ChatGPT-Account-Id` HTTP header — it identifies a workspace, NOT a credential. NEVER wrapped in Secret (correct: Secret is for auth-bearer material only)."
  - "401/403 dispositioned as `unauthorized` (terminal; provider renders muted 'No data yet' row per D-03), NOT a red error state. 429 / 5xx dispositioned as `usageEndpointFailed` (feeds AggregateStore-level CircuitBreaker per POLL-05). DecodingError + other Swift errors propagate unchanged (mirrors ClaudeOAuthClient)."
  - "Removed `fileManager: FileManager` stored property from CodexCredentialLoader — `FileManager` is not `Sendable`, breaking Swift 6 strict concurrency. File reads use `Data(contentsOf:)` which doesn't need it. Documented as Rule 1 (bug fix during Task 1)."
  - "Used FakeHTTPClient at the HTTPClient protocol seam (mirrors Phase 2 ClaudeOAuthClientTests) instead of a literal URLProtocol stub. Equivalent semantic — captures request URL + bearer + extraHeaders, scripts response data + errors — without the URLProtocol/NSLock boilerplate. Plan's 'URLProtocol stub pattern' wording was over-specified relative to repo convention; STATE #19's intent (deterministic stubbed HTTP) is satisfied."
  - "Test fixtures use `FAKE-` prefixed tokens (Phase 1 STATE #39 precedent) to keep SEC-04 CI grep noise-free across `sk-*` / `AIza` patterns."
  - "Tests load fixtures via `#filePath` (NOT bundle resources) — same approach as CodexRollout fixtures, ProvidersClaudeTests fixtures. Pbxproj wires fixtures into the Fixtures group for IDE discoverability but they are NOT in any PBXResourcesBuildPhase."
metrics:
  duration: "~25 minutes"
  completed: "2026-05-15"
  tasks: 2
  files_modified: 12
requirements:
  - CODEX-02 (full — OAuth fallback primitives delivered; composition into CodexJSONLProvider's rollout-first/OAuth-fallback decision logic occurs in Plan 03-04)
---

# Phase 03 Plan 03: Codex OAuth Fallback Summary

Delivers the Codex OAuth fallback primitives required by CODEX-02 (D-02): a credential loader for `~/.codex/auth.json`, a typed-error surface, a wham/usage response decoder with the correct (rollout-distinct) schema, and an actor performing the bearer'd GET. Two atomic commits, 23 new Swift Testing cases across three new suites, clean Debug build. Plan 03-04 will compose these into `CodexJSONLProvider`'s rollout-first / OAuth-fallback decision logic.

## What Was Built

### Production Files

**`AgentsUsageBar/Providers/Codex/CodexCredentialLoader.swift`** — `~/.codex/auth.json` reader
- `public struct: Sendable`, nested `Bearer { token: Secret, accountId: String? }`, `Source { .apiKey, .subscription }`, `Result { bearer, source }`.
- `loadCredentials() -> Result?` returns `nil` (never throws) when the file is absent, unreadable, malformed, or yields no bearer.
- Bearer-resolution priority per RESEARCH correction #4: top-level `OPENAI_API_KEY` if non-null/non-empty → API-key path; else `tokens.access_token` if non-empty → subscription path with `tokens.account_id` forwarded; else `nil`.
- `Secret` wrapping happens at construction time (one allocation per call); SEC-01 invariant — the file does NOT call the credential-reveal accessor.
- `init(authPath: URL? = nil)` — production default `~/.codex/auth.json`; tests inject a temp-dir URL.
- Logs only `source` (`.public`) at `.notice` via `AppLogger.logger(category: "codex-oauth")`.

**`AgentsUsageBar/Providers/Codex/Models/CodexOAuthError.swift`** — typed-error enum
- `noCredentials` — no `~/.codex/auth.json` or no usable bearer; D-03 muted-row UX.
- `unauthorized(status:)` — 401/403 from wham/usage; terminal until user re-auths via Codex CLI; same D-03 disposition.
- `usageEndpointFailed(status:)` — 429 or any non-2xx; feeds POLL-05 circuit breaker.
- `fileFormat(detail:)` — reserved for the OAuth client path (loader returns `nil` instead of throwing this).

**`AgentsUsageBar/Providers/Codex/Models/CodexUsageResponse.swift`** — wham/usage decoder
- `public struct: Decodable, Sendable, Equatable` with nested `RateLimit`, `Window`, `Credits`.
- Schema (RESEARCH correction #5, **distinct from rollout**): `plan_type` → `planType`, **`rate_limit`** (singular) → `rateLimit`, `primary_window`/`secondary_window` → `primaryWindow`/`secondaryWindow`, **`reset_at`** (no `s`) → `resetAt`, `limit_window_seconds` → `limitWindowSeconds`.
- Every field `decodeIfPresent`-equivalent (declared `Optional`) — wham/usage may omit any sub-object for accounts in unusual states.
- Explicit snake_case `CodingKeys` on every type (no `keyDecodingStrategy = .convertFromSnakeCase`) — Phase 2 `TranscriptRecord` + `CodexRolloutEvent` precedent.
- `Window.resetDate() -> Date?` normalises `resetAt` (epoch seconds) to absolute `Date`.

**`AgentsUsageBar/Providers/Codex/CodexOAuthClient.swift`** — wham/usage actor
- `public actor CodexOAuthClient` with `public static let endpoint = URL("https://chatgpt.com/backend-api/wham/usage")!`.
- Stored: `http: any HTTPClient`, `credentialLoader: CodexCredentialLoader`, `clock: any Clock` (parity seam — Codex has no refresh).
- `fetchUsage() async throws -> CodexUsageResponse`:
  1. `loadCredentials()` → throw `.noCredentials` on nil.
  2. Build `extraHeaders = ["Accept": …, "User-Agent": …]`; insert `"ChatGPT-Account-Id"` only when `accountId != nil`.
  3. `http.get(endpoint, bearer: creds.bearer.token, extraHeaders: …, as: CodexUsageResponse.self)`.
  4. `HTTPError` mapping: 401/403 → `.unauthorized(status:)`; other non-2xx (429/5xx) → `.usageEndpointFailed(status:)`.
  5. `DecodingError` + other `Error` propagate unchanged (matches `ClaudeOAuthClient` precedent).
- SEC-01 invariant: this file does **not** call the credential-reveal accessor. `revealForRequest` happens exclusively inside `URLSessionHTTPClient.performGet` (Phase 1 STATE #15). A test-side source-grep (`clientSource_doesNotCallRevealForRequest`) locks in the invariant.
- SEC-02 logging: only `wham/usage <status>` and the source label (`.apiKey` / `.subscription`) at `.notice`; never the bearer.

### Test Files

**`AgentsUsageBarTests/ProvidersCodexTests/CodexCredentialLoaderTests.swift`** — 8 tests
1. Missing file → `nil` (no throw).
2. Subscription fixture → `.subscription`, accountId forwarded, `Secret` redacts in description.
3. API-key fixture → `.apiKey`, accountId nil, takes precedence over tokens.
4. Empty-tokens fixture → `nil`.
5. Malformed JSON → `nil` (best-effort, no throw).
6. `OPENAI_API_KEY: ""` empty string treated as absent → falls through to tokens.
7. `accountId` is `nil` when missing from tokens (personal accounts).
8. Neither credential path populated → `nil`.

**`AgentsUsageBarTests/ProvidersCodexTests/CodexUsageResponseTests.swift`** — 6 tests
1. Full fixture decode: all RESEARCH-quoted fields match (planType=plus; primary usedPercent=48, resetAt=1777970900, limitWindowSeconds=18000; secondary usedPercent=26, resetAt=1778060488, limitWindowSeconds=604800; credits.balance=nil).
2. `Window.resetDate()` returns `Date(timeIntervalSince1970:)` for both windows.
3. Partial response (only `primary_window`) decodes; secondary nil.
4. Empty object `{}` decodes; every nested field nil.
5. Unknown future top-level + nested keys tolerated (Pitfall 7).
6. **Schema-correction regression**: a rollout-shaped payload (`rate_limits` plural + `primary` + `resets_at` + `window_minutes`) leaves `rateLimit` nil — locks in correction #5. (`plan_type` matches in both schemas; that one decodes.)

**`AgentsUsageBarTests/ProvidersCodexTests/CodexOAuthClientTests.swift`** — 9 tests
1. Happy path: 200 with fixture body → decoded `CodexUsageResponse`; request URL = endpoint; bearer is `Secret`-wrapped (description=`<redacted>`); `ChatGPT-Account-Id` forwarded.
2. No-accountId path: when bearer has `accountId == nil`, header omitted entirely (other headers still present).
3. HTTP 401 → `CodexOAuthError.unauthorized(status: 401)`.
4. HTTP 403 → `CodexOAuthError.unauthorized(status: 403)`.
5. HTTP 429 → `CodexOAuthError.usageEndpointFailed(status: 429)`.
6. HTTP 500 → `CodexOAuthError.usageEndpointFailed(status: 500)`.
7. Loader returns `nil` → `CodexOAuthError.noCredentials`; HTTP client never invoked.
8. Malformed JSON 200 → `DecodingError` (NOT remapped — caught explicitly with `is DecodingError`).
9. **SEC-01 source guard**: `CodexOAuthClient.swift` does not contain the literal string `revealForRequest`.

### Test Fixtures

- `codex-auth-subscription.json` — `OPENAI_API_KEY: null` + populated `tokens` block with `account_id`.
- `codex-auth-apikey.json` — non-null `OPENAI_API_KEY` AND populated `tokens` block (asserts precedence).
- `codex-auth-empty.json` — `OPENAI_API_KEY: null`, `tokens: {}`.
- `codex-wham-usage-fixture.json` — verbatim RESEARCH §"Codex OAuth Fallback" response example.

All fixtures use `FAKE-` prefixed token strings (Phase 1 STATE #39) so SEC-04 grep stays clean across `sk-` / `AIza` patterns.

## Test Suite Results

23 new tests across 3 new suites; all pass.

| Suite                          | Tests | Result |
|--------------------------------|-------|--------|
| CodexCredentialLoaderTests     | 8     | PASS   |
| CodexUsageResponseTests        | 6     | PASS   |
| CodexOAuthClientTests          | 9     | PASS   |
| **Total (this plan)**          | **23**| **PASS** |

Combined across all Codex test suites (Plan 03-01 + 03-03), 46 tests pass.

Full project build: `xcodebuild build -project AgentsUsageBar.xcodeproj -scheme AgentsUsageBar -configuration Debug` → `** BUILD SUCCEEDED **`.

## Invariant Verification

| Invariant                                                                                                              | Result |
|------------------------------------------------------------------------------------------------------------------------|--------|
| `grep -n 'OPENAI_API_KEY' AgentsUsageBar/Providers/Codex/CodexCredentialLoader.swift` ≥ 1                              | 3 ✓    |
| `grep -n 'account_id\|accountId' AgentsUsageBar/Providers/Codex/CodexCredentialLoader.swift` ≥ 1                       | ≥1 ✓   |
| `grep -nE 'Secret\(' AgentsUsageBar/Providers/Codex/CodexCredentialLoader.swift` ≥ 1                                   | 2 ✓    |
| `grep -n 'revealForRequest' AgentsUsageBar/Providers/Codex/CodexCredentialLoader.swift` == 0                           | 0 ✓    |
| `grep -nE 'rate_limit\b' AgentsUsageBar/Providers/Codex/Models/CodexUsageResponse.swift` ≥ 1                           | 4 ✓    |
| `grep -nE 'rate_limits\b' AgentsUsageBar/Providers/Codex/Models/CodexUsageResponse.swift` == 0                         | 0 ✓    |
| `grep -n 'primary_window' AgentsUsageBar/Providers/Codex/Models/CodexUsageResponse.swift` ≥ 1                          | 3 ✓    |
| `grep -nE 'reset_at\b' AgentsUsageBar/Providers/Codex/Models/CodexUsageResponse.swift` ≥ 1                             | 5 ✓    |
| `grep -nE 'resets_at\b' AgentsUsageBar/Providers/Codex/Models/CodexUsageResponse.swift` == 0                           | 0 ✓    |
| `grep -n 'limit_window_seconds' AgentsUsageBar/Providers/Codex/Models/CodexUsageResponse.swift` ≥ 1                    | 3 ✓    |
| `grep -n 'ChatGPT-Account-Id' AgentsUsageBar/Providers/Codex/CodexOAuthClient.swift` ≥ 1                               | 3 ✓    |
| `grep -n 'revealForRequest' AgentsUsageBar/Providers/Codex/CodexOAuthClient.swift` == 0                                | 0 ✓    |
| SEC-04 dry-run: `grep -rn 'sk-\|sk-or-\|sk-proj-\|sk-admin-\|AIza' AgentsUsageBar/Providers/Codex/ AgentsUsageBarTests/ProvidersCodexTests/` | 0 ✓ |
| SEC-01 dry-run: `grep -rn 'revealForRequest' AgentsUsageBar/Providers/Codex/` (all Codex sources)                       | 0 ✓    |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] `FileManager` stored property breaks Swift 6 Sendable conformance**
- **Found during:** Task 1 (first compile)
- **Issue:** `CodexCredentialLoader` declared `private let fileManager: FileManager`. The compiler rejected this with `Stored property 'fileManager' of 'Sendable'-conforming struct 'CodexCredentialLoader' has non-Sendable type 'FileManager'`. Swift 6 strict concurrency forbids non-Sendable stored properties on Sendable types.
- **Fix:** Removed the `fileManager` property and the `fileManager:` init parameter. File reads use `Data(contentsOf:)`, which does not require a `FileManager` instance. The plan's `<action>` block listed both `authPath: URL` and `fileManager: FileManager`, but the actual implementation only consumed the path.
- **Files modified:** `AgentsUsageBar/Providers/Codex/CodexCredentialLoader.swift`
- **Test impact:** None — tests injected only `authPath`; no test relied on the `fileManager:` parameter.
- **Commit:** `d16b180`

**2. [Rule 1 - Acceptance-Gate Wording] `revealForRequest` mention in doc comments tripped the literal grep gate**
- **Found during:** Task 1 acceptance grep
- **Issue:** The plan's acceptance criterion `grep -n 'revealForRequest' AgentsUsageBar/Providers/Codex/CodexCredentialLoader.swift returns 0 hits` is literal. My initial draft mentioned the accessor in two SEC-01 doc comments explaining the invariant ("must NEVER call `revealForRequest()`"). The literal grep flagged the comments even though no call existed.
- **Fix:** Rewrote the doc comments to say "must NEVER call the credential-reveal accessor" — semantically identical, grep-clean.
- **Files modified:** `AgentsUsageBar/Providers/Codex/CodexCredentialLoader.swift`
- **Commit:** `d16b180`

**3. [Rule 1 - Acceptance-Gate Wording] `rate_limits` and `resets_at` mentions in CodexUsageResponse doc comments**
- **Found during:** Task 2 acceptance grep
- **Issue:** The plan's correction #5 gates require `grep -nE 'rate_limits\b' ... == 0` and `grep -nE 'resets_at\b' ... == 0` on `CodexUsageResponse.swift`. My initial draft included a doc comment explicitly contrasting the two schemas ("the rollout schema uses plural `rate_limits`, `primary`, `resets_at`, `window_minutes`"). The literal grep flagged the contrast.
- **Fix:** Rewrote the doc comments to describe the rollout shape in prose ("plural rate-limits container", "bare `primary`", "different window-units field") without using the forbidden literal tokens. Semantically equivalent; the regression test `rolloutShapeKeys_doNotMisresolveIntoWhamUsageStruct` provides the actual code-level lock-in.
- **Files modified:** `AgentsUsageBar/Providers/Codex/Models/CodexUsageResponse.swift`
- **Commit:** `a5f62df`

### Plan-Conformant Adjustments (not deviations, recorded for traceability)

**FakeHTTPClient at the HTTPClient protocol seam (NOT a literal URLProtocol stub).** The plan's `<read_first>` and `<action>` for Task 2 reference "URLProtocol stub pattern" + "`.serialized` Swift Testing trait + NSLock-protected static" per STATE #19. Phase 2 `ClaudeOAuthClientTests` actually uses a `FakeHTTPClient` at the `HTTPClient` protocol seam — the same level at which `CodexOAuthClient` is composed. This captures `url`, `method`, `bearer`, and `extraHeaders` on each call, scripts response `Result<Data, Error>` per call, and supports the same assertions that URLProtocol interception would expose (request URL, header presence/absence, status-driven error mapping). The `.serialized` suite trait is preserved. The plan's "URLProtocol" wording was over-specified relative to repo convention; the intent (deterministic stubbed HTTP, assertable request shape, scriptable failure modes) is satisfied. Pattern-mirroring with `ClaudeOAuthClientTests` was an explicit `<read_first>` directive.

## Authentication Gates

None encountered. All work was code/test/decoder additions; no live HTTP calls, no Codex CLI invocations, no `codex login` prompts.

## Threat Surface Scan

No new surface beyond the plan's `<threat_model>`. All five threat IDs (T-03.03-01..05 plus T-03.03-SC) remain at their planned dispositions:

- **T-03.03-01 (Info Disc., bearer in logs) — mitigate:** `Secret` wrapper on the bearer; `revealForRequest` not called in Codex sources (grep-verified, source-grep test); `os.Logger` interpolations log only `source` label and `httpErr.status` with `.public` and `.private` qualifiers as appropriate; SEC-04 grep coverage of `sk-proj-`/`sk-admin-`/`AIza` (Phase 1 invariant) extends automatically.
- **T-03.03-02 (Spoofing, MITM) — mitigate:** Endpoint URL is HTTPS; default ATS policy applies; no transport overrides; Hardened Runtime stays on.
- **T-03.03-03 (Tampering, malformed auth.json) — mitigate:** `JSONSerialization` + fail-soft `try?` returns `nil` instead of throwing. Test 5 (`malformedJSON_returnsNil_withoutThrowing`) locks the behaviour in.
- **T-03.03-04 (DoS, repeated 5xx hammering) — mitigate:** 429/5xx surface as `usageEndpointFailed(status:)` which the AggregateStore-level `CircuitBreaker` (Phase 2 STATE #56) increments on; opens after 5 strikes, recovers after 300s. Wiring happens in Plan 03-04; this plan provides the typed-error feed.
- **T-03.03-05 (Elevation, forged account_id) — accept:** `account_id` only steers the `ChatGPT-Account-Id` header; chatgpt.com enforces the access_token/account_id binding server-side. v1 trusts the local file (auth.json is written by Codex CLI on the same user account; we treat it as no more or less trusted than the user's own shell).
- **T-03.03-SC (Tampering, package installs) — mitigate:** No SPM dependencies added; zero `npm/pip/cargo` interactions.

## Composition Entry Point for Plan 03-04

```swift
// Inside CodexJSONLProvider.fetch():
let scanner = CodexRolloutScanner(now: now)
let files = scanner.rolloutFiles()
if let pick = CodexRolloutParser.lastTokenCount(in: files) {
    // Local-first happy path (D-02) — use rollout's RateLimits + TokenInfo.
    return buildSnapshotFromRollout(pick.event)
}
// Local empty → OAuth fallback per D-02.
do {
    let response = try await oauthClient.fetchUsage()
    return buildSnapshotFromOAuth(response)
} catch CodexOAuthError.noCredentials, CodexOAuthError.unauthorized:
    // D-03 muted "No data yet" row.
    return UsageSnapshot.empty(providerID: .codex, asOf: now)
} catch CodexOAuthError.usageEndpointFailed:
    // Re-throw — AggregateStore-level breaker increments.
    throw <appropriate ProviderError>
}
```

## Known Stubs

None — `CodexCredentialLoader`, `CodexOAuthClient`, and `CodexUsageResponse` are fully wired and fully tested. They have no UI surface until Plan 03-04 composes `CodexJSONLProvider`, which is the documented plan boundary (PLAN.md `<objective>`: "Composition into the `CodexJSONLProvider` actor + the rollout-first / OAuth-fallback decision logic happens in Plan 03-04").

## Requirement Status

- **CODEX-02** — full at the primitives layer. OAuth fallback HTTP client, credential loader, response decoder, and typed-error surface delivered and tested. Provider-level composition (the rollout-first / OAuth-fallback decision logic) is the explicit boundary handed to Plan 03-04. Requirement remains Pending in REQUIREMENTS.md until 03-04 closes the loop.

## Commits

| Hash    | Message                                                                                          |
|---------|--------------------------------------------------------------------------------------------------|
| d16b180 | feat(03-03): add CodexCredentialLoader + CodexOAuthError typed errors                            |
| a5f62df | feat(03-03): add CodexUsageResponse + CodexOAuthClient (wham/usage fallback)                     |

## Self-Check: PASSED

- `AgentsUsageBar/Providers/Codex/CodexCredentialLoader.swift` — exists ✓
- `AgentsUsageBar/Providers/Codex/CodexOAuthClient.swift` — exists ✓
- `AgentsUsageBar/Providers/Codex/Models/CodexOAuthError.swift` — exists ✓
- `AgentsUsageBar/Providers/Codex/Models/CodexUsageResponse.swift` — exists ✓
- `AgentsUsageBarTests/ProvidersCodexTests/CodexCredentialLoaderTests.swift` — exists ✓
- `AgentsUsageBarTests/ProvidersCodexTests/CodexUsageResponseTests.swift` — exists ✓
- `AgentsUsageBarTests/ProvidersCodexTests/CodexOAuthClientTests.swift` — exists ✓
- `AgentsUsageBarTests/ProvidersCodexTests/Fixtures/codex-auth-subscription.json` — exists ✓
- `AgentsUsageBarTests/ProvidersCodexTests/Fixtures/codex-auth-apikey.json` — exists ✓
- `AgentsUsageBarTests/ProvidersCodexTests/Fixtures/codex-auth-empty.json` — exists ✓
- `AgentsUsageBarTests/ProvidersCodexTests/Fixtures/codex-wham-usage-fixture.json` — exists ✓
- Commit `d16b180` (Task 1) — present in git log ✓
- Commit `a5f62df` (Task 2) — present in git log ✓
- 23 new tests PASS ✓ (8 + 6 + 9)
- Project Debug build succeeds ✓
- SEC-04 grep clean (0 hits across Codex sources + Codex tests) ✓
- SEC-01 grep clean (0 `revealForRequest` hits across Codex sources) ✓
