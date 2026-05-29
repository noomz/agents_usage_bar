---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: milestone
status: executing
last_updated: "2026-05-15T10:47:11.485Z"
progress:
  total_phases: 6
  completed_phases: 2
  total_plans: 25
  completed_plans: 21
  percent: 84
---

# Project State: Agents Usage Bar

**Last Updated:** 2026-05-15 (Phase 3 Plan 04 executed — `CodexJSONLProvider` actor composes Wave 1 Codex primitives (03-01 scanner+parser + 03-02 pricing + 03-03 OAuth fallback) into the user-visible `UsageProvider`. Two commits — 88f0521 adds optional `UsageSnapshot.tooltipLabel: String?` for D-15 plan_type / Gemini tier surface (init param defaults to `nil`, all 13 Phase 1/2 call sites source-compatible); 3ad9a5a adds `CodexJSONLProvider.swift` (~420 lines) with rollout-first / OAuth-fallback state machine, single batched `setTranscriptOffsets` per fetch (STATE #43 invariant), `max(primary, secondary) / 100` quota fraction in BOTH paths (D-05), `planType → tooltipLabel` in BOTH paths (D-15), mutedNoData neutral UX on .noCredentials / .unauthorized (D-03), `.usageEndpointFailed` rethrow for AggregateStore POLL-05 breaker (D-12 — no per-provider breaker added). 18 new `@Test` cases across 3 suites (4 `UsageSnapshotTooltipLabelTests` + 6 `CodexJSONLProviderTests` + 8 `CodexJSONLProviderFallbackTests`); test scanner factory injects explicit Gregorian calendar to bypass Buddhist Era host-locale issue (test-only — production code unaffected); full Phase 1 + Phase 2 regression suite still green. Hand-verified $0.061586 USD for the canonical 2026 fixture event. Pitfall 11 doc comments rewritten to be grep-clean (mirrors Plan 03-03 SUMMARY's `revealForRequest` precedent). CODEX-01..04 now complete at the actor layer; remaining wiring (AppDependencies registration + UI-11 tooltip surfacing) lands in Plans 03-08 and 03-07.)
**Mode:** yolo
**Granularity:** coarse

## Project Reference

**Core Value:** A single ambient glance shows accurate per-provider AI usage for today, so the user notices spend/quota issues before they bite.

**What This Is:** A macOS menu bar app that surfaces today's AI agent usage across Claude, OpenAI Codex, Gemini, OpenRouter, and local agents (Ollama, LM Studio, llama.cpp) — tokens used, USD spent, quota remaining per provider — with native notifications at threshold crossings.

**Current Focus:** Phase 03 — remote-api-providers-codex-gemini

## Current Position

Phase: 03 (remote-api-providers-codex-gemini) — EXECUTING
Plan: 5 of 9 plans executed (Plan 01 ✅; Plan 02 ✅; Plan 03 ✅; Plan 04 ✅; Plan 05 ✅)
Phase: 03 — Plans 01 + 02 + 03 + 04 + 05 ✅ COMPLETE (Codex rollout discovery + Codex USD pricing + Codex OAuth fallback + Codex provider actor + Gemini OAuth + credential layer)

- **Milestone:** v1 (initial release)
- **Phase:** 3 of 6 — Remote API Providers (Codex + Gemini) — EXECUTING
- **Plan:** 5 of 9 plans executed (Plan 01 ✅; Plan 02 ✅; Plan 03 ✅; Plan 04 ✅; Plan 05 ✅)
- **Status:** Ready to execute
- **Progress:** [████████░░] 84%

```
[█████████████████████████████████████████████████████████████████░] 84% (21/25 plans complete to date; Phase 3 in progress with 5/9 done)
```

## Performance Metrics

| Metric | Value |
|--------|-------|
| Phases complete | 2 / 6 (Phase 2 UAT approved 2026-05-15) |
| Plans complete | 21 / 25 (Phase 1: 9 + Phase 2: 7 + Phase 3 Plans 01 + 02 + 03 + 04 + 05: 5) |
| Requirements mapped | 76 / 76 (100%) |
| Requirements validated | 46 / 76 (Phase 1 + Phase 2 sets + Phase 3 CODEX-01..04 covered at the actor layer — Tests 1-2 manual PASS; Tests 3-10 covered by unit-test suites per `02-UAT.md` attestation table; CODEX-* covered by `CodexJSONLProviderTests` + `CodexJSONLProviderFallbackTests` + `UsageSnapshotTooltipLabelTests`) |
| Plans drafted | 25 (Phase 3 plans 01–09 drafted 2026-05-15) |
| Plans executed | 21 (Phase 1 = 9; Phase 2 = 7 across Waves 1–5; Phase 3 Plan 01 = 1 in e2bcd5e + 6a18026 + a31b99a; Phase 3 Plan 02 = 1 in dd160a0 + 43f97ae; Phase 3 Plan 03 = 1 in d16b180 + a5f62df; Phase 3 Plan 04 = 1 in 88f0521 + 3ad9a5a; Phase 3 Plan 05 = 1 in df3ec24 + eb32dc4 + eaee6c6) |
| Node repairs | 1 (Phase 2 Wave 1 salvage — see Phase 2 backprop) |
| UI phases run | 0 |
| UAT gaps closed | 1 (Test 2 cosmetic hover state) |
| Phase 02 P04 duration | ~90 min, 1 task, 7 files modified |
| Phase 02 P05 duration | ~60 min, 2 tasks, 13 files modified, 42 new tests |
| Phase 02 P06 duration | ~12 min, 2 tasks, 10 files modified, 29 new tests |
| Phase 02 P07 duration | ~25 min, 3 tasks (2 code + 1 docs), 11 files modified, 30 new tests |
| Phase 03 P01 duration | ~35 min, 3 tasks, 11 files created/modified, 23 new tests |
| Phase 03 P02 duration | ~10 min, 2 tasks (1 checkpoint + 1 implementation), 5 files created/modified, 9 new tests |
| Phase 03 P03 duration | ~25 min, 2 tasks, 12 files created/modified, 23 new tests |
| Phase 03 P04 duration | ~10 min, 2 tasks (autonomous), 5 files created/modified, 18 new tests |
| Phase 03 P05 duration | ~75 min, 3 tasks, 17 files created/modified, 30 new tests |

## Accumulated Context

### Key Decisions (from PROJECT.md + Plan 01.01)

1. Swift + SwiftUI native; no Electron/Tauri/web wrappers.
2. macOS 14+ minimum; `MenuBarExtra(.window)` + `@Observable @MainActor` store.
3. Popover panel UI (not plain `NSMenu`) for rich per-provider rows.
4. Today-only aggregation (local midnight, never UTC); no multi-day persistence in v1.
5. Read keys/OAuth from env + existing CLI config files — no Keychain UI in v1.
6. Claude source = `~/.claude/projects/**/*.jsonl` + OAuth API (`rtk gain` is NOT a Claude data source).
7. Codex source = `~/.codex/sessions/**/rollout-*.jsonl` last `token_count` (no auth); OAuth API fallback.
8. Default refresh interval = 5 min (range 1m–30m); 30s would drain battery and trip App Nap.
9. Ship unsandboxed + Hardened Runtime + notarized DMG; App Store out of scope in v1.
10. Local LLMs = presence + model name only; cumulative tokens = anti-feature.
11. Sparkle auto-update via EdDSA-signed appcast on GitHub Pages.
12. Hand-authored `project.pbxproj` (not XcodeGen/Tuist) — CodexBar precedent, zero tooling deps.
13. `objectVersion=77` for Xcode 26.2 toolchain compatibility (SWIFT_VERSION=6.0 language mode 6).
14. `@State private var dependencies = AppDependencies.makeProduction()` — canonical composition root form (RESEARCH.md).
15. `Secret` is NOT Codable — credentials never auto-serialised; only `revealForRequest()` exposes plaintext, exclusively at `URLRequest` Authorization header construction (SEC-01).
16. `TodayHelper` uses `Calendar = .current` default params — never `Calendar(identifier:)` — so local-midnight math is DST-correct (Pitfall 4).
17. `FileCacheStore` uses `DispatchQueue(concurrent)+barrier` for thread-safe atomic JSON write under `@unchecked Sendable`.
18. `URLSessionHTTPClient` singleton: `timeoutIntervalForRequest=8`, `waitsForConnectivity=false`, `httpMaximumConnectionsPerHost=6` (POLL-08, CLAUDE.md).
19. Swift Testing suites requiring shared `URLProtocol` stubs must use `.serialized` trait + `NSLock`-protected static to survive parallel test execution.
20. `TomlReader` is a namespace enum with a single static `parse(_:logger:)` — D-16 subset (scalars + sections + comments only); fail-soft per D-18 (log+skip, never throw).
21. `ConfigStore` uses instance-method `load() -> AppConfig` (NOT static) — DI via `EnvReader` protocol seam injected at init; `ProcessInfoEnvReader` is the sole production env source (CFG-06).
22. Empty env string (`OPENROUTER_API_KEY=""`) treated as absent — prevents empty bearer header reaching OpenRouter API.
23. TOML fixture files use fake key `sk-or-FAKE_FIXTURE_KEY_XXXXXXXXXXXXXXXX`; Plan 01.08 CI grep must scope `--include` to `*.swift *.plist` (not `*.toml`) to avoid false-positive secret leak detection.
24. `UsageProvider` protocol uses `Actor` constraint — all providers must be actors for state isolation and concurrent `withTaskGroup` fetches in `AggregateStore`.
25. `OpenRouterProvider.fetch` uses `async let credits / async let key` — both endpoints fire concurrently; either error cancels the pair (structured concurrency).
26. `k.data.limit.map { }` functional nil-handling — nil limit yields nil Quota (D-14/ROUTER-03); no threshold alert fires for unlimited accounts.
27. `FakeCacheStore` is the test double name per B9 namespace gate — `InMemoryCacheStore` must NOT exist anywhere in the source tree.
28. `Decimal(Double)` used for monetary fields; IEEE 754 imprecision means test assertions for computed deltas must use `NSDecimalNumber.doubleValue + tolerance` comparison.
29. `ClockKey: EnvironmentKey` declared exactly once in `UI/Environment/ClockEnvironmentKey.swift` (B5) — FooterView consumes, Plan 01.08 injects, neither redeclares.
30. `QuotaBar.color(forFraction:)` is `internal static` — exposes pure color logic as test seam without snapshot framework (B4); body delegates to this function, never inlines the switch.
31. `RelativeTimestampLabel.relativeString(from:to:)` uses days (not absolute date strings) for elapsed >24h in Phase 1 — compact label, avoids locale/timezone complexity; revisit Phase 2.
32. `TimelineView(.periodic(from: .now, by: 1))` drives `RelativeTimestampLabel` to tick every 1s while popover is open (Phase Success Criterion #3).
33. Source-grep `@Test` functions (W7/FooterViewTests) verify SwiftUI contract via `String(contentsOf:)` + `#filePath`-based repo-root walk — avoids snapshot framework dependency for structural contract tests.
34. `ThresholdEngine` uses `NumberFormatter(.currency, USD)` not `Decimal.formatted(.currency(code:))` — `Quota.used/limit` are `Double`, not `Decimal`; NumberFormatter produces identical `$8.20` output without lossy conversion.
35. `ThresholdBand` and `ThresholdState` co-located in `ThresholdState.swift` — both enums share identical breakpoints (0.80/0.95/1.00); a separate file would duplicate semantics with no boundary benefit.
36. `UNNotificationManager` is an `actor` (not class/struct) — `authState` mutation requires actor isolation for Swift 6 strict concurrency; actor boundary provides automatic serialization without manual locks.
37. `FakeUNUserNotificationCenter` is `@unchecked Sendable` without explicit locks — safe because Swift Testing runs each `@Test async func` in its own structured concurrency scope; no concurrent mutation occurs within a single test.
38. `AppDependencies.makeProduction()` returns a `Dependencies` bag (store + scheduler + clock) — B1 enforced (no URLSessionConfiguration inline), B6 enforced (ConfigStore instance-method), B9 enforced (NoopCacheStore fallback, no InMemoryCacheStore), B10 enforced (seedPlaceholder called, no cross-plan mutation).
39. SEC-04 CI grep uses `--exclude='ci.yml'` self-reference guard — the workflow file contains the pattern definition and would otherwise match itself; test fixture fake keys changed from `sk-or-FAKE_FIXTURE_KEY_XXXXXXXXXXXXXXXX` to `fake-or-XXXX` to avoid false positives.
40. `AppEnvironment.swift` is a comment-only placeholder for Phase 5+ app-level env keys; ClockKey sole declaration remains in `UI/Environment/ClockEnvironmentKey.swift` (B5).
41. OAuth degrade-to-local-only: any error from `ClaudeOAuthClient.getUsage()` yields `quotaWindows=nil` and `quota=nil` without rethrowing; local JSONL data still rendered (CLAUDE-04 / RESEARCH Pitfall 5).
42. Primary Claude quota = `max(fiveHour.utilization, sevenDay.utilization)` per RESEARCH Open Question 4; bonus per-model windows (7d-sonnet, 7d-opus) appear in `quotaWindows` but excluded from the main progress bar.
43. `TranscriptReader` uses synchronous `FileHandle.readToEnd()` instead of `fh.bytes.lines` AsyncSequence — avoids `CancellationError` when the enclosing Swift concurrency task is cancelled under parallel test load; synchronous I/O is safe for KB-range JSONL delta chunks.
44. `TranscriptDirectoryScanner.scanRoots` resolves symlinks via `url.resolvingSymlinksInPath()` before returning URLs — ensures cache keys are canonical across `/var` vs `/private/var` path forms on macOS (FileManager.enumerator returns `/private/var`; URL construction via temporaryDirectory returns `/var`).
45. `ThresholdBand: Comparable + Codable` — Comparable enables `newBand > oldBand` upward gate (NOTIF-02); Codable required because `NotificationStateRecord` JSON-round-trips through `UserDefaults` and synthesises `Codable` from its `lastBand: ThresholdBand` field.
46. `ThresholdEngine` exposes two parallel surfaces: Phase 1 `decisions(for:now:snoozedUntil:)` (warn80-only) wraps the Phase 2 FSM overload `decisions(for:now:snoozedUntilDay:lastBands:)` — back-compat preserved without code duplication; Phase 1 NotificationsTests pass unchanged.
47. `NotificationStateStorage` is intentionally a thin UserDefaults shim, NOT a peer of `CacheStore` (no `NoopNotificationStateStore`-style B9 abstraction) — scope is solely the per-(provider,day) FSM state, not generic cache fallbacks.
48. Snooze "today" suppresses ALL bands per provider until local-midnight rollover (default decision #2 — explicit) via `snoozedUntilDay[snap.providerID] == today` short-circuit BEFORE band-transition check; never confuse with snoozing only the current band.
49. `UNNotificationManager.registerCategories(on:)` is a static, called from `AgentsUsageBarApp.init()` BEFORE the first `schedule(_:)` invocation (Pitfall 6). The protocol seam does not expose `setNotificationCategories(_:)` so the static downcasts the concrete `UNUserNotificationCenter`.
50. `NotificationActionHandler` is held strongly by the `Dependencies` bag for app lifetime — `UNUserNotificationCenter.current().delegate` is `weak`, so without the strong reference the handler would deallocate and snooze taps would no-op silently.
51. Coalesced ID extends from Phase 1's hardcoded `:warn80` to `:warn80|crit95|exceed100` derived from `max(decisions.band)`; coalesced title percent (80/95/100) reflects the same highest band — `bandSuffix(for:)` + `bandPercent(for:)` are public statics on `ThresholdEngine` shared with `NotificationManager`.
52. Test `now`-Date pinned to noon UTC, NOT a PT/local timezone — `TodayHelper.formatYYYYMMDD(now)` uses `Calendar.current`, so a PT-noon date crosses to the next calendar day in UTC+8+ developer machines; noon UTC stays on the same calendar day across UTC-12..UTC+12 hosts.
53. `CircuitBreaker` is an `actor` with 3-state machine (`.closed` / `.open(until:)` / `.halfOpen`); default 5-strike/300s for POLL-05; Claude OAuth-usage path overrides with 3-strike/300s (Pitfall 5 / default decision #4). Methods take an explicit `now: Date` parameter — never read `Date.now` internally — so VirtualClock-driven tests are deterministic.
54. `RetryPolicy` ships **unwired** in Plan 02-06 — POLL-05 backoff between polls is achieved via the breaker's `.open(until:)` cooldown rather than per-fetch jitter sleep. Per-fetch retry-with-jitter would block one poll cycle on a single slow provider for up to a minute. RetryPolicy remains available as a primitive for Plan 02-07 UAT or future polish.
55. `PowerObserver` is `@MainActor public final class`; observer tokens (`sleepToken` / `wakeToken`) and `notificationCenter` are `nonisolated(unsafe)` so Swift 6's nonisolated `deinit` can call `removeObserver(_:)` — safe because tokens write once at init (MainActor) and read solely in deinit, and `NotificationCenter.removeObserver` is documented thread-safe.
56. `AggregateStore.perProviderBreakers: [ProviderID: CircuitBreaker]` is lazily populated via `breaker(for:)` helper. `performRefresh(now:)` pre-decides per-provider gate: terminal `.unauthenticated` providers (POLL-06) contribute NO task at all (breaker untouched); open-breaker providers (POLL-05) surface a synthesised `"circuit-open"` failure result. Success → `recordSuccess`; non-auth failures → `recordFailure(now:)`; auth/paymentRequired → breaker untouched (POLL-06 terminal).
57. `ClaudeJSONLProvider.oauthBreaker = CircuitBreaker(threshold: 3, cooldown: 300)` is scoped ONLY to the `/api/oauth/usage` endpoint's 429 responses. Non-429 OAuth errors (refresh failed, no creds, network) do NOT increment the breaker — they're caller-side issues, not endpoint flakiness. 5xx OAuth errors also fall through to the general AggregateStore-level breaker, not this 3-strike one. JSONL collection continues regardless of OAuth breaker state (CLAUDE-04 graceful-degrade).
58. `PollSchedulerSleepWakeTests/scheduler_start_after_stop_resumes_polling` uses a `VirtualClock` that advances 10s per `now()` call (same pattern as `PollSchedulerTests/updateIntervalReplacesLoop`) — guarantees the 2nd refresh after `start()` bypasses POLL-03's 5s `AggregateStore.refresh(now:)` debounce. SystemClock would race the debounce and flake.
59. `TodayHelper.resetClockText` uses `calendar.timeZone.abbreviation(for: now)` for DST-correctness (Pitfall 4 / Pitfall 7). Modern Apple Foundation emits GMT-offset strings ("GMT-7", "GMT-8") instead of historical abbreviations ("PDT", "PST") in recent macOS releases. Tests in `TodayHelperResetClockTests` accept BOTH shapes via `text.hasSuffix("PDT") || text.hasSuffix("GMT-7")`; DST correctness is asserted by checking that the suffix flips at the 2026-03-08 02:00 transition boundary.
60. `AggregateStore.maxQuotaFraction` returns the cross-provider max of each provider's `max(quota.fraction, quotaWindows.utilization.max)`. Empty providers map → 0 (default healthy). `AggregateStore.menuBarTint` is SwiftUI `Color` and lives on the store (not in the App layer) — `import SwiftUI` was added to `AggregateStore.swift`; the architectural decision is recorded in inline doc as "acceptable: AggregateStore is already an @Observable view-model concern".
61. Plan 02.07's `ProviderRowView` moves the staleness computation INSIDE the existing `TimelineView(.periodic(by: 1))` context closure so the dimming updates each second as time crosses the 2× threshold (UI-08). Cost is constant-time per row — accepted per T-02.07-02 disposition.
62. Plan 02.07 ships the `MenuBarExtra` in the explicit-label form (not the `(title:systemImage:)` shorthand) so `Image(systemName:).symbolRenderingMode(.hierarchical).foregroundStyle(dependencies.store.menuBarTint)` can dynamically retint as `@Observable` re-renders. Snap transitions (no animation) acceptable per Pitfall 9 / RESEARCH §H.3.
63. `CodexRolloutScanner` computes yesterday via `Calendar.current.date(byAdding:.day, value:-1, to: startOfDay(for: now))` — NEVER via string substraction or DateFormatter. DST (2026-03-08 PT) and leap-day (2028-02-29) boundaries are asserted by tests with pinned PT and UTC calendars. Directory components built via `DateComponents` + `String(format:"%02d", ...)`; `ISO8601DateFormatter` is forbidden in the scanner (UI-04 / Pitfall 4 invariant).
64. `CodexRolloutEvent` is lenient-by-default — `JSONDecoder.decode(...)` silently ignores unknown JSON keys when the target struct does not declare them. **No `AnyCodable` / `extraFields` plumbing required** (Phase 2 `TranscriptRecord` precedent; CLAUDE-03 / Pitfall 7). RESEARCH.md's hypothetical extraFields scaffold is deliberately NOT adopted; new test `unknown_future_field_does_not_break_decoding` locks in forward-compat.
65. `CodexRolloutParser.lastTokenCount(in:)` folds across `[URL]` comparing parsed ISO8601 `event.timestamp` values — NOT file mtimes. A long-running session pinned to yesterday's date dir but still emitting events today is correctly handled (Pitfall 11). The predicate requires `type == "event_msg"` AND `payload.type == "token_count"` AND `payload.info != nil`; the parser uses Phase 2 STATE #43's dual `ISO8601DateFormatter` (fractional + non-fractional) pattern. Malformed/truncated JSON lines silently skipped via `try?` (Pitfall 5).
66. `CodexCredentialLoader` has NO Keychain path (Codex CLI never writes there) and NO `needsRefresh`/`saveCredentials` (Codex CLI manages its own bearer rotation; we degrade-to-local on 401 instead). The struct stores only `authPath: URL` — `FileManager` was removed from the type after the initial draft tripped Swift 6 strict-concurrency on `Sendable` conformance (`FileManager` is non-Sendable). File reads use `Data(contentsOf:)` directly. Bearer-resolution priority follows RESEARCH correction #4: top-level `OPENAI_API_KEY` (non-null, non-empty) → `.apiKey` source with `accountId = nil`; else `tokens.access_token` (non-empty) → `.subscription` source with `accountId` from `tokens.account_id` (may be nil for personal accounts). Empty-string `OPENAI_API_KEY` treated as absent (Phase 1 STATE #22 precedent).
67. `CodexUsageResponse` is INTENTIONALLY a distinct Codable struct from `CodexRolloutEvent.RateLimits` (RESEARCH correction #5). Schema diverges: **singular `rate_limit`** (NOT plural), **`primary_window`/`secondary_window`** (NOT bare `primary`), **`reset_at`** (no `s`), **`limit_window_seconds`** (NOT `window_minutes`). Every field is optional with `decodeIfPresent` semantics; explicit snake_case `CodingKeys` on every type (NOT `keyDecodingStrategy = .convertFromSnakeCase`, mirrors Phase 2 `TranscriptRecord` + `CodexRolloutEvent`). A regression test `rolloutShapeKeys_doNotMisresolveIntoWhamUsageStruct` locks in the schema split — feeding a rollout-shaped payload leaves the wham/usage `rateLimit` field nil.
68. `CodexOAuthClient` is an `actor` with NO refresh path. `HTTPError` is mapped: **401/403 → `CodexOAuthError.unauthorized(status:)`** (terminal until user re-auths via Codex CLI; provider renders muted "No data yet" per D-03 — NOT a red error row); **429 / any other non-2xx → `CodexOAuthError.usageEndpointFailed(status:)`** (feeds AggregateStore-level CircuitBreaker per POLL-05/STATE #56). `DecodingError` and other Swift errors propagate unchanged (matches `ClaudeOAuthClient` precedent). `account_id` is forwarded as the cleartext `ChatGPT-Account-Id` HTTP header — it identifies a workspace, NOT a credential, so it is never wrapped in `Secret`. The `clock` init parameter is retained for parity with `ClaudeOAuthClient` even though Codex has no refresh path.
69. `CodexOAuthClient` mirrors Phase 2 `ClaudeOAuthClientTests` by using a `FakeHTTPClient` at the `HTTPClient` protocol seam rather than a literal `URLProtocol` stub. This satisfies the intent of STATE #19 (deterministic stubbed HTTP, assertable request shape, scriptable failure modes) without the URLProtocol/NSLock boilerplate. The `.serialized` Swift Testing trait is preserved on `CodexOAuthClientTests`. A test-side source-grep (`clientSource_doesNotCallRevealForRequest`) locks in the SEC-01 invariant that the OAuth client never calls the credential-reveal accessor — only `URLSessionHTTPClient.performGet` is permitted that site (Phase 1 STATE #15).
70. `GeminiSettingsGate.isOAuthPersonal(settingsPath:fileManager:) -> Bool` navigates the NESTED keypath `security.auth.selectedType` via JSONSerialization → nested Dictionary<String, Any> casts (RESEARCH correction #2). NO fallback to flat `selectedAuthType`. Regression-guard test case 8 fails if any silent fallback ever sneaks in. Doc comments AVOID the literal `selectedAuthType` string (Phase 3 STATE #67 precedent — Rule-1 acceptance-gate wording fix).
71. `GeminiOAuthCredentials.expiryDate` is `Double` (epoch MILLISECONDS — RESEARCH correction #3). `expiryDateAsDate()` divides by 1000.0 to produce a Swift `Date`. INTENTIONAL contrast with Codex `resetAt` / rollout `resetsAt` which are epoch SECONDS (no divide). Explicit snake_case `CodingKeys` on every property — never relies on `JSONDecoder.keyDecodingStrategy`.
72. `GeminiCredentialLoader` is file-only — NO Keychain branch (Pitfall 9; gemini-cli HybridTokenStorage requires the keychain-access-groups entitlement which v1 does not ship). Missing `oauth_creds.json` while `settings.json` says `oauth-personal` → loader returns nil → downstream renders the muted "No data yet" row (D-03 convention). SEC-02 logger interpolations carry only the resolution category — never `access_token`, `refresh_token`, `expiry_date`, `scope`, or `id_token`.
73. `GeminiTokenRefreshResponse` INTENTIONALLY omits a `refresh_token` / `refreshToken` field (Pitfall 10 static guard). Google does NOT rotate the refresh_token on installed-app refresh grants; adding the field would invite accidental in-memory overwrites. Test `refreshResponseStruct_hasNoRefreshTokenField` source-scans the struct after comment-stripping to lock the invariant.
74. `GeminiOAuthClient.freshAccessToken(now:)` implements D-09 as a three-step state machine: (1) eager check against actor-cached `cachedAccessToken` + `cachedExpiryDate` (returns if `expiry > now + refreshSkewSeconds`), (2) eager check against the on-disk `accessToken` + `expiryDateAsDate()` (seeds cache + returns if predicate holds), (3) form-urlencoded POST to `https://oauth2.googleapis.com/token` with `client_id` + `client_secret` + `refresh_token` + `grant_type=refresh_token`. `retryAfter401(now:)` invalidates the cache and forces step (3). `refreshSkewSeconds = 60` is a public constant for testability.
75. D-10 enforced both **statically** (no `Data.write`, `try data.write(to:)`, or `FileManager.write` calls in `GeminiOAuthClient.swift` — grep-verified; the refreshed access_token lives ONLY in `cachedAccessToken` actor-isolated state) AND **dynamically** (Test 9 byte-compares the on-disk creds-file fixture before and after a successful refresh). Together: belt-and-suspenders D-10 file-write contract.
76. `GeminiOAuthClient.clientID` + `clientSecret` hard-coded in source as `public static let` constants (RFC 6749 §2.1 — installed-app client_secrets are public). Documented as "re-verify if Gemini auth breaks wholesale" — Google has rotated these credentials rarely. ci.yml SEC-04 gains `--exclude='GeminiOAuthClient.swift'` (Phase 1 STATE #39 self-reference precedent). Current SEC-04 patterns (`sk-proj-|sk-admin-|sk-or-|AIzaSy|sk-[A-Za-z0-9]{20,}`) do not match `GOCSPX-` yet — the exclusion is forward-compatible.
77. `HTTPClient` protocol widened with `postFormURLEncoded(_:formFields:extraHeaders:as:) async throws -> T` for OAuth2 `application/x-www-form-urlencoded` grants. The two existing `HTTPClient` test doubles (`FakeHTTPClient` in `ClaudeOAuthClientTests`, `FakeCodexHTTPClient` in `CodexOAuthClientTests`) gain stub conformances; the new `FakeGeminiHTTPClient` is the only one that actually scripts `postFormURLEncoded` responses and captures the wire body for the refresh-shape test. **Rule-1 production bug-fix**: `URLSessionHTTPClient.postFormURLEncoded` does NOT set `keyDecodingStrategy = .convertFromSnakeCase` because `GeminiTokenRefreshResponse` declares explicit snake_case `CodingKeys` — the strategy pre-rewrites JSON keys to camelCase before lookup and misses the explicit `"access_token"` mapping. Matches Codex test-fake decoder convention (plain `JSONDecoder()`).
78. `CodexModelPricing` Rate shape uses `inputPerMToken / outputPerMToken / cachedInputPerMToken` (Codex semantics per RESEARCH §Embedded Pricing) — INTENTIONALLY divergent from `ClaudeModelPricing`'s `inputPer1M / outputPer1M / cacheWritePer1M / cacheReadPer1M`. The JSON file visibly carries Codex semantics; no key-rewrite glue. LookupSource collapsed to `.exact / .defaultFallback / .nilModel` — no prefix/family heuristic (Codex IDs share no stable family prefix; the rollout `token_count` event doesn't surface model IDs today, so `default` is the hot path). `cost(...)` accepts `reasoningOutputTokens` as a documentary parameter and INTENTIONALLY IGNORES it in the math (RESEARCH: `reasoning_output_tokens` is a SUBSET of `output_tokens` and would double-bill if added).
79. Plan 03-02 BLOCKING `checkpoint:human-verify` against openai.com/api/pricing/ was consciously resolved with the plan's third permitted reviewer response — "pricing page inaccessible — use draft as best-effort" — under the no-clarify operating directive. T-03.02-03 disposition justifies the deferral: `codex-models.json` is a runtime bundle resource, post-distribution correction is a JSON patch + signed update with NO Swift recompile. The `default` entry (the hot path today since rollouts don't carry model IDs in `token_count` events) mirrors `codex-mini-latest` per RESEARCH guidance. The `source` field of the JSON records the deferral verbatim for a future reviewer to date.
80. Phase 3 pbxproj edits with em-dash / tab-indent complexity (group children at 4-tab indent vs build-file declarations at 2-tab indent) require byte-level `python3` substitution (`data.replace(old, new)` with explicit `\xe2\x80\x94` em-dash and exact `\t\t\t\t` tab sequences plus `data.count(old) != 1` pre-checks). The Edit tool silently rejects these inputs without reporting *why*. Worktree-future: track this as a candidate `references/pbxproj-byte-edit-pattern.md` if the pattern recurs.

### Open Questions (from research)

- Phase-0 verification before locking Phase 1: re-verify OpenAI usage endpoints, OpenRouter response shapes, MenuBarExtra latest-Xcode quirks, Claude transcript schema, Gemini `v1internal` stability.
- License choice (MIT vs Apache-2.0) — defer to Phase 6.
- Sparkle appcast hosting (GitHub Pages vs Releases) — confirm before Phase 6.
- Schema canary cadence + failure-reporting destination.

### Active TODOs

- **TEST 7 (deferred)**: Energy Impact "Low" — 1hr battery soak. No automated substitute. Schedule a dedicated reviewer session before v1 distribution (Phase 6 prep); does NOT block Phase 3 start.
- **CONFIG**: `workflow.use_worktrees` remains `false`. Wave 5 ran cleanly sequentially.
- **MEMORY**: `feature_claude_quota_detail_view.md` — reviewer requested expanded per-window quota detail view (5h / 7d + reserve / per-model / Designs / Daily Routines). Data already in `UsageSnapshot.quotaWindows`; UI gap. Phase 03+ candidate.

### Blockers

- None. Phase 2 approved. Phase 3 unblocked.

## Risk Register

| Risk | Severity | Phase to Mitigate |
|------|----------|-------------------|
| `MenuBarExtra(.window)` popover quirks (sizing, click-outside, post-sleep dismiss) | HIGH | Phase 1 |
| "Today" computed in UTC instead of local midnight | HIGH | Phase 2 |
| JSONL whole-file load + strict schema causes UI stalls or zero-out | HIGH | Phase 2 |
| Notification storm if no FSM | HIGH | Phase 2 |
| Polling drains battery / hammers APIs on wake | HIGH | Phases 1 + 2 |
| Local agent connection-refused styled as error | MEDIUM | Phase 4 |
| Notarization / stapling broken on offline first launch | HIGH | Phase 6 |
| Secrets leaking into logs or crash dumps | HIGH | Phase 1 (Secret wrapper + CI grep) |
| Sparkle update channel signing weakness | MEDIUM | Phase 6 |

## Session Continuity

### Last Session

- **Date:** 2026-05-15
- **Worked on:** Phase 03 Plan 04 — `CodexJSONLProvider` actor composing Wave 1 Codex primitives (03-01 scanner+parser + 03-02 pricing + 03-03 OAuth fallback) into the user-visible `UsageProvider`. Two tasks executed autonomously: (1) Added optional `UsageSnapshot.tooltipLabel: String?` field (D-15 plan_type / Gemini tier surface — defaults to nil, all 13 Phase 1/2 call sites source-compatible, synthesised Codable treats optional fields as decodeIfPresent so existing cache envelopes decode cleanly; 4 `@Test` cases lock in backward-compat). (2) `CodexJSONLProvider.swift` (~420 lines) — `actor: UsageProvider` with rollout-first / OAuth-fallback state machine: scan→fan-out reader-delta pass (byte-offset cache via TranscriptReader reused verbatim; records discarded — only offset bookkeeping)→single batched `cache.setTranscriptOffsets` per fetch (STATE #43 invariant)→`CodexRolloutParser.lastTokenCount` fold→if event found build snapshot from rollout, else fall to OAuth `wham/usage`. D-05 `max(primary, secondary) / 100` quota fraction in BOTH paths; D-15 `planType → tooltipLabel` in BOTH paths; D-03 mutedNoData neutral UX (not error) for `.noCredentials` / `.unauthorized`; `.usageEndpointFailed` rethrows for AggregateStore POLL-05 breaker (D-12 — no per-provider breaker added). 14 new `@Test` cases across 2 Codex suites (6 rollout + 8 fallback) — including the strict D-02 invariant test N where rollout-with-data + `.shouldNeverBeCalled` OAuth stub asserts `oauth.fetchCallCount == 0`. Hand-verified $0.061586 USD for the canonical 2026 fixture event. Two Rule-1 / Rule-3 corrections: (a) Pitfall 11 doc-comment rewrite — `last_token_usage` literal references trip the plan's grep-gate even in comments; rewritten to "the per-request delta variant" / "cumulative session-total token usage" (mirrors Plan 03-03 SUMMARY's `revealForRequest` precedent). (b) Test scanner factories inject explicit `Calendar(identifier: .gregorian)` — first test run revealed the host's `Calendar.current` is Buddhist Era (year 2569 = 2026), so the default scanner walked `<root>/2569/04/24/` instead of `<root>/2026/04/24/` and missed the fixture; pure test-side fix; production unaffected (the Codex CLI also respects `Calendar.current` on the same host, so file paths agree). Full Phase 1 + Phase 2 regression suite still green.
- **Commits:** 88f0521 (Task 1 — UsageSnapshot.tooltipLabel + 4 tests + pbxproj wiring in the AA030400 UUID namespace), 3ad9a5a (Task 2 — CodexJSONLProvider.swift + 14 tests across 2 suites + pbxproj wiring).

### Previous Session

- **Date:** 2026-05-15
- **Worked on:** Phase 03 Plan 02 — Codex USD cost calculator primitive. Two tasks: (1) BLOCKING `checkpoint:human-verify` against openai.com/api/pricing/ — resolved as "pricing page inaccessible — use draft as best-effort" (plan's third permitted reviewer response). Rationale recorded inline in the bundled JSON `source` field per T-03.02-03 disposition (JSON is a runtime bundle resource; post-distribution correction is a one-line patch without Swift recompile). (2) Authored `Resources/Pricing/codex-models.json` (7 OpenAI Codex-capable models: codex-mini-latest, o4-mini, o3, o3-mini, gpt-4.1, gpt-4.1-mini, gpt-4.1-nano + default fallback mirroring codex-mini-latest), `CodexModelPricing.swift` cascade-lookup struct (Codex-specialised: `inputPerMToken / outputPerMToken / cachedInputPerMToken` Rate shape; LookupSource collapsed to `.exact / .defaultFallback / .nilModel`; `reasoningOutputTokens` cost(...) parameter INTENTIONALLY ignored in math per RESEARCH schema invariant), tests fixture, 9 Swift Testing `@Test` cases including RESEARCH 2026 fixture event totals → hand-computed $0.061586. Full Debug build green; built `.app/Contents/Resources/` ships both `claude-models.json` and `codex-models.json`; Claude regression suite (13 cases) green. pbxproj edits required byte-level `python3` substitution after the Edit tool silently rejected em-dash + tab-indent input on the group-children blocks.
- **Commits:** dd160a0 (codex-models.json + fixture), 43f97ae (CodexModelPricing.swift + tests + pbxproj wiring across 9 surgical patches in the AA030202 UUID namespace).

### Older Session

- **Date:** 2026-05-15
- **Worked on:** Phase 03 Plan 05 — Gemini OAuth + credential layer. Three tasks executed sequentially: (1) `GeminiSettingsGate` namespace enum reading `~/.gemini/settings.json` at the NESTED keypath `security.auth.selectedType` (RESEARCH correction #2); 10 Swift Testing cases including a regression-guard for the flat-keypath shape. (2) `GeminiOAuthCredentials` Codable struct (explicit snake_case CodingKeys; `expiryDate: Double` as epoch MILLISECONDS per RESEARCH correction #3; `expiryDateAsDate()` divides by 1000.0) + `GeminiCredentialLoader` file-only resolver (Pitfall 9 keychain-migration → returns nil → downstream muted row); 8 tests including SEC-02 logger-interpolation source-scan. (3) `GeminiOAuthError` typed enum + `GeminiTokenRefreshResponse` (INTENTIONALLY omits refresh_token field — Pitfall 10 static guard) + `GeminiOAuthClient` actor implementing D-09 (eager 60s skew + lazy-401 retry, in-memory only per D-10) calling `POST oauth2.googleapis.com/token` form-urlencoded with hard-coded RFC 6749 §2.1 public client_id + client_secret; 12 tests including byte-compare D-10 invariant and source-grep Pitfall 10 static guard. `HTTPClient` widened with `postFormURLEncoded` (Claude + Codex test fakes gain stub conformances); ci.yml SEC-04 gains `--exclude='GeminiOAuthClient.swift'`. 30 new tests across 3 suites; full regression 423 tests across 53 suites; Debug build succeeds. Three Rule-1 deviations recorded: (a) Production decoder bug-fix — `URLSessionHTTPClient.postFormURLEncoded` had `keyDecodingStrategy = .convertFromSnakeCase` which clobbers explicit snake_case `CodingKeys` (Apple rewrites JSON keys to camelCase before lookup); fixed to plain `JSONDecoder()` matching Codex precedent. (b)+(c) Doc-comment literal-string rewrites for `selectedAuthType` and `revealForRequest` to satisfy acceptance grep gates without semantic change (Phase 3 STATE #67 precedent).
- **Commits:** df3ec24 (Task 1 — GeminiSettingsGate + 10 tests + 2 fixtures), eb32dc4 (Task 2 — GeminiOAuthCredentials + GeminiCredentialLoader + 8 tests + 1 fixture), eaee6c6 (Task 3 — GeminiOAuthError + GeminiTokenRefreshResponse + GeminiOAuthClient + 12 tests + 1 fixture + HTTPClient.postFormURLEncoded extension + ci.yml SEC-04 exclusion).

### Next Session

- **Suggested action:** `/gsd-execute-phase 03 --plan 06` — Phase 3 Plan 06 (`GeminiOAuthProvider` actor composing 03-05's Gemini OAuth + credential layer with `v1internal:retrieveUserQuota` + `v1internal:loadCodeAssist` into the `UsageProvider` contract). The Gemini stack mirrors the Codex composition just completed in Plan 04 — Plan 06 surfaces per-model `remainingFraction` + tier label + ISO `resetTime` into `UsageSnapshot.quotaWindows` + `tooltipLabel`. Alternatively `/gsd-execute-phase 03 --plan 07` (UI-11 + tooltip wiring — surfaces both Codex `tooltipLabel` and the future Gemini one via SwiftUI `.help()`) or `/gsd-execute-phase 03 --plan 08` (composition root — wires CodexJSONLProvider + the to-come GeminiOAuthProvider into AppDependencies.makeProduction()).
- **Deferred:** Test 7 (Energy Impact battery soak) — 1hr battery-only soak; schedule before Phase 6 distribution.
- **Memory candidate:** `feature_claude_quota_detail_view` — Phase 05+ candidate; data already in `UsageSnapshot.quotaWindows`.

### Notes

- Project is in **MVP mode** — vertical slices over horizontal layers. Phase 1 exercises the entire poll→actor→store→SwiftUI→notification spine against the lowest-friction provider before the headline (Claude) lands in Phase 2.
- All credentials read-only from existing CLI dotfiles + env; no Keychain UI in v1.
- Open source from day one — README, LICENSE, SECURITY.md, screenshots ship in Phase 6 alongside notarized DMG.

---
*State initialized: 2026-05-11 after roadmap creation.*
