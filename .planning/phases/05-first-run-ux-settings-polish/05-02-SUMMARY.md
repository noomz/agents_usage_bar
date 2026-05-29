---
phase: 05-first-run-ux-settings-polish
plan: 02
subsystem: config
tags: [userdefaults, observable, mainactor, swift-6, hot-reload, environment-key, precedence-chain, swift-testing]

# Dependency graph
requires:
  - phase: 05-first-run-ux-settings-polish
    plan: 01
    provides: Dependencies bag pattern (gains preferences property); WindowActivationObserver retention pattern (preferences follows same composition-root-retained model)
  - phase: 01-skeleton-openrouter-vertical-slice
    provides: ConfigStore env > toml > defaults precedence chain (Plan 05-02 layers UserDefaults on top); ClockEnvironmentKey precedent for SwiftUI environment key pattern
provides:
  - UserPreferencesStore — @Observable @MainActor class backed by UserDefaults with 6 knobs (refreshInterval, threshold, theme, openAtLogin, hasSeenWelcome, providerEnabled) + 6 write methods + UserDefaults.didChangeNotification observer for hot-reload
  - AUBDefaultsKey namespace — All Phase 5 UserDefaults keys with aub.* prefix
  - AppTheme enum — light/dark/auto with String rawValue storage
  - ProviderID.allKnown — ordered static array of all 7 known providers
  - RefreshInterval.tomlString — canonical String representation for UserDefaults round-trip via parse()
  - \.preferences SwiftUI environment key (UserPreferencesStoreKey)
  - ConfigStore.load(preferences:) @MainActor overload — applies UserDefaults overlay per D-02/D-03
  - withEnabled(_:) factory methods on all 6 per-provider config structs (additive, preserves let immutability)
  - Dependencies.preferences property — strongly retained for app lifetime
affects:
  - 05-03 (SettingsGeneralTab) — reads preferences via @Environment(\.preferences) for refresh/threshold/theme/openAtLogin
  - 05-04 (SettingsProvidersTab) — reads preferences.providerEnabled and writes via setProviderEnabled(_:enabled:)
  - 05-05 (WelcomeWindowController) — reads preferences.hasSeenWelcome and writes via setHasSeenWelcome(_:); also seeds providerEnabled per D-11
  - 05-06 (SettingsAboutTab) — neutral (no preferences interaction)

# Tech tracking
tech-stack:
  added:
    - "UserDefaults(suiteName:) per-test isolation pattern (Research Q13)"
    - "MainActor.assumeIsolated for nonisolated EnvironmentKey defaultValue on @MainActor type"
    - "Per-struct withEnabled(_:) factory for let-only Equatable config types"
  patterns:
    - "Async-after-write tests: Task.sleep(for:.milliseconds(50)) bridges UserDefaults.didChangeNotification → @Observable reload"
    - "Direct UserDefaults pre-write before store construction: synchronously seeds loadAll() in init, bypasses notification-bus latency in tests"
    - "ConfigStore.load(preferences:) per-field overlay: AppConfig rebuilt with new values for knobs; credentials path untouched (D-03)"

key-files:
  created:
    - "AgentsUsageBar/Config/UserPreferencesStore.swift"
    - "AgentsUsageBar/UI/Environment/AppEnvironmentKeys.swift"
    - "AgentsUsageBarTests/ConfigTests/UserPreferencesStoreTests.swift"
    - "AgentsUsageBarTests/ConfigTests/ConfigStorePrecedenceTests.swift"
  modified:
    - "AgentsUsageBar/Domain/ProviderID.swift — added allKnown static array"
    - "AgentsUsageBar/Domain/RefreshInterval.swift — added tomlString computed property"
    - "AgentsUsageBar/Config/ConfigStore.swift — added @MainActor load(preferences:) overload"
    - "AgentsUsageBar/Config/AppConfig.swift — added withEnabled(_:) extensions on all 6 config structs"
    - "AgentsUsageBar/App/AppDependencies.swift — Dependencies gains preferences property; makeProduction() constructs UserPreferencesStore BEFORE ConfigStore.load(preferences:)"
    - "AgentsUsageBar/App/AgentsUsageBarApp.swift — both scenes inject .environment(\\.preferences, dependencies.preferences)"
    - "AgentsUsageBar.xcodeproj/project.pbxproj — wired 4 new files (2 app + 2 test) under UUID namespace AA050200"

