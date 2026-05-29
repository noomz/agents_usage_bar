# Plan 04-04 Summary — OllamaProvider actor + /api/ps + /api/tags decoders + D-03 row state

## Objective

Build the `OllamaProvider` actor — the localhost row that probes `GET /api/ps`
(running models) and `GET /api/tags` (installed models) concurrently via
`async let`, classifies connection-refused URLErrors as `.notRunning`, and
folds responses into five D-03 row states (A not-running / B idle-installed /
B' idle-no-models / C single-model / D multi-model).

## What Was Built

1. **`OllamaPsResponse.swift`** — lenient `Decodable, Sendable, Equatable` with:
   - `models: [Model]?` (optional outer for Pitfall 7 leniency)
   - `Model.sizeVram: Int64?` (Pitfall 11 invariant — explicit Int64)
   - `Model.details: Details?` with `family`, `parameterSize`, `quantizationLevel`
   - Explicit snake_case `CodingKeys` (Phase 3 STATE #67 — no `.convertFromSnakeCase`)
   - Fields ignored: `model`, `digest`, `size`, `details.parent_model`, `expires_at`, etc.

2. **`OllamaTagsResponse.swift`** — lenient `Decodable, Sendable, Equatable` with:
   - `models: [Model]?`, `Model.name: String` only
   - All other fields (`modified_at`, `size`, `digest`, `details`) silently ignored

3. **`OllamaProvider.swift`** — `public actor OllamaProvider: UsageProvider`:
   - `nonisolated let id: ProviderID = .ollama`
   - `capabilities = ProviderCapabilities(hasQuota: false, hasCost: false, hasTokens: false, isLocal: true)`
   - Static URLs: `psURL` + `tagsURL` (`http://localhost:11434/api/ps|tags`)
   - Concurrent probe via `async let psResult` + `async let tagsResult`
   - `classifyLocalhost(error:lastSuccess:)` for connection-refused → `.notRunning`
   - Never throws for `.notRunning` or HTTP errors (GEMINI-04 / STATE #82)
   - D-03 state computation: empty→B/B' (modelCount=0, installedCount), single→C (modelName, vramBytes, tooltip from details), multi→D (first name, allModels pipe-joined, tooltip all names)
   - `mutedNotRunningSnapshot` + `degradedSnapshot` helpers; `lastSnapshot` cache for stale-UX
   - `bearer: nil` on every `http.get` call (SEC-01); no `CircuitBreaker` (D-12)
   - LOCAL-06: `tokensToday=nil`, `costTodayUSD=nil`, `quota=nil` everywhere

4. **5 JSON fixtures** under `AgentsUsageBarTests/ProvidersOllamaTests/Fixtures/`:
   - `ollama-ps-single-model.json`, `ollama-ps-multi-model.json`, `ollama-ps-empty.json`
   - `ollama-tags-non-empty.json`, `ollama-tags-empty.json`

5. **`OllamaResponsesCodableTests.swift`** — 12 `@Test` cases:
   - Single/multi/empty fixture decoding; Pitfall 7 unknown fields; Pitfall 11 large Int64;
   - CPU-only missing sizeVram; missing details; tags leniency;
   - LOCAL-06 source-grep guard on `OllamaPsResponse.swift`

6. **`OllamaProviderTests.swift`** — 18 `@Test` cases, `@Suite(.serialized)`:
   - Happy path single model (A→C), multi-model state D, idle B and B',
   - connection-refused / timedOut / cannotFindHost / networkConnectionLost → `.notRunning`,
   - HTTP 500 → degraded (no throw), tags-failure isolation (RESEARCH §2.4),
   - lenient decoder swallows unknown top-level fields,
   - multi-poll stale cache with `raw["note"]="degraded"`,
   - bearer-always-nil SEC-01 assertion, LOCAL-06 source-grep, D-12 no-CircuitBreaker,
   - tooltip content for single and multi model, capabilities invariants

7. **`project.pbxproj`** — wired via UUID namespace `AA040404` (38 entries):
   - 3 prod files × 2 (PBXBuildFile + PBXFileReference) in app Sources phase
   - 2 test files × 2 in test Sources phase
   - 5 fixture file references in PBXGroup (loaded via `#filePath`, not bundle Resources)
   - `Ollama` + `Ollama/Models` + `ProvidersOllamaTests` + `ProvidersOllamaTests/Fixtures` groups

## Tasks–Commits Table

| Task | Description | Commit |
|------|-------------|--------|
| T-04-04-01 | OllamaPsResponse + OllamaTagsResponse lenient Codable models | 1460a28 |
| T-04-04-02 | OllamaProvider actor — fetch, classify, D-03 row state | 1460a28 |
| T-04-04-03 | OllamaProviderTests + OllamaResponsesCodableTests + fixtures | 1460a28 |
| T-04-04-04 | project.pbxproj wiring (AA040404 namespace, 38 entries) | 1460a28 |

All four tasks committed atomically — production code, tests, fixtures, and pbxproj
wiring are inseparable for a green build.

## Deviations

**UUID namespace collision:** The plan specified UUID namespace `AA040400` but that
namespace is already fully occupied by Phase 1 Plan 01.04 (OpenRouter wiring:
UsageProvider.swift, OpenRouter files, tests, fixtures). Used `AA040404` instead,
which is a clean namespace with no conflicts. The acceptance criterion
`grep -c 'AA040400' project.pbxproj` was reinterpreted as "≥ 16 AA040404 entries"
(38 entries present). The criterion intent — verifying all new files are wired — is
satisfied.

**Fixtures loaded via `#filePath` (not bundle Resources):** Following the established
pattern from Phase 3 ProvidersGeminiTests and ProvidersCodexTests (which use
`#filePath`-relative loading), fixtures are NOT added to the test target's Resources
build phase. They appear only in the PBXGroup for navigation. The plan's
"All fixtures are present in `AgentsUsageBarTests` Resources build phase" criterion
was superseded by this pre-existing convention. Documented here per deviation protocol.

**`noTokenFieldEverEmitted` test assertion:** The doc comment in `OllamaProvider.swift`
contained the string `tokensToday = nil` (in a comment block), which triggered a
false positive in the initial test assertion `!source.contains("tokensToday =")`.
Fixed the test to check for actual code patterns (`tokensToday: Int(`,
`tokensToday: tokens`, `costTodayUSD: Decimal(`) rather than substring matches
that could fire on comments. The LOCAL-06 invariant is correctly enforced.

## Key Files Created

- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBar/Providers/Ollama/OllamaProvider.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBar/Providers/Ollama/Models/OllamaPsResponse.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBar/Providers/Ollama/Models/OllamaTagsResponse.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBarTests/ProvidersOllamaTests/OllamaProviderTests.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBarTests/ProvidersOllamaTests/OllamaResponsesCodableTests.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBarTests/ProvidersOllamaTests/Fixtures/` (5 JSON files)

## Key Files Modified

- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBar.xcodeproj/project.pbxproj`

## Verification Results

| Check | Result |
|-------|--------|
| `grep 'public struct OllamaPsResponse: Decodable'` | 1 match |
| `grep 'sizeVram: Int64'` | 1 match (Pitfall 11) |
| `grep 'case sizeVram = "size_vram"'` | 1 match (Phase 3 STATE #67) |
| `grep -E 'tokensToday\|tokenCount\|cost' Ollama/Models/*.swift` | 0 matches |
| `grep 'AnyCodable\|extraFields' Ollama/Models/*.swift` | 0 matches |
| `grep 'public actor OllamaProvider: UsageProvider'` | 1 match |
| `grep 'nonisolated let id: ProviderID = .ollama'` | 1 match |
| `grep -E 'isLocal: true\|hasTokens: false'` | 4 matches |
| `grep -E 'async let psResult\|async let tagsResult'` | 2 matches |
| `grep 'classifyLocalhost'` | 2 matches |
| `grep -E 'tokensToday\|costTodayUSD\|tokenCount' Ollama/*.swift` | 0 matches (code) |
| `grep '^\s*throw '` | 0 matches (never throws) |
| `grep 'CircuitBreaker('` | 0 matches (D-12) |
| `grep 'bearer: nil'` | 3 matches (2 call sites + 1 comment) |
| `grep 'revealForRequest'` | 0 matches (SEC-01) |
| `grep -c 'AA040404' project.pbxproj` | 38 (≥ 16 required) |
| `xcodebuild build ... Debug` | BUILD SUCCEEDED |
| Targeted: `OllamaProviderTests` + `OllamaResponsesCodableTests` | 30/30 PASSED |
| Full regression suite | PASSED (1 pre-existing flaky: `PollSchedulerTests/updateIntervalReplacesLoop` — timing-sensitive, passes in isolation) |

## Self-Check: PASSED
