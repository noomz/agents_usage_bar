---
phase: 02-claude-provider-threshold-rollover-jsonl-streaming
plan: 05
subsystem: notifications
tags: [threshold-fsm, snooze, unnotificationcategory, userdefaults-persistence, coalesced-ids]
dependency_graph:
  requires: [02-04]
  provides: [threshold-fsm-v2, notif-state-store, snooze-action-handler, app-category-registration]
  affects: [AggregateStore, AgentsUsageBarApp, AppDependencies, ThresholdEngine, NotificationManager, ThresholdState]
tech_stack:
  added:
    - ThresholdBand Comparable conformance (rank-ordered FSM)
    - NotificationStateStore protocol + UserDefaults + InMemory implementations
    - NotificationActionHandler (UNUserNotificationCenterDelegate)
    - UNNotificationManager.registerCategories(on:) static
    - AggregateStore.snoozeToday / snoozeAllToday
  patterns:
    - Phase 1 back-compat overload preserved — internal delegation to FSM-aware method
    - Per-(provider, day) UserDefaults key format `notif.<rawValue>.<yyyy-MM-dd>` with 7-day prune
    - Coalesced ID format extends to 3 bands via `max(decisions.band)` + bandSuffix lookup
    - Snooze "today" suppresses ALL bands (default decision #2 — not only the snoozed band)
    - Category registration in App.init() BEFORE delegate install in `.task` (Pitfall 6)
key_files:
  created:
    - AgentsUsageBar/Notifications/NotificationStateStore.swift
    - AgentsUsageBar/Notifications/NotificationActionHandler.swift
    - AgentsUsageBarTests/NotificationsTests/ThresholdEngineFSMTests.swift
    - AgentsUsageBarTests/NotificationsTests/NotificationStateStoreTests.swift
    - AgentsUsageBarTests/NotificationsTests/NotificationManagerCategoryTests.swift
    - AgentsUsageBarTests/NotificationsTests/NotificationActionHandlerTests.swift
    - AgentsUsageBarTests/AggregationTests/AggregateStoreSnoozeTests.swift
  modified:
    - AgentsUsageBar/Domain/ThresholdState.swift (Comparable + Codable on ThresholdBand)
    - AgentsUsageBar/Notifications/ThresholdEngine.swift (FSM-aware overload + bandSuffix/bandPercent statics)
    - AgentsUsageBar/Notifications/NotificationManager.swift (registerCategories + categoryIdentifier on every request + 3-band coalesced IDs)
    - AgentsUsageBar/Aggregation/AggregateStore.swift (notificationState DI + snoozeToday + snoozeAllToday + FSM-aware fireThreshold)
    - AgentsUsageBar/App/AgentsUsageBarApp.swift (registerCategories in init + delegate install in .task)
    - AgentsUsageBar/App/AppDependencies.swift (UserDefaultsNotificationStateStore + 7-day prune + actionHandler in Dependencies bag)
    - AgentsUsageBar.xcodeproj/project.pbxproj (7 new file refs across app + test targets)
decisions:
  - "ThresholdBand: Comparable orders by rank — normal(0) < warning(1) < critical(2) < exceeded(3); enables `newBand > oldBand` upward-transition gate (NOTIF-02)"
  - "ThresholdBand also adopts Codable so NotificationStateRecord can JSON-round-trip in UserDefaults"
  - "Phase 1 decisions(for:now:snoozedUntil:) preserved as thin wrapper — internally delegates to the FSM overload with lastBands=[:] and filters to .warning only (D-11 preserved at the back-compat surface)"
  - "Stable IDs extended: warn80 / crit95 / exceed100 — NOTIF-03 contract for all three bands; bandSuffix(for:) and bandPercent(for:) statics on ThresholdEngine for reuse in NotificationManager coalescing"
  - "Coalesced ID = `coalesced:<day>:<highestBandSuffix>` derived from `max(decisions.band)` — extends Phase 1's hardcoded :warn80 suffix"
  - "Coalesced title reflects highest band percent: `N providers crossed 80%/95%/100%`"
  - "UNNotificationCategory(usage.warning) + UNNotificationAction(snooze.today) registered in AgentsUsageBarApp.init() BEFORE any UNUserNotificationCenter.add() call — Pitfall 6"
  - "NotificationActionHandler.handle(actionID:identifier:now:) factored out for direct test (UNNotificationResponse is not publicly constructible)"
  - "Coalesced snooze (id starting `coalesced:`) → store.snoozeAllToday — fans out to every seeded provider"
  - "Snooze gate suppresses ALL bands (default decision #2 — NOT just the band that was showing) via `snoozedUntilDay[pid] == today` short-circuit before band-transition check"
  - "NotificationStateRecord JSON-encoded under `notif.<pid.rawValue>.<yyyy-MM-dd>` in UserDefaults; pruneOldKeys(olderThan:today:) removes entries with date < (today - retentionDays) at app launch (recommended 7d)"
  - "AggregateStore.init gains `notificationState: any NotificationStateStorage = InMemoryNotificationStateStore()` — defaulted parameter keeps all existing tests + composition sites untouched"
  - "AppDependencies wires UserDefaultsNotificationStateStore + prune + NotificationActionHandler; Dependencies bag holds strong reference so UNUserNotificationCenter's weak delegate does not deallocate"
  - "Test now-Date pinned to noon UTC so TodayHelper.formatYYYYMMDD(now) yields the same yyyy-MM-dd string across every reasonable test-host timezone (PT/ICT/etc.)"
metrics:
  duration: "~60 minutes"
  completed: "2026-05-14"
  tasks: 2
  files_modified: 13
  tests_added: 42
---

# Phase 02 Plan 05: Threshold FSM v2 + Snooze + Category Registration Summary

ThresholdEngine upgraded to a Phase 2 FSM that emits decisions for warning / critical / exceeded
bands on upward transitions only, gated by per-(provider, day) snooze. UserDefaults persists the
FSM state across app launches. UNNotificationCategory + "Snooze for today" action are registered
in `AgentsUsageBarApp.init()` before the first `UNUserNotificationCenter.add(_:)` (Pitfall 6),
and `NotificationActionHandler` routes the action back into `AggregateStore.snoozeToday(...)`.
Plan 02-05 leaves Phase 1 NotificationsTests green via a preserved back-compat surface.

## What Was Built

### Production files

**`AgentsUsageBar/Domain/ThresholdState.swift`** — `ThresholdBand` extended
- `extension ThresholdBand: Comparable` — rank order `normal(0) < warning(1) < critical(2) < exceeded(3)`
- Also adopts `Codable` (used by `NotificationStateRecord` JSON round-trip)

**`AgentsUsageBar/Notifications/NotificationStateStore.swift`** — NEW
- `NotificationStateRecord` (Codable: lastBand, snoozedUntilDay?)
- `NotificationStateStorage` protocol
- `UserDefaultsNotificationStateStore` — keyed `"notif.<rawValue>.<yyyy-MM-dd>"`, JSON value
- `InMemoryNotificationStateStore` — dict-backed test double mirroring contract
- `pruneOldKeys(olderThan:today:)` scans `notif.*` keys, parses trailing yyyy-MM-dd, removes < cutoff

**`AgentsUsageBar/Notifications/ThresholdEngine.swift`** — extended
- New `decisions(for:now:snoozedUntilDay:lastBands:)` overload
  - Algorithm: `newBand > oldBand` AND `newBand != .normal` AND `snoozedUntilDay[pid] != today`
  - Stable IDs: `"<rawValue>:<day>:warn80|crit95|exceed100"`
- Phase 1 `decisions(for:now:snoozedUntil:)` preserved as wrapper — filters new overload to `.warning` only
- `bandSuffix(for:)` + `bandPercent(for:)` statics — shared with `NotificationManager` for coalescing

**`AgentsUsageBar/Notifications/NotificationManager.swift`** — extended
- `static usageWarningCategoryID = "usage.warning"` + `static snoozeActionID = "snooze.today"`
- `static func registerCategories(on:)` builds `UNNotificationAction("Snooze for today") + UNNotificationCategory("usage.warning")` and downcasts to call `setNotificationCategories([category])` when the center is the real `UNUserNotificationCenter`
- `schedule(_:)` sets `content.categoryIdentifier = "usage.warning"` on every request (single + coalesced)
- Coalesced ID extended to `"coalesced:<day>:<highestBandSuffix>"`, title uses highest-band percent

**`AgentsUsageBar/Notifications/NotificationActionHandler.swift`** — NEW
- `@MainActor final class NotificationActionHandler: NSObject, UNUserNotificationCenterDelegate`
- `userNotificationCenter(_:didReceive:withCompletionHandler:)` — extracts action + identifier, hops to MainActor Task to call `handle(...)`, resolves completion handler immediately (fire-and-forget snooze write)
- `handle(actionID:identifier:now:)` — pure routing helper for direct testability:
  - unknown actionID → no-op
  - missing `:` separator → no-op (no crash)
  - leading component `"coalesced"` → `store.snoozeAllToday(on:)`
  - else → `store.snoozeToday(providerID: ProviderID(rawValue: leading), on:)`
- Optional `willPresent` delegate method returns `[.banner, .sound]` so banners appear when app is foregrounded

**`AgentsUsageBar/Aggregation/AggregateStore.swift`** — extended
- `init(..., notificationState: any NotificationStateStorage = InMemoryNotificationStateStore())` — defaulted, additive
- `snoozeToday(providerID:on:)` — writes `snoozedUntilDay = today` (preserves existing lastBand)
- `snoozeAllToday(on:)` — iterates `providers.keys`
- `fireThresholdNotificationsIfNeeded(now:)` rewritten to:
  1. Build `lastBands` + `snoozedUntilDay` maps from `notificationState.allRecordsForToday(day)`
  2. Call FSM-aware overload
  3. Schedule via `NotificationManager`
  4. Persist new `lastBand` per fired decision; preserve existing `snoozedUntilDay`

**`AgentsUsageBar/App/AgentsUsageBarApp.swift`** — extended
- `import UserNotifications`
- `init()` calls `UNNotificationManager.registerCategories(on: UNUserNotificationCenter.current())` after `setActivationPolicy(.accessory)` — Pitfall 6 mitigated
- `.task { ... }` installs `UNUserNotificationCenter.current().delegate = dependencies.actionHandler` BEFORE `dependencies.scheduler.start()`

**`AgentsUsageBar/App/AppDependencies.swift`** — extended
- `Dependencies.actionHandler: NotificationActionHandler` — held strongly for app lifetime (OS delegate is weak)
- `makeProduction()`:
  - constructs `UserDefaultsNotificationStateStore` + calls `pruneOldKeys(olderThan: 7, today: …)`
  - passes `notificationState` to `AggregateStore.init`
  - constructs `NotificationActionHandler(store:clock:)`
  - returns `Dependencies(... actionHandler:)`

**`AgentsUsageBar.xcodeproj/project.pbxproj`** — 7 new file refs across app + test targets under `AA020500…` ID namespace

### Test files (5 new, all Swift Testing)

| Suite | Tests | What's verified |
|------|------|-----------------|
| `ThresholdEngineFSMTests` | 15 | Comparable ordering · 3 upward transitions emit correct band suffix · same-band/downward/nil-quota no-emit · multi-provider partial transition · snooze suppresses all 3 bands · snooze-yesterday rollover · normal→exceeded jump emits one decision at .exceeded · Phase 1 back-compat (warn80 only, critical empty, snooze-date still suppresses) |
| `NotificationStateStoreTests` | 11 | InMemory + UserDefaults: fresh-nil · set/read · overwrite · allRecordsForToday day-filter · pruneOldKeys at 7d boundary · key format contract `notif.<pid>.<day>` |
| `NotificationManagerCategoryTests` | 7 | single + coalesced both set categoryIdentifier · 3 highest-band coalesced ID suffix tests · 2 coalesced title percent tests |
| `NotificationActionHandlerTests` | 4 | per-provider snooze · coalesced snoozes all seeded providers · unknown action no-op · malformed ID no-op |
| `AggregateStoreSnoozeTests` | 4 | snoozeToday persists · snoozeAllToday persists for every seeded provider · fireThreshold passes lastBands → warning→critical transition emits :crit95 + persists .critical · fireThreshold respects pre-seeded snooze (0 decisions) |

**Total: 42 new Swift Testing tests, all passing.**

## Test Suite Results

Full test target runs green: **291 tests pass, 0 fail, 1 skip** (pre-existing
`fetch_jsonlFanOutError_setsErrorStatus_andRethrows` skip from Plan 02-04).

Phase 1 NotificationManagerTests + ThresholdEngineTests regression-clean — the Phase 1
back-compat overload preserves the warn80-only emission and the snooze-Date suppression.

## Source Assertion Checks (from acceptance criteria)

| Check | Result |
|------|--------|
| `extension ThresholdBand: Comparable` in `Domain/ThresholdState.swift` | ✓ |
| `warn80|crit95|exceed100` in `ThresholdEngine.swift` | ✓ (3 explicit returns + doc refs) |
| `newBand > oldBand` in `ThresholdEngine.swift` | ✓ |
| `notif\.` in `NotificationStateStore.swift` | ✓ (keyPrefix default + key format) |
| `registerCategories` in `AgentsUsageBarApp.swift` | ✓ |
| `categoryIdentifier` in `NotificationManager.swift` | ✓ (set on both single + coalesced paths) |
| `"Snooze for today"` in `NotificationManager.swift` | ✓ |
| `UNUserNotificationCenter.current().delegate = dependencies.actionHandler` in `AgentsUsageBarApp.swift` | ✓ |
| `func snoozeToday` + `func snoozeAllToday` in `AggregateStore.swift` | ✓ (2 funcs) |

## Bug Fixes Applied During Green Phase

**[Rule 1 - Bug] ThresholdBand missing Codable conformance**
- Found during: first xcodebuild run
- Issue: `NotificationStateRecord: Codable` failed to synthesize because `ThresholdBand`
  only declared `Sendable, Equatable, CaseIterable`
- Fix: add `Codable` to `ThresholdBand` declaration
- File modified: `AgentsUsageBar/Domain/ThresholdState.swift`

**[Rule 1 - Bug] NotificationActionHandler.userNotificationCenter Sendable violation**
- Found during: second xcodebuild run
- Issue: Swift 6 strict concurrency rejected `Task { @MainActor in ... completionHandler() }`
  pattern because `completionHandler` is non-Sendable
- Fix: call `completionHandler()` synchronously outside the Task — the snooze write is
  fire-and-forget and the OS does not block UI on this callback
- File modified: `AgentsUsageBar/Notifications/NotificationActionHandler.swift`

**[Rule 1 - Bug] SnoozeFakeProvider.status() missing argument**
- Found during: second test run
- Issue: `ProviderStatus.ok` requires `lastSuccess: Date` argument
- Fix: return `.ok(lastSuccess: Date())`
- File modified: `AgentsUsageBarTests/AggregationTests/AggregateStoreSnoozeTests.swift`

**[Rule 1 - Bug] Test `today` string mismatches host timezone**
- Found during: third test run (6 failures in AggregateStoreSnoozeTests + NotificationActionHandlerTests)
- Issue: tests pinned `Self.now` to PT-noon and asserted hardcoded `today = "2026-05-13"`,
  but `AggregateStore.snoozeToday` uses `TodayHelper.formatYYYYMMDD(now)` with `Calendar.current` —
  on the developer machine (Bangkok UTC+7), PT-noon falls on the next local day, so the
  production code wrote under `2026-05-14` while the test compared against `2026-05-13`
- Fix: pin `Self.now` to noon UTC (same calendar-day in every reasonable timezone) AND derive
  `Self.today` dynamically via `TodayHelper.formatYYYYMMDD(now)`
- Files modified: `AggregateStoreSnoozeTests.swift`, `NotificationActionHandlerTests.swift`

## Entry Points for Plan 02-06 (PowerObserver / RetryPolicy / CircuitBreaker)

`AggregateStore` and `ClaudeJSONLProvider` remain the integration points. Plan 02-06 wraps
`UsageProvider.fetch(now:)` with retry + circuit breaker — no changes to the threshold FSM
needed. Snooze + FSM state are poll-cycle-independent and unaffected by retry behavior.

## Forward Hook — Plan 5+ Settings UI

`AggregateStore.snoozeToday(providerID:on:)` is the canonical entry point for any future
"Snooze this provider for today" affordance in the popover or Settings scene (CFG-04).
The notification-driven snooze and a future UI-driven snooze share the same persistence path.

## Known Stubs

None — every code path is exercised. The `userNotificationCenter(_:willPresent:...)`
delegate method is the only optional addition (banner-while-foregrounded QoL); it is wired
but not unit-tested because Swift Testing cannot construct `UNNotification` from outside
`UserNotifications`.

## Self-Check: PASSED

- `AgentsUsageBar/Notifications/NotificationStateStore.swift` — exists ✓
- `AgentsUsageBar/Notifications/NotificationActionHandler.swift` — exists ✓
- 5 new test files exist ✓
- `xcodebuild test` exits 0 with 291 pass / 0 fail / 1 skip ✓
- 9/9 source-grep contract assertions pass ✓
- Phase 1 NotificationsTests + ThresholdEngineTests unchanged ✓
