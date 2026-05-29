---
phase: 03-remote-api-providers-codex-gemini
plan: 05
subsystem: gemini-oauth
tags: [gemini, oauth, settings-gate, credential-loader, form-urlencoded, http-client-extension, eager-pre-check, lazy-401, in-memory-cache, no-write-back]
dependency_graph:
  requires: [02-03, 03-01]
  provides:
    - gemini-settings-gate
    - gemini-oauth-credentials
    - gemini-credential-loader
    - gemini-oauth-error
    - gemini-token-refresh-response
    - gemini-oauth-client
    - http-client-form-urlencoded
  affects:
    - Providers/Gemini (settings gate + credential loader + OAuth client land alongside the future GeminiOAuthProvider)
    - Providers/Gemini/Models (GeminiOAuthCredentials + GeminiOAuthError + GeminiTokenRefreshResponse alongside future quota/tier types)
    - Infrastructure/HTTPClient (new postFormURLEncoded protocol requirement)
    - Infrastructure/URLSessionHTTPClient (postFormURLEncoded implementation + dropped convertFromSnakeCase strategy)
    - AgentsUsageBarTests fakes (FakeHTTPClient in Claude tests + FakeCodexHTTPClient gain postFormURLEncoded stubs)
    - .github/workflows/ci.yml (SEC-04 exclusion for GeminiOAuthClient.swift)
tech_stack:
  added:
    - GeminiSettingsGate (enum; reads ~/.gemini/settings.json at nested security.auth.selectedType)
    - GeminiOAuthCredentials (struct; epoch-ms expiry_date as Double)
    - GeminiCredentialLoader (struct; file-only resolution, returns nil on missing/malformed)
    - GeminiOAuthError (typed enum; noCredentials/settingsGateClosed/refreshFailed/notSignedIn/transport)
    - GeminiTokenRefreshResponse (lenient Codable; intentionally NO refresh_token CodingKey)
    - GeminiOAuthClient (actor; D-09 eager-pre-check + lazy-401 + D-10 in-memory only)
    - HTTPClient.postFormURLEncoded (protocol requirement; URLSession-backed)
  patterns:
    - Nested JSON keypath navigation via JSONSerialization + Dictionary<String, Any> casts (mirrors ClaudeCredentialLoader.decodeOAuthBlob)
    - expiry_date epoch-ms divide-by-1000 to TimeInterval (distinct from Codex resets_at epoch-seconds)
    - Refresh response struct OMITS rotating token field as a static Pitfall-10 guard
    - File-byte-compare invariant test for D-10 (SHA-equivalent before/after a successful refresh)
    - Source-grep static guards in test target — file `String(contentsOf:)` + `#filePath`-anchored repo root walk
    - JSONDecoder with explicit snake_case CodingKeys decoded WITHOUT keyDecodingStrategy (Codex precedent — strategy clobbers explicit keys)
key_files:
  created:
    - AgentsUsageBar/Providers/Gemini/GeminiSettingsGate.swift
    - AgentsUsageBar/Providers/Gemini/GeminiCredentialLoader.swift
    - AgentsUsageBar/Providers/Gemini/GeminiOAuthClient.swift
    - AgentsUsageBar/Providers/Gemini/Models/GeminiOAuthCredentials.swift
    - AgentsUsageBar/Providers/Gemini/Models/GeminiOAuthError.swift
    - AgentsUsageBar/Providers/Gemini/Models/GeminiTokenRefreshResponse.swift
    - AgentsUsageBarTests/ProvidersGeminiTests/GeminiSettingsGateTests.swift
    - AgentsUsageBarTests/ProvidersGeminiTests/GeminiCredentialLoaderTests.swift
    - AgentsUsageBarTests/ProvidersGeminiTests/GeminiOAuthClientTests.swift
    - AgentsUsageBarTests/ProvidersGeminiTests/Fixtures/gemini-settings-fixture.json
    - AgentsUsageBarTests/ProvidersGeminiTests/Fixtures/gemini-settings-other-auth.json
    - AgentsUsageBarTests/ProvidersGeminiTests/Fixtures/gemini-oauth-creds-fixture.json
    - AgentsUsageBarTests/ProvidersGeminiTests/Fixtures/gemini-token-refresh-fixture.json
  modified:
    - AgentsUsageBar/Infrastructure/HTTPClient.swift (added postFormURLEncoded protocol requirement)
    - AgentsUsageBar/Infrastructure/URLSessionHTTPClient.swift (implemented postFormURLEncoded; dropped keyDecodingStrategy)
    - AgentsUsageBarTests/ProvidersClaudeTests/ClaudeOAuthClientTests.swift (FakeHTTPClient conformance stub)
    - AgentsUsageBarTests/ProvidersCodexTests/CodexOAuthClientTests.swift (FakeCodexHTTPClient conformance stub)
    - .github/workflows/ci.yml (--exclude='GeminiOAuthClient.swift' for SEC-04 grep)
    - AgentsUsageBar.xcodeproj/project.pbxproj (Gemini source subgroup + Models subgroup + ProvidersGeminiTests + Fixtures + build phases across both targets)