key-decisions:
  - "RefreshInterval does NOT conform to RawRepresentable — added .tomlString computed property + parse(_:) for UserDefaults round-trip (avoids destabilising existing Codable conformance)"
  - "@MainActor on ConfigStore.load(preferences:) not nonisolated — reads @MainActor properties on UserPreferencesStore; pure-data load() stays nonisolated for back-compat"
  - "withEnabled(_:) factory methods over mutating var — preserves AppConfig let immutability (Sendable + Equatable still hold); per-provider extension keeps modification surface minimal"
  - "MainActor.assumeIsolated for nonisolated(unsafe) EnvironmentKey defaultValue — required because SwiftUI's EnvironmentKey protocol is non-actor-isolated but UserPreferencesStore is @MainActor"
  - "Direct UserDefaults pre-write in makePrefs() test helper, not setter-then-wait — avoids async didChangeNotification dependency in test setup paths"

patterns-established:
  - "@MainActor overload of nonisolated method on @unchecked Sendable class: pattern for layering MainActor-isolated input on top of an existing non-actor-bound method without breaking back-compat"
  - "withEnabled(_:) factory on Equatable let-struct: surgical mutation pattern for value types with immutable storage and Sendable+Equatable conformance"

requirements-completed: [CFG-05, CFG-06]

# Metrics
duration: ~45min
completed: 2026-05-21
---

# Phase 5 Plan 02: UserPreferencesStore + ConfigStore Precedence Overlay Summary

**`UserPreferencesStore` (@Observable @MainActor, UserDefaults-backed) now persists 6 user-mutable knobs across restarts and hot-reloads them via `UserDefaults.didChangeNotification`; `ConfigStore.load(preferences:)` applies the UserDefaults overlay on top of env > toml > defaults per D-02/D-03 with credentials strictly untouched.**

## Performance

- **Duration:** ~45 min
- **Started:** 2026-05-21T10:02:23Z (approx)
- **Completed:** 2026-05-21 (~50 min after start with mid-task socket drop and resume)
- **Tasks:** 2 of 2 completed
- **Files modified:** 7 (ProviderID.swift, RefreshInterval.swift, ConfigStore.swift, AppConfig.swift, AppDependencies.swift, AgentsUsageBarApp.swift, project.pbxproj)
- **Files created:** 4 (UserPreferencesStore.swift, AppEnvironmentKeys.swift, UserPreferencesStoreTests.swift, ConfigStorePrecedenceTests.swift)
- **New tests:** 14 Swift Testing `@Test` cases (9 UserPreferencesStoreTests + 5 ConfigStorePrecedenceTests)

## Accomplishments

- **`UserPreferencesStore` is live** with `@Observable @MainActor` isolation, 6 observable knob properties + 6 explicit write methods, and `UserDefaults.didChangeNotification`-driven hot-reload (D-04 satisfied at the store layer).
- **`AUBDefaultsKey` namespace** with `aub.*` prefix isolates all Phase 5 UserDefaults entries from system and third-party keys (no key collisions possible).
- **`AppTheme` enum** (light/dark/auto) provides the type-safe surface that `SettingsGeneralTab` (Plan 05-03) will bind a `Picker(...).pickerStyle(.segmented)` to. `ColorScheme?` mapping deliberately deferred to Plan 05-03 to keep `Config/` free of `SwiftUI` import.
- **`ProviderID.allKnown`** is the canonical ordered array (openrouter, claude, codex, gemini, ollama, lmstudio, llamacpp) consumed by `UserPreferencesStore.loadAll()` to enumerate per-provider toggles and by `SettingsProvidersTab` (Plan 05-04) for row enumeration.
- **`\.preferences` SwiftUI environment key** is the single injection point at both scene roots (`MenuBarExtra` and `Settings`) — Plans 05-03/04/06 read from `@Environment(\.preferences)` without touching the composition root.
- **`ConfigStore.load(preferences:)` overload** layers UserDefaults overrides per-field (refreshInterval, threshold, per-provider enabled) while keeping `apiKey` / `bearer` / OAuth credential paths strictly env > toml (D-03, CFG-01 enforced).
- **Composition root** constructs `UserPreferencesStore` BEFORE `ConfigStore.load(preferences:)` so the overlay is applied at launch, and retains `preferences` in `Dependencies` for app lifetime.
- All 14 new tests + 12 regression smoke tests (`AppDependenciesLocalRegistrationTests` + `AppDependenciesCodexGeminiRegistrationTests`) PASS on the verified run.

