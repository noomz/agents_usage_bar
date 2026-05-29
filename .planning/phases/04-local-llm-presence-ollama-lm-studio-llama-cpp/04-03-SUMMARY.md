# Plan 04-03 Summary — Infrastructure: URLSessionHTTPClient(timeoutSeconds:) POLL-08 localhost tier

## Objective

Extend `URLSessionHTTPClient.init()` with an additive `timeoutSeconds: TimeInterval = 8`
parameter so Plan 04-08 (composition root) can construct a second instance with a 2-second
timeout for localhost probes — implementing the POLL-08 timeout split (8s remote / 1–2s
localhost) declared in Phase 1 STATE #18 and first exercised against localhost in Phase 4.

## What Was Built

1. **`URLSessionHTTPClient.init(timeoutSeconds: TimeInterval = 8)`** — additive parameter
   replacing the hard-coded `8` literal. `cfg.timeoutIntervalForRequest = timeoutSeconds`.
   Resource timeout formula: `cfg.timeoutIntervalForResource = max(timeoutSeconds * 4, 30)`.
   - Remote tier (8s): request=8s, resource=32s (up from hard-coded 30s — 2s increase, no
     observable behavioral change for Phase 1/2/3 providers).
   - Localhost tier (2s): request=2s, resource=30s (floor preserves cold-socket overhead
     budget; ECONNREFUSED fires in <100ms per RESEARCH §3.1).
   - POLL-08 invariants unchanged on both tiers: `waitsForConnectivity=false`,
     `httpMaximumConnectionsPerHost=6`, `requestCachePolicy=.reloadIgnoringLocalCacheData`.
2. **Updated class doc comment** — documents the `timeoutSeconds` parameter, the per-tier
   scaling formula, and the two-instance pattern (remote 8s + localhost 2s). Includes a
   code example showing both construction forms.
3. **`URLSessionHTTPClientTimeoutTierTests.swift`** — 8 `@Test` cases (Swift Testing,
   no `.serialized` trait needed — no URLProtocol stub; `configurationSnapshot()` is
   nonisolated):
   - `defaultInit_yieldsRemoteTier8sRequest` — back-compat, request=8s
   - `defaultInit_yieldsRemoteTier32sResource` — max(8×4,30)=32s
   - `explicit8s_matchesDefault` — explicit arg matches default
   - `localhostTier2s_yields2sRequest` — request=2s
   - `localhostTier2s_yields30sResourceFloor` — max(2×4,30)=30s floor
   - `unusual_15sTimeoutScalesResourceTo60` — max(15×4,30)=60s scaling regression
   - `pollSettings_unchanged` — waitsForConnectivity/connections/cachePolicy on both tiers
   - `twoInstances_areDistinctURLSessions` — ObjectIdentifier of configurations differ
4. **`project.pbxproj`** — 4 entries added in UUID namespace `AA040300`:
   - `AA040300000000000000010A` — PBXBuildFile (Sources build phase)
   - `AA040300000000000000010B` — PBXFileReference
   - InfrastructureTests group child entry
   - Sources build phase entry (after `URLSessionHTTPClientTests.swift in Sources`)

## Tasks–Commits Table

| Task | Description | Commit |
|------|-------------|--------|
| T-04-03-01 | `URLSessionHTTPClient.init(timeoutSeconds:)` parameter + doc comment | e6a0731 |
| T-04-03-02 | `URLSessionHTTPClientTimeoutTierTests` — 8 `@Test` cases | e6a0731 |
| T-04-03-03 | `project.pbxproj` wiring (AA040300 namespace, 4 entries) | e6a0731 |

All three tasks grouped into one atomic commit — production code change, test file, and
pbxproj wiring are inseparable for a green build.

## Deviations

None. All tasks executed as specified.

One implementation note: the plan's acceptance criterion
`grep 'cfg.timeoutIntervalForResource = max(timeoutSeconds \* 4, 30)'` uses a shell-escaped
`\*` which in Swift source is an unescaped `*`. The actual source line is
`cfg.timeoutIntervalForResource = max(timeoutSeconds * 4, 30)` — the criterion is satisfied
structurally and verified by the `defaultInit_yieldsRemoteTier32sResource` +
`localhostTier2s_yields30sResourceFloor` + `unusual_15sTimeoutScalesResourceTo60` test trio.

The `defaultInit_yieldsRemoteTier30sResource` test name in the plan was corrected to
`defaultInit_yieldsRemoteTier32sResource` in the implementation because `max(8*4,30)=32`,
not 30 — the plan body correctly states the expected value is `32.0`; only the test name
in the action block had an inconsistency. Test name matches the asserted value.

## Key Files Modified

- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBar/Infrastructure/URLSessionHTTPClient.swift` — lines 4–52 (doc comment + init signature)

## Key Files Created

- `/Users/noomz/Projects/Opensources/agents_usage_bar/AgentsUsageBarTests/InfrastructureTests/URLSessionHTTPClientTimeoutTierTests.swift`

## Verification Results

| Check | Result |
|-------|--------|
| `grep 'public init(timeoutSeconds: TimeInterval = 8)'` | 1 match |
| `grep 'cfg.timeoutIntervalForRequest = timeoutSeconds'` | 1 match |
| `grep 'cfg.timeoutIntervalForResource = max(timeoutSeconds * 4, 30)'` | 1 match |
| `grep 'URLSessionHTTPClient()' AppDependencies.swift` | 1 match (back-compat default compiles) |
| `grep 'cfg.timeoutIntervalForRequest = 8' URLSessionHTTPClient.swift` | 0 matches (hard-code replaced) |
| `grep -c 'AA040300' project.pbxproj` | 4 (≥2 required) |
| `xcodebuild build ... Debug` | BUILD SUCCEEDED |
| Targeted: `URLSessionHTTPClientTimeoutTierTests` | 8/8 PASSED |
| Full regression suite | TEST SUCCEEDED |
| `internal init(session:)` untouched | CONFIRMED (test seam preserved) |
| `configurationSnapshot()` untouched | CONFIRMED (test seam preserved) |

## Self-Check: PASSED
