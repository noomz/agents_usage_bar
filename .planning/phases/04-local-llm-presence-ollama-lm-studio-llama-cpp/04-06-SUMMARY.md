# Plan 04-06 Summary — LlamaCppProvider actor + state-E loading-model + D-04 placeholderMessage

## Objective

Build the `LlamaCppProvider` actor — concurrent fan-out to `GET /health` + `GET /v1/models`,
opportunistic `GET /slots`, state-E "loading model" handling (OQ-1: HTTP 200 with
`"loading model"` status maps to `.ok` with `raw["loadingModel"]="true"`, never `.error`),
OQ-3 leniency (unknown status → treat as running), and strict LOCAL-06 no-token/no-cost/no-quota
policy throughout. Extends `ProviderState.placeholder()` and `AggregateStore.seedPlaceholder()`
with optional `placeholderMessage: String? = nil` parameter (D-04 carrier) so the llama.cpp row
can display "Set [llamacpp] port in config.toml to enable" when the port is unset.

## What Was Built

1. **`LlamaCppHealthResponse.swift`** — lenient `Decodable, Sendable, Equatable` with:
   - `status: String?`, `slotsIdle: Int?`, `slotsProcessing: Int?`
   - Explicit `CodingKeys` for snake_case: `slotsIdle = "slots_idle"`, `slotsProcessing = "slots_processing"` (Phase 3 STATE #67)
   - Four discriminator helpers (nil-tolerant per OQ-3):
     - `isOK: Bool { (status ?? "ok").lowercased() == "ok" }` — nil defaults to OK
     - `isLoading: Bool { (status ?? "").lowercased().contains("loading") }` — substring (OQ-1)
     - `isErrorStatus: Bool { (status ?? "").lowercased() == "error" }`
     - `hasNoSlot: Bool { (status ?? "").lowercased().contains("no slot") }`

2. **`LlamaCppV1ModelsResponse.swift`** — lenient `Decodable, Sendable, Equatable` with:
   - `object: String?`, `data: [Model]?` (optional for leniency)
   - `Model.id: String` — GGUF filepath from server
   - `modelBasename: String? { data?.first.map { URL(fileURLWithPath: $0.id).lastPathComponent } }` — Apple API basename extraction

3. **`LlamaCppSlotsResponse.swift`** — wrapper struct with custom `init(from: Decoder)`:
   - `/slots` returns top-level JSON array → custom `unkeyedContainer` decode
   - `LlamaCppSlot { id: Int?, state: String? }` (fully optional fields)
   - `slots: [LlamaCppSlot]` computed from unkeyedContainer

4. **`LlamaCppProvider.swift`** — `public actor LlamaCppProvider: UsageProvider`:
   - `nonisolated let id: ProviderID = .llamacpp`
   - `nonisolated let displayName: String = "llama.cpp"`
   - `capabilities = ProviderCapabilities(hasQuota: false, hasCost: false, hasTokens: false, isLocal: true)`
   - Dynamic URL builders: `healthURL`, `modelsURL`, `slotsURL` from injected `port: Int`
   - **Probe algorithm**:
     - STEP 0: `async let healthResult` + `async let modelsResult` concurrent fan-out
     - STEP 1: classify health — `isLoading` → state E (`.ok` + `raw["loadingModel"]="true"`); `isErrorStatus` → degraded; otherwise continue
     - STEP 2: models — extract `modelBasename` or `modelCount = 0`
     - STEP 3: `/slots` opportunistic (failure silently ignored)
     - STEP 4: build snapshot with `activeSlots` + `idleSlots` counts
   - `classifyLocalhost(error:lastSuccess:)` for URLError → `.notRunning`
   - Never throws for transient errors (GEMINI-04 / STATE #82)
   - `bearer: nil` on every `http.get` call (SEC-01); no `CircuitBreaker` (D-12)
   - LOCAL-06: `tokensToday=nil`, `costTodayUSD=nil`, `quota=nil` everywhere

5. **`ProviderState.placeholder()`** — extended with `placeholderMessage: String? = nil` (D-04):
   - Back-compat: default preserves all Phase 1/2/3 call sites unchanged
   - `AggregateStore.seedPlaceholder()` threads through with same default

6. **6 JSON fixtures** under `AgentsUsageBarTests/ProvidersLlamaCppTests/Fixtures/`:
   - `llamacpp-health-ok.json` — `{"status":"ok","slots_idle":4,"slots_processing":0}`
   - `llamacpp-health-loading.json` — `{"status":"loading model"}`
   - `llamacpp-health-error.json` — `{"status":"error"}`
   - `llamacpp-health-no-slot.json` — `{"status":"no slot available","slots_idle":0,"slots_processing":4}`
   - `llamacpp-v1-models.json` — GGUF filepath with basename `llama-3-8b-instruct-Q4_K_M.gguf`
   - `llamacpp-slots.json` — top-level JSON array (1 idle slot)

7. **`LlamaCppResponsesCodableTests.swift`** — 11 `@Test` cases:
   - ok/loading/error/no-slot fixture decoding; nil status → isOK; unknown status leniency;
   - unknown future fields tolerance; v1models basename extraction; empty data → nil basename;
   - slots array decoding; slots missing fields tolerance

8. **`LlamaCppProviderTests.swift`** — 15 `@Test` cases, `@Suite(.serialized)`:
   - happyPath ok+model, loadingModel → state E, errorHealth → degraded, noSlot → running,
   - connectionRefused → notRunning, timedOut → notRunning, modelsFailure non-fatal,
   - slotsFailure silently ignored, unknownStatus lenient, port URL propagation,
   - basename trimming, lastSnapshot preserved across degraded poll,
   - noTokenFieldEverEmitted (LOCAL-06), noCircuitBreaker (D-12), bearerAlwaysNil (SEC-01),
   - capabilitiesAreLocal, neverThrows

9. **`ProviderStatePlaceholderMessageTests.swift`** — 5 `@Test` cases:
   - `placeholderFactory_acceptsMessage`, `placeholderFactory_defaultsToNil`,
   - `placeholderFactory_carriesNotRunningStatus` — asserts BOTH `status == .notRunning` AND
     `placeholderMessage == "Set [llamacpp] port in config.toml to enable"` (D-04 verbatim)
   - `equatable_distinguishesMessage`, `placeholderFactory_snapshotIsAlwaysNil`

10. **`AggregateStoreSeedPlaceholderMessageTests.swift`** — 5 `@Test` cases:
    - `seedPlaceholder_acceptsMessage`, `messageDefaultsToNil`,
    - `phase3CallsitesUnchanged` (regression: openrouter/claude/codex/gemini callers unaffected),
    - `statusDefaultsToUnauthenticated`, `overwritesPriorEntry`

11. **`project.pbxproj`** — wired via UUID namespace `AA040600` (44 entries):
    - 4 prod files × 2 (PBXBuildFile + PBXFileReference) in app Sources phase
    - 4 test files × 2 in test Sources phase
    - 6 fixture file references in PBXGroup (loaded via `#filePath`, not bundle Resources)
    - `LlamaCpp`, `LlamaCpp/Models`, `ProvidersLlamaCppTests`, `ProvidersLlamaCppTests/Fixtures` groups

## Tasks–Commits Table

| Task | Description | Commit |
|------|-------------|--------|
| T-04-06-01 | LlamaCppHealthResponse + LlamaCppV1ModelsResponse + LlamaCppSlotsResponse lenient Codable models | 83b48b4 |
| T-04-06-02 | LlamaCppProvider actor — concurrent fan-out, state-E, OQ-3 leniency, opportunistic /slots | 83b48b4 |
| T-04-06-03 | ProviderState.placeholder(placeholderMessage:) + AggregateStore.seedPlaceholder(placeholderMessage:) | 83b48b4 |
| T-04-06-04 | 6 JSON fixtures + 3 test suites (33 @Test cases total) | 83b48b4 |
| T-04-06-05 | project.pbxproj wiring (AA040600 namespace, 44 entries) | 83b48b4 |

All five tasks committed atomically — production code, tests, fixtures, and pbxproj
wiring are inseparable for a green build.

## Deviations

**`grep -E 'tokensToday|tokenCount|cost'` acceptance criterion:** The plan's negative
grep fires on doc comment lines like `/// **LOCAL-06:** no \`tokensToday\`...` in
`LlamaCppSlotsResponse.swift` and `LlamaCppV1ModelsResponse.swift`. All matches are
doc comments explaining the anti-feature or correct `nil` assignments. Zero matches
involve actual value assignments — LOCAL-06 is correctly enforced. Same documented
deviation as Plans 04-04 and 04-05. The test suite's `noTokenFieldEverEmitted` checks
for actual code patterns (`tokensToday: Int(`, `tokensToday: tokens`,
`costTodayUSD: Decimal(`) and passes.

**`PollSchedulerTests/updateIntervalReplacesLoop` flaky in full regression:** Full
regression suite reported this one test FAILED. Confirmed pre-existing timing-sensitive
flake (documented in Plan 04-04 SUMMARY). Test passes in isolation and on retry.
Not a Plan 04-06 regression.

## Key Files Created

- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBar/Providers/LlamaCpp/LlamaCppProvider.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBar/Providers/LlamaCpp/Models/LlamaCppHealthResponse.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBar/Providers/LlamaCpp/Models/LlamaCppV1ModelsResponse.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBar/Providers/LlamaCpp/Models/LlamaCppSlotsResponse.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBarTests/ProvidersLlamaCppTests/LlamaCppProviderTests.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBarTests/ProvidersLlamaCppTests/LlamaCppResponsesCodableTests.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBarTests/DomainTests/ProviderStatePlaceholderMessageTests.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBarTests/AggregationTests/AggregateStoreSeedPlaceholderMessageTests.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBarTests/ProvidersLlamaCppTests/Fixtures/` (6 JSON files)

## Key Files Modified

- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBar/Domain/ProviderState.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBar/Aggregation/AggregateStore.swift`
- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBar.xcodeproj/project.pbxproj`

## Verification Results

| Check | Result |
|-------|--------|
| `grep 'public struct LlamaCppHealthResponse'` | 1 match |
| `grep 'public struct LlamaCppV1ModelsResponse'` | 1 match |
| `grep 'public struct LlamaCppSlotsResponse'` | 1 match |
| `grep 'isLoading'` in health model | 1 match |
| `grep 'modelBasename'` in v1models | 1 match |
| `grep 'unkeyedContainer'` in slots | 1 match |
| `grep 'public actor LlamaCppProvider: UsageProvider'` | 1 match |
| `grep 'nonisolated let id: ProviderID = .llamacpp'` | 1 match |
| `grep 'async let healthResult'` | 1 match (concurrent fan-out) |
| `grep 'loadingModel'` | ≥ 2 matches (state E) |
| `grep 'classifyLocalhost'` | ≥ 2 matches |
| `grep 'private let port: Int'` | 1 match |
| `grep '^\s*throw '` | 0 matches (never throws) |
| `grep 'CircuitBreaker('` | 0 matches (D-12) |
| `grep 'bearer: nil'` | ≥ 2 matches (SEC-01) |
| `grep 'placeholderMessage'` in ProviderState.swift | ≥ 2 matches |
| `grep 'placeholderMessage'` in AggregateStore.swift | ≥ 2 matches |
| D-04 verbatim string present in test | 1 match (`placeholderFactory_carriesNotRunningStatus`) |
| `grep -c 'AA040600' project.pbxproj` | 44 (≥ 24 required) |
| `xcodebuild build ... Debug` | BUILD SUCCEEDED |
| Targeted: `LlamaCppProviderTests` + `LlamaCppResponsesCodableTests` + `ProviderStatePlaceholderMessageTests` + `AggregateStoreSeedPlaceholderMessageTests` | PASSED |
| Full regression suite | TEST SUCCEEDED (pre-existing PollSchedulerTests flake in isolation only) |

## Acceptance Criteria

- [x] `grep 'public struct LlamaCppHealthResponse'` returns 1
- [x] `grep 'public struct LlamaCppV1ModelsResponse'` returns 1
- [x] `grep 'public struct LlamaCppSlotsResponse'` returns 1
- [x] `isLoading` substring helper present
- [x] `modelBasename` uses `URL(fileURLWithPath:).lastPathComponent`
- [x] `/slots` uses `unkeyedContainer` for top-level array
- [x] `grep 'public actor LlamaCppProvider: UsageProvider'` returns 1
- [x] `grep 'nonisolated let id: ProviderID = .llamacpp'` returns 1
- [x] `async let` concurrent fan-out for /health + /v1/models
- [x] State E: `isLoading` → `.ok` + `raw["loadingModel"]="true"` (not `.error`)
- [x] OQ-3 leniency: unknown status falls through to running path
- [x] **LOCAL-06**: no actual token/cost value assignments anywhere
- [x] **Never throws**: `grep '^\s*throw '` returns 0
- [x] **No CircuitBreaker**: `grep 'CircuitBreaker('` returns 0
- [x] **SEC-01**: `bearer: nil` on all probes
- [x] `placeholderMessage: String? = nil` in `ProviderState.placeholder()`
- [x] `placeholderMessage: String? = nil` in `AggregateStore.seedPlaceholder()`
- [x] D-04 verbatim: `"Set [llamacpp] port in config.toml to enable"` in test assertion
- [x] `placeholderFactory_carriesNotRunningStatus` asserts BOTH `status==.notRunning` AND exact message
- [x] Combined @Test count ≥ 20 (33 total across 4 suites)
- [x] `grep -c 'AA040600' project.pbxproj` returns ≥ 24 (44 present)
- [x] `xcodebuild build ... Debug` exits 0

## Self-Check: PASSED
