---
phase: 05-first-run-ux-settings-polish
plan: 05
subsystem: ui
tags: [swiftui, appkit, welcome-window, first-run, detection-probe, activation-policy, swift-6, nsnotificationcenter, userdefaults]

# Dependency graph
requires:
  - phase: 05-first-run-ux-settings-polish
    plan: 02
    provides: UserPreferencesStore with hasSeenWelcome flag + setHasSeenWelcome/setProviderEnabled write API
  - phase: 05-first-run-ux-settings-polish
    plan: 04
    provides: DetectionProbe.probeAll + OnboardingCopy.loadBundled() consumed by WelcomeRootView
  - phase: 05-first-run-ux-settings-polish
    plan: 01
    provides: WindowActivationObserver with managedTitles ["Settings","Welcome"] — single source of truth for activation-policy flip
provides:
  - WelcomeWindowController — NSWindow host (520x480pt, non-resizable, centered); opens on !hasSeenWelcome; retained in Dependencies for app lifetime
  - WelcomeRootView — SwiftUI content with DetectionProbe.probeAll on appear, 7 provider rows, Get Started + Open Settings footer
  - WelcomeProviderRow — per-provider detection badge (Checking/Detected/Not running/Not configured/Not detected) with expandable help panel + Copy buttons
  - AppDependencies.welcomeWindowController — strongly retained in Dependencies; showIfNeeded() called from AgentsUsageBarApp .task
  - WelcomeWindowControllerTests — 6 Swift Testing cases (gate, open, noop, title assertion, no-policy-call, willClose observer)
  - WelcomeRootViewTests — 5 structural source-walk cases (allKnown, probeAll, seed, footer buttons, CFG-06)
affects:
  - 05-06 (SettingsAboutTab + Polish) — no dependency on Welcome UI

# Tech tracking
tech-stack:
  added:
    - "NSHostingController wrapping SwiftUI WelcomeRootView in a manually-created NSWindow"
    - "NSWindow.willCloseNotification per-window observer retained in WelcomeWindowController (Pitfall 4)"
  patterns:
    - "WelcomeWindowController delegates activation-policy flip to WindowActivationObserver via win.title='Welcome' (ISS-04)"
    - "URLSessionHTTPClient(timeoutSeconds: 2) re-created inside WelcomeRootView.runProbes() — one-time cost, avoids adding localhostHTTP to Dependencies bag (D-13)"
    - "Source-walk tests for structural compliance (ISS-04, CFG-06, Pitfall 4)"

key-files:
  created:
    - "AgentsUsageBar/UI/Welcome/WelcomeWindowController.swift"
    - "AgentsUsageBar/UI/Welcome/WelcomeRootView.swift"
    - "AgentsUsageBar/UI/Welcome/WelcomeProviderRow.swift"
    - "AgentsUsageBarTests/UITests/WelcomeTests/WelcomeWindowControllerTests.swift"
    - "AgentsUsageBarTests/UITests/WelcomeTests/WelcomeRootViewTests.swift"
  modified:
    - "AgentsUsageBar/App/AppDependencies.swift — Dependencies gains welcomeWindowController; makeProduction() constructs it"
    - "AgentsUsageBar/App/AgentsUsageBarApp.swift — .task calls welcomeWindowController.showIfNeeded() after scheduler.start()"
    - "AgentsUsageBar.xcodeproj/project.pbxproj — wired 3 app sources + 2 test sources under UUID namespace AA050500050000000000xx"

key-decisions:
  - "win.title = 'Welcome' (not 'Welcome to Agents Usage Bar') so WindowActivationObserver.managedTitles matches and owns the activation-policy flip (ISS-04)"
  - "WelcomeWindowController does NOT call NSApp.setActivationPolicy directly — WindowActivationObserver is the single source of truth (ISS-04, D-06)"
  - "URLSessionHTTPClient re-created inside runProbes() — avoids adding localhostHTTP to Dependencies bag; acceptable one-time cost for welcome screen (D-13)"
  - "nonisolated(unsafe) on closeObserver token — required for Swift 6 deinit cleanup pattern, mirrors PowerObserver"
  - "Color.accentColor (not .accent) for SwiftUI foregroundStyle — .accent ShapeStyle does not exist on macOS 14"
  - "default: case added to iconName switch — ProviderID is a struct with rawValue, not an exhaustive enum"

requirements-completed: [CFG-03, CFG-04, CFG-05]

# Metrics
duration: ~35min
completed: 2026-05-21
---

# Phase 5 Plan 05: WelcomeWindowController + WelcomeRootView + WelcomeProviderRow Summary

