---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: milestone
status: planning
last_updated: "2026-05-13T00:00:00.000Z"
progress:
  total_phases: 6
  completed_phases: 1
  total_plans: 16
  completed_plans: 9
  percent: 56
---

# Project State: Agents Usage Bar

**Last Updated:** 2026-05-13 (after Phase 2 planning — 7 plans drafted across 5 waves)
**Mode:** yolo
**Granularity:** coarse

## Project Reference

**Core Value:** A single ambient glance shows accurate per-provider AI usage for today, so the user notices spend/quota issues before they bite.

**What This Is:** A macOS menu bar app that surfaces today's AI agent usage across Claude, OpenAI Codex, Gemini, OpenRouter, and local agents (Ollama, LM Studio, llama.cpp) — tokens used, USD spent, quota remaining per provider — with native notifications at threshold crossings.

**Current Focus:** Phase 02 — Claude Provider + Threshold/Rollover + JSONL Streaming (7 plans planned, ready to execute)

## Current Position

Phase: 02 (claude-provider-threshold-rollover-jsonl-streaming) — PLANNING COMPLETE
Plan: 0 of 7 executed (planning ready)

- **Milestone:** v1 (initial release)
- **Phase:** 2 of 6 — Claude Provider + Threshold/Rollover + JSONL Streaming — PLANS DRAFTED
- **Plan:** 0 of 7 plans executed (Wave 1 = {01, 02, 03}; Wave 2 = {04}; Wave 3 = {05}; Wave 4 = {06}; Wave 5 = {07})
- **Status:** Phase 02 planning complete; awaiting `/gsd-execute-phase 02`
- **Progress:** [░░░░░░░░░░] 0% (Phase 2 execution)

```
[============================================================] 100% (9/9 plans complete)
```

## Performance Metrics

| Metric | Value |
|--------|-------|
| Phases complete | 1 / 6 |
| Plans complete | 9 / 9 (Phase 1 fully complete incl. UAT gap closure) |
| Requirements mapped | 76 / 76 (100%) |
| Requirements validated | 28 / 76 (all Phase 1: SHELL-01,02,03,04,06 + SEC-01,SEC-02,SEC-04,SEC-05 + UI-01,02,04,06,07,10 + POLL-01,02,03,07,08 + NOTIF-06,07 + CFG-01,02 + ROUTER-01,02,03,04) |
| Plans drafted | 9 |
| Plans executed | 9 (01.09 cosmetic gap closure — 1 task, 4 files; HoverableBorderedButtonStyle + FooterView modifier swap; B5 + W7 preserved) |
| Node repairs | 0 |
| UI phases run | 0 |
| UAT gaps closed | 1 (Test 2 cosmetic hover state) |

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

### Open Questions (from research)

- Phase-0 verification before locking Phase 1: re-verify OpenAI usage endpoints, OpenRouter response shapes, MenuBarExtra latest-Xcode quirks, Claude transcript schema, Gemini `v1internal` stability.
- License choice (MIT vs Apache-2.0) — defer to Phase 6.
- Sparkle appcast hosting (GitHub Pages vs Releases) — confirm before Phase 6.
- Schema canary cadence + failure-reporting destination.

### Active TODOs

(None yet — populated by phase planning.)

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

- **Date:** 2026-05-13
- **Worked on:** Phase 02 planning — 7 plans drafted (5 waves) for Claude provider + threshold FSM + JSONL streaming + power/retry/breaker + UI extensions + UAT script.
- **Result:** 8 new SwiftUI files (ClockEnvironmentKey + 3 components + TotalsHeaderView + 3 replaced Wave 0 views) + 3 test suites. 20 new Swift Testing assertions (8 QuotaBar B4 + 9 RelativeTimestampLabel W2 + 3 FooterView W7). Full suite 122 assertions pass. BUILD SUCCEEDED. B4 color thresholds verified, B5 ClockKey sole-declaration verified, UI-07 no loading flash guaranteed by AggregateStore cache seed.
- **Commits:** ae7ec37 (Task 1 — components + tests), b341836 (Task 2 — popover scene views)

### Next Session

- **Suggested action:** Execute Phase 02 — `/gsd-execute-phase 02`. Wave 1 (plans 01/02/03) runs in parallel.
- **Pre-work:** None — all Phase 2 plans reference Phase 1 SUMMARYs + 02-RESEARCH.md as authoritative sources.

### Notes

- Project is in **MVP mode** — vertical slices over horizontal layers. Phase 1 exercises the entire poll→actor→store→SwiftUI→notification spine against the lowest-friction provider before the headline (Claude) lands in Phase 2.
- All credentials read-only from existing CLI dotfiles + env; no Keychain UI in v1.
- Open source from day one — README, LICENSE, SECURITY.md, screenshots ship in Phase 6 alongside notarized DMG.

---
*State initialized: 2026-05-11 after roadmap creation.*
