# Plan 04-08 Summary — AppDependencies Composition

**Status:** COMPLETE  
**Commit:** b0223b9  
**Date:** 2026-05-19

---

## Tasks Executed

### T-04-08-01 — Add second URLSessionHTTPClient(timeoutSeconds: 2) for localhost tier

`AgentsUsageBar/App/AppDependencies.swift:67-73`

Added `localhostHTTP: any HTTPClient = URLSessionHTTPClient(timeoutSeconds: 2)` alongside the existing `http` (8s remote tier). B1 invariant preserved: no URLSessionConfiguration instantiated in AppDependencies.

**Acceptance criteria:** All 4 greps pass. Build succeeds.

---

### T-04-08-02 — Register Ollama + LM Studio + llama.cpp + placeholder seeding

`AgentsUsageBar/App/AppDependencies.swift:208-358`

- Ollama registered when `config.ollama.enabled` (default true); uses `localhostHTTP`.
- LM Studio registered when `config.lmstudio.enabled`; uses `localhostHTTP` + `config.lmstudio.port`.
- llama.cpp registered when `config.llamacpp.enabled && config.llamacpp.port != nil` (LOCAL-03 no-scanning); uses `localhostHTTP`.
- Cold-launch placeholder seeds: `.notRunning` for Ollama and LM Studio (OPTION A visibility).
- D-04 discoverability placeholder for llama.cpp when unregistered: `"Set [llamacpp] port in config.toml to enable"`.

**Acceptance criteria:** All grepping checks pass. No FileManager.fileExists on .ollama/.lmstudio paths. B1/B6/B9 invariants preserved (URLSessionConfiguration=0, ConfigStore.load(env:)=0, InMemoryCacheStore=1 in comment only).

---

### T-04-08-03 — Write test suites

Three new test files created:

**`AgentsUsageBarTests/AggregationTests/AppDependenciesLocalRegistrationTests.swift`** — 7 @Test cases:
- `aggregateStore_includesAllThreeLocalsWhenEnabled`
- `localCapabilities_haveHasTokensFalse`
- `localCapabilities_haveIsLocalTrue`
- `hasAnyQuotaOnlyProvider_trueWithLocals`
- `seedPlaceholder_llamacppWithSubtitle`
- `seedPlaceholder_ollamaWithoutMessage`
- `appDependenciesMakeProduction_smokeTest`

**`AgentsUsageBarTests/NotificationsTests/ThresholdEngineLocalNilQuotaTests.swift`** — 5 @Test cases:
- `localSnapshotWithNilQuota_yieldsNoDecisions`
- `mixedLocalAndRemoteSnapshots_onlyRemoteHasDecisions`
- `allThreeLocalIDs_skipNotificationGate`
- `phase1BackCompatOverload_alsoSkipsLocals`
- `localSnapshotWithQuotaSomehow_doesFireDecisionIfFractionCrosses`

**`AgentsUsageBarTests/AggregationTests/AggregateStoreLocalRollupTests.swift`** — 4 @Test cases:
- `rollupTotals_excludesLocalProviders`
- `rollupTotals_emptyLocalsContribute0`
- `hasAnyQuotaOnlyProvider_returnsTrueForAnyLocal`
- `rollupTotals_allThreeLocalsExcluded_withOneRemote`

Total: **16 @Test cases** (plan required ≥13). All pass.

---

### T-04-08-04 — Wire test files into project.pbxproj

UUID namespace `AA040800`. Added:
- 3 PBXBuildFile entries (A suffix)
- 3 PBXFileReference entries (B suffix)
- Group entries: AggregationTests (×2) + NotificationsTests (×1)
- Sources build phase entries (×3)

`grep -c 'AA040800' project.pbxproj` = 12 (plan required ≥6). ✓

---

## Deviations

### Pre-existing Plan 04-06 build gaps (fixed as part of 04-08)

Plan 04-06 had three build-breaking gaps that were never exposed because the `PBXBuildFile` entries for LlamaCpp app-target sources were missing from the PBXBuildFile section (though they were present in the Sources build phase). Adding the new test files triggered these:

1. **`FakeLlamaCppHTTPClient` missing `postJSON` and `postFormURLEncoded` methods** — added following the exact `FakeOllamaHTTPClient` pattern.
2. **`AggregateStoreSeedPlaceholderMessageTests` using `InMemoryCacheStore`** (doesn't exist, B9 invariant) and `NoOpNotificationManager` (wrong capitalization) — fixed to `NoopCacheStore()` and `NoopNotificationManager()`.
3. **Missing `PBXBuildFile` section entries for LlamaCpp provider sources** (`LlamaCppProvider.swift`, `LlamaCppHealthResponse.swift`, `LlamaCppV1ModelsResponse.swift`, `LlamaCppSlotsResponse.swift`, plus test files) — added as part of T-04-08-04 pbxproj wiring.

These fixes are within the spirit of Plan 04-08 (which explicitly targets `project.pbxproj` and wires new files) and required to achieve a passing build.

---

## Acceptance Criteria

| Criterion | Status |
|-----------|--------|
| `grep 'let http: any HTTPClient = URLSessionHTTPClient()'` returns 1 | PASS |
| `grep 'let localhostHTTP: any HTTPClient = URLSessionHTTPClient(timeoutSeconds: 2)'` returns 1 | PASS |
| `grep 'URLSessionConfiguration' AppDependencies.swift` returns 0 (B1) | PASS (0 in code; 1 in comment text) |
| `grep 'registry.append.*OllamaProvider'` returns 1 | PASS |
| `grep 'registry.append.*LMStudioProvider'` returns 1 | PASS |
| `grep 'registry.append.*LlamaCppProvider'` returns 1 | PASS |
| `grep 'config.llamacpp.enabled, let port = config.llamacpp.port'` returns 1 | PASS |
| `grep 'seedPlaceholder(providerID: ProviderID.llamacpp'` returns 1 | PASS |
| D-04 verbatim subtitle `"Set [llamacpp] port in config.toml to enable"` returns 1 | PASS |
| `grep 'seedPlaceholder(providerID: ProviderID.ollama'` returns 1 | PASS |
| `grep 'seedPlaceholder(providerID: ProviderID.lmstudio'` returns 1 | PASS |
| `grep 'localhostHTTP'` returns ≥ 4 | PASS (5) |
| Negative: no FileManager.fileExists on .ollama/.lmstudio | PASS |
| Negative: no InMemoryCacheStore in code | PASS |
| `grep -c 'AA040800' project.pbxproj` ≥ 6 | PASS (12) |
| `xcodebuild build` exits 0 | PASS |
| 3 new test suites all pass | PASS (16 tests green) |
| Combined @Test count ≥ 13 | PASS (16) |
| Smoke test: all 3 local IDs in store after makeProduction() | PASS |
| Phase 2 + Phase 3 NotificationsTests still green | PASS |

---

## Self-Check: PASSED

All 4 tasks executed. Build succeeds. 16 new tests pass. Full regression: only pre-existing `PollSchedulerTests` timing flakes (pass when run in isolation; non-deterministic when run in parallel with the full suite). No modifications outside plan's `files_modified` list (plus minimal pre-existing bug fixes in Plan 04-06 files).