**NSWindow-hosted Welcome window auto-opens on fresh install, runs parallel provider detection via DetectionProbe.probeAll, seeds detected providers in UserDefaults, and is permanently dismissed via Get Started / Open Settings footer buttons — activation-policy flip delegated to WindowActivationObserver (ISS-04).**

## Performance

- **Duration:** ~35 min
- **Completed:** 2026-05-21T10:49:06Z
- **Tasks:** 2 of 2 completed
- **Files created:** 5 (3 app sources + 2 test sources)
- **Files modified:** 3 (AppDependencies.swift, AgentsUsageBarApp.swift, project.pbxproj)
- **New tests:** 11 Swift Testing `@Test` cases (6 WelcomeWindowControllerTests + 5 WelcomeRootViewTests), all PASS

## Accomplishments

- **WelcomeWindowController** is live: 520x480pt NSWindow, non-resizable, centered on main screen. `showIfNeeded()` guards on `!preferences.hasSeenWelcome` (D-10). `NSWindow.willCloseNotification` observer retained for app lifetime (Pitfall 4 — mirrors PowerObserver pattern). Does NOT call `NSApp.setActivationPolicy` directly — `WindowActivationObserver` is the single source of truth (ISS-04).
- **WelcomeRootView** runs `DetectionProbe.probeAll` on appear via a 2s `URLSessionHTTPClient` re-created inline (D-13 — composition root stays fast). Seeds detected providers in `UserPreferencesStore.providerEnabled` for first-run-only initialization (CFG-03 + D-11). Both footer buttons call `onDismiss` which calls `setHasSeenWelcome(true)`.
- **WelcomeProviderRow** renders per-provider detection badges with disclosure-group expandable help panels, Copy-to-Clipboard buttons via `NSPasteboard.general`, and docs links (D-14/D-15).
- **AppDependencies** retains `WelcomeWindowController` in `Dependencies` for app lifetime; `AgentsUsageBarApp.task` calls `showIfNeeded()` after `scheduler.start()`.
- All 11 new tests PASS. Pre-existing failures (`OnboardingCopyTests` bundle resource + `PollSchedulerTests/updateIntervalReplacesLoop` timing flake) are unaffected by this plan.

## Task Commits

1. **Task 1: WelcomeWindowController + WelcomeRootView + WelcomeProviderRow** — `53047f8` (feat)
2. **Task 2: Wire WelcomeWindowController into AppDependencies + tests** — `e42a4f6` (feat)

## Files Created/Modified

### Created

- **`AgentsUsageBar/UI/Welcome/WelcomeWindowController.swift`** — `@MainActor public final class`. `show()` creates `NSHostingController(rootView: WelcomeRootView)`, wraps in `NSWindow` with `.titled .closable` style mask, `isReleasedWhenClosed = false`, 520x480pt, centered. `NSWindow.willCloseNotification` observer registered before `makeKeyAndOrderFront(_:)` (Pitfall 4). `nonisolated(unsafe) var closeObserver` for Swift 6 deinit cleanup. `dismiss(openSettings:)` calls `setHasSeenWelcome(true)` + dispatches `showSettingsWindow:` responder chain if needed.
- **`AgentsUsageBar/UI/Welcome/WelcomeRootView.swift`** — SwiftUI `View` with `@State` detection results + isProbing flag. `runProbes()` creates inline `URLSessionHTTPClient(timeoutSeconds: 2)`, calls `DetectionProbe.probeAll`, updates state, seeds `preferences.setProviderEnabled` for detected providers where key was never previously set. Footer has "Open Settings" (escape) and "Get Started" (return, .borderedProminent) buttons.
- **`AgentsUsageBar/UI/Welcome/WelcomeProviderRow.swift`** — `View` with `@State isExpanded`, `copiedEnv`, `copiedToml`. Detection badge via `@ViewBuilder detectionBadge` switching on `DetectionResult?`. `shouldShowHelpPanel` shows chevron for notDetected/notConfigured/notRunning/nil. `snippetBlock` renders monospace snippet with `NSPasteboard.general` copy button + 2s "Copied!" feedback.
- **`AgentsUsageBarTests/UITests/WelcomeTests/WelcomeWindowControllerTests.swift`** — `@Suite(.serialized) @MainActor` with 6 cases: gate (hasSeenWelcome=true blocks show), open (hasSeenWelcome=false proceeds), noop (double show), title assertion (ISS-04), no-direct-policy-call source-walk (ISS-04), willClose observer source-walk (Pitfall 4).
- **`AgentsUsageBarTests/UITests/WelcomeTests/WelcomeRootViewTests.swift`** — 5 structural source-walk cases: allKnown reference, probeAll call, setProviderEnabled seed, both footer button strings, CFG-06 no shell RC references.

### Modified

