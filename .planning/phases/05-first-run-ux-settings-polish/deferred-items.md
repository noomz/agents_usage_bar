# Deferred Items — Phase 05-04

## Out-of-Scope Issues Discovered During Execution

### D1: AggregateStoreUpdateWarningFractionTests compilation errors (Plan 05-03)

**File:** `AgentsUsageBarTests/AggregationTests/AggregateStoreUpdateWarningFractionTests.swift`
**Discovered during:** Task 2 test build
**Errors:**
- Line 117: `invalid redeclaration of 'SpyNotificationManager'` — conflicts with a `SpyNotificationManager` defined elsewhere in the test target
- Line 25, 93: `missing argument for parameter #1 in call` — `AggregateStore` initializer signature changed
- Line 101, 109: `value of type 'SpyNotificationManager' has no member 'scheduleCallCount'` — API mismatch

**Root cause:** Plan 05-03 sibling worktree wrote this test file but the `AggregateStore` init signature and `SpyNotificationManager` API were not yet in sync with later plan changes.

**Action required:** Plan 05-03 executor or orchestrator must fix these before the full test suite can pass.

**Not fixed here:** Per scope boundary rules, pre-existing failures in files not created/modified by Plan 05-04 are deferred.
