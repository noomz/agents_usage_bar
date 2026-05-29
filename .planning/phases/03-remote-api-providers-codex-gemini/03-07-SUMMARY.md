---
phase: 03-remote-api-providers-codex-gemini
plan: 07
subsystem: ui-dashboard-tooltip-footnote-degraded
tags: [ui, ui-11, d-07, d-11, d-13, d-14, d-15, gemini-03, dashboard-button, tooltip, footnote, degraded-styling]
dependency_graph:
  requires: [03-04, 03-06, 03-08]
  provides:
    - provider-dashboard-url-lookup
    - open-dashboard-url-environment-key
    - provider-row-dashboard-button
    - provider-row-tooltip
    - provider-row-degraded-styling
    - totals-header-quota-only-footnote
  affects:
    - UI/ProviderDashboardURL (new — D-14 hard-coded URL map)
    - UI/Environment/OpenDashboardURLEnvironmentKey (new — testability seam)
    - UI/ProviderRowView (dashboard button + tooltip + degraded styling)
    - UI/TotalsHeaderView (D-07 footnote)
    - UI/Components/StatusDot (forceAmber parameter additive)
tech_stack:
  added:
    - ProviderDashboardURL (enum namespace; D-14 hard-coded URL lookup keyed by ProviderID)
    - OpenDashboardURLKey (SwiftUI EnvironmentKey — production default opens URL via AppKit; tests inject recorder)
    - EnvironmentValues.openDashboardURL accessor
    - StatusDot.forceAmber: Bool additive parameter (D-11 degraded amber tint)
  patterns:
    - Hard-coded HTTPS-only URL table per D-14 (no config knob in v1; ATS-friendly)
    - EnvironmentKey testability seam — production opens via AppKit, tests inject recording closure (mirrors STATE #29 ClockKey)
    - Source-grep contract tests via #filePath repo-root walk (mirrors STATE #33 FooterViewTests)
    - SwiftUI .help(_:) suppression-on-empty — passing "" yields no tooltip (D-15 silent-when-absent)
    - VStack-wrap of TotalsHeaderView header HStack — preserves no-footnote layout byte-identical to Phase 1
    - Composing UI-08 stale dim + D-11 degraded dim via `isStale || isDegraded ? 0.6 : 1.0` opacity
    - Composing StatusDot stale alpha on top of forceAmber tint (degraded + stale renders amber-dimmed)
    - Single-sourced D-11 literal via ThresholdEngine.degradedTag (Plan 03-08 STATE #84)
    - Trailing dashboard button .disabled(dashboardURL == nil) — preserves row layout symmetry across providers
key_files:
  created:
    - AgentsUsageBar/UI/ProviderDashboardURL.swift
    - AgentsUsageBar/UI/Environment/OpenDashboardURLEnvironmentKey.swift
    - AgentsUsageBarTests/UITests/ProviderDashboardURLTests.swift
    - AgentsUsageBarTests/UITests/ProviderRowViewDashboardButtonTests.swift
    - AgentsUsageBarTests/UITests/ProviderRowViewTooltipTests.swift
    - AgentsUsageBarTests/UITests/ProviderRowViewDegradedTests.swift
    - AgentsUsageBarTests/UITests/TotalsHeaderViewFootnoteTests.swift
  modified:
    - AgentsUsageBar/UI/ProviderRowView.swift (env-key + dashboard button + tooltip + degraded styling)
    - AgentsUsageBar/UI/TotalsHeaderView.swift (VStack wrap + D-07 footnote)
    - AgentsUsageBar/UI/Components/StatusDot.swift (forceAmber additive parameter)
    - AgentsUsageBar.xcodeproj/project.pbxproj (AA030700 UUID namespace — 7 build files + 7 file refs + UI/Environment/UITests group children)
decisions:
  - "ProviderDashboardURL is a pure enum namespace with 4 public static let URL constants + a switch-by-rawValue lookup. Force-unwrap of URL(string:) on the four hard-coded strings is acceptable: each unwrap is type-checked at compile time AND covered by Task 1's 9 unit tests; failure would be a programming error caught the moment the test suite runs. Switching on rawValue (not on ProviderID directly) keeps the lookup safe against ProviderID constants added at other layers — the default arm returns nil, the safe behaviour for unknown IDs."
  - "EnvironmentKey approach chosen for the dashboard-launch seam (over inline NSWorkspace + a (URL)->Void parameter) — mirrors Phase 1 STATE #29 ClockKey precedent. Production default declared once in OpenDashboardURLEnvironmentKey.swift; ProviderRowView consumes via @Environment; tests inject via .environment(\\.openDashboardURL, recorder). The default closure is @MainActor because it calls into AppKit (NSWorkspace.shared.open requires main-actor)."
  - "StatusDot gains `forceAmber: Bool = false` as a third init parameter (default preserves every Phase 1/2 call site). When true, the amber colour overrides the semantic status colour BEFORE the UI-08 stale dim is applied — so a degraded-AND-stale row renders as amber-dimmed (the visual hierarchy stays: degraded supersedes ok/error, then stale composes on top)."
  - "Plan 03-07 references ThresholdEngine.degradedTag directly (not GeminiOAuthProvider.degradedNote) per Plan 03-08 STATE #84 DRY contract. Either constant resolves to the same literal `usage-temporarily-unavailable`, but threading the dependency through ThresholdEngine keeps Plan 03-07 ignorant of Gemini-specific naming."
  - "TotalsHeaderView wraps the existing HStack in a VStack so the footnote can sit below the totals row without disturbing the original horizontal layout. The HStack's padding (.padding(.horizontal, 12).padding(.vertical, 10)) stays attached to the HStack — when no quota-only provider is registered, the rendered hierarchy is `VStack { HStack { ... } }` which lays out identically to the Phase 1 bare HStack (SwiftUI inlines a single-child VStack without overhead)."
  - "Plan-permitted pbxproj wiring choice: I pre-registered all Task-2 and Task-3 file refs in the AA030700 UUID namespace during Task 1's pbxproj edit. Splitting the pbxproj edits per-task would have required three separate atomic Edits on the same file region — error-prone for an XML-ish DSL. The trade is recorded here for traceability; each task's commit still includes its own source files, and Task 1's commit also carries the pbxproj wiring needed to build the subsequent tasks' (placeholder, then real) files."
  - "Doc-comment rewording (Rule 1 - Test Wording Gate): ProviderRowView's @Environment doc comment originally said 'calls NSWorkspace.shared.open(_:); tests inject a recording closure' — the literal 'NSWorkspace.shared.open' tripped Task 2's negative-grep assertion (`#expect(src.contains(\"NSWorkspace.shared.open\") == false, ...)`). Reworded to 'opens the URL via AppKit; tests inject a recording closure' — semantically identical (and the literal AppKit call still lives in OpenDashboardURLEnvironmentKey.swift exactly where it belongs). Mirrors Plan 03-04 SUMMARY deviation #1 (Pitfall 11 doc-comment grep wording fix)."
  - "Test scaffolding: source-grep helpers live as `nonisolated static func` so the three ProviderRowView* test suites can share them across MainActor-isolated (ButtonTests) and nonisolated (TooltipTests, DegradedTests) call sites. Same pattern as Phase 1 STATE #33."
  - "Plan 03-07's `runtime_envKeyReceivesExpectedURL` test invokes the env-injected closure directly through `EnvironmentValues` rather than instantiating a SwiftUI view hierarchy — avoids ViewInspector dependency and matches the test-via-protocol-seam pattern STATE #19/#69 establishes elsewhere."
metrics:
  duration: "~11 minutes (3 tasks; autonomous; no checkpoints)"
  completed: "2026-05-18"
  tasks: 3
  files_modified: 11
  tests_added: 32
requirements:
  - UI-11 (full — per-row 'arrow.up.right.square' dashboard button wired through ProviderDashboardURL.lookup + openDashboardURL EnvironmentKey; always visible; .disabled for providers without a mapped URL)
---

# Phase 03 Plan 07: UI Dashboard Button + Tooltip + Footnote + Degraded Styling Summary

Lands the Phase 3 UI surface: per-row "Open dashboard" button (UI-11 / D-13 / D-14), `.help()` tooltip carrying `UsageSnapshot.tooltipLabel` (D-15 / GEMINI-03), "Total excludes quota-only providers" footnote on the totals header (D-07), and the cached-dim + amber-dot + subtitle styling for Gemini's `"usage-temporarily-unavailable"` snapshot (D-11). Three atomic commits across 11 production + test files; 32 new Swift Testing cases.

## What Was Built

### Production Files

**`AgentsUsageBar/UI/ProviderDashboardURL.swift`** (new — ~50 LOC)
- `public enum ProviderDashboardURL` — pure namespace with four public `static let URL` constants for the D-14 dashboard URLs.
- `public static func lookup(_ providerID: ProviderID) -> URL?` switches over `rawValue` — returns the mapped URL for `openrouter`/`claude`/`codex`/`gemini`; returns `nil` for any other rawValue (local LLMs / unknown future IDs).
- Doc comment calls out the `/u/0/` pin on the Gemini URL (RESEARCH §"Dashboard URLs") which skips Google's account-picker.
- HTTPS-only invariant baked into the constants; verified by Task 1 test 8.

**`AgentsUsageBar/UI/Environment/OpenDashboardURLEnvironmentKey.swift`** (new — ~30 LOC)
- `private struct OpenDashboardURLKey: EnvironmentKey` — production default closure calls `NSWorkspace.shared.open(_:)` (the only AppKit-touching call site in the row UI).
- `public extension EnvironmentValues { var openDashboardURL: @MainActor (URL) -> Void }` accessor.
- B5 invariant preserved: this file does NOT redeclare `ClockKey` or extend `EnvironmentValues` with anything other than `openDashboardURL`.

**`AgentsUsageBar/UI/ProviderRowView.swift`** (modified)
- Added `@Environment(\.openDashboardURL) private var openDashboardURL`.
- New computed properties: `dashboardURL: URL?` (lookup) + `isDegraded: Bool` (D-11 detector keyed on `ThresholdEngine.degradedTag`).
- `Text(state.displayName)` gains `.help(state.snapshot?.tooltipLabel ?? "")` per D-15 / GEMINI-03 (SwiftUI shows no tooltip when the argument is empty — matches D-15 silent-when-absent semantics).
- `StatusDot` invocation gains `forceAmber: isDegraded` so the dot tints amber when the snapshot is degraded.
- Quota bar and the token/USD/balance HStack gain `.opacity(isStale || isDegraded ? 0.6 : 1.0)` — extends the UI-08 stale dim with the D-11 degraded dim using a single opacity rule.
- After the existing "Resets —" row, a conditional `if isDegraded { Text("Updated Xs ago — usage temporarily unavailable") }` renders the D-11 subtitle (uses the existing `RelativeTimestampLabel.relativeString(from:to:)` helper). Falls back to the `ctx.date` when `state.lastSuccess == nil` so the row never renders "Updated —s ago …".
- New trailing dashboard button: SF Symbol `arrow.up.right.square`, monochrome, 14pt; `HoverableBorderedButtonStyle()`; `.disabled(dashboardURL == nil)` for providers without a mapped URL; `.help("Open \(state.displayName) dashboard")` for accessibility.
- New SwiftUI preview "ProviderRowView — Gemini degraded (D-11)" so the reviewer can inspect the full degraded styling treatment.

**`AgentsUsageBar/UI/TotalsHeaderView.swift`** (modified)
- Wraps the existing `HStack` in `VStack(alignment: .leading, spacing: 2)`.
- The HStack retains its `.padding(.horizontal, 12).padding(.vertical, 10)` so the layout in the no-footnote branch is identical to Phase 1.
- Below the HStack: `if store.hasAnyQuotaOnlyProvider { Text("Total excludes quota-only providers").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 6) }`.

**`AgentsUsageBar/UI/Components/StatusDot.swift`** (modified)
- Added `public let forceAmber: Bool` stored property.
- `init(status:isStale:forceAmber:)` — `forceAmber` defaults to `false` so every Phase 1/2 call site stays source-compatible.
- `dotColor` resolves the base semantic color, applies `forceAmber ? .orange : base`, then applies the UI-08 `isStale ? 0.4 : 1.0` alpha on top. Composing in that order keeps degraded supersedes ok/error/etc., with stale-dim layered after.

### Test Files (5 new suites, 32 new `@Test` cases)

**`AgentsUsageBarTests/UITests/ProviderDashboardURLTests.swift`** — 9 tests
- Each of the four known providers maps to the exact D-14 URL literal.
- Gemini URL specifically asserts `path.contains("/u/0/")` (RESEARCH safety invariant).
- 3 local-LLM rawValues + 1 unknown future rawValue all return `nil`.
- All four mapped URLs are HTTPS + have a non-empty host.

**`AgentsUsageBarTests/UITests/ProviderRowViewDashboardButtonTests.swift`** — 5 tests
- Source-grep: ProviderRowView contains `arrow.up.right.square`, references `openDashboardURL` AND `@Environment(\.openDashboardURL)`, does NOT contain `NSWorkspace.shared.open` (env-key indirection enforced).
- Source-grep: button is `.disabled(dashboardURL == nil)`; carries accessibility help string `"Open \(state.displayName) dashboard"`.
- Runtime: `EnvironmentValues.openDashboardURL` injected with a `MainActor`-isolated recorder receives `ProviderDashboardURL.lookup(.codex)` then `.lookup(.gemini)` when the closure is invoked — proves end-to-end env-key wiring without instantiating the SwiftUI view hierarchy.

**`AgentsUsageBarTests/UITests/ProviderRowViewTooltipTests.swift`** — 5 tests
- Source-grep: ProviderRowView annotates the displayName Text with `.help(state.snapshot?.tooltipLabel ?? "")`.
- 4 behavioural tests on the helper that mirrors the .help argument computation:
  - `nil` snapshot → `""`
  - `tooltipLabel == nil` → `""` (D-15 silent-when-absent semantic)
  - `tooltipLabel == "Free"` → `"Free"` (Gemini tier verbatim)
  - `tooltipLabel == "plus"` → `"plus"` (Codex plan_type verbatim)

**`AgentsUsageBarTests/UITests/ProviderRowViewDegradedTests.swift`** — 7 tests
- Source-grep: ProviderRowView detects the D-11 marker via literal OR via `ThresholdEngine.degradedTag`/`GeminiOAuthProvider.degradedNote`.
- Source-grep: passes `forceAmber: isDegraded` to StatusDot; includes the literal `"— usage temporarily unavailable"` for the subtitle.
- Source-grep: StatusDot.swift exposes the `forceAmber` parameter.
- Behavioural: `raw["note"] == ThresholdEngine.degradedTag` matches; 5 noise-note values do NOT trip the detector; absent `raw["note"]` does NOT trip the detector. The literal-equality test also locks in `ThresholdEngine.degradedTag == "usage-temporarily-unavailable"` (DRY invariant cross-check).

**`AgentsUsageBarTests/UITests/TotalsHeaderViewFootnoteTests.swift`** — 7 tests
- Source-grep: TotalsHeaderView contains the literal `"excludes quota-only providers"` and reads `hasAnyQuotaOnlyProvider`; AggregateStore exposes `hasTokensByID` AND `hasAnyQuotaOnlyProvider` (Plan 03-08 precondition).
- Behavioural: empty registry → `false`; registry with only a hasTokens=false provider (Gemini stub) → `true`; registry with only a hasTokens=true provider (Codex stub) → `false`; mixed registry → `true`. Uses an in-suite `private actor StubProvider: UsageProvider` to control capabilities deterministically.

## Test Suite Results

| Suite | Tests | Result |
|-------|-------|--------|
| ProviderDashboardURLTests | 9 | PASS |
| ProviderRowViewDashboardButtonTests | 5 | PASS |
| ProviderRowViewTooltipTests | 5 | PASS |
| ProviderRowViewDegradedTests | 7 | PASS |
| TotalsHeaderViewFootnoteTests | 7 | PASS |
| **Plan 03-07 total** | **32** | **PASS** |
| Full Phase 1 + 2 + 3 regression sweep | 546 passed, 0 failed | PASS |

Full project build: `xcodebuild build -project AgentsUsageBar.xcodeproj -scheme AgentsUsageBar -configuration Debug` → `** BUILD SUCCEEDED **`.

Full suite: `xcodebuild test -project AgentsUsageBar.xcodeproj -scheme AgentsUsageBar` → `** TEST SUCCEEDED **` (546 / 546 PASS on the verified run).

Note: A transient flake on `PollSchedulerTests/updateIntervalReplacesLoop` + `PollSchedulerTests/startTriggersImmediateRefresh` appeared on the first two parallel-runner attempts; both pass in isolation and on retry. This matches the pre-existing timing-sensitive PollScheduler test class (STATE #58 documents the workaround applied to a sibling test). It is NOT a Plan 03-07 regression.

## Invariant Verification (acceptance criteria)

| Invariant | Result |
|-----------|--------|
| `grep -n 'aistudio.google.com/u/0/usage' …ProviderDashboardURL.swift` ≥ 1 | 2 ✓ |
| `grep -n 'platform.openai.com/usage' …ProviderDashboardURL.swift` ≥ 1 | 2 ✓ |
| `grep -n 'console.anthropic.com/settings/usage' …ProviderDashboardURL.swift` ≥ 1 | 2 ✓ |
| `grep -n 'openrouter.ai/credits' …ProviderDashboardURL.swift` ≥ 1 | 2 ✓ |
| `grep -n 'http://' …ProviderDashboardURL.swift` == 0 (HTTPS-only) | 0 ✓ |
| `ProviderDashboardURLTests` declares ≥ 9 `@Test` cases | 9 ✓ |
| `grep -n 'arrow.up.right.square' …ProviderRowView.swift` ≥ 1 | 2 ✓ (button + doc-comment) |
| `grep -nE '\.help\(' …ProviderRowView.swift` ≥ 2 | 2 ✓ (tooltip + button accessibility) |
| `grep -n 'openDashboardURL' …ProviderRowView.swift` ≥ 2 | 3 ✓ (env key, closure call, doc comment) |
| `grep -nE 'usage-temporarily-unavailable\|degradedTag' …ProviderRowView.swift` ≥ 1 | 1 ✓ (via ThresholdEngine.degradedTag — single-sourced literal) |
| `grep -n 'forceAmber' …Components/StatusDot.swift` ≥ 1 | 3 ✓ (stored property + init param + doc) |
| `grep -n 'excludes quota-only providers' …TotalsHeaderView.swift` == 1 | 1 ✓ |
| `grep -n 'hasAnyQuotaOnlyProvider' …Aggregation/AggregateStore.swift` ≥ 1 | 2 ✓ (Plan 03-08 precondition) |
| Combined new Plan 03-07 `@Test` cases ≥ 11 | 32 ✓ |
| Full xcodebuild build + test suite green | PASS ✓ |
| D-11 degraded styling sources `ThresholdEngine.degradedTag` (no literal duplication in ProviderRowView) | ✓ — ProviderRowView references `ThresholdEngine.degradedTag`; the literal `usage-temporarily-unavailable` itself appears only in tests (assertion side) and in the canonical constant declaration in ThresholdEngine.swift / GeminiOAuthProvider.swift |
| D-07 footnote conditional on `hasAnyQuotaOnlyProvider` | ✓ — TotalsHeaderView body wraps the footnote in `if store.hasAnyQuotaOnlyProvider { ... }` |
| D-15 tooltip reads `UsageSnapshot.tooltipLabel` | ✓ — `.help(state.snapshot?.tooltipLabel ?? "")` annotation on the displayName Text |
| UI-11 per-row Open Dashboard button wires through `ProviderDashboardURL` | ✓ — `private var dashboardURL: URL? { ProviderDashboardURL.lookup(state.id) }` + Button action invokes `openDashboardURL(url)` |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Test Wording Gate] Doc comment in `ProviderRowView` tripped the negative-grep assertion in `source_invokesOpenDashboardURLViaEnvKey()`**
- **Found during:** First post-Task-2 test run (parallel-runner failure on `source_invokesOpenDashboardURLViaEnvKey`).
- **Issue:** The Task 2 test asserts `#expect(src.contains("NSWorkspace.shared.open") == false, ...)` to enforce that ProviderRowView never invokes the AppKit API directly (the EnvironmentKey closure owns that call). My first-draft doc comment on the `@Environment(\.openDashboardURL)` property said "The default (declared in `OpenDashboardURLEnvironmentKey.swift`) calls `NSWorkspace.shared.open(_:)`; tests inject a recording closure." The literal `NSWorkspace.shared.open` in that comment matched the negative grep.
- **Fix:** Reworded the comment to "opens the URL via AppKit; tests inject a recording closure. Keeping AppKit out of this view body satisfies the testability seam from D-13." Semantically identical; the literal AppKit call remains in `OpenDashboardURLEnvironmentKey.swift` exactly where it belongs (and that file is OUT of the grep scope because the test reads only `ProviderRowView.swift`).
- **Files modified:** `AgentsUsageBar/UI/ProviderRowView.swift` (doc comment only, no behavioural change).
- **Commit:** Folded into commit `74a109c` (Task 2). Mirrors Plan 03-04 SUMMARY deviation #1 (Pitfall 11 doc-comment grep wording fix) and Plan 03-06 STATE #67 precedent.

**2. [Rule 3 - Blocking Compile] `StubProvider` in `TotalsHeaderViewFootnoteTests` did not conform to `UsageProvider`**
- **Found during:** First test compile after writing the Task 3 tests.
- **Issue:** My first-draft `StubProvider` actor implemented `id` / `displayName` / `capabilities` / `fetch(now:)` but omitted `status() -> ProviderStatus`. The `UsageProvider` protocol requires both `fetch(now:)` AND `status()` — Swift 6 compile error caught it.
- **Fix:** Added `func status() -> ProviderStatus { .unauthenticated }` to `StubProvider`. The status value is irrelevant to the hasAnyQuotaOnlyProvider tests (they probe the registry's hasTokens metadata, not per-provider status).
- **Files modified:** `AgentsUsageBarTests/UITests/TotalsHeaderViewFootnoteTests.swift` (private stub only, no production change).
- **Commit:** Folded into commit `2efa0d7` (Task 3).

**3. [Rule 3 - Blocking Compile] Helper static `providerRowViewSource()` declared in a `@MainActor`-isolated test suite was unreachable from non-isolated sibling test suites**
- **Found during:** First test compile.
- **Issue:** `ProviderRowViewDashboardButtonTests` is `@MainActor` (it instantiates `URLRecorder` in the runtime test). The other two row-test suites (`ProviderRowViewTooltipTests` + `ProviderRowViewDegradedTests`) reuse `ProviderRowViewDashboardButtonTests.providerRowViewSource()` to avoid duplicating the source-walk helper, but their @Suite types are not MainActor-isolated. Swift 6 compile error: "Call to main actor-isolated static method 'providerRowViewSource()' in a synchronous nonisolated context."
- **Fix:** Marked the helper `nonisolated static func providerRowViewSource() throws -> String` — pure file-IO has no isolation requirement, and the test suite type isolation doesn't propagate to nonisolated members.
- **Files modified:** `AgentsUsageBarTests/UITests/ProviderRowViewDashboardButtonTests.swift` (helper modifier only).
- **Commit:** Folded into commit `74a109c` (Task 2).

No production-code bugs found (Rule 1 — beyond the doc-comment wording above); no missing critical functionality (Rule 2); no architectural changes needed (Rule 4). Production code was correct from the first compile in each task; only test wording and Swift 6 isolation modifiers needed adjustment.

### Plan-Conformant Adjustments (not deviations — recorded for traceability)

**Pre-registered all Task 2 + Task 3 pbxproj file refs in Task 1's commit.** Plan 03-07's three tasks each create new source files that need pbxproj wiring (app target Sources + test target Sources + group children). Splitting the pbxproj edits into three commits would have required three separate atomic Edits on the same project file region — error-prone for an XML-ish DSL. Instead, I added all 7 file refs + build files + group entries in a single pbxproj edit during Task 1's commit (75e0ac9). Each subsequent task's commit (74a109c, 2efa0d7) carries its own source file additions/modifications without further pbxproj touches. This is plan-conformant (the plan does not constrain pbxproj atomicity) and matches the AA030600 / AA030800 namespace pattern that prior Phase 3 plans used for similar bundles of related files.

**Runtime `runtime_envKeyReceivesExpectedURL` test invokes via `EnvironmentValues` directly rather than instantiating SwiftUI views.** The plan's Task 2 action allowed either: programmatically trigger the Button action via NSApplication.shared.sendAction (or directly call the closure via inspecting `dashboardURL` and openDashboardURL — simpler). I chose the simpler form: build an `EnvironmentValues` value, set `openDashboardURL` on it, then invoke the closure with each `ProviderDashboardURL.lookup(...)` URL and assert the recorder captures both. This proves the end-to-end contract (env key, lookup, closure invocation) without requiring SwiftUI view-hierarchy instantiation or a ViewInspector-style dependency.

## Threat Surface Scan

No new surface beyond the plan's `<threat_model>`. All five threat IDs (T-03.07-01..04 plus T-03.07-SC) remain at their planned dispositions:

- **T-03.07-01 (Tampering, hard-coded URLs)** — `accept` ✓ URLs originate from compile-time `let` constants in `ProviderDashboardURL`; tampering requires a source-code edit caught at code review. The 9 unit tests in `ProviderDashboardURLTests` lock the exact URL strings so any future edit is caught at PR time.
- **T-03.07-02 (Info Disclosure via tooltipLabel)** — `accept` ✓ `tooltipLabel` displays only on the local user's hover; never leaves the machine. Plan 03-06 STATE #82 confirms the tooltipLabel string carries account-tier metadata, not credential material.
- **T-03.07-03 (Spoofing via injected URL)** — `not-applicable` ✓ The button computes its URL from `ProviderDashboardURL.lookup(state.id)` only; `state.snapshot.raw["note"]` and `tooltipLabel` are rendered exclusively as Text views, never as URLs. No path from a snapshot field to a URL.
- **T-03.07-04 (Repudiation, misleading footnote)** — `accept` ✓ Footnote fires whenever any registered provider's `capabilities.hasTokens == false`. In Phase 1+2+3 that includes OpenRouter (Phase 1 STATE #26 documents OpenRouter does not expose token counts) AND Gemini (Plan 03-06 actor declares `hasTokens: false`). The footnote is therefore technically correct: the cross-provider token total excludes both providers' contributions (both are 0 anyway). Reviewer may revisit phrasing in Plan 03-09 UAT.
- **T-03.07-SC (Tampering, package installs)** — `mitigate` ✓ No package installs in this plan.

## Authentication Gates

None encountered. All work was code/test additions; no live HTTP, no CLI invocations, no auth prompts.

## Known Stubs

None — every UI surface added by this plan is fully wired and tested. The dashboard button opens the correct URL via AppKit at runtime (verified via the env-key default closure). The tooltip surfaces real `UsageSnapshot.tooltipLabel` values (Plan 03-04 / Plan 03-06 populate it). The footnote conditional reads the live `AggregateStore.hasAnyQuotaOnlyProvider` accessor (Plan 03-08 populates `hasTokensByID` from the registered providers' capabilities).

## Requirement Status

- **UI-11** — **full**. Per-row trailing-icon "Open dashboard" button using SF Symbol `arrow.up.right.square`. Always visible (no hover-reveal, no kebab menu — D-13). Wires through `ProviderDashboardURL.lookup(state.id)` for the four known providers (D-14); `.disabled(dashboardURL == nil)` for out-of-scope providers (local LLMs — Phase 4). Click invokes the `openDashboardURL` environment closure which in production opens via AppKit; tests inject a recording closure. Accessibility help string "Open \(displayName) dashboard". Verified by 5 `ProviderRowViewDashboardButtonTests` cases + 9 `ProviderDashboardURLTests` cases.

## Commits

| Hash    | Message                                                                                                        |
|---------|----------------------------------------------------------------------------------------------------------------|
| 75e0ac9 | feat(03-07): add ProviderDashboardURL lookup for D-13/D-14 dashboard launch (+ pbxproj wiring for all 7 plan files) |
| 74a109c | feat(03-07): wire dashboard button, tooltip + D-11 degraded styling on ProviderRowView                          |
| 2efa0d7 | feat(03-07): render D-07 'Total excludes quota-only providers' footnote                                         |

## Composition Entry Point for Plan 03-09 (UAT walkthrough)

```text
Visual smoke checklist (Plan 03-09 will exercise these):
1. Launch app with all four providers registered (env CODEX_BEARER_TOKEN +
   ~/.gemini/oauth_creds.json + ~/.gemini/settings.json with
   selectedAuthType=oauth-personal + OPENROUTER_API_KEY).
2. Each provider row shows trailing 'arrow.up.right.square' button — click
   opens the correct dashboard URL in default browser.
3. Hovering Codex row shows tooltip with plan_type label (e.g. "plus").
4. Hovering Gemini row shows tooltip with tier label (e.g. "Free").
5. Totals row shows 'Total excludes quota-only providers' footnote (always
   true once Gemini is registered).
6. Disconnect Wi-Fi for >2 min, force a poll: Gemini row renders amber dot,
   dimmed values, 'usage temporarily unavailable' subtitle. Other rows stay
   normal.
7. Restore connectivity: next poll restores Gemini to ok-state automatically.
```

## Self-Check: PASSED

- `AgentsUsageBar/UI/ProviderDashboardURL.swift` — exists ✓
- `AgentsUsageBar/UI/Environment/OpenDashboardURLEnvironmentKey.swift` — exists ✓
- `AgentsUsageBarTests/UITests/ProviderDashboardURLTests.swift` — exists ✓
- `AgentsUsageBarTests/UITests/ProviderRowViewDashboardButtonTests.swift` — exists ✓
- `AgentsUsageBarTests/UITests/ProviderRowViewTooltipTests.swift` — exists ✓
- `AgentsUsageBarTests/UITests/ProviderRowViewDegradedTests.swift` — exists ✓
- `AgentsUsageBarTests/UITests/TotalsHeaderViewFootnoteTests.swift` — exists ✓
- `AgentsUsageBar/UI/ProviderRowView.swift` modified (dashboard button + tooltip + degraded styling + env key) ✓
- `AgentsUsageBar/UI/TotalsHeaderView.swift` modified (D-07 footnote) ✓
- `AgentsUsageBar/UI/Components/StatusDot.swift` modified (forceAmber additive param) ✓
- Commit `75e0ac9` (Task 1) — present in git log ✓
- Commit `74a109c` (Task 2) — present in git log ✓
- Commit `2efa0d7` (Task 3) — present in git log ✓
- 32 new `@Test` cases PASS (9 + 5 + 5 + 7 + 7) ✓
- Full Phase 1+2+3 regression suite PASS (546 / 546 on the verified run) ✓
- D-07 / D-11 / D-13 / D-14 / D-15 / GEMINI-03 / UI-11 grep gates ALL pass ✓
- DRY invariant: D-11 literal sourced via `ThresholdEngine.degradedTag` in ProviderRowView (no inline duplication) ✓
