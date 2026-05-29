---
phase: 02-claude-provider-threshold-rollover-jsonl-streaming
plan: 06
status: complete
commits:
  - 4121cfe feat(02-06): RetryPolicy + CircuitBreaker primitives
  - afc7825 feat(02-06): PowerObserver + per-provider CircuitBreaker + POLL-06 unauthenticated terminal
test_outcome: 320 passed / 0 failed / 1 skipped (pre-existing — disabled FS permission test)
acceptance_criteria_met: true
---

# Plan 02-06 — Energy + Resilience Layer

Plan 02-06 lands the cross-cutting energy + resilience contract that Phase 2
commits to: NSWorkspace sleep/wake observation, per-provider 5-strike circuit
breaker for POLL-05, a Pitfall 5-specific 3-strike breaker for Claude's
`/api/oauth/usage` 429s, and POLL-06 terminal-unauthenticated provider skip.

## Production files added (3)

| Path | LOC | Purpose |
|------|-----|---------|
| `AgentsUsageBar/Infrastructure/RetryPolicy.swift` | 62 | Decorrelated-jitter `Sendable` value type (AWS Architecture Blog formula). Ships **unwired** — POLL-05 backoff between polls is achieved via the breaker's `.open(until:)` cooldown rather than per-fetch jitter sleep. |
| `AgentsUsageBar/Infrastructure/CircuitBreaker.swift` | 97 | Actor-isolated 3-state machine (`.closed` / `.open(until:)` / `.halfOpen`). Default 5-strike / 300s cooldown (POLL-05); overridable for Claude OAuth-usage 3-strike (Pitfall 5). |
| `AgentsUsageBar/Infrastructure/PowerObserver.swift` | 115 | `@MainActor` observer for `NSWorkspace.willSleepNotification` / `didWakeNotification`. Constructor-injectable `NotificationCenter` for test isolation. |

## Production files extended (5)

| Path | Change |
|------|--------|
| `AgentsUsageBar/Domain/ProviderStatus.swift` | Doc-only — POLL-06 terminality paragraph on `.unauthenticated`. No enum-shape change. |
| `AgentsUsageBar/Providers/Claude/ClaudeJSONLProvider.swift` | New `oauthBreaker: CircuitBreaker(threshold: 3, cooldown: 300)`. OAuth `async let` block consults `canAttempt(now:)` before `oauth.getUsage()`; records 429 failures as breaker strikes; non-429 errors do NOT trip the breaker (upstream-side issue). |
| `AgentsUsageBar/Aggregation/AggregateStore.swift` | New `perProviderBreakers: [ProviderID: CircuitBreaker]` map + lazy `breaker(for:)` helper. `performRefresh(now:)` pre-computes gate decisions: POLL-06 terminal-unauth providers contribute no task; POLL-05 open-breaker providers surface a `"circuit-open"` failure result. Success → `recordSuccess`; non-auth/non-payment failure → `recordFailure(now:)`; auth/paymentRequired → breaker untouched (POLL-06 terminal). |
| `AgentsUsageBar/App/AppDependencies.swift` | `Dependencies` adds `powerObserver: PowerObserver` (strong reference, Pitfall 4). `makeProduction()` constructs `PowerObserver(store:, scheduler:, clock:)` after the scheduler. |
| `AgentsUsageBar/App/AgentsUsageBarApp.swift` | `.task` modifier force-realizes `_ = dependencies.powerObserver` before `scheduler.start()` to lock in the willSleep/didWake observers before any wake event. |

## Test files added (5)

| Suite | Cases | What's verified |
|-------|-------|-----------------|
| `RetryPolicyTests` | 5 | Zero-lastDelay floor returns baseDelay; bounded progression (`lastDelay=1 → [1,3]`, `5 → [1,15]`, `30 → [1,60]`); maxDelay cap (`max=10 → [1,10]`); custom baseDelay (`2.5`); Equatable conformance. |
| `CircuitBreakerTests` | 12 | Fresh-closed `canAttempt == true`; success-keeps-closed; 4 failures stay closed; 5th trips to `.open(until: now+300)`; open blocks `canAttempt`; cooldown→`.halfOpen` transition; halfOpen+success→`.closed`; halfOpen+failure re-trips with new cooldown; custom 3-strike threshold; custom 60s cooldown; success after partial failures resets count. |
| `PowerObserverTests` | 4 | `willSleep` notification → `scheduler.stop()`; `didWake` → `store.refresh + scheduler.start()`; direct `handleWake()` invocation drives refresh and survives day-rollover; deinit removes observers (weak-ref `nil` after scope exit; subsequent posts do not crash). |
| `PollSchedulerSleepWakeTests` | 3 | `stop()` cancels in-flight via structured concurrency within 1s; `start()` after `stop()` resumes polling (uses VirtualClock advancing 10s/call to bypass POLL-03 5s coalescing); Pitfall 4 wake-then-immediate-refresh does not lose FSM state. |
| `ClaudeJSONLProviderCircuitBreakerTests` | 5 | 3 × 429 trips → 4th fetch skips OAuth; 5 × 500 does NOT trip the 429-specific breaker; success between 429s resets the count (`2 × 429 + success + 1 × 429 = 4 oauth calls`); halfOpen after cooldown allows one trial (clock+305s); JSONL collection still populates `tokensToday=600` even when OAuth breaker is open. |

## Acceptance criteria — verification

