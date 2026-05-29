---
phase: 02-claude-provider-threshold-rollover-jsonl-streaming
plan: 07
status: code-complete-uat-pending
commits:
  - 5f042c8 feat(02-07): TodayHelper.resetClockText + AggregateStore stale/tint surfaces
  - 6be6396 feat(02-07): UI extensions for stale dimming, reset caption, menu bar tint
  - 4895ae8 docs(02-07): Phase 2 UAT script — 10 reviewer steps gating phase exit
test_outcome: 343 passed / 0 failed / 1 skipped (pre-existing — disabled FS permission test)
acceptance_criteria_met: automated criteria PASS; manual UAT gate (Task 3) pending reviewer
human_verify_gate: blocking — awaiting reviewer to run 02-UAT.md and respond `approved` / file gaps
---

# Plan 02-07 — UI Extensions + Phase 2 UAT

Plan 02-07 closes the Phase 2 UI surface: stale-data dimming (UI-08), menu
bar tint reflecting max quota (UI-09), reset-clock caption in the footer
(UI-05), and a doc-only lock on the ClaudeBar 50% / 20% convention (UI-03).
It also creates `02-UAT.md`, the canonical reviewer script for Phase 2.

## Production files added (1 — non-code)

| Path | Purpose |
|------|---------|
| `.planning/phases/02-claude-provider-threshold-rollover-jsonl-streaming/02-UAT.md` | Phase 2 UAT script — 10 reviewer steps mapped to Phase 2 success criteria 1–5 + Plan 02.07 UI add-ons. |

## Production files extended (7)

| Path | Change |
|------|--------|
| `AgentsUsageBar/Domain/TodayHelper.swift` | New `static func resetClockText(_:calendar:)` — UI-05 footer caption helper. DST-correct via `Calendar.current`'s `timeZone.abbreviation(for: now)`. Falls back to `"Resets 00:00"` (no TZ suffix) for zones without a published abbreviation. |
| `AgentsUsageBar/Aggregation/AggregateStore.swift` | `import SwiftUI` added. New `public func isStale(_:now:)` (UI-08), `public var maxQuotaFraction` (UI-09), `public var menuBarTint: Color` (UI-09). All `@MainActor`, pure functions of the current `providers` map + interval. |
| `AgentsUsageBar/UI/Components/QuotaBar.swift` | Doc-only — top-of-file UI-03 reconciliation comment locks the existing ClaudeBar 50% / 20% convention against future drift. No body change. |
| `AgentsUsageBar/UI/Components/StatusDot.swift` | New `public init(status:isStale:)` overload (default `isStale = false`). When `isStale == true`, the semantic colour gets `.opacity(0.4)` and the accessibility label appends `" (stale)"`. |
| `AgentsUsageBar/UI/Components/RelativeTimestampLabel.swift` | New `public init(date:prefix:isStale:)` overload (default `false`). `foregroundStyle` switches from `.secondary` to `.tertiary` when stale; text content unchanged. |
| `AgentsUsageBar/UI/ProviderRowView.swift` | Now consumes `@Environment(AggregateStore.self)` and `@Environment(\.clockService)`. Computes `isStale` inside a `TimelineView(.periodic(by: 1))` so dimming updates each second as time crosses the 2× threshold. Passes the flag through to `StatusDot` + `RelativeTimestampLabel`. Previews updated to provide a preview `AggregateStore` via `.environment(...)`. |
| `AgentsUsageBar/UI/FooterView.swift` | Caption row above the buttons via `Text(TodayHelper.resetClockText(clock.now())).font(.caption2).foregroundStyle(.secondary)`. Wrapped in a `VStack(spacing: 4)`. |
| `AgentsUsageBar/App/AgentsUsageBarApp.swift` | `MenuBarExtra` switched from the `(title:systemImage:)` shorthand to the explicit-label form: `Image(systemName: "chart.bar.doc.horizontal").symbolRenderingMode(.hierarchical).foregroundStyle(dependencies.store.menuBarTint)`. `@Observable` re-renders the label as `maxQuotaFraction` changes (snap transition acceptable per Pitfall 9). Accessibility label preserved via `.accessibilityLabel("Agents Usage Bar")`. |

