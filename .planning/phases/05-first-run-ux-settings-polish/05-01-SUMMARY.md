---
phase: 05-first-run-ux-settings-polish
plan: 01
subsystem: ui
tags: [swiftui, appkit, settings-scene, menubar-extra, activation-policy, lsuielement, swift-6, nsnotificationcenter]

# Dependency graph
requires:
  - phase: 02-claude-jsonl-vertical-slice
    provides: PowerObserver Swift 6 strict-concurrency observer pattern (nonisolated(unsafe) tokens, @MainActor isolation, deinit cleanup) — direct template for WindowActivationObserver
  - phase: 01-skeleton-openrouter-vertical-slice
    provides: Dependencies bag pattern, AppDependencies.makeProduction() composition root, AppLogger subsystem
provides:
  - WindowActivationObserver — counter-style NSWindow open/close observer that flips activation policy .accessory <-> .regular for any window titled "Settings" or "Welcome"
  - SwiftUI Settings { … } scene scaffold with three tab stubs (General / Providers / About per D-07)
  - SettingsScene + SettingsGeneralTab + SettingsProvidersTab + SettingsAboutTab placeholder views — empty stubs filled by Plans 05-03 / 05-04 / 05-06
  - Cmd-, override (CommandGroup replacing .appSettings) that calls NSApp.activate(ignoringOtherApps:) before dispatching showSettingsWindow: down the responder chain — D-05 LSUIElement Cmd-, focus fix
  - Dependencies.windowActivationObserver property — strongly retained for app lifetime (Pitfall 4)
affects:
  - 05-02 (UserPreferencesStore + ConfigStore overlay) — Dependencies bag will gain preferences property
  - 05-03 (SettingsGeneralTab implementation) — fills the stub created here
  - 05-04 (SettingsProvidersTab implementation) — fills the stub created here
  - 05-05 (WelcomeWindowController) — uses the same WindowActivationObserver via "Welcome" managed title
  - 05-06 (SettingsAboutTab implementation) — fills the stub created here

# Tech tracking
tech-stack:
  added:
    - "AppKit NSWindow notifications: didBecomeKeyNotification + willCloseNotification"
    - "SwiftUI Settings { } scene + CommandGroup(replacing: .appSettings) override pattern"
  patterns:
    - "Set<ObjectIdentifier> open-window tracking (idempotent under regained key focus)"
    - "Window-title allow-list filter for activation policy targeting"
    - "Responder-chain dispatch for SwiftUI Settings programmatic open (showSettingsWindow: with showPreferencesWindow: legacy fallback)"

key-files:
  created:
    - "AgentsUsageBar/App/WindowActivationObserver.swift"
    - "AgentsUsageBar/UI/Settings/SettingsScene.swift"
    - "AgentsUsageBar/UI/Settings/SettingsGeneralTab.swift"
    - "AgentsUsageBar/UI/Settings/SettingsProvidersTab.swift"
    - "AgentsUsageBar/UI/Settings/SettingsAboutTab.swift"
    - "AgentsUsageBarTests/UITests/SettingsTests/WindowActivationObserverTests.swift"
  modified:
    - "AgentsUsageBar/App/AgentsUsageBarApp.swift — added Settings { SettingsScene() } scene, Cmd-, override, force-realize windowActivationObserver in .task"
    - "AgentsUsageBar/App/AppDependencies.swift — Dependencies gains windowActivationObserver property; makeProduction() constructs it after PowerObserver"
    - "AgentsUsageBar.xcodeproj/project.pbxproj — wired 5 app + 1 test source under UUID namespace AA050100; added UI/Settings group + UITests/SettingsTests subgroup"

key-decisions:
  - "Used NSWindow.didBecomeKeyNotification (not the plan's nonexistent willOpenNotification) as the canonical 'window appeared' signal — verified against SDK NSWindow.h"
  - "Set<ObjectIdentifier> open-window tracking instead of an Int counter — prevents double-increment on regained key focus"
  - "Window-title allow-list ('Settings', 'Welcome') for managed-window filtering — defers identifier-based filtering to a later refinement if needed"
  - "Cmd-, button dispatches showSettingsWindow: (macOS 14+) with showPreferencesWindow: legacy fallback via NSApp.responds(to:) check"

patterns-established:
  - "Set-based observer dedupe: Pattern for any subsystem that needs idempotent presence tracking under repeated AppKit notifications"
  - "Responder-chain Settings open: Reusable pattern for any LSUIElement app that needs to present SwiftUI Settings programmatically and survive Apple's selector rename across OS versions"

