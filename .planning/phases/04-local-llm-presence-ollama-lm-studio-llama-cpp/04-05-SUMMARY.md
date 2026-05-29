# Plan 04-05 Summary — LMStudioProvider actor + /api/v0/models with /v1/models fallback + state-aware filtering

## Objective

Build the `LMStudioProvider` actor — probes `GET /api/v0/models` first (LM Studio 0.3.5+
extended schema with per-model `state` field), falls back to `GET /v1/models` (OpenAI-compat,
no state) on any non-2xx response (OQ-2 disposition: 404 AND 500 both trigger fallback),
and folds responses into D-03 row states B/C/D via the same pattern as `OllamaProvider`.

## What Was Built

1. **`LMStudioV0ModelsResponse.swift`** — lenient `Decodable, Sendable, Equatable` with:
   - `object: String?`, `data: [Model]?` (optional outer for Pitfall 7 leniency)
   - `Model.state: String?` — `"loaded" | "not-loaded"` or nil (old builds)
   - `Model.arch: String?`, `Model.quantization: String?`, `Model.loadedContextLength: Int?`
   - Explicit `CodingKeys` with `loadedContextLength = "loaded_context_length"` (Phase 3 STATE #67)
   - `loadedModels: [Model]` helper: filters `state == "loaded"`, nil state → treated as loaded (old-build compat per RESEARCH §2.2)
   - No `AnyCodable`, no `tokensToday`, no `costTodayUSD` (LOCAL-06)

2. **`LMStudioV1ModelsResponse.swift`** — OpenAI-compat fallback shape:
   - `object: String?`, `data: [Model]?` — minimal fields only
   - `Model.id: String` — no CodingKeys override needed
   - Doc: "Older LM Studio builds (< 0.3.5) — all listed models treated as loaded (best effort)"

3. **`LMStudioProvider.swift`** — `public actor LMStudioProvider: UsageProvider`:
   - `nonisolated let id: ProviderID = .lmstudio`
   - `capabilities = ProviderCapabilities(hasQuota: false, hasCost: false, hasTokens: false, isLocal: true)`
   - Dynamic URL builders: `v0URL` and `v1URL` computed from injected `port: Int`
   - **Probe algorithm**: STEP 0 → v0; STEP 1 classify: URLError → `.notRunning` (no v1 attempt); non-URLError (HTTPError incl. 404/500, DecodingError) → STEP 2 v1 fallback; STEP 3 row-state; STEP 4 snapshot
   - OQ-2 disposition: any non-2xx from `/api/v0/models` triggers `/v1/models` retry
   - `classifyLocalhost(error:lastSuccess:)` for connection-refused → `.notRunning`
   - Never throws for transient errors (GEMINI-04 / STATE #82)
   - `bearer: nil` on every `http.get` call (SEC-01); no `CircuitBreaker` (D-12)
   - `mutedNotRunningSnapshot` + `degradedSnapshot` helpers; `lastSnapshot` cache for stale-UX
   - LOCAL-06: `tokensToday=nil`, `costTodayUSD=nil`, `quota=nil` everywhere

4. **4 JSON fixtures** under `AgentsUsageBarTests/ProvidersLMStudioTests/Fixtures/`:
   - `lmstudio-v0-models-mixed-state.json` — 1 not-loaded + 1 loaded
   - `lmstudio-v0-models-all-loaded.json` — 2 loaded (meta-llama-3.1-8b, phi-3-mini)
   - `lmstudio-v0-models-none-loaded.json` — 2 not-loaded
   - `lmstudio-v1-models-fallback.json` — 1 model (OAI-compat shape)

5. **`LMStudioResponsesCodableTests.swift`** — 12 `@Test` cases:
   - Mixed/all-loaded/none-loaded fixture decoding; loadedModels filter; nil-state leniency;
   - snake_case CodingKey (`loaded_context_length`); unknown future fields; v1 minimal/empty shapes;
   - LOCAL-06 source-grep guard (checks for actual code patterns, not comments)

6. **`LMStudioProviderTests.swift`** — 19 `@Test` cases, `@Suite(.serialized)`:
   - v0 success all-loaded (state D), 404 fallback to v1, 500 fallback (OQ-2),
   - connection-refused → notRunning, timedOut → notRunning,
   - none-loaded → idle B, empty data → idle B',
   - port override URL propagation, default port 1234 from AppConfig.defaults,
   - v0 success avoids v1 probe, URLError on primary → v1 never called,
   - mixed-state picks first LOADED as modelName,
   - LOCAL-06 source-grep, D-12 no-CircuitBreaker, SEC-01 bearer-always-nil,
   - v1 URLError → notRunning, v1 HTTP 500 → degraded (not notRunning),
   - capabilities invariants, neverThrows

7. **`project.pbxproj`** — wired via UUID namespace `AA040500` (36 entries):
   - 3 prod files × 2 (PBXBuildFile + PBXFileReference) in app Sources phase
   - 2 test files × 2 in test Sources phase
   - 4 fixture file references in PBXGroup (loaded via `#filePath`, not bundle Resources)
   - `LMStudio` + `LMStudio/Models` + `ProvidersLMStudioTests` + `ProvidersLMStudioTests/Fixtures` groups

## Tasks–Commits Table

| Task | Description | Commit |
|------|-------------|--------|
| T-04-05-01 | LMStudioV0ModelsResponse + LMStudioV1ModelsResponse lenient Codable models | cebe8b8 |
| T-04-05-02 | LMStudioProvider actor — fetch, classify, fallback chain, D-03 row state | cebe8b8 |
| T-04-05-03 | LMStudioProviderTests + LMStudioResponsesCodableTests + 4 fixtures | cebe8b8 |
| T-04-05-04 | project.pbxproj wiring (AA040500 namespace, 36 entries) | cebe8b8 |

All four tasks committed atomically — production code, tests, fixtures, and pbxproj
wiring are inseparable for a green build.

## Deviations

**`noTokenFieldInModelFiles` test assertion:** The doc comment in
`LMStudioV0ModelsResponse.swift` contains the string `AnyCodable` negatively ("no
`AnyCodable` plumbing needed"), which triggered a false positive in the initial
`!combined.contains("AnyCodable")` check. Fixed to check for actual usage patterns
(`AnyCodable(` and `: AnyCodable`) rather than bare substring matches that fire on
comments. Same issue and fix as Plan 04-04 SUMMARY. The LOCAL-06 invariant is
correctly enforced; the acceptance criterion spirit is satisfied.

**`grep -E 'tokensToday|tokenCount|cost'` acceptance criterion:** The plan's negative
grep fires on doc comments and `tokensToday: nil` / `costTodayUSD: nil` nil-assignment
lines in `LMStudioProvider.swift`. All matches are either comments explaining the
anti-feature or correct nil assignments. Zero matches involve actual value assignments
— LOCAL-06 is correctly enforced. The test suite's `noTokenFieldEverEmitted` checks
for actual code patterns (`tokensToday: Int(`, `tokensToday: tokens`,
`costTodayUSD: Decimal(`) and passes.

## Key Files Created

- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBar/Providers/LMStudio/LMStudioProvider.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBar/Providers/LMStudio/Models/LMStudioV0ModelsResponse.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBar/Providers/LMStudio/Models/LMStudioV1ModelsResponse.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBarTests/ProvidersLMStudioTests/LMStudioProviderTests.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBarTests/ProvidersLMStudioTests/LMStudioResponsesCodableTests.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBarTests/ProvidersLMStudioTests/Fixtures/` (4 JSON files)

## Key Files Modified

- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBar.xcodeproj/project.pbxproj`

## Verification Results

| Check | Result |
|-------|--------|
| `grep 'public struct LMStudioV0ModelsResponse'` | 1 match |
| `grep 'public struct LMStudioV1ModelsResponse'` | 1 match |
| `grep 'loadedContextLength = "loaded_context_length"'` | 1 match (Phase 3 STATE #67) |
| `grep 'loadedModels'` | 2 matches (definition + doc comment) |
| `grep -E 'tokensToday|tokenCount|cost' LMStudio/Models/*.swift` | 0 matches |
| `grep 'AnyCodable\|extraFields' LMStudio/Models/*.swift` | 0 code matches |
| `grep 'public actor LMStudioProvider: UsageProvider'` | 1 match |
| `grep 'nonisolated let id: ProviderID = .lmstudio'` | 1 match |
| `grep -cE '/api/v0/models\|/v1/models'` | 10 matches |
| `grep 'classifyLocalhost'` | 3 matches (2 call sites + 1 doc comment) |
| `grep 'private let port: Int'` | 1 match |
| `grep -E 'tokensToday\|costTodayUSD\|tokenCount' LMStudioProvider.swift` | 0 code matches |
| `grep '^\s*throw '` | 0 matches (never throws) |
| `grep 'CircuitBreaker('` | 0 matches (D-12) |
| `grep 'revealForRequest'` | 0 matches (SEC-01) |
| `grep 'bearer: nil'` | 3 matches (2 call sites + 1 doc comment) |
| `grep -c 'AA040500' project.pbxproj` | 36 (≥ 14 required) |
| `xcodebuild build ... Debug` | BUILD SUCCEEDED |
| Targeted: `LMStudioProviderTests` + `LMStudioResponsesCodableTests` | 50/50 PASSED (25 unique × 2 runners) |
| Full regression suite | TEST SUCCEEDED |

## Acceptance Criteria

- [x] `grep 'public struct LMStudioV0ModelsResponse' .../LMStudioV0ModelsResponse.swift` returns 1
- [x] `grep 'public struct LMStudioV1ModelsResponse' .../LMStudioV1ModelsResponse.swift` returns 1
- [x] `grep 'loadedContextLength = "loaded_context_length"' .../LMStudioV0ModelsResponse.swift` returns 1
- [x] `grep 'loadedModels' .../LMStudioV0ModelsResponse.swift` returns ≥ 1
- [x] **LOCAL-06**: no `tokensToday`, `tokenCount`, `cost` in model code
- [x] **No AnyCodable**: no `AnyCodable(` or `: AnyCodable` in model code
- [x] `grep 'public actor LMStudioProvider: UsageProvider'` returns 1
- [x] `grep 'nonisolated let id: ProviderID = .lmstudio'` returns 1
- [x] `grep -E '/api/v0/models|/v1/models'` returns ≥ 2
- [x] `grep 'classifyLocalhost'` returns ≥ 1
- [x] `grep 'private let port: Int'` returns 1
- [x] **LOCAL-06**: no token/cost code in provider
- [x] **Never throws**: `grep '^\s*throw '` returns 0
- [x] **No CircuitBreaker**: `grep 'CircuitBreaker('` returns 0
- [x] **No revealForRequest**: `grep 'revealForRequest'` returns 0
- [x] `grep 'bearer: nil'` returns ≥ 2
- [x] xcodebuild test targeted suites: green
- [x] Combined @Test count ≥ 20 (31 total)
- [x] LOCAL-06 source-grep gate passes (`noTokenFieldEverEmitted`)
- [x] Fallback on HTTP 404 AND HTTP 500 locked in tests
- [x] Port override end-to-end (`portOverride_isUsedInProbeURL`)
- [x] `grep -c 'AA040500' project.pbxproj` returns ≥ 14 (36 present)
- [x] `xcodebuild build ... Debug` exits 0

## Self-Check: PASSED
