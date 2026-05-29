---
phase: 05-first-run-ux-settings-polish
plan: "03"
subsystem: settings-hot-reload
tags: [settings, hot-reload, aggregate-store, smappservice, threshold-engine, observable]
dependency_graph:
  requires: [05-02]
  provides: [SettingsGeneralTab-impl, updateWarningFraction, setProviderEnabled, observePreferences]
  affects: [AggregateStore, AppDependencies, AgentsUsageBarApp]
tech_stack:
  added: []
  patterns:
    - withObservationTracking + withCheckedContinuation loop for non-SwiftUI @Observable observation
    - SMAppService register/unregister with silent revert on failure (macOS norm)
    - ThresholdEngine rebuild preserves FSM state in UserDefaultsNotificationStateStore
key_files:
  created:
    - AgentsUsageBarTests/UITests/SettingsTests/SettingsGeneralTabTests.swift
    - AgentsUsageBarTests/AggregationTests/AggregateStoreUpdateWarningFractionTests.swift
    - AgentsUsageBarTests/AggregationTests/AggregateStoreProviderEnabledTests.swift
  modified:
    - AgentsUsageBar/Aggregation/AggregateStore.swift
    - AgentsUsageBar/App/AppDependencies.swift
    - AgentsUsageBar/Config/UserPreferencesStore.swift
    - AgentsUsageBar/App/AgentsUsageBarApp.swift
    - AgentsUsageBar/UI/Settings/SettingsGeneralTab.swift
    - AgentsUsageBar.xcodeproj/project.pbxproj
decisions:
  - "setProviderEnabled uses providers.removeValue + placeholder re-seed rather than a separate disabled-set — simpler, Observable re-renders automatically"
  - "SpyNotificationManager reused from AggregateStoreTests.swift (class, not actor) — test file removed duplicate actor definition"
  - "VirtualClock(fixed: Date()) used in new tests — no zero-arg init exists"
metrics:
  duration: "~90 min (resumed from compacted context)"
  completed: "2026-05-21"
  tasks_completed: 3
  files_count: 9
---

# Phase 05 Plan 03: Settings General Tab + Hot-Reload Wiring Summary

All four hot-reload paths from D-04 fully wired: refresh interval, warning threshold, theme, open-at-login, and per-provider toggle.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | AggregateStore.updateWarningFraction + observePreferences hot-reload | bed1a51 | AggregateStore.swift, AppDependencies.swift, UserPreferencesStore.swift, AgentsUsageBarApp.swift |
| 2 | SettingsGeneralTab full impl + 2 test suites | 56cc887 | SettingsGeneralTab.swift, SettingsGeneralTabTests.swift, AggregateStoreUpdateWarningFractionTests.swift |
| 3 | AggregateStoreProviderEnabledTests + pbxproj wiring | 34b6e33 | AggregateStoreProviderEnabledTests.swift, project.pbxproj |

## What Was Built

**AggregateStore.swift:**
- `private let thresholds` → `private var thresholds` (enables live rebuild)
- `updateWarningFraction(_:)` — replaces ThresholdEngine with new instance; FSM state in UserDefaultsNotificationStateStore is NOT touched (Research Q7)
- `setProviderEnabled(_:enabled:)` — removes provider from `providers` dict on disable (row hides immediately per D-04); seeds placeholder on enable (next scheduler tick fetches live data)

**AppDependencies.swift:**
- `observePreferences(_:scheduler:store:)` static `@MainActor` async method — uses `withObservationTracking` + `withCheckedContinuation` bridge to observe `refreshInterval`, `threshold`, and `providerEnabled` changes and propagate to `PollScheduler.updateInterval`, `AggregateStore.updateWarningFraction`, and `AggregateStore.setProviderEnabled`

**UserPreferencesStore.swift:**
- Added `AppTheme.colorScheme: ColorScheme?` computed property (`.light`/`.dark`/`nil` for auto)

**AgentsUsageBarApp.swift:**
- `.preferredColorScheme(dependencies.preferences.theme.colorScheme)` applied at both MenuBarExtra content and Settings scene roots (D-04 theme hot-reload)
- `async let _ = AppDependencies.observePreferences(...)` started alongside `scheduler.start()` in `.task` modifier

**SettingsGeneralTab.swift:**
- Refresh interval `Picker(.menu)` with 6 options (manual → 30 min)
- Warning threshold `Slider(0.5...0.95, step: 0.05)` with percentage label
- Theme `Picker(.segmented)` with light/dark/auto
- Open-at-login `Toggle` with `SMAppService.mainApp.register()/unregister()`, silent revert on failure via `logger.warning`, `.requiresApproval` deep-link CTA to System Settings → Login Items (D-08)

**Test suites (11 tests total, all passing):**
- `SettingsGeneralTabTests` — 5 source-grep structural tests
- `AggregateStoreUpdateWarningFractionTests` — 3 tests (engine rebuild, FSM survival, no spurious firing)
- `AggregateStoreProviderEnabledTests` — 3 tests (toggleOff removes row, toggleOn re-inserts, no cancellation propagation)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] VirtualClock missing zero-arg init**
- **Found during:** Task 2 test compilation
- **Issue:** Test file used `VirtualClock()` but the type only has `VirtualClock(fixed:)` and `VirtualClock(_ closure:)` inits
- **Fix:** Changed to `VirtualClock(fixed: Date())`
- **Files modified:** AggregateStoreUpdateWarningFractionTests.swift

**2. [Rule 1 - Bug] Duplicate SpyNotificationManager**
- **Found during:** Task 2 test compilation
- **Issue:** Test file defined `final actor SpyNotificationManager` but `AggregateStoreTests.swift` already defines `final class SpyNotificationManager` in the same test module
- **Fix:** Removed local actor definition; updated `scheduleCallCount` → `scheduledDecisions.count` to match the existing class's API
- **Files modified:** AggregateStoreUpdateWarningFractionTests.swift

**3. [Rule 1 - Bug] SettingsGeneralTabTests UUID not in SettingsTests PBXGroup**
- **Found during:** Task 2 build (prior-session insert had failed silently)
- **Issue:** `SettingsGeneralTabTests.swift` PBXFileReference existed but was not in any PBXGroup's children list; Xcode resolved it relative to the project root
- **Fix:** Inserted UUID into SettingsTests group children via Python byte-level edit
- **Files modified:** project.pbxproj

## Regression Notes

Two pre-existing failures unrelated to Plan 05-03:
- `OnboardingCopyTests` — Plan 05-04 (sibling agent) test failures in that plan's scope
- `URLSessionHTTPClientTests` — pre-existing infra test failures

All 11 Plan 05-03 tests pass. All previously-passing tests continue to pass.

## Threat Flags

None. No new network endpoints, auth paths, or file access patterns introduced. SMAppService toggle is `@MainActor`-only per T-05-03-01 mitigation.

## Self-Check: PASSED

- `AgentsUsageBarTests/UITests/SettingsTests/SettingsGeneralTabTests.swift` — FOUND
- `AgentsUsageBarTests/AggregationTests/AggregateStoreUpdateWarningFractionTests.swift` — FOUND
- `AgentsUsageBarTests/AggregationTests/AggregateStoreProviderEnabledTests.swift` — FOUND
- Commit `bed1a51` — FOUND (Task 1)
- Commit `56cc887` — FOUND (Task 2)
- Commit `34b6e33` — FOUND (Task 3)
