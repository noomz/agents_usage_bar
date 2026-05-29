---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: milestone
status: executing
last_updated: "2026-05-14T12:00:00.000Z"
progress:
  total_phases: 6
  completed_phases: 1
  total_plans: 16
  completed_plans: 15
  percent: 94
---

# Project State: Agents Usage Bar

**Last Updated:** 2026-05-14 (after Phase 2 Wave 4 — Plan 02-06 PowerObserver + RetryPolicy + CircuitBreaker landed)
**Mode:** yolo
**Granularity:** coarse

## Project Reference

**Core Value:** A single ambient glance shows accurate per-provider AI usage for today, so the user notices spend/quota issues before they bite.

**What This Is:** A macOS menu bar app that surfaces today's AI agent usage across Claude, OpenAI Codex, Gemini, OpenRouter, and local agents (Ollama, LM Studio, llama.cpp) — tokens used, USD spent, quota remaining per provider — with native notifications at threshold crossings.

**Current Focus:** Phase 02 — claude-provider-threshold-rollover-jsonl-streaming

## Current Position

Phase: 02 (claude-provider-threshold-rollover-jsonl-streaming) — WAVE 4 COMPLETE
Plan: 6 of 7 executed

- **Milestone:** v1 (initial release)
- **Phase:** 2 of 6 — Claude Provider + Threshold/Rollover + JSONL Streaming — IN PROGRESS
- **Plan:** 6 of 7 plans executed (Wave 1 = {01 ✅, 02 ✅, 03 ✅}; Wave 2 = {04 ✅}; Wave 3 = {05 ✅}; Wave 4 = {06 ✅}; Wave 5 = {07})
- **Status:** Wave 4 (Plan 02-06 PowerObserver + RetryPolicy + CircuitBreaker) landed; ready for `/gsd-execute-phase 02 --wave 5`
- **Progress:** [████████████░░] 86% (6/7 Phase 2 plans)

```
[██████████████████████████████████████████████████████████████░] 94% (15/16 plans complete)
```

## Performance Metrics

| Metric | Value |
|--------|-------|
| Phases complete | 1 / 6 |
| Plans complete | 15 / 16 (Phase 1: 9 plans + Phase 2 Waves 1+2+3+4: 02-01/02/03/04/05/06) |
| Requirements mapped | 76 / 76 (100%) |
| Requirements validated | 42 / 76 (Phase 1 set unchanged; Phase 2 Waves 1+2+3+4 cover CLAUDE-01..05 + NOTIF-01..05 + POLL-04..06 + POLL-09 partial; end-to-end UAT deferred to Plan 02-07) |
| Plans drafted | 16 |
| Plans executed | 15 (Phase 1 = 9; Phase 2 Wave 1 = 3 bundled in salvage commit 2bf5bf6; Phase 2 Wave 2 = 1 in commits e703320 + 3e3f9cf; Phase 2 Wave 3 = 1 in commit ea07831; Phase 2 Wave 4 = 1 in commits 4121cfe + afc7825) |
| Node repairs | 1 (Phase 2 Wave 1 salvage — see Phase 2 backprop) |
| UI phases run | 0 |
| UAT gaps closed | 1 (Test 2 cosmetic hover state) |
| Phase 02 P04 duration | ~90 min, 1 task, 7 files modified |
| Phase 02 P05 duration | ~60 min, 2 tasks, 13 files modified, 42 new tests |
| Phase 02 P06 duration | ~12 min, 2 tasks, 10 files modified, 29 new tests |

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

### Open Questions (from research)

- Phase-0 verification before locking Phase 1: re-verify OpenAI usage endpoints, OpenRouter response shapes, MenuBarExtra latest-Xcode quirks, Claude transcript schema, Gemini `v1internal` stability.
- License choice (MIT vs Apache-2.0) — defer to Phase 6.
- Sparkle appcast hosting (GitHub Pages vs Releases) — confirm before Phase 6.
- Schema canary cadence + failure-reporting destination.

### Active TODOs

- **CONFIG**: `workflow.use_worktrees` remains `false`. Waves 2, 3, 4 all ran cleanly sequentially. Decide before Wave 5 (Plan 02-07 UI extensions + UAT) — likely keep `false` since 02-07 is the only remaining Phase 2 plan.
- **WAVE 5**: Plan 02-07 (UI extensions UI-03/05/08/09 + 02-UAT.md) depends on 02-04/05/06 (all ✅) — unblocked. NOT autonomous (`autonomous: false`) — requires user-driven UAT checkpoint between code landing and phase verification.

### Blockers

(None.)

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

- **Date:** 2026-05-14
- **Worked on:** Phase 02 Plan 02-06 — Energy + resilience layer (Wave 4). Added `RetryPolicy` (decorrelated jitter value type, unwired primitive), `CircuitBreaker` (actor, 3-state machine, default 5-strike/300s for POLL-05), `PowerObserver` (@MainActor, NSWorkspace willSleep/didWake → scheduler.stop/start + store.refresh). Extended `ClaudeJSONLProvider` with 3-strike OAuth-usage-specific breaker (Pitfall 5), `AggregateStore` with `perProviderBreakers` map + POLL-06 terminal-unauthenticated skip + POLL-05 open-breaker skip, `ProviderStatus.unauthenticated` doc (POLL-06 terminality), `AppDependencies.Dependencies.powerObserver` strong-reference, and `AgentsUsageBarApp` force-realize before scheduler.start (Pitfall 4). Fixed 2 root causes during green phase: (1) Swift 6 strict-concurrency deinit access — `nonisolated(unsafe)` on observer tokens + notificationCenter; (2) `PollSchedulerSleepWakeTests/scheduler_start_after_stop_resumes_polling` flake — POLL-03 5s coalescing window was skipping the 2nd refresh under SystemClock; fix = VirtualClock advancing 10s/call.
- **Commits:** 4121cfe (feat — RetryPolicy + CircuitBreaker primitives), afc7825 (feat — PowerObserver + per-provider CircuitBreaker + POLL-06 unauthenticated terminal), 0eed73a (docs — SUMMARY). 29 new Swift Testing assertions; full xcodebuild test = 320 pass / 0 fail / 1 pre-existing skip.

### Next Session

- **Suggested action:** `/gsd-execute-phase 02 --wave 5`. Plan 02-07 is the final Phase 2 plan (Wave 5) — UI extensions (UI-03 last-error tooltip, UI-05 stale dimming, UI-08 menu-bar tint pulse, UI-09 footer reset countdown) + Phase 2 UAT script (`02-UAT.md`). NOT autonomous — runs through UAT checkpoint.
- **Pre-work:** Confirm `xcodebuild test -scheme AgentsUsageBar` still passes at HEAD 0eed73a (320/0/1 at landing). Re-read 02-06-SUMMARY.md for PowerObserver + AggregateStore.perProviderBreakers entry points (UAT script needs to reference them). Plan 02-07 has UI work — keep `workflow.use_worktrees=false` for sequential single-plan execution.

### Notes

- Project is in **MVP mode** — vertical slices over horizontal layers. Phase 1 exercises the entire poll→actor→store→SwiftUI→notification spine against the lowest-friction provider before the headline (Claude) lands in Phase 2.
- All credentials read-only from existing CLI dotfiles + env; no Keychain UI in v1.
- Open source from day one — README, LICENSE, SECURITY.md, screenshots ship in Phase 6 alongside notarized DMG.

---
*State initialized: 2026-05-11 after roadmap creation.*