requirements-completed: [SHELL-05]

# Metrics
duration: ~50min
completed: 2026-05-21
---

# Phase 5 Plan 01: Settings Scene + Window Activation Observer Summary

**Cmd-, now opens a SwiftUI Settings scene scaffold with three empty tab stubs, and the activation policy flips `.accessory ↔ .regular` automatically via a counter-style NSWindow observer keyed on window title.**

## Performance

- **Duration:** ~50 min
- **Started:** 2026-05-21T16:25:00Z (approx)
- **Completed:** 2026-05-21T17:15:00Z (approx)
- **Tasks:** 2 of 2 completed
- **Files modified:** 3 (AgentsUsageBarApp.swift, AppDependencies.swift, project.pbxproj)
- **Files created:** 6 (WindowActivationObserver.swift + 4 Settings views + 1 test file)
- **New tests:** 8 Swift Testing `@Test` cases (single window open, single close, two-window keep-regular, two-window both-close, unrelated-window-ignored, force-launch reset, regained-key-no-double-increment, full NotificationCenter wire integration)

## Accomplishments

- **WindowActivationObserver** is live on app launch and reliably flips activation policy on Settings/Welcome window lifecycle (D-06 / SHELL-05 satisfied at the observer layer).
- **SwiftUI Settings { } scene** is registered alongside MenuBarExtra; the empty three-tab scaffold (General / Providers / About) is ready for Plans 05-03 / 05-04 / 05-06 to fill (D-07 satisfied).
- **Cmd-, focus fix** is wired (D-05) — pressing Cmd-, calls `NSApp.activate(ignoringOtherApps: true)` before dispatching `showSettingsWindow:` down the responder chain, mitigating the documented LSUIElement focus quirk on macOS 14+.
- **Composition root** retains the observer for the app lifetime (Pitfall 4 — without strong retention the observer is deallocated and policy flips silently drop).
- All 8 new tests + the regression-relevant `AppDependenciesLocalRegistrationTests` (composition smoke) + `AppDependenciesCodexGeminiRegistrationTests` (registration smoke) PASS on the verified run.

## Task Commits

Each task was committed atomically:

1. **Task 1: WindowActivationObserver + Settings scene scaffold** — `32e2e78` (feat)
2. **Task 2: Wire Settings scene + Cmd-, override into AgentsUsageBarApp + AppDependencies** — `caa8bc4` (feat)

**Plan metadata commit:** added in the worktree-protocol metadata commit after this SUMMARY is staged.

## Files Created/Modified

- `AgentsUsageBar/App/WindowActivationObserver.swift` — `@MainActor` counter-style observer that flips `NSApplication.shared.setActivationPolicy` between `.accessory` and `.regular` based on `NSWindow.didBecomeKeyNotification` + `willCloseNotification`. Uses `Set<ObjectIdentifier>` open-window tracking so a window briefly losing then regaining key status does NOT double-increment. Mirrors `PowerObserver.swift`'s Swift 6 strict-concurrency pattern (`nonisolated(unsafe)` tokens, `deinit` cleanup, `Task { @MainActor … }` hop from observer block).
- `AgentsUsageBar/UI/Settings/SettingsScene.swift` — SwiftUI `TabView` with three `tabItem`-labeled tabs (gearshape / antenna.radiowaves.left.and.right / info.circle SF Symbols). `.frame(minWidth: 520, minHeight: 400)`.
- `AgentsUsageBar/UI/Settings/SettingsGeneralTab.swift` — empty stub: `Text("General settings coming in Plan 05-03").padding()`.
- `AgentsUsageBar/UI/Settings/SettingsProvidersTab.swift` — empty stub: `Text("Providers settings coming in Plan 05-04").padding()`.
- `AgentsUsageBar/UI/Settings/SettingsAboutTab.swift` — empty stub: `Text("About coming in Plan 05-06").padding()`.
- `AgentsUsageBar/App/AgentsUsageBarApp.swift` — added `Settings { SettingsScene() … }` scene alongside `MenuBarExtra`; `.commands { CommandGroup(replacing: .appSettings) { … } }` button calls `NSApp.activate(ignoringOtherApps: true)` then dispatches `showSettingsWindow:` (with `showPreferencesWindow:` legacy fallback via `NSApp.responds(to:)`). `.task` gains `_ = dependencies.windowActivationObserver` to force-realize the strong reference.
- `AgentsUsageBar/App/AppDependencies.swift` — `Dependencies` class gains `public let windowActivationObserver: WindowActivationObserver` property + new init parameter (last position to minimize call-site churn — only `makeProduction()` calls `Dependencies.init` directly). `makeProduction()` constructs the observer after `PowerObserver` and returns it.
- `AgentsUsageBarTests/UITests/SettingsTests/WindowActivationObserverTests.swift` — `@Suite(.serialized)` test suite (8 `@Test async` cases) exercising single-window, multi-window, unrelated-window, force-launch reset, regained-key dedupe, and full NotificationCenter integration paths. Each test resets activation policy to `.accessory` via `defer` to prevent global-state cross-contamination.
- `AgentsUsageBar.xcodeproj/project.pbxproj` — UUID namespace `AA050100` for Plan 05-01: 5 app source + 1 test source PBXBuildFile entries; 6 PBXFileReference entries; App group extended with `WindowActivationObserver.swift`; new UI/Settings PBXGroup created and added to UI group; new UITests/SettingsTests PBXGroup created and added to UITests group; PBXSourcesBuildPhase for both targets extended.