decisions:
  - "RESEARCH correction #2 locked: settings keypath is NESTED at security.auth.selectedType. NO flat-keypath fallback. Test case 8 (flatKeypath_regressionGuard_returnsFalse) fails the moment a silent fallback sneaks in."
  - "RESEARCH correction #3 locked: expiry_date is epoch MILLISECONDS as a Double. expiryDateAsDate() divides by 1000.0. Test case 2 asserts within 0.001s of the expected TimeInterval."
  - "GeminiCredentialLoader has NO Keychain branch (Pitfall 9; gemini-cli HybridTokenStorage needs the keychain-access-groups entitlement which v1 does not ship). Missing oauth_creds.json → loader returns nil → downstream renders the muted 'No data yet' row (D-03 convention)."
  - "D-09 implemented as a two-step eager pre-check: (1) actor-cached access_token if expiry > now+60s, (2) on-disk access_token if same predicate holds. Refresh is the third step and only happens when both pre-checks miss."
  - "D-10 enforced statically (no Data.write / try data.write(to:) calls in GeminiOAuthClient.swift — verified by grep) AND dynamically (Test 9 byte-compares the creds file before and after a successful refresh)."
  - "Pitfall 10 enforced statically: GeminiTokenRefreshResponse INTENTIONALLY omits a refresh_token / refreshToken field. Test 10 source-scans the struct after comment-stripping to prove the absence."
  - "GeminiOAuthClient.tokenURL / clientID / clientSecret are public constants per RFC 6749 §2.1 (installed-app flows). Re-verify if Gemini auth breaks wholesale (Google has rotated these credentials rarely)."
  - "HTTPClient protocol widened with postFormURLEncoded — the only ergonomic seam for application/x-www-form-urlencoded grants. The two existing FakeHTTPClient test doubles (Claude + Codex) gain stub conformances. New 4th conformer (FakeGeminiHTTPClient) captures the form body for the refresh-shape test."
  - "URLSessionHTTPClient.postFormURLEncoded uses plain JSONDecoder() (not keyDecodingStrategy=.convertFromSnakeCase) because GeminiTokenRefreshResponse declares explicit snake_case CodingKeys — Apple's strategy pre-rewrites JSON keys to camelCase before lookup, missing the explicit mapping. Rule-1 production bug-fix surfaced during test runs. Matches the Codex test fake decoder convention."
  - "ci.yml SEC-04 gains --exclude='GeminiOAuthClient.swift'. Current SEC-04 patterns (sk-proj-|sk-admin-|sk-or-|AIzaSy|sk-[A-Za-z0-9]{20,}) do not match GOCSPX- yet, but the exclusion is forward-compatible — Phase 1 STATE #39 self-reference precedent."
  - "Tests load fixtures via #filePath (mirrors Codex/Claude convention) — fixtures are NOT in any PBXResourcesBuildPhase, no bundle dependency."
metrics:
  duration: "~75 minutes"
  completed: "2026-05-15"
  tasks: 3
  files_modified: 17
requirements:
  - GEMINI-01 (full at the primitives layer — settings gate + credential loader + token refresh state machine delivered. Provider-level composition into GeminiOAuthProvider lands in Plan 03-06)
---

# Phase 03 Plan 05: Gemini OAuth + Credential Layer Summary