## Task Commits

Each task was committed atomically:

1. **Task 1: UserPreferencesStore + AppTheme + AUBDefaultsKey + ProviderID.allKnown + preferences env key** — `76a0dcc` (feat)
2. **Task 2: ConfigStore precedence overlay + composition root wiring + 14 tests** — `d358eec` (feat)

## Files Created/Modified

### Created

- **`AgentsUsageBar/Config/UserPreferencesStore.swift`** — `@Observable @MainActor public final class` backed by injectable `UserDefaults`. Six `private(set) var` observable properties (`refreshInterval`, `threshold`, `theme`, `openAtLogin`, `hasSeenWelcome`, `providerEnabled`); six write methods (`setRefreshInterval(_:)`, etc.). `init(defaults:)` calls `loadAll()` synchronously then registers a `UserDefaults.didChangeNotification` observer; on every fire, `loadAll()` runs on `@MainActor`. `deinit` removes the observer. Logger category `"preferences"`. `nonisolated(unsafe) private var changeToken: NSObjectProtocol?` enables deinit access from nonisolated context.
- **`AgentsUsageBar/UI/Environment/AppEnvironmentKeys.swift`** — Declares `private struct UserPreferencesStoreKey: EnvironmentKey` with `nonisolated(unsafe) static let defaultValue` constructed via `MainActor.assumeIsolated { UserPreferencesStore() }` (the Swift 6 idiom for bridging `nonisolated` protocol requirement to `@MainActor` type). `EnvironmentValues.preferences` accessor declared.
- **`AgentsUsageBarTests/ConfigTests/UserPreferencesStoreTests.swift`** — `@Suite(.serialized) @MainActor` with 9 `@Test async throws` cases: 6 setter round-trips, 1 fresh-store defaults check, 1 `didChangeNotification` reload assertion (with 100ms sleep), 1 `absentKey_doesNotOverrideDefaultThreshold` regression (asserts the `object(forKey:) as? Double` pattern correctly returns 0.80 not 0.0 when threshold key is absent).
- **`AgentsUsageBarTests/ConfigTests/ConfigStorePrecedenceTests.swift`** — `@Suite(.serialized) @MainActor` with 5 `@Test throws` cases: UserDefaults beats TOML (refreshInterval), UserDefaults beats default (threshold), credentials not overridden (apiKey from env still authoritative; no AUBDefaultsKey contains credential material), `nil` preferences returns base config unchanged, empty providerEnabled map does not change TOML provider flags. `makePrefs()` test helper writes values directly to `UserDefaults` before constructing the store so `loadAll()` in `init` reads them synchronously (sidesteps the async `didChangeNotification` propagation that the setter-based pattern would require).

### Modified

- **`AgentsUsageBar/Domain/ProviderID.swift`** — Added `public static let allKnown: [ProviderID]` after `localIDs`. Ordered: openrouter, claude, codex, gemini, ollama, lmstudio, llamacpp.
- **`AgentsUsageBar/Domain/RefreshInterval.swift`** — Added `public var tomlString: String` computed property mirroring `parse(_:)` inverse mapping (`.manual` → `"manual"`, `.m5` → `"5m"`, etc.). `UserPreferencesStore` round-trips via this property + `parse(_:)`.
- **`AgentsUsageBar/Config/ConfigStore.swift`** — Added `@MainActor public func load(preferences: UserPreferencesStore? = nil) -> AppConfig` overload. When `preferences == nil`, returns the same result as `load()` (back-compat). Otherwise rebuilds `AppConfig` with `prefs.refreshInterval`, `prefs.threshold`, and per-provider `enabled` flags overridden via `withEnabled(_:)` when keyed in `prefs.providerEnabled`. Credentials path (apiKey, bearer, OAuth) is never touched.
- **`AgentsUsageBar/Config/AppConfig.swift`** — Added internal `withEnabled(_:)` extensions on all 6 per-provider config structs (`OpenRouterConfig`, `CodexConfig`, `GeminiConfig`, `OllamaConfig`, `LMStudioConfig`, `LlamaCppConfig`). Each method returns a copy with `enabled` replaced; preserves `let` immutability + existing `Sendable + Equatable` conformance.
- **`AgentsUsageBar/App/AppDependencies.swift`** — `Dependencies` class gains `public let preferences: UserPreferencesStore` + new last-position init parameter. `makeProduction()` constructs `let preferences = UserPreferencesStore()` BEFORE `ConfigStore(env:).load(preferences: preferences)`. Final `Dependencies(...)` call includes `preferences: preferences`.
- **`AgentsUsageBar/App/AgentsUsageBarApp.swift`** — `MenuBarExtra { PopoverRootView() }` and `Settings { SettingsScene() }` both gain `.environment(\.preferences, dependencies.preferences)` after the existing `.clockService` injection.
- **`AgentsUsageBar.xcodeproj/project.pbxproj`** — UUID namespace `AA050200` for Plan 05-02. 4 new files wired: 2 app sources (`UserPreferencesStore.swift` in `Config` group, `AppEnvironmentKeys.swift` in UI/Environment group), 2 test sources (both in `ConfigTests` group). 4 PBXBuildFile + 4 PBXFileReference entries. App-target + test-target `PBXSourcesBuildPhase` extended.