## Test files added (5 — all Swift Testing)

| Suite | Cases | What's verified |
|-------|-------|-----------------|
| `TodayHelperResetClockTests` | 6 | Pacific (mid-May), Eastern, UTC, fixed-offset fallback, pre/post-spring-forward in PT on 2026-03-08. Verifies BOTH the historical `"PDT"/"PST"` shapes AND the modern Foundation `"GMT-7"/"GMT-8"` shapes (Apple Foundation's `abbreviation(for:)` now emits GMT offsets on recent macOS releases). |
| `AggregateStoreStaleAndTintTests` | 15 | `isStale` boundaries (no-lastSuccess, recent, just-under-2×, above-2×, `.manual` interval), `maxQuotaFraction` shapes (empty, primary-only, window-only, cross-provider max, per-provider max-of-fields), and `menuBarTint` breakpoints (0.75/0.80/0.95/1.10, plus empty-providers green default). |
| `QuotaBarThresholdConventionTests` | 4 | UI-03 ClaudeBar convention lock — 0.50 → green, 0.49 → yellow, 0.20 → yellow, 0.19 → red. Test names cite "UI-03" explicitly so any drift trips an attributed test. |
| `FooterResetCaptionTests` | 2 | Source-grep contract: `FooterView.swift` invokes `TodayHelper.resetClockText(clock.now())` AND uses `.font(.caption2)`. Mirrors the Phase 1 W7 `#filePath`-based pattern. |
| `MenuBarTintTests` | 3 | Source-grep contract: `AgentsUsageBarApp.swift` binds `dependencies.store.menuBarTint` AND `symbolRenderingMode(.hierarchical)` (Pitfall 9); `AggregateStore.swift` exposes `public var menuBarTint` AND `public var maxQuotaFraction`. |

**Total: 30 new Swift Testing assertions, all passing.**

## UI-03 / 05 / 08 / 09 coverage matrix

| Requirement | Automated coverage | Source assertion | UAT step |
|-------------|--------------------|------------------|----------|
| UI-03 (ClaudeBar 50%/20% convention) | `QuotaBarThresholdConventionTests` (4 cases) + existing `QuotaBarTests` (8 cases) | `UI-03 reconciliation` in QuotaBar.swift header | n/a — convention locked at compile time |
| UI-05 (Resets HH:mm <TZ> footer caption) | `TodayHelperResetClockTests` (6 cases) + `FooterResetCaptionTests` (2 source-grep cases) | `TodayHelper.resetClockText` in FooterView.swift | Test 3 (rollover) verifies the caption updates across days |
| UI-08 (stale-data dimming) | `AggregateStoreStaleAndTintTests/isStale_*` (5 cases) | `isStale: Bool` in StatusDot.swift + RelativeTimestampLabel.swift | Test 9 (network-down for > 2× interval) |
| UI-09 (menu bar tint reflects max quota) | `AggregateStoreStaleAndTintTests/maxQuotaFraction_* + menuBarTint_*` (10 cases) + `MenuBarTintTests` (3 source-grep cases) | `foregroundStyle(dependencies.store.menuBarTint)` + `symbolRenderingMode(.hierarchical)` in AgentsUsageBarApp.swift | Test 10 (force fractions across 0.80 / 0.95 boundaries) |

## Test suite results

Full `xcodebuild test -scheme AgentsUsageBar -destination 'platform=macOS'`:

```
** TEST SUCCEEDED **
343 passed / 0 failed / 1 skipped
```

The single skip is the pre-existing `fetch_jsonlFanOutError_setsErrorStatus_andRethrows`
(disabled FS-permission test from Plan 02-04). No regressions in any Phase 1
or Phase 2 Plans 01–06 suites.

## Source assertion checks (from acceptance criteria)

| Check | Result |
|-------|--------|
| `grep -RIn 'func resetClockText' AgentsUsageBar/Domain/TodayHelper.swift` | PASS |
| `grep -RIn 'func isStale' AgentsUsageBar/Aggregation/AggregateStore.swift` | PASS |
| `grep -RIn 'var maxQuotaFraction' AgentsUsageBar/Aggregation/AggregateStore.swift` | PASS |
| `grep -RIn 'var menuBarTint' AgentsUsageBar/Aggregation/AggregateStore.swift` | PASS |
| `grep -RIn 'timeZone\.abbreviation' AgentsUsageBar/Domain/TodayHelper.swift` | PASS |
| `grep -RIn 'UI-03 reconciliation' AgentsUsageBar/UI/Components/QuotaBar.swift` | PASS |
| `grep -RIn 'isStale: Bool' AgentsUsageBar/UI/Components/StatusDot.swift` | PASS |
| `grep -RIn 'isStale: Bool' AgentsUsageBar/UI/Components/RelativeTimestampLabel.swift` | PASS |
| `grep -RIn 'foregroundStyle(dependencies\.store\.menuBarTint)' AgentsUsageBar/App/AgentsUsageBarApp.swift` | PASS |
| `grep -RIn 'symbolRenderingMode(.hierarchical)' AgentsUsageBar/App/AgentsUsageBarApp.swift` | PASS |
| `grep -RIn 'TodayHelper\.resetClockText' AgentsUsageBar/UI/FooterView.swift` | PASS |

## Bug fixes applied during execution

**[Rule 1 — Apple Foundation change]** Initial `TodayHelperResetClockTests`
asserted exact `"PDT"` / `"EDT"` / `"PST"` abbreviations. Modern Apple
Foundation (`TimeZone.abbreviation(for:)`) emits GMT offsets like `"GMT-7"`,
`"GMT-8"`, `"GMT-4"` instead of the historical zone abbreviations on recent
macOS releases. **Fix:** loosened assertions to accept either shape — DST
correctness is still verified by asserting that the suffix flips at the
2026-03-08 02:00 transition (GMT-8 → GMT-7), which is the load-bearing
invariant for UI-05. The production code is unchanged (the abbreviation is
whatever Apple returns).

## Human-verify gate (Task 3) — status

Plan 02.07 contains a **blocking** human-verify checkpoint at Task 3. The
deliverable artifact (`02-UAT.md`) is committed. The 10-step reviewer
script is ready to run.

**Gate is NOT YET RESOLVED.** Next reviewer action:

1. Build the app from HEAD (`4895ae8`).
2. Walk through Tests 1–10 in `02-UAT.md`.
3. Respond `approved` (Phase 2 complete) OR file failed steps for
   `/gsd-plan-phase 02 --gaps` remediation.

Plan 02.07's CODE WORK is complete; the phase exit is deferred pending
reviewer sign-off on the UAT script.

## Pointer to next phase

**Phase 3 — Codex + Gemini providers.** Reuses:

- `TranscriptReader` (Plan 02.01) for Codex `rollout-*.jsonl` parsing.
- `TranscriptDirectoryScanner` (Plan 02.01) — Codex sessions live at
  `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`; scanner generalises with
  new roots.
- `CacheStore.transcriptOffset` schema v2 (Plan 02.01) — Codex provider
  uses the same offset cursor approach.
- `ThresholdEngine` v2 FSM (Plan 02.05) — Codex + Gemini providers slot
  into the same notification path; per-(provider, day) keys make the FSM
  provider-agnostic.
- `CircuitBreaker` + `PowerObserver` (Plan 02.06) — cross-cutting
  resilience layer needs no per-provider duplication.
- `menuBarTint` (Plan 02.07) — automatically reflects new providers'
  quota as they're added to the registry.

## Self-check: PASSED (code) — PENDING (UAT)

- 02-UAT.md exists at the canonical path ✓
- 3 commits landed on `main` ✓
- 30 new Swift Testing assertions pass ✓
- 11/11 source-grep contract assertions pass ✓
- Full `xcodebuild test` exits 0 ✓
- xcodebuild build for `AgentsUsageBar` scheme exits 0 ✓
- Plan 01.* + Plans 02.01–06 regression clean ✓
- Manual UAT (Task 3 blocking checkpoint) ⬜ — awaiting reviewer
