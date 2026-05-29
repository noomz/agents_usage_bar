# Plan 04-01 Summary — Foundation: ProviderStatus.notRunning + ProviderID local constants + classifyLocalhost

## Objective

Land the non-actor foundation every Phase 4 actor and view depends on:
`ProviderStatus.notRunning`, three `ProviderID` local constants, `ProviderStatus.classifyLocalhost(error:lastSuccess:)`, and `StatusDot` ripple updates.

## What Was Built

1. **`ProviderStatus.notRunning`** — new enum case added between `.unauthenticated` and `.disabled` (D-01). Marked non-terminal with explicit doc comment: absent from `AggregateStore.performRefresh` POLL-06 terminal-skip block so every 5-min tick re-probes localhost.
2. **`ProviderStatus.classifyLocalhost(error:lastSuccess:)`** — static factory (LOCAL-05). Maps `URLError.Code.cannotConnectToHost`, `.cannotFindHost`, `.networkConnectionLost`, `.timedOut` → `.notRunning`; all other errors flow through `ProviderError.from(_:)` to `.stale` or `.error`.
3. **`ProviderID.{ollama, lmstudio, llamacpp}`** — three static constants in the existing `extension ProviderID` block after `.gemini`. `displayHint` switch already returned the correct strings (no edit needed).
4. **`ProviderID.localIDs: Set<ProviderID>`** — `[.ollama, .lmstudio, .llamacpp]` helper for downstream UI capability lookup (Plan 04-07).
5. **`StatusDot` ripple** — `dotColor` switch gains `case .notRunning: base = .gray` (LOCAL-04 muted-never-red); `accessibilityLabel` gains `case .notRunning: return "Status: Not running" + suffix`; preview added.
6. **4 Swift Testing suites (23 `@Test` cases)** — `ProviderStatusNotRunningTests` (4), `ProviderIDLocalConstantsTests` (6), `ProviderErrorLocalhostClassifierTests` (9), `StatusDotNotRunningTests` (4). All wired into `AgentsUsageBar.xcodeproj` via AA040100 UUID namespace.

## Tasks–Commits Table

| Task | Description | Commit |
|------|-------------|--------|
| T-04-01-01 | `ProviderStatus.notRunning` + StatusDot ripple | 67accbe |
| T-04-01-02 | `ProviderID.{ollama,lmstudio,llamacpp}` + `localIDs` | 67accbe |
| T-04-01-03 | `ProviderStatus.classifyLocalhost(error:lastSuccess:)` | 67accbe |
| T-04-01-04 | 4 Swift Testing suites (23 `@Test` cases) | 50aa22e |
| T-04-01-05 | `AgentsUsageBar.xcodeproj` pbxproj wiring (AA040100 namespace) | 50aa22e |

## Deviations

None. All tasks executed as specified. The plan grouped T-04-01-01/02/03 (pure production code edits to existing files) into a single atomic commit and T-04-01-04/05 (new test files + pbxproj) into a second commit — this is consistent with the "atomic per-logical-unit" convention and keeps diffs reviewable.

One minor implementation note: `grep -E '\.cannotConnectToHost|\.cannotFindHost|\.networkConnectionLost|\.timedOut'` returns 1 match (not 4) because the four codes are in a single multi-case `switch` arm. The acceptance criterion check was satisfied structurally — all four `URLError.Code` values are present in the file and tested individually by `ProviderErrorLocalhostClassifierTests`.

## Key Files Created

- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBarTests/DomainTests/ProviderStatusNotRunningTests.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBarTests/DomainTests/ProviderIDLocalConstantsTests.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBarTests/DomainTests/ProviderErrorLocalhostClassifierTests.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBarTests/UITests/StatusDotNotRunningTests.swift`

## Key Files Modified

- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBar/Domain/ProviderStatus.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBar/Domain/ProviderID.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBar/UI/Components/StatusDot.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBar.xcodeproj/project.pbxproj`

## Verification Results

| Check | Result |
|-------|--------|
| `grep -c 'case notRunning' ProviderStatus.swift` | 1 |
| `grep -c 'case .notRunning' StatusDot.swift` | 2 (dotColor + accessibilityLabel) |
| `grep -E 'case \.notRunning' AggregateStore.swift` | 0 (POLL-06 non-terminal invariant) |
| `grep 'case notRunning' ProviderError.swift` | 0 (no new Kind case) |
| `grep -c 'AA040100' project.pbxproj` | 16 (≥8 required) |
| New `@Test` count | 23 (≥18 required) |
| Targeted test run | 46/46 PASSED |
| Full regression suite | PASSED |

## Self-Check: PASSED