## Decisions Made

- **`@MainActor` on `ConfigStore.load(preferences:)` not `nonisolated`.** The overload reads `@MainActor`-isolated properties on `UserPreferencesStore`, so the method itself must run on the main actor. The original `nonisolated public func load() -> AppConfig` stays untouched and back-compatible — call sites that don't need the preferences overlay still work from any context.
- **`withEnabled(_:)` factory methods on each config struct.** Plan text suggested `mutating func setProviderEnabled` on `AppConfig`, but all `AppConfig` properties are `let` (intentional — preserves `Sendable + Equatable`). Per-struct `withEnabled(_:)` is the additive, type-safe, immutability-preserving alternative.
- **`RefreshInterval.tomlString` computed property added** — `RefreshInterval` does NOT conform to `RawRepresentable` (the enum cases don't have raw values; the `parse(_:)` function provides the only string mapping). Adding `tomlString` as an explicit computed property is the surgical inverse mapping without destabilising the existing `Codable` conformance.
- **`MainActor.assumeIsolated` for `EnvironmentKey.defaultValue`.** SwiftUI's `EnvironmentKey` protocol requires a `nonisolated static var defaultValue`, but `UserPreferencesStore` is `@MainActor`. Wrapping the default-instance construction in `MainActor.assumeIsolated { UserPreferencesStore() }` and pinning the storage with `nonisolated(unsafe)` is the Swift 6 idiom for bridging the protocol requirement to the actor-isolated type.
- **`makePrefs()` test helper writes to `UserDefaults` directly before `init`** — the setter-based path would write to UserDefaults but `loadAll()` is only re-invoked asynchronously via `didChangeNotification`, so `load(preferences:)` could see stale defaults. Writing directly to the suite first lets the store's `init` → `loadAll()` synchronously pick up the values.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 — Bug] Plan's `RefreshInterval.rawValue` did not exist**
- **Found during:** Task 1 (compile diagnostic: `value of type 'RefreshInterval' has no member 'rawValue'` and `incorrect argument label in call (have 'rawValue:', expected 'from:')`).
- **Issue:** `RefreshInterval` does NOT conform to `RawRepresentable` (`String`); it is a plain enum with `Codable` synthesis. The plan's reference code used `RefreshInterval(rawValue:)` and `.rawValue` — neither compiles.
- **Fix:** Added `public var tomlString: String` computed property mirroring `parse(_:)` inverse mapping. `UserPreferencesStore.setRefreshInterval(_:)` writes `v.tomlString`; `loadAll()` reads via `RefreshInterval.parse(...)`. Surgical change — no impact on existing `Codable` conformance or `parse(_:)` call sites.
- **Files modified:** `AgentsUsageBar/Domain/RefreshInterval.swift`, `AgentsUsageBar/Config/UserPreferencesStore.swift`
- **Verification:** `UserPreferencesStoreTests/roundTrip_refreshInterval()` PASSES.
- **Committed in:** `76a0dcc` (Task 1)

**2. [Rule 1 — Bug] Plan's `EnvironmentKey.defaultValue` used `@MainActor static var`**
- **Found during:** Task 1 (compile diagnostic: `conformance of 'UserPreferencesStoreKey' to protocol 'EnvironmentKey' crosses into main actor-isolated code and can cause data races`).
- **Issue:** SwiftUI's `EnvironmentKey` protocol requires `nonisolated static var defaultValue`. The plan's `@MainActor static var defaultValue: UserPreferencesStore = UserPreferencesStore()` does not satisfy the protocol under Swift 6 strict concurrency.
- **Fix:** Switched to `nonisolated(unsafe) static let defaultValue` with the initialiser wrapped in `MainActor.assumeIsolated { UserPreferencesStore() }`. Documents the unsafe boundary (SwiftUI reads environment defaults on main thread in practice) without requiring an actor crossing in the static initialiser.
- **Files modified:** `AgentsUsageBar/UI/Environment/AppEnvironmentKeys.swift`
- **Verification:** Build succeeds; `\.preferences` environment key works in both scene injections.
- **Committed in:** `76a0dcc` (Task 1)

**3. [Rule 1 — Bug] Plan's `nonisolated(unsafe)` was rejected on `changeToken` then required after `@MainActor load()` annotation**
- **Found during:** Task 1 (two iterations: first compile said `'nonisolated(unsafe)' has no effect on 'changeToken'`, second said `main actor-isolated property 'changeToken' can not be referenced from a nonisolated context`).
- **Issue:** `deinit` in a `@MainActor` class is `nonisolated` in Swift 6. Reading the `changeToken` property from `deinit` to call `removeObserver` requires the property to be visible from nonisolated context. Plain `var changeToken` is `@MainActor`-isolated; `nonisolated(unsafe) var` is the correct Swift 6 escape hatch documenting the deinit access pattern.
- **Fix:** Re-added `nonisolated(unsafe)` on `changeToken`. The `(unsafe)` is genuinely required here — the property is written once on MainActor at the end of init, then read once from nonisolated deinit. The compile diagnostic that first removed it was triggered by a transient state where deinit wasn't yet accessing it.
- **Files modified:** `AgentsUsageBar/Config/UserPreferencesStore.swift`
- **Verification:** Build succeeds; deinit cleanly removes the observer.
- **Committed in:** `76a0dcc` (Task 1)

**4. [Rule 1 — Bug] AppConfig's `let` properties blocked plan's `mutating var` suggestion**
- **Found during:** Task 2 (`AppConfig` properties cannot be reassigned).
- **Issue:** Plan suggested making `config.refreshInterval` mutable in `AppConfig`. All `AppConfig` properties are `let`; flipping them to `var` would break `Equatable` synthesis assumptions and unnecessarily widen the mutation surface.
- **Fix:** Added per-provider `withEnabled(_:)` factory extensions and rebuild `AppConfig` end-to-end in `load(preferences:)` with overridden knob values. Preserves immutability + existing `Sendable + Equatable` conformance.
- **Files modified:** `AgentsUsageBar/Config/AppConfig.swift`, `AgentsUsageBar/Config/ConfigStore.swift`
- **Verification:** Build succeeds; all 5 `ConfigStorePrecedenceTests` PASS.
- **Committed in:** `d358eec` (Task 2)

**5. [Rule 1 — Bug] `ConfigStore.load(preferences:)` could not read `@MainActor` properties from nonisolated context**
- **Found during:** Task 2 (compile diagnostic: `main actor-isolated property 'refreshInterval' can not be referenced from a nonisolated context`).
- **Issue:** `ConfigStore` is `@unchecked Sendable` with nonisolated methods. The new `load(preferences:)` overload reads `prefs.refreshInterval`, `prefs.threshold`, and `prefs.providerEnabled` — all `@MainActor`-isolated on `UserPreferencesStore`. The compiler correctly rejected the cross-isolation access.
- **Fix:** Annotated `load(preferences:)` with `@MainActor`. The original `load()` stays nonisolated for back-compat. Composition root calls happen from `@MainActor` (`AppDependencies.makeProduction` is `@MainActor`), so no call-site churn.
- **Files modified:** `AgentsUsageBar/Config/ConfigStore.swift`
- **Verification:** Build succeeds; `AppDependenciesLocalRegistrationTests/appDependenciesMakeProduction_smokeTest` regression PASSES.
- **Committed in:** `d358eec` (Task 2)

**6. [Rule 1 — Bug] `makePrefs()` setter path saw stale values in `load(preferences:)`**
- **Found during:** Task 2 verification (initial test run: `userDefaultsBeatsToml_refreshInterval` and `userDefaultsBeatsDefault_threshold` failed; the other 3 `ConfigStorePrecedenceTests` passed because they did not depend on synchronously-read preference values).
- **Issue:** The original `makePrefs()` called `store.setRefreshInterval(.m2)` then immediately returned the store. `UserPreferencesStore.setRefreshInterval` writes to `UserDefaults` but `loadAll()` only re-runs via the async `UserDefaults.didChangeNotification` observer (queue: `.main`, fired post-write but on the next runloop tick). When `load(preferences:)` reads `prefs.refreshInterval`, it still sees the initial `.m5` default.
- **Fix:** `makePrefs()` now writes values DIRECTLY to the underlying `UserDefaults` suite BEFORE constructing the store. The store's `init` calls `loadAll()` synchronously, which reads the pre-seeded values. No async wait required.
- **Files modified:** `AgentsUsageBarTests/ConfigTests/ConfigStorePrecedenceTests.swift`
- **Verification:** All 5 `ConfigStorePrecedenceTests` PASS on the verified run.
- **Committed in:** `d358eec` (Task 2)

---

**Total deviations:** 6 auto-fixed (all Rule 1 — bugs / compile errors caused by plan's reference code not matching the actual Swift 6 / project surface)
**Impact on plan:** All six auto-fixes were necessary for the plan to compile and behave correctly. No Rule 4 (architectural) escalation. Plan executed within ~45 min budget.

## Issues Encountered

- **Mid-task socket drop after Task 1 commit:** Orchestrator socket dropped while Task 2 was in progress (after `xcodebuild build` returned BUILD SUCCEEDED, before test verification). Harness re-spawn warned of stale SourceKit cache diagnostics (e.g. "Cannot find type 'ProviderID'", "AppConfig not Equatable", "AppDependencies type not found"). Fresh `xcodebuild build` immediately returned `BUILD SUCCEEDED` — the warnings were SourceKit cache artifacts, not real compile errors. No code changes required on resume; continued straight to test verification → Task 2 commit.
- **2 `ConfigStorePrecedenceTests` failed on first run** due to `makePrefs()` setter pattern (Rule-1 deviation #6 above). Fixed by writing directly to UserDefaults before store construction. All 14 tests now PASS.

## User Setup Required

None. Plan 05-02 introduces no new entitlements, env vars, Info.plist changes, or CI secrets. UserDefaults storage uses the existing `.standard` suite on the app's domain; no migration is needed (existing v1 users start with all defaults).

## Self-Check

- [x] `AgentsUsageBar/Config/UserPreferencesStore.swift` exists
- [x] `AgentsUsageBar/UI/Environment/AppEnvironmentKeys.swift` exists
- [x] `AgentsUsageBarTests/ConfigTests/UserPreferencesStoreTests.swift` exists
- [x] `AgentsUsageBarTests/ConfigTests/ConfigStorePrecedenceTests.swift` exists
- [x] Commit `76a0dcc` exists (Task 1 — verified via `git log`)
- [x] Commit `d358eec` exists (Task 2 — verified via `git log`)
- [x] `grep -c 'class UserPreferencesStore' AgentsUsageBar/Config/UserPreferencesStore.swift` returns 1
- [x] `grep -c 'allKnown' AgentsUsageBar/Domain/ProviderID.swift` returns ≥1
- [x] `grep -c 'load(preferences:' AgentsUsageBar/Config/ConfigStore.swift` returns ≥1
- [x] `grep -c 'preferences, dependencies.preferences' AgentsUsageBar/App/AgentsUsageBarApp.swift` returns 2 (MenuBarExtra + Settings)
- [x] `grep -c 'aub\\.' AgentsUsageBar/Config/UserPreferencesStore.swift` returns ≥5 (key namespace used)
- [x] All 9 `UserPreferencesStoreTests` PASS
- [x] All 5 `ConfigStorePrecedenceTests` PASS
- [x] `AppDependenciesLocalRegistrationTests/appDependenciesMakeProduction_smokeTest` regression PASSES
- [x] `AppDependenciesCodexGeminiRegistrationTests/makeProduction_smoke` regression PASSES
- [x] No `.zshrc` / `.bashrc` / `config.fish` references in Plan 05-02 new files (CFG-06)
- [x] No credential/secret keys in UserDefaults write paths (D-03 / threat T-05-02-01)
- [x] App-target `xcodebuild build` succeeds

## Self-Check: PASSED