## Decisions Made

- **NSWindow notification choice.** The plan text referenced `NSWindow.willOpenNotification`, which does NOT exist in AppKit (verified against `NSWindow.h` in the macOS 26.5 SDK — only `Will`/`Did` notifications for `Close`, `Miniaturize`, `Move`, `Resize`, etc. plus `Did(Become|Resign)(Key|Main)`). The canonical "window appeared and is interactive" signal is `didBecomeKeyNotification`. On LSUIElement apps the user-visible "Settings just opened" moment coincides with the first `didBecomeKey` event after `NSApp.activate(ignoringOtherApps:)`.
- **Set-based open-window tracking.** Switched from the plan's plain Int `openWindowCount` to a `Set<ObjectIdentifier>` of NSWindow instances. The Int counter would have double-incremented every time a window lost and regained key status (e.g. user Cmd-Tabs away and back). Set-based dedupe is correct semantics; `openWindowCount` is exposed as a computed `internal var` for test inspection.
- **Cmd-, programmatic open.** SwiftUI's default `.appSettings` command group does NOT call `NSApp.activate(ignoringOtherApps:)`. Replacing it lets us activate-first, then dispatch the standard `showSettingsWindow:` selector down the responder chain (macOS 14+; falls back to `showPreferencesWindow:` if the modern selector is unavailable). Using `NSApp.responds(to:)` instead of an OS-version check keeps the code resilient to future Apple selector renames.
- **Dependencies init parameter position.** Added `windowActivationObserver` as the LAST init parameter so existing test smoke calls that use `AppDependencies.makeProduction()` need zero changes (only `makeProduction` directly calls `Dependencies(...)` — no test in the suite constructs `Dependencies` manually).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 — Bug] Plan referenced nonexistent `NSWindow.willOpenNotification`**
- **Found during:** Task 1 (compile diagnostic: `Type 'NSWindow' has no member 'willOpenNotification'`)
- **Issue:** The plan's exemplar code used `NSWindow.willOpenNotification`, which is not defined in AppKit on any macOS version. The notification names defined in `NSWindow.h` for "window appeared" are limited to `didBecomeKeyNotification`, `didBecomeMainNotification`, `didExposeNotification`, and `didDeminiaturizeNotification`. There is no "will open" notification because windows don't have a discrete open lifecycle event — they become key/main when they appear.
- **Fix:** Substituted `NSWindow.didBecomeKeyNotification` for the open signal. Updated the doc-comments to call out the AppKit correction explicitly. Switched the open-window tracker from an Int counter to a `Set<ObjectIdentifier>` so the more frequent `didBecomeKey` (which can fire multiple times for the same window across focus loss/regain) does not corrupt the count.
- **Files modified:** `AgentsUsageBar/App/WindowActivationObserver.swift` (initial implementation), `AgentsUsageBarTests/UITests/SettingsTests/WindowActivationObserverTests.swift` (test names + assertions match the new notification + the regained-key dedupe case).
- **Verification:** All 8 tests in `WindowActivationObserverTests` pass; `notificationCenter_actuallyWiresHandlers` exercises the real `NotificationCenter.post` → handler path with both notifications.
- **Committed in:** `32e2e78` (Task 1 commit)