Delivers the load-bearing Gemini credential infrastructure required by GEMINI-01: a nested-keypath settings gate (RESEARCH correction #2), a `~/.gemini/oauth_creds.json` loader with epoch-millisecond arithmetic (RESEARCH correction #3), a typed-error surface, a lenient token-refresh response decoder, and an actor implementing the D-09 eager-pre-check + lazy-401 state machine — with D-10 in-memory-only guarantees enforced both statically (no `Data.write` calls in the client source) and dynamically (file byte-compare before/after a successful refresh). Three atomic commits, 30 new Swift Testing cases across three new suites, clean Debug build, full regression sweep passes (423 tests across 53 suites). Plan 03-06 will compose these into `GeminiOAuthProvider`.

## What Was Built

### Production Files

**`AgentsUsageBar/Providers/Gemini/GeminiSettingsGate.swift`** — namespace enum
- `public static func isOAuthPersonal(settingsPath:fileManager:) -> Bool` — returns true ONLY when the file exists AND parses as a JSON object AND the **nested** keypath `security.auth.selectedType` equals exactly the case-sensitive string `"oauth-personal"`.
- RESEARCH correction #2: navigates `json["security"]["auth"]["selectedType"]` — NO fallback to the flat-keypath shape. The regression-guard test (case 8) ensures this invariant survives all future edits.
- Never throws. `false` is the unambiguous "Gemini gated off" signal — Plan 03-06's composition root reads this and skips registering the provider entirely.

**`AgentsUsageBar/Providers/Gemini/Models/GeminiOAuthCredentials.swift`** — Decodable shape of `~/.gemini/oauth_creds.json`
- `accessToken: String?` (optional — gemini-cli may clear after a failed refresh), `refreshToken: String` (NON-optional — file unusable without it), `scope`, `idToken`, `expiryDate: Double` (epoch MILLISECONDS — RESEARCH correction #3), `tokenType`.
- Explicit snake_case `CodingKeys` on every property — never relies on `JSONDecoder.keyDecodingStrategy`.
- `func expiryDateAsDate() -> Date` divides `expiryDate` by 1000.0 — RESEARCH correction #3 enforcement.

**`AgentsUsageBar/Providers/Gemini/GeminiCredentialLoader.swift`** — `~/.gemini/oauth_creds.json` reader
- `public struct: Sendable`, nested `Source { .file }` (single case — v1 has no Keychain branch per Pitfall 9), `Result { credentials, source }`.
- `loadCredentials() -> Result?` returns `nil` (never throws) for missing file, malformed JSON, or missing `refresh_token` (DecodingError swallowed).
- SEC-02 logger interpolations carry only the resolution category — never `access_token`, `refresh_token`, `expiry_date`, `scope`, or `id_token`.

**`AgentsUsageBar/Providers/Gemini/Models/GeminiOAuthError.swift`** — typed-error enum
- `.noCredentials` — synonym for `.notSignedIn` in v1; both yield the muted "No data yet" row (D-03 convention).
- `.settingsGateClosed` — settings.json does not say `oauth-personal`. Reserved for completeness — Plan 03-06's composition root catches this before the client is called.
- `.refreshFailed(status:)` — non-2xx from `oauth2.googleapis.com/token`. Feeds AggregateStore-level CircuitBreaker (POLL-05).
- `.notSignedIn` — `oauth_creds.json` absent while `settings.json` says `oauth-personal` (Pitfall 9 — keychain migration).
- `.transport(underlying:)` — network / DecodingError / non-`HTTPError` failure.
- Custom `Equatable` conformance — `.transport` compares as equal across underlying errors for assertion convenience.

**`AgentsUsageBar/Providers/Gemini/Models/GeminiTokenRefreshResponse.swift`** — lenient Codable for `oauth2/token` response
- `accessToken: String`, `expiresIn: Int`, `tokenType: String?`, `scope: String?`, `idToken: String?`.
- **INTENTIONALLY omits a `refresh_token` / `refreshToken` field** — Pitfall 10 static guard. Google does NOT rotate the refresh_token on installed-app refresh grants; adding the field would invite accidental in-memory overwrites. Test 10 source-scans the file after comment-stripping to lock the invariant.

**`AgentsUsageBar/Providers/Gemini/GeminiOAuthClient.swift`** — `public actor` implementing D-09 + D-10
- `tokenURL = https://oauth2.googleapis.com/token`, `clientID` + `clientSecret` from gemini-cli oauth2.ts (RFC 6749 §2.1 public for installed-app flows).
- `refreshSkewSeconds = 60` — published constant for testing + future tuning.
- `freshAccessToken(now:) async throws -> Secret`:
  1. Eager check against actor-cached `cachedAccessToken` + `cachedExpiryDate` (returns immediately if `expiry > now + 60s`).
  2. Otherwise resolve credentials. Missing file → `GeminiOAuthError.notSignedIn` (Pitfall 9).
  3. Eager check against on-disk `accessToken` + `expiryDateAsDate()` (seeds cache + returns if predicate holds).
  4. Otherwise refresh — POST form-urlencoded `client_id` + `client_secret` + `refresh_token` + `grant_type=refresh_token` to `tokenURL`; cache the new access_token + computed expiry in actor state ONLY.
- `retryAfter401(now:) async throws -> Secret` — invalidates the cache and forces a refresh. One-shot per high-level request (Plan 03-06's `GeminiOAuthProvider` enforces).
- D-10 invariant: NO `Data.write`, `try data.write(to:)`, or `FileManager.write` calls in this file. The refreshed access_token lives ONLY in `cachedAccessToken` (actor-isolated). Test 9 dynamic-asserts via byte-compare of the on-disk fixture file before and after a successful refresh.
- SEC-01 invariant: the client does NOT call the credential-reveal accessor. `Secret` wrapping happens at `URLRequest` Authorization-header construction inside `URLSessionHTTPClient.performGet` (Phase 1 STATE #15).
- SEC-02 invariant: logger interpolations carry only `oauth2/token` + HTTP status — never the refresh_token or response access_token.

**`AgentsUsageBar/Infrastructure/HTTPClient.swift`** (modified) — protocol widened with `postFormURLEncoded(_:formFields:extraHeaders:as:) async throws -> T` for `application/x-www-form-urlencoded` grants. Documented as unauthenticated at the transport layer (body itself carries the credential).

**`AgentsUsageBar/Infrastructure/URLSessionHTTPClient.swift`** (modified) — implements `postFormURLEncoded` through the shared `URLSession` singleton (POLL-08). Percent-encodes each form value with `.urlQueryAllowed`, sets `Content-Type: application/x-www-form-urlencoded`, logs only path + status (SEC-02). Drops `keyDecodingStrategy = .convertFromSnakeCase` for this method only — `GeminiTokenRefreshResponse` declares explicit snake_case CodingKeys.

### Test Files

**`AgentsUsageBarTests/ProvidersGeminiTests/GeminiSettingsGateTests.swift`** — 10 tests
1. oauth-personal fixture → true
2. api-key fixture → false
3. Missing file → false (no throw)
4. Malformed JSON → false
5. Missing `security` key → false
6. Missing `auth` key (within security) → false
7. `selectedType` non-string (integer) → false
8. **REGRESSION GUARD** — flat keypath `{ "selectedAuthType": "oauth-personal" }` → false (RESEARCH correction #2 lock-in)
9. Wrong case "OAuth-Personal" → false (case-sensitive)
10. `selectedType == "vertex-ai"` → false

**`AgentsUsageBarTests/ProvidersGeminiTests/GeminiCredentialLoaderTests.swift`** — 8 tests
1. Happy fixture decodes cleanly; expiryDate within 1.0 of 1778834115287.89
2. `expiryDateAsDate()` produces TimeInterval within 0.001 of 1778834115.28789 (RESEARCH correction #3)
3. `access_token: null` → optional decodes to nil; refreshToken still populated
4. `expiry_date` as plain integer → decodes as Double; expiryDateAsDate() correct
5. Missing file → nil (no throw; Pitfall 9)
6. Malformed JSON → nil
7. Missing `refresh_token` → nil (DecodingError swallowed)
8. SEC-02 logger interpolation source-scan — credentials never appear in logger calls

**`AgentsUsageBarTests/ProvidersGeminiTests/GeminiOAuthClientTests.swift`** — 12 tests
1. Eager cache hit (post first call) does not hit HTTP
2. Eager from-file hit does not refresh
3. Expiry-imminent (30s in future, less than 60s skew) refreshes; subsequent call within skew window reuses cache
4. Refresh body is form-urlencoded with correct fields (client_id, client_secret, grant_type, percent-encoded refresh_token)
5. HTTP 400 → `GeminiOAuthError.refreshFailed(status: 400)`
6. HTTP 401 → `GeminiOAuthError.refreshFailed(status: 401)`
7. Missing oauth_creds.json → `GeminiOAuthError.notSignedIn` (Pitfall 9)
8. `retryAfter401` invalidates cache and forces refresh on next call
9. **D-10 invariant** — creds file byte-identical before and after a successful refresh
10. **Pitfall 10 static guard** — refresh response struct has no `refresh_token` / `refreshToken` field
11. Fixture SEC-04 sweep — no real Google token shapes (`GOCSPX-4uHg` / `"ya29.`) in any fixture
12. ci.yml SEC-04 exclusion presence check — `GeminiOAuthClient.swift` listed in the exclude list

### Test Fixtures (loaded via `#filePath`, not bundle)

- `Fixtures/gemini-settings-fixture.json` — `{ "security": { "auth": { "selectedType": "oauth-personal" } } }`
- `Fixtures/gemini-settings-other-auth.json` — same shape with `"api-key"`
- `Fixtures/gemini-oauth-creds-fixture.json` — RESEARCH §"Gemini oauth_creds.json Schema" shape with FAKE- prefixed tokens
- `Fixtures/gemini-token-refresh-fixture.json` — RESEARCH §"Gemini OAuth Refresh" response shape with FAKE- prefixed tokens

### Test Doubles (modified)

- `AgentsUsageBarTests/ProvidersClaudeTests/ClaudeOAuthClientTests.swift::FakeHTTPClient` — added `postFormURLEncoded` conformance stub.
- `AgentsUsageBarTests/ProvidersCodexTests/CodexOAuthClientTests.swift::FakeCodexHTTPClient` — added `postFormURLEncoded` conformance stub.
- `AgentsUsageBarTests/ProvidersGeminiTests/GeminiOAuthClientTests.swift::FakeGeminiHTTPClient` — new fake; the only one that actually scripts `postFormURLEncoded` responses and captures the wire body for shape assertions.

## Test Suite Results

30 new tests across 3 new suites; full regression sweep (423 tests in 53 suites) green.

| Suite                            | Tests | Result |
|----------------------------------|-------|--------|
| GeminiSettingsGateTests          | 10    | PASS   |
| GeminiCredentialLoaderTests      | 8     | PASS   |
| GeminiOAuthClientTests           | 12    | PASS   |
| **Total (this plan)**            | **30**| **PASS** |
| **Full regression**              | **423** in 53 suites | **PASS** |

Full project Debug build: `xcodebuild build -project AgentsUsageBar.xcodeproj -scheme AgentsUsageBar -configuration Debug` → `** BUILD SUCCEEDED **`.

## Invariant Verification

| Invariant                                                                                                                | Result |
|--------------------------------------------------------------------------------------------------------------------------|--------|
| `grep -cE 'security.*auth.*selectedType' AgentsUsageBar/Providers/Gemini/GeminiSettingsGate.swift` ≥ 1                   | 4 ✓    |
| `grep -cE 'selectedAuthType' AgentsUsageBar/Providers/Gemini/GeminiSettingsGate.swift` == 0                              | 0 ✓    |
| `grep -cE 'expiry_date' AgentsUsageBar/Providers/Gemini/Models/GeminiOAuthCredentials.swift` ≥ 1                         | 4 ✓    |
| `grep -cE '/ 1000' AgentsUsageBar/Providers/Gemini/Models/GeminiOAuthCredentials.swift` ≥ 1                              | 3 ✓    |
| `grep -cE 'ya29\.a0A\|GOCSPX-' AgentsUsageBarTests/ProvidersGeminiTests/Fixtures/gemini-oauth-creds-fixture.json` == 0   | 0 ✓    |
| `grep -cE 'refreshSkewSeconds\|60' AgentsUsageBar/Providers/Gemini/GeminiOAuthClient.swift` ≥ 1                          | 7 ✓    |
| `grep -cE 'try data\.write\|Data.*\.write\(to:' AgentsUsageBar/Providers/Gemini/GeminiOAuthClient.swift` == 0            | 0 ✓    |
| `grep -cE 'refresh_token.*=.*nil\|refreshToken.*=.*nil' AgentsUsageBar/Providers/Gemini/GeminiOAuthClient.swift` == 0    | 0 ✓    |
| `grep -cE 'revealForRequest' AgentsUsageBar/Providers/Gemini/GeminiOAuthClient.swift` == 0                               | 0 ✓    |
| `grep -nE 'application/x-www-form-urlencoded' (URLSessionHTTPClient.swift)` ≥ 1                                          | 3 ✓    |
| SEC-04 dry-run: `grep -rnE 'sk-proj-\|sk-admin-\|sk-or-\|AIza' AgentsUsageBar/Providers/Gemini/ AgentsUsageBarTests/ProvidersGeminiTests/` excluding GeminiOAuthClient.swift | 0 ✓ |
| SEC-01 dry-run: `grep -rn 'revealForRequest' AgentsUsageBar/Providers/Gemini/`                                            | 0 ✓    |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Production Bug] `keyDecodingStrategy = .convertFromSnakeCase` clobbers explicit snake_case CodingKeys**
- **Found during:** First run of `GeminiOAuthClientTests.expiryImminent_refreshes_thenCachesSubsequentCalls()` (Task 3 GREEN step)
- **Issue:** `URLSessionHTTPClient.postFormURLEncoded` and the test fake's decoder both set `decoder.keyDecodingStrategy = .convertFromSnakeCase`. `GeminiTokenRefreshResponse` declares explicit snake_case `CodingKeys` (e.g. `case accessToken = "access_token"`). When the strategy is set, the decoder first rewrites the JSON key `"access_token"` to `"accessToken"` before matching, missing the explicit `"access_token"` mapping and throwing `DecodingError.keyNotFound`.
- **Fix:** Dropped the `keyDecodingStrategy` in `URLSessionHTTPClient.postFormURLEncoded` (matches the `CodexOAuthClientTests::FakeCodexHTTPClient` decoder convention — plain `JSONDecoder()`). The Codex provider has the same struct pattern (explicit snake_case CodingKeys) and the same decoder choice; consistency restored across providers.
- **Files modified:** `AgentsUsageBar/Infrastructure/URLSessionHTTPClient.swift`, `AgentsUsageBarTests/ProvidersGeminiTests/GeminiOAuthClientTests.swift`
- **Commit:** `eaee6c6`

**2. [Rule 1 - Acceptance-Gate Wording] `selectedAuthType` literal in doc comment tripped the regression-guard grep**
- **Found during:** Task 1 acceptance grep
- **Issue:** The plan's acceptance criterion `grep -cE 'selectedAuthType' GeminiSettingsGate.swift == 0` is literal. My initial draft mentioned the forbidden flat-keypath name in a doc comment explaining RESEARCH correction #2 ("...NOT the flat `selectedAuthType` that..."). The literal grep flagged the doc-comment string even though no code path uses it.
- **Fix:** Rewrote the doc comment to describe the flat shape semantically ("the flat single-key shape that CONTEXT.md / REQUIREMENTS.md describe") without using the forbidden literal token. The regression-guard test (case 8) provides the actual code-level lock-in.
- **Files modified:** `AgentsUsageBar/Providers/Gemini/GeminiSettingsGate.swift`
- **Commit:** `df3ec24`

**3. [Rule 1 - Acceptance-Gate Wording] `revealForRequest` literal in doc comment tripped the SEC-01 grep**
- **Found during:** Task 3 acceptance grep
- **Issue:** The plan's SEC-01 invariant `grep -nE 'revealForRequest' GeminiOAuthClient.swift == 0` is literal. My initial draft mentioned the accessor in a doc comment explaining the SEC-01 contract ("...does not pass through `Secret.revealForRequest()`"). The grep flagged the comment despite no code path calling the accessor.
- **Fix:** Rewrote the doc comment to describe the access pattern semantically ("does not pass through the `Secret` reveal accessor"). The Plan 03-03 STATE #67 precedent — same fix pattern.
- **Files modified:** `AgentsUsageBar/Providers/Gemini/GeminiOAuthClient.swift`
- **Commit:** `eaee6c6`

### Plan-Conformant Adjustments (not deviations, recorded for traceability)

**FakeHTTPClient at the HTTPClient protocol seam (NOT a literal URLProtocol stub).** The plan's Task 3 action references "URLProtocol stubs (STATE #19 pattern)". Phase 2 `ClaudeOAuthClientTests` and Phase 3 `CodexOAuthClientTests` both use a `FakeHTTPClient` at the `HTTPClient` protocol seam instead — equivalent semantic (deterministic stubbed HTTP, assertable request shape, scriptable failure modes), less boilerplate. The new `FakeGeminiHTTPClient` continues the convention. Plan 03-03 STATE #69 records the same plan-vs-repo wording resolution.

**FakeHTTPClient conformance updates in Claude + Codex test files.** The HTTPClient protocol widening with `postFormURLEncoded` cascades to every existing `HTTPClient` conformer in the test target. The two test fakes (`FakeHTTPClient` in `ClaudeOAuthClientTests.swift`, `FakeCodexHTTPClient` in `CodexOAuthClientTests.swift`) gain stub conformances — not exercised by their suites but required for compilation. Rule-3 mechanical update; documented for traceability.

## Authentication Gates

None encountered. All work was code/test/decoder additions; no live HTTP calls, no `gemini login` prompts, no Google OAuth consent flows.

## Threat Surface Scan

No new surface beyond the plan's `<threat_model>`. All seven threat IDs (T-03.05-01..06 plus T-03.05-SC) remain at their planned dispositions:

- **T-03.05-01 (Info Disc., access/refresh token leak via logs) — mitigate:** `Secret` wrapper on the bearer; the credential-reveal accessor not called in any Gemini source file (grep-verified); SEC-02 logger interpolations carry only `.public` URL paths + HTTP status codes; SEC-04 covers `AIzaSy` / Google API key prefixes.
- **T-03.05-02 (Spoofing, MITM on token refresh) — mitigate:** HTTPS to `oauth2.googleapis.com`; default ATS; Hardened Runtime stays on.
- **T-03.05-03 (Tampering, local oauth_creds.json corruption) — mitigate:** loadCredentials returns `nil` on malformed JSON (test 6); downstream renders muted "No data yet" row instead of crashing.
- **T-03.05-04 (Tampering, wrong settings keypath silent disable) — mitigate:** RESEARCH correction #2 + regression-guard test (case 8) + grep gate (zero literal-name matches in source).
- **T-03.05-05 (Elevation, hard-coded client_secret) — accept:** RFC 6749 §2.1 public for installed-app flows; verified against gemini-cli `oauth2.ts`. Documented in `GeminiOAuthClient.clientSecret` constant doc comment.
- **T-03.05-06 (DoS, refresh storm on expiry-imminent calls) — mitigate:** Eager pre-check (60s skew) means a successful refresh caches for ~3540s (3599 - 60); `retryAfter401` is single-shot per high-level request (caller-enforced in Plan 03-06).
- **T-03.05-SC (Tampering, package installs) — mitigate:** No SPM dependencies added; zero npm/pip/cargo interactions.

## Composition Entry Point for Plan 03-06 (GeminiOAuthProvider)

```swift
// Inside GeminiOAuthProvider.fetch():
guard GeminiSettingsGate.isOAuthPersonal() else {
    // Provider registered but file doesn't say oauth-personal —
    // render muted "No data yet" / "Gemini not signed in" row.
    return UsageSnapshot.empty(providerID: .gemini, asOf: now)
}
let client = GeminiOAuthClient(http: shared, ...)
do {
    let bearer = try await client.freshAccessToken(now: now)
    // Use `bearer` to call v1internal:retrieveUserQuota + loadCodeAssist.
    // On 401 from either call, fall back to:
    //   let bearer2 = try await client.retryAfter401(now: now)
    //   // retry once
    return composeSnapshot(quota: ..., tier: ...)
} catch GeminiOAuthError.notSignedIn, GeminiOAuthError.noCredentials {
    // Pitfall 9 muted row.
    return UsageSnapshot.empty(providerID: .gemini, asOf: now)
} catch GeminiOAuthError.refreshFailed(let status) {
    // AggregateStore breaker increments (POLL-05).
    throw ProviderError.upstreamFailure(status: status)
}
```

## Known Stubs

None — `GeminiSettingsGate`, `GeminiCredentialLoader`, and `GeminiOAuthClient` are fully wired and fully tested. They have no UI surface until Plan 03-06 composes `GeminiOAuthProvider`, which is the documented plan boundary (PLAN.md `<objective>`: "Composition into `GeminiOAuthProvider` + the quota/tier fetches + the degraded UX path (D-11) happens in Plan 03-06").

## Requirement Status

- **GEMINI-01** — full at the primitives layer. Settings gate, credential loader, token refresh state machine, eager-pre-check + lazy-401 retry, in-memory token cache, byte-compare D-10 guarantee, Pitfall 10 static guard all delivered and tested. Provider-level composition (the actor wiring + `v1internal:retrieveUserQuota` + `v1internal:loadCodeAssist` + degraded UX) is the explicit boundary handed to Plan 03-06. Requirement remains Pending in REQUIREMENTS.md until 03-06 closes the loop.

## Commits

| Hash    | Message                                                                                          |
|---------|--------------------------------------------------------------------------------------------------|
| df3ec24 | feat(03-05): add GeminiSettingsGate with nested security.auth.selectedType keypath               |
| eb32dc4 | feat(03-05): add GeminiOAuthCredentials + GeminiCredentialLoader (Pitfall 9 muted-row contract)  |
| eaee6c6 | feat(03-05): add GeminiOAuthClient with D-09 eager-pre-check + lazy-401 state machine            |

## Self-Check: PASSED

- `AgentsUsageBar/Providers/Gemini/GeminiSettingsGate.swift` — exists ✓
- `AgentsUsageBar/Providers/Gemini/GeminiCredentialLoader.swift` — exists ✓
- `AgentsUsageBar/Providers/Gemini/GeminiOAuthClient.swift` — exists ✓
- `AgentsUsageBar/Providers/Gemini/Models/GeminiOAuthCredentials.swift` — exists ✓
- `AgentsUsageBar/Providers/Gemini/Models/GeminiOAuthError.swift` — exists ✓
- `AgentsUsageBar/Providers/Gemini/Models/GeminiTokenRefreshResponse.swift` — exists ✓
- `AgentsUsageBarTests/ProvidersGeminiTests/GeminiSettingsGateTests.swift` — exists ✓
- `AgentsUsageBarTests/ProvidersGeminiTests/GeminiCredentialLoaderTests.swift` — exists ✓
- `AgentsUsageBarTests/ProvidersGeminiTests/GeminiOAuthClientTests.swift` — exists ✓
- `AgentsUsageBarTests/ProvidersGeminiTests/Fixtures/gemini-settings-fixture.json` — exists ✓
- `AgentsUsageBarTests/ProvidersGeminiTests/Fixtures/gemini-settings-other-auth.json` — exists ✓
- `AgentsUsageBarTests/ProvidersGeminiTests/Fixtures/gemini-oauth-creds-fixture.json` — exists ✓
- `AgentsUsageBarTests/ProvidersGeminiTests/Fixtures/gemini-token-refresh-fixture.json` — exists ✓
- Commit `df3ec24` (Task 1) — present in git log ✓
- Commit `eb32dc4` (Task 2) — present in git log ✓
- Commit `eaee6c6` (Task 3) — present in git log ✓
- 30 new tests PASS ✓ (10 + 8 + 12)
- Full regression: 423 tests across 53 suites PASS ✓
- Project Debug build succeeds ✓
- SEC-04 grep clean (0 matches across Gemini sources + tests, excluding GeminiOAuthClient.swift per ci.yml allow-list) ✓
- SEC-01 grep clean (0 `revealForRequest` matches across Gemini sources) ✓
- D-10 grep clean (0 `Data.write` / `try data.write(to:)` matches in GeminiOAuthClient.swift) ✓
- Pitfall 10 static guard (no `refresh_token` / `refreshToken` field in GeminiTokenRefreshResponse) ✓
