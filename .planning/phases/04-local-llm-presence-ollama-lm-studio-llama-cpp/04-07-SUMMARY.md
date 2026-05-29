# Plan 04-07 Summary — UI ProviderRowView local-row branching + LocalRowSecondaryView

## Objective

Branch `ProviderRowView.swift` to render the five D-02/D-03 row states for `isLocal=true`
rows, replacing the `tokens · USD · balance` HStack (meaningless for locals per LOCAL-06)
with a new `LocalRowSecondaryView` helper. The helper reads `raw["modelName"]`,
`raw["modelCount"]`, `raw["vramBytes"]`, `raw["loadingModel"]`, `raw["installedCount"]`
stamped by Plans 04-04 / 04-05 / 04-06, and renders the appropriate secondary-line string.
LOCAL-06 anti-feature enforced at the rendering layer: local rows never reach
`tokenText()` / `usdText()` / `balanceText()`.

## What Was Built

1. **`LocalRowSecondaryView.swift`** — `public struct LocalRowSecondaryView: View`:
   - `internal var secondaryText: String` test seam (pure value accessor)
   - Six row-state branches in priority order:
     - D-04 `placeholderMessage` (highest priority — Plan 04-08 seeds this)
     - State E: `raw["loadingModel"] == "true"` → `"Running — loading model…"`
     - State A: `case .notRunning` → `"Not running"`
     - State B': `count==0 && installedCount==0` → `"Idle — no models installed"`
     - State B: `count==0` → `"Idle — 0 models loaded"`
     - State C: `count==1` → `"<modelName>"` + optional `" · X.X GB VRAM"` suffix
     - State D: `count>1` → `"<modelName> · +N more"`
     - Fallback: `"—"` (defensive, unreachable in practice)
   - VRAM suffix: `Double(vramBytes) / 1_073_741_824.0` formatted `"%.1f GB VRAM"`;
     suppressed when `vramBytes == 0` (OQ-4 CPU-only case)
   - Seven `#Preview` blocks (states A/B/B'/C/D/E + placeholderMessage)
   - LOCAL-06: struct body contains zero token/cost/balance surface

2. **`ProviderRowView.swift`** (modified):
   - `private var isLocal: Bool { ProviderID.localIDs.contains(state.id) }`
   - `if isLocal { LocalRowSecondaryView(state: state).opacity(...) } else { HStack(tokens·USD·bal) }`
   - `.opacity(isStale || isDegraded ? 0.6 : 1.0)` composited on both branches (UI-08 + D-11 preserved)
   - Phase 3 invariants untouched: dashboard button `arrow.up.right.square` (×1), D-11 degraded subtitle
   - Two new `#Preview` blocks: Ollama running single model + Ollama not running

3. **`LocalRowSecondaryViewTests.swift`** — 16 `@Test` cases on `secondaryText` accessor:
   - All six states (A/B/B'/C/D/E) + precedence tests + placeholder + LOCAL-06 leak test
   - `stateC_singleModelWithVRAM`: 5137025024 bytes → `"llama3:8b · 4.8 GB VRAM"` (rounded)
   - `stateC_singleModelZeroVRAM_suppressedSuffix`: zero bytes → no `" · 0.0 GB VRAM"` suffix
   - `stateE_takesPrecedenceOverModelCount`: loadingModel checked before model-count logic
   - `noLocal06Leak_secondaryTextNeverIncludesUSD`: snapshot with `tokensToday=999` +
     `costTodayUSD=99.99` → rendered text contains no `"USD"` / `"$"` / `"tokens"` / `"bal"`
   - `localIDsCarrier_containsOllamaLMStudioLlamacpp`: Plan 04-01 contract regression

4. **`ProviderRowViewLocalRowTests.swift`** — 7 `@Test` cases (source-walk):
   - `providerRowView_referencesLocalRowSecondaryView`: contains `LocalRowSecondaryView`,
     `isLocal`, `ProviderID.localIDs.contains`
   - `providerRowView_branchesOnIsLocal`: `if isLocal {` present + appears before dashboard button
   - `providerRowView_local06AntiFeature_localsNeverReachTokenText`: extracts isLocal=true branch;
     asserts `tokenText(` / `usdText(` / `balanceText(` absent from it (LOCAL-06 gate)
   - `providerRowView_dashboardButtonStillVisibleForLocals`: `arrow.up.right.square` count == 1
   - `providerRowView_d11SubtitlePreservedForNonLocals`: `"Updated"` + `"usage temporarily unavailable"` present
   - `localRowSecondaryView_noLocal06References`: scans struct body (pre-`#Preview` only via
     approach A truncation) for quota/cost call patterns — all clean
   - `localRowSecondaryView_noAppKitImports`: no `NSWorkspace` / `NSAlert`

5. **`project.pbxproj`** — 12 AA040700 UUID entries:
   - 3 PBXBuildFile entries (1 prod + 2 test)
   - 3 PBXFileReference entries
   - 3 group membership entries (Components + UITests ×2)
   - 3 Sources build phase entries (app target + test target ×2)

## Tasks–Commits Table

| Task | Description | Commit |
|------|-------------|--------|
| T-04-07-01 | LocalRowSecondaryView.swift — five-state secondaryText + 7 previews | d4a9d0a |
| T-04-07-02 | ProviderRowView.swift — isLocal branch + 2 Ollama previews | d4a9d0a |
| T-04-07-03 | LocalRowSecondaryViewTests (16 @Test) + ProviderRowViewLocalRowTests (7 @Test) | d4a9d0a |
| T-04-07-04 | project.pbxproj AA040700 wiring (12 entries) | d4a9d0a |

All four tasks committed atomically — production code, tests, and pbxproj wiring
are inseparable for a green build.

## Deviations

**LOCAL-06 negative grep (T-04-07-01 acceptance criterion):** The plan's `grep -E 'tokens|USD|bal\b|costToday|tokensToday|formattingCurrency'` fires on `#Preview` stub lines that pass `tokensToday: nil`, `costTodayUSD: nil`, `balanceUSD: nil` as zero-value placeholders. These are not LOCAL-06 violations (nil assignments carry no financial data). Same documented deviation as Plans 04-04, 04-05, 04-06. The runtime enforcement test `noLocal06Leak_secondaryTextNeverIncludesUSD` (16th @Test case) is the authoritative gate: it passes a snapshot with `tokensToday=999` + `costTodayUSD=99.99` and asserts none of those values appear in `secondaryText`. Passes cleanly.

**`localRowSecondaryView_noLocal06References` source-walk test:** Initial implementation filtered `///` and `//` comment lines but still fired on `#Preview` stub init lines. Fixed using approach A (strip from first `#Preview` marker onward before scanning) — scans only the struct body where `secondaryText` is computed. Equivalent intent; struct body is clean.

## Key Files Created

- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBar/UI/Components/LocalRowSecondaryView.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBarTests/UITests/LocalRowSecondaryViewTests.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBarTests/UITests/ProviderRowViewLocalRowTests.swift`

## Key Files Modified

- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBar/UI/ProviderRowView.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBar.xcodeproj/project.pbxproj`

## Verification Results

| Check | Result |
|-------|--------|
| `grep 'public struct LocalRowSecondaryView'` | 1 match |
| `grep 'internal var secondaryText: String'` | 1 match |
| `grep -cE 'Not running\|Idle — 0 models loaded\|Idle — no models installed\|Running — loading model'` | 5 matches (≥4 required) |
| LOCAL-06 negative grep on struct body (pre-#Preview) | CLEAN — 0 violations |
| `grep -F 'private var isLocal: Bool { ProviderID.localIDs.contains'` | 1 match |
| `grep 'LocalRowSecondaryView' ProviderRowView.swift` | 1 match |
| `grep -F 'if isLocal {'` | 1 match |
| `grep 'degradedTag\|usage-temporarily-unavailable' Providers/Ollama,LMStudio,LlamaCpp` | CLEAN — 0 matches |
| `grep 'arrow.up.right.square' ProviderRowView.swift` | 1 match |
| `grep 'usage temporarily unavailable' ProviderRowView.swift` | 1 match |
| `grep -c 'AA040700' project.pbxproj` | 12 (≥6 required) |
| `xcodebuild build ... Debug` | BUILD SUCCEEDED |
| Targeted: `LocalRowSecondaryViewTests` + `ProviderRowViewLocalRowTests` | 23/23 PASSED |
| Full regression suite | TEST SUCCEEDED (exit 0) |

## Acceptance Criteria

- [x] `grep 'public struct LocalRowSecondaryView'` returns 1
- [x] `grep 'internal var secondaryText: String'` returns 1 (test seam)
- [x] Four state literal strings present (≥4 matches)
- [x] **Negative invariant — LOCAL-06**: struct body (pre-#Preview) contains no quota/cost surface
- [x] **Negative invariant — no AppKit**: no `NSWorkspace` / `NSAlert`
- [x] `grep 'private var isLocal: Bool { ProviderID.localIDs.contains'` returns 1
- [x] `grep 'LocalRowSecondaryView' ProviderRowView.swift` returns ≥1
- [x] `grep 'if isLocal {'` returns 1
- [x] **Negative invariant — local actors do NOT stamp degradedTag**: 0 matches
- [x] **Phase 3 dashboard button preserved**: `arrow.up.right.square` returns 1
- [x] **Phase 3 D-11 degraded subtitle preserved**: `"Updated" + "usage temporarily unavailable"` present
- [x] `xcodebuild build ... Debug` exits 0
- [x] Targeted tests green (23/23 @Test cases)
- [x] Combined @Test count ≥19 (23 total)
- [x] `noLocal06Leak_secondaryTextNeverIncludesUSD` passes (LOCAL-06 runtime gate)
- [x] `providerRowView_local06AntiFeature_localsNeverReachTokenText` passes
- [x] `grep -c 'AA040700' project.pbxproj` returns ≥6 (12 present)
- [x] Full regression TEST SUCCEEDED

## Self-Check: PASSED