**2. [Rule 1 — Bug] Plan's `nonisolated(unsafe) private let notificationCenter` was unnecessary**
- **Found during:** Task 1 (compile diagnostic: `'nonisolated(unsafe)' unnecessary on NotificationCenter constant`)
- **Issue:** `nonisolated(unsafe)` is required for non-Sendable mutable storage read from `deinit`. A `let` of a Sendable type read in a nonisolated `deinit` does not need the annotation under Swift 6 strict concurrency.
- **Fix:** Dropped `nonisolated(unsafe)` on the `notificationCenter: NotificationCenter` constant; kept the annotation on the two mutable `becomeKeyToken` / `willCloseToken` properties where it is genuinely required.
- **Files modified:** `AgentsUsageBar/App/WindowActivationObserver.swift`
- **Committed in:** `32e2e78` (Task 1 commit)

**3. [Rule 2 — Missing functionality] Programmatic Settings open from Cmd-, button**
- **Found during:** Task 2 (re-reading the plan's commands{} block during implementation)
- **Issue:** The plan's exemplar `CommandGroup(replacing: .appSettings)` button called `NSApp.activate(ignoringOtherApps: true)` but did NOT dispatch any action to actually open the Settings scene — the plan's comment claimed "Opening the Settings scene is handled by SwiftUI when the command fires", but that only happens when a `.appSettings` command-named identifier is fired down the responder chain. Replacing the entire CommandGroup means the standard SwiftUI relay no longer runs.
- **Fix:** After `NSApp.activate(...)`, dispatch the standard `showSettingsWindow:` selector via `NSApp.sendAction(...)`. Use `NSApp.responds(to:)` to fall back to the legacy `showPreferencesWindow:` selector on dot-revisions of macOS 14 where the modern responder has not yet been adopted.
- **Files modified:** `AgentsUsageBar/App/AgentsUsageBarApp.swift`
- **Verification:** Build succeeds; the `.commands { CommandGroup(replacing: .appSettings) }` and `ignoringOtherApps` grep verifications both return ≥2 (button decl + responder-chain branch).
- **Committed in:** `caa8bc4` (Task 2 commit)

---

**Total deviations:** 3 auto-fixed (2 × Rule 1 bug, 1 × Rule 2 missing functionality)
**Impact on plan:** All three auto-fixes were necessary for the plan to compile and behave correctly. No scope creep; no architectural changes; no Rule 4 escalation. Plan executed within budget.

## Issues Encountered

- **Pre-existing flaky test in regression sweep:** `PollSchedulerTests/updateIntervalReplacesLoop()` failed under the full-suite parallel run (0.706s). The same test PASSES when run in isolation. STATE.md documents this as a known pre-existing Phase 01-05 timing flake ("pre-existing PollSchedulerTests timing flakes pass in isolation and on retry — not a Plan regression"). Out of scope for Plan 05-01 per the SCOPE BOUNDARY rule. Not fixed.

## User Setup Required

None. Plan 05-01 introduces no new entitlements, no new env vars, no Info.plist changes, no new CI secrets. The Cmd-, key binding works automatically.

## Self-Check

- [x] `AgentsUsageBar/App/WindowActivationObserver.swift` exists
- [x] `AgentsUsageBar/UI/Settings/SettingsScene.swift` exists
- [x] `AgentsUsageBar/UI/Settings/SettingsGeneralTab.swift` exists
- [x] `AgentsUsageBar/UI/Settings/SettingsProvidersTab.swift` exists
- [x] `AgentsUsageBar/UI/Settings/SettingsAboutTab.swift` exists
- [x] `AgentsUsageBarTests/UITests/SettingsTests/WindowActivationObserverTests.swift` exists
- [x] Commit `32e2e78` exists (Task 1 — verified via `git log`)
- [x] Commit `caa8bc4` exists (Task 2 — verified via `git log`)
- [x] `grep -c 'Settings {' AgentsUsageBar/App/AgentsUsageBarApp.swift` returns 1
- [x] `grep -c 'windowActivationObserver' AgentsUsageBar/App/AppDependencies.swift` returns 5
- [x] `grep -c 'CommandGroup(replacing: .appSettings)' AgentsUsageBar/App/AgentsUsageBarApp.swift` returns ≥1 (actual: 2)
- [x] `grep -c 'ignoringOtherApps' AgentsUsageBar/App/AgentsUsageBarApp.swift` returns ≥1 (actual: 2)
- [x] All 8 `WindowActivationObserverTests` PASS
- [x] App-target `xcodebuild build` succeeds
- [x] `AppDependenciesLocalRegistrationTests/appDependenciesMakeProduction_smokeTest` PASSES (composition root unaffected by signature change)
- [x] No `.zshrc` / `.bashrc` / `config.fish` references in Plan 05-01 new files (CFG-06)

## Self-Check: PASSED