- **`AgentsUsageBar/App/AppDependencies.swift`** — `Dependencies` gains `public let welcomeWindowController: WelcomeWindowController` + new last-position init parameter. `makeProduction()` constructs `WelcomeWindowController(preferences: preferences, config: config)` after `windowActivationObserver` (step 14) and includes it in the `Dependencies(...)` return.
- **`AgentsUsageBar/App/AgentsUsageBarApp.swift`** — `.task` block gains `await dependencies.welcomeWindowController.showIfNeeded()` after `scheduler.start()`. No-op on all subsequent launches.
- **`AgentsUsageBar.xcodeproj/project.pbxproj`** — UUID namespace `AA050500050000000000xx`: 3 app PBXBuildFile + 3 PBXFileReference; 2 test PBXBuildFile + 2 PBXFileReference. App sources added to app-target PBXSourcesBuildPhase; test sources added to test-target PBXSourcesBuildPhase. Welcome PBXGroup and WelcomeTests PBXGroup extended.

## Decisions Made

- **ISS-04: No direct `setActivationPolicy` call.** `win.title = "Welcome"` ensures `WindowActivationObserver.managedTitles` filter matches. This was the central design constraint — all four occurrences of `setActivationPolicy` in the source are in comments only (0 actual calls verified by source-walk test).
- **`Color.accentColor` not `.accent`.** `.foregroundStyle(.accent)` fails on macOS 14 — `ShapeStyle` has no `accent` member. Used `Color.accentColor` (works) vs `.accentColor` (only valid for `.tint()`). [Rule 1 — Bug]
- **`default:` in `iconName` switch.** `ProviderID` is a struct with `rawValue`, not a Swift enum — switch is not exhaustive without `default`. [Rule 1 — Bug]

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 — Bug] `.accent` ShapeStyle does not exist on macOS 14**
- **Found during:** Task 1 build
- **Issue:** `WelcomeRootView` used `.foregroundStyle(.accent)` from the plan's exemplar code. `ShapeStyle` has no `accent` member on macOS 14 (compile error).
- **Fix:** Replaced with `Color.accentColor` which is a valid `ShapeStyle` on macOS 14+.
- **Files modified:** `AgentsUsageBar/UI/Welcome/WelcomeRootView.swift`
- **Commit:** `53047f8`

**2. [Rule 1 — Bug] `iconName` switch not exhaustive on struct-based ProviderID**
- **Found during:** Task 1 build
- **Issue:** `ProviderID` is a `struct` with `rawValue`, not a Swift `enum`. Switch statements on it require a `default:` arm or the compiler rejects as non-exhaustive.
- **Fix:** Added `default: return "cpu"` arm to `iconName` computed property.
- **Files modified:** `AgentsUsageBar/UI/Welcome/WelcomeProviderRow.swift`
- **Commit:** `53047f8`

## Known Stubs

None. All Welcome window data sources are wired:
- Detection results: live via `DetectionProbe.probeAll` on appear
- Onboarding copy: live via `OnboardingCopy.loadBundled()` from bundle
- Provider seeding: live via `preferences.setProviderEnabled`

## Threat Flags

No new threat surface beyond what is documented in the plan's threat model. All `NSApp.setActivationPolicy` calls routed through `WindowActivationObserver` (T-05-05-01 accept). No credential data written to UserDefaults (T-05-05-02 accept). 2s timeout on detection probes (T-05-05-03 accept).

## Self-Check

- [x] `AgentsUsageBar/UI/Welcome/WelcomeWindowController.swift` exists
- [x] `AgentsUsageBar/UI/Welcome/WelcomeRootView.swift` exists
- [x] `AgentsUsageBar/UI/Welcome/WelcomeProviderRow.swift` exists
- [x] `AgentsUsageBarTests/UITests/WelcomeTests/WelcomeWindowControllerTests.swift` exists
- [x] `AgentsUsageBarTests/UITests/WelcomeTests/WelcomeRootViewTests.swift` exists
- [x] Commit `53047f8` exists (Task 1)
- [x] Commit `e42a4f6` exists (Task 2)
- [x] `grep -c 'WelcomeWindowController' AgentsUsageBar/App/AppDependencies.swift` returns 4
- [x] `grep -c 'showIfNeeded' AgentsUsageBar/App/AgentsUsageBarApp.swift` returns 2
- [x] `grep -c 'NSApp.setActivationPolicy' WelcomeWindowController.swift` (non-comment) returns 0
- [x] `grep -c 'win.title = "Welcome"' WelcomeWindowController.swift` returns 1
- [x] All 11 new tests PASS
- [x] `xcodebuild build` succeeds
- [x] No CFG-06 violations in Welcome UI files

## Self-Check: PASSED