| Criterion | Result |
|-----------|--------|
| Full `xcodebuild test` exits 0 | **PASS** — 320 cases pass / 0 fail / 1 pre-existing skip (`fetch_jsonlFanOutError_setsErrorStatus_andRethrows` — disabled FS permission test from Plan 02-04). |
| `grep -RIn 'lastDelay \* 3' RetryPolicy.swift` | **PASS** — matches at line 53. |
| `grep -c 'case closed\|case open\|case halfOpen' CircuitBreaker.swift` | **PASS** — 3 cases. |
| `grep -RIn 'threshold: Int = 5\|cooldown: TimeInterval = 300' CircuitBreaker.swift` | **PASS** — `public init(threshold: Int = 5, cooldown: TimeInterval = 300)`. |
| `grep -RIn 'POLL-05' CircuitBreaker.swift` | **PASS** — 2 occurrences (header + threshold doc). |
| `grep -RIn 'willSleepNotification\|didWakeNotification' PowerObserver.swift` | **PASS** — 6 lines (3 each — observer registration + doc). |
| `grep -RIn 'CircuitBreaker(threshold: 3' ClaudeJSONLProvider.swift` | **PASS** — matches at `oauthBreaker` declaration. |
| `grep -RIn 'case .unauthenticated' AggregateStore.swift` + `POLL-06` | **PASS** — POLL-06 guard at line 171 + multiple POLL-06 doc references. |
| `grep -RIn 'perProviderBreakers' AggregateStore.swift` | **PASS** — declaration + helper accesses. |
| `grep -RIn 'PowerObserver(store: store, scheduler: scheduler' AppDependencies.swift` | **PASS** — matches at line 202. |
| `! grep 'import Combine' PowerObserver.swift` | **PASS** — pure structured concurrency. |
| `! grep 'DispatchQueue\.main\.async' PowerObserver/ClaudeJSONLProvider/AggregateStore` | **PASS** — none. |
| `revealForRequest()` call-site count | **PASS** — single sanctioned call site in `URLSessionHTTPClient.swift:122` (other matches are doc comments). |

## Bug fixes applied during execution

1. **PowerObserver deinit + Swift 6 strict concurrency.** First compile failed with `cannot access property 'sleepToken' with a non-Sendable type '(any NSObjectProtocol)?' from nonisolated deinit`. **Root cause:** Swift 6 strict concurrency forbids accessing non-Sendable stored properties from a nonisolated `deinit`. **Fix:** Annotated `notificationCenter` + `sleepToken` + `wakeToken` as `nonisolated(unsafe)` — safe because tokens are written exactly once in `init` (on the main actor), then read solely by deinit; `NotificationCenter.removeObserver(_:)` is thread-safe and callable from any isolation context.

2. **`PollSchedulerSleepWakeTests/scheduler_start_after_stop_resumes_polling` flake.** First run failed: `(countAfterResume → 1) >= (countAfterStart + 1 → 2)`. **Root cause:** The test used `SystemClock`, and the 2nd `start()` happened < 5s after the 1st refresh — POLL-03's 5s debounce in `AggregateStore.refresh(now:)` skipped the 2nd refresh. **Fix:** Switched to a `VirtualClock` that advances 10s per `now()` call (mirroring `PollSchedulerTests/updateIntervalReplacesLoop`), guaranteeing the 2nd refresh bypasses the debounce window. Test now passes deterministically.

## Threat model — disposition

All four documented threats (T-02.06-01 through T-02.06-04) ship per their plan
disposition. Notably:
- T-02.06-02 (persistent 429 trips breaker for 5 min) is the **intended**
  Pitfall 5 behavior — the 5 min cooldown is short enough to recover from
  transient blips and long enough to back off truly persistent rate limits.
- T-02.06-04 (PowerObserver log info-disclosure): all `logger.notice` strings
  carry only category labels (`"sleep — pausing scheduler"`, `"wake — refreshing"`,
  `"oauth circuit breaker open — degrading to local-only"`); no provider
  response data, no credentials.

## Out-of-scope / deferred

- **RetryPolicy production consumer:** None this plan — POLL-05 backoff between
  polls is achieved via the breaker's `.open(until:)` cooldown. The full
  per-fetch retry-with-jitter delay loop would block one poll cycle on a single
  slow provider for up to a minute of jitter sleep, which is the wrong shape for
  Phase 2's polling cadence. RetryPolicy is available as an unwired primitive
  for Plan 02-07 UAT validation or a future polish pass.
- **POLL-09 Energy Impact ("Low" after 1h idle on battery):** Manual UAT step,
  deferred to Plan 02-07 (Instruments-based verification on M-series Mac).

## Pointers for Plan 02-07 UAT

- **PowerObserver constructor** lives at
  `AgentsUsageBar/Infrastructure/PowerObserver.swift:46`. Verify wired in
  `AppDependencies.makeProduction()` step 12 + force-realized in
  `AgentsUsageBarApp.task`.
- **`AggregateStore.perProviderBreakers`** map lives at
  `AgentsUsageBar/Aggregation/AggregateStore.swift:60`; the `breaker(for:)`
  helper at line 232. UAT script can inspect breaker state via tests by
  constructing the store with the test's own `CircuitBreaker(...)` instances if
  needed — production code does not currently expose the map.
- **Manual sleep/wake smoke:** Run `pmset sleepnow` (or close lid on laptop)
  while the app is running. Inspect Console.app for the
  `app.agents-usage-bar / power` category and confirm "sleep — pausing
  scheduler" + "wake — refreshing" entries flank the sleep cycle.
- **Energy log:** Open Activity Monitor → Energy tab while the app is idle on
  battery for ≥1h. The "Energy Impact" column for "AgentsUsageBar" should read
  "Low" or "Very Low".
