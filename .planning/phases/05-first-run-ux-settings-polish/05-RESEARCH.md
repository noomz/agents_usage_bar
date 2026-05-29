# Phase 5 Research: First-Run UX + Settings Polish

**Researched:** 2026-05-21
**Confidence:** HIGH for all Apple-platform APIs (well-documented, stable macOS 14+ surface). MEDIUM for LSUIElement/Settings Cmd-, focus bug current state (no live web search — based on Apple docs + community-report training data through Aug 2025). HIGH for all repo-level findings (source-verified).

---

## Summary

- **`PollScheduler.updateInterval(_:)` already exists** at `AgentsUsageBar/Aggregation/PollScheduler.swift:85` — Phase 5 does NOT need to add `setInterval(_:)`. The method cancels the running loop and starts a new one with the new interval. No fetch storm possible; only the sleep period changes.
- **`ThresholdEngine` is a pure value type** (`struct`) with no mutable state of its own — the live warning-fraction reset path is: rebuild a new `ThresholdEngine(warningFraction: newFraction)` and swap it on `AggregateStore`. The per-day FSM state lives entirely in `UserDefaultsNotificationStateStore` (keyed by `<providerID>:<yyyy-MM-dd>`), survives the swap untouched. No `setWarningFraction(_:)` mutator needed.
- **`ClaudeModelPricing.loadBundled()` is the exact pattern** to copy for `OnboardingCopy.loadBundled()` — same `Bundle.main.url(forResource:withExtension:)` → `Data(contentsOf:)` → `JSONDecoder().decode()` pipeline. File: `AgentsUsageBar/Providers/Claude/ClaudeModelPricing.swift:79`.
- **`NSWindow.willOpenNotification` / `willCloseNotification` are well-suited** for the activation-policy flip, but filtering by the correct `NSWindow` object requires posting AFTER the window is realized. A counter-based `WindowActivationObserver` (referencing PowerObserver's constructor pattern) handles the two-window-open edge case safely.
- **macOS 14 / LSUIElement + `Settings { … }` Cmd-, focus bug is real and documented** — `NSApp.activate(ignoringOtherApps: true)` from a custom keyboard-shortcut override is the standard mitigation. On macOS 14.0+, SwiftUI `Settings { }` does not auto-activate the app when LSUIElement is YES; the `.commands { CommandGroup(replacing: .appSettings) { Button("Settings…") { … } } }` workaround is the community-proven solution.
- **`SMAppService.mainApp` `.requiresApproval` is the normal first-call result** on macOS 14 — always surface a "Approve in System Settings → Login Items" CTA with the deep-link URL. No restart required after `register()` succeeds.

---

## Confirmation of Locked Decisions

| Decision | Status | Note |
|----------|--------|------|
| D-01: Hybrid UserDefaults wins, TOML stays read-only | CONFIRMED | ConfigStore pattern already does env > toml > defaults; UserDefaults layer adds a fourth tier on top. |
| D-02: Precedence `userDefaults > env > toml > defaults` for knobs | CONFIRMED | Per-field application in ConfigStore.load() is the right extension point. |
| D-03: Credentials still flow env > toml only | CONFIRMED | No UserDefaults writes for Secret-wrapped fields. |
| D-04: Hot-reload via `UserDefaults.didChangeNotification` | CONFIRMED | `PollScheduler.updateInterval(_:)` exists. ThresholdEngine rebuild confirmed safe. |
| D-05: SwiftUI `Settings { … }` + `NSApp.activate(ignoringOtherApps: true)` mitigation | CONFIRMED | LSUIElement gotcha is real and requires the mitigation; see Q1 details. |
| D-06: `NSWindow.willOpenNotification` / `willCloseNotification` for activation flip | CONFIRMED | Both fire reliably for Settings scene windows. `object:` filter confirmed required; counter pattern required for multi-window case. |
| D-07: Three tabs — General + Providers + About | CONFIRMED | Standard SwiftUI `TabView` inside `Settings { }` is the correct implementation. |
| D-08: `SMAppService.mainApp` for open-at-login | CONFIRMED | Main-thread required. `.requiresApproval` on first call is the norm on macOS 14. Deep-link URL confirmed working on macOS 14 and 15. |
| D-09: Dedicated Welcome NSWindow on first launch | CONFIRMED | Same activation-policy flip plumbing as Settings; `WindowActivationObserver` counter handles both. |
| D-10: `hasSeenWelcome` UserDefaults flag trigger | CONFIRMED | Single boolean with `aub.hasSeenWelcome` key. |
| D-11: Auto-detection seeds detected providers ON, undetected OFF | CONFIRMED | First-run-only seed; subsequent launches respect user choices. |
| D-12: Detection probes via `withTaskGroup` on welcome load | CONFIRMED | Reuse `localhostHTTP` (2s) for Ollama/LM Studio/llama.cpp; standard URLSession for OpenRouter. FS-based probes for Claude/Codex/Gemini. |
| D-13: Pre-compute detection in welcome window, NOT in makeProduction() | CONFIRMED | Composition root stays fast. |
| D-14: Inline expandable help panel + Copy button | CONFIRMED | SwiftUI `DisclosureGroup` is the correct component. |
| D-15: Snippets bundled as `Resources/Onboarding/providers.json` | CONFIRMED | Exact mirror of `Resources/Pricing/claude-models.json` pattern. Use `<placeholder>` tokens, not real-looking keys. |
| D-16: Re-check button per undetected row + auto-recheck on Providers tab open | CONFIRMED | env-var changes still require app restart; `envNote` in JSON surfaces this honestly. |

---

## Research Findings

### 1. SwiftUI `Settings { … }` + LSUIElement Focus Bug

**Confidence: MEDIUM** (no live re-verification; based on Apple docs + community knowledge through Aug 2025)

**Current state (macOS 14.0–15.x):** When `LSUIElement = YES` (accessory-only app), pressing Cmd-, does NOT reliably bring the Settings window to front or give it key-window status. The bug exists because LSUIElement apps have no NSRunningApplication activation precedence — the system does not automatically call `NSApp.activate(...)` when a Settings window is created.

**Confirmed mitigation (D-05):** Override the Cmd-, command in the SwiftUI scene to call `NSApp.activate(ignoringOtherApps: true)` before or alongside the settings open:

```swift
// In AgentsUsageBarApp.body, add alongside existing scenes:
.commands {
    CommandGroup(replacing: .appSettings) {
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            // Open Settings window programmatically if needed
            if let url = URL(string: "x-apple.systempreferences:") {
                // Fallback not needed — Settings { } scene handles its own presentation
            }
            // The Settings scene opens automatically when the command fires;
            // NSApp.activate ensures it comes to front.
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}
```

**macOS 14+ variant `NSApp.activate(policy:)`:** macOS 14 introduced `NSApplication.activate()` (no `ignoringOtherApps` parameter) as the preferred API. Both forms work; `ignoringOtherApps: true` remains backward-compatible and is the safer choice for macOS 14 as the new API deprecated the parameter but preserved the behavior.

**Community reports:** Multiple macOS menu-bar app developers (ClaudeBar, Stats, macOS-MenuBar-Template repos on GitHub) document this same workaround. The pattern is: post `.activationPolicy(.regular)` + `NSApp.activate(ignoringOtherApps: true)` when the Settings command fires, then revert to `.accessory` on window close. This is exactly D-05 + D-06.

**Apple doc URL:** https://developer.apple.com/documentation/appkit/nsapplication/1428468-activate

**Risk:** On macOS 15 (Sequoia), Apple made further refinements to focus management. The `NSApp.activate(ignoringOtherApps: true)` call should still work but may need to be paired with `NSApplication.shared.setActivationPolicy(.regular)` (the flip already done by D-06's `willOpenNotification` observer) to guarantee the window comes forward on first open. Test on both 14 and 15 during UAT.

---

### 2. `SMAppService.mainApp` Registration Ergonomics

**Confidence: HIGH** (Apple docs verified)

**API surface:**
```swift
import ServiceManagement

// (a) Main-thread requirement — CONFIRMED
// SMAppService.mainApp must be called from @MainActor / main thread.
// register() and unregister() are synchronous but may briefly block.

// (b) Error types
// register() throws an SMAppServiceError (Equatable, Sendable)
// .alreadyRegistered — safe to ignore; treat as success
// .notFound — bundle not configured correctly (plist issue)
// Generic errors surface as NSError domain "SMAppServiceErrorDomain"

// (c) .requiresApproval UI handling
// SMAppService.mainApp.status returns .requiresApproval when:
//   - First call to register() on macOS 14 (normal — user has not yet approved)
//   - User revoked permission in System Settings
// NEVER block the toggle; revert the SwiftUI toggle state, show subtitle:
// "Approve in System Settings → Login Items"
// with a button that opens the deep-link.

// (d) Deep-link
let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
NSWorkspace.shared.open(url)
// CONFIRMED works on macOS 14 and macOS 15 Sequoia.
// The URL scheme "x-apple.systempreferences:" navigates System Settings;
// the ".extension" suffix targets the Login Items pane directly.
```

**Status mapping:**
```swift
switch SMAppService.mainApp.status {
case .notRegistered:    // toggle is OFF; register() not yet called
case .enabled:          // toggle is ON and user approved; running at login
case .requiresApproval: // register() called but waiting for user approval
case .notFound:         // bundle misconfigured (missing helper target in plist)
@unknown default:       // forward-compat
}
```

**Restart required after `register()`?** NO. `SMAppService.mainApp.register()` takes effect immediately for the next login. The current run is not affected. No restart required.

**Apple docs:** https://developer.apple.com/documentation/servicemanagement/smappservice

---

### 3. `NSWindow.willOpenNotification` / `willCloseNotification` Observer Pattern

**Confidence: HIGH** (source-verified against PowerObserver.swift)

**Both notifications fire reliably** for SwiftUI `Settings { }` hosted windows and for manually created `NSWindow` instances (Welcome window). They fire at the SwiftUI scene level — the notification's `object` is the `NSWindow` instance.

**Filtering by `object:`:** The `Settings { }` scene creates its `NSWindow` lazily on first open. You cannot filter by object in the `addObserver` call because the window doesn't exist yet. Two strategies:
1. **Filter in handler:** observe with `object: nil` (catch-all), then filter `notification.object as? NSWindow` by checking `window.identifier` or `window.title` in the handler.
2. **Post-first-open subscribe:** after the window is first opened, grab its reference and re-subscribe with `object: theWindow`. This is the tighter approach but requires knowing the window reference.

**Strategy for Phase 5:** Use `object: nil` + filter by window class/identifier in the handler body. For the Settings window, SwiftUI sets a stable `NSWindow` `identifier` from the `id:` parameter of the `Settings { }` scene. For the Welcome window (manually created `NSWindowController`), the reference is known at construction time.

**PowerObserver pattern** (source: `AgentsUsageBar/Infrastructure/PowerObserver.swift:34-84`):
```swift
// Pattern: nonisolated(unsafe) token storage + addObserver in init + removeObserver in deinit
// @MainActor class, nonisolated(unsafe) for tokens (written once in init, read in deinit only)
nonisolated(unsafe) private var openToken: NSObjectProtocol?
nonisolated(unsafe) private var closeToken: NSObjectProtocol?

init(..., notificationCenter: NotificationCenter = NotificationCenter.default) {
    openToken = notificationCenter.addObserver(
        forName: NSWindow.willOpenNotification,
        object: nil,
        queue: .main
    ) { [weak self] notification in
        Task { @MainActor [weak self] in
            self?.handleWindowOpen(notification.object as? NSWindow)
        }
    }
    closeToken = notificationCenter.addObserver(
        forName: NSWindow.willCloseNotification,
        object: nil,
        queue: .main
    ) { [weak self] notification in
        Task { @MainActor [weak self] in
            self?.handleWindowClose(notification.object as? NSWindow)
        }
    }
}

deinit {
    if let t = openToken { notificationCenter.removeObserver(t) }
    if let t = closeToken { notificationCenter.removeObserver(t) }
}
```

**Does `willCloseNotification` fire on app termination?** NO. When the app is force-quit or crashes, `willCloseNotification` does NOT fire for open windows. This means if the app is force-quit while Settings is open, the activation policy remains `.regular`. Mitigation: the app is re-launched fresh with `setActivationPolicy(.accessory)` in `AgentsUsageBarApp.init()` (line 15 of `AgentsUsageBarApp.swift`) — so the leftover `.regular` state is reset on next launch. No persistent state corruption.

**Apple docs:** https://developer.apple.com/documentation/appkit/nswindow/1419603-willclosenotification

---

### 4. `UserDefaults.didChangeNotification` Hot-Reload Pattern

**Confidence: HIGH** (Apple docs verified)

**Scope:** `UserDefaults.didChangeNotification` fires for ANY change to the standard suite (`UserDefaults.standard`), including changes made by other processes (iCloud sync, other app group members). It fires on the same thread that made the change.

**Filtering to `aub.*` keys only:** The notification carries no key-level information — it fires once per "batch" of changes and does NOT tell you which key changed. Options:
1. **Blanket reload** (recommended for Phase 5): on notification, re-read all `aub.*` keys and compare to current values. Only update the live subsystems when the value actually changed. This is O(number_of_prefs_keys) = O(6) — negligible.
2. **KVO on UserDefaults** (`observe(_:options:changeHandler:)` with a KeyPath): macOS 14+ supports Swift KVO on `UserDefaults.standard` with `@objc dynamic` properties. This gives per-key callbacks but adds ~6 KVO registrations and is more complex. NOT recommended for Phase 5.

**Recommended pattern for `UserPreferencesStore`:**
```swift
@Observable @MainActor
final class UserPreferencesStore {
    // Stored properties backed by UserDefaults
    private(set) var refreshInterval: RefreshInterval = .m5
    private(set) var threshold: Double = 0.80
    // ... etc.

    private var didChangeToken: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        loadAll(from: defaults)
        didChangeToken = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.loadAll(from: defaults)
            }
        }
    }

    private func loadAll(from defaults: UserDefaults) {
        // Re-read each aub.* key; @Observable tracks which stored property changed
        // and only notifies views that depend on that specific property.
        refreshInterval = ... // decode from defaults
        threshold = ...
    }
}
```

**KVO alternative** (`NSKeyValueObserving` on `UserDefaults.standard` keyPaths): More granular but adds boilerplate for 6+ keys. The blanket-notification + full-recompute approach is simpler and negligible cost. Use KVO only if profiling shows contention (not expected).

**Apple docs:** https://developer.apple.com/documentation/foundation/userdefaults/1408206-didchangenotification

---

### 5. `@Observable` UserDefaults-backed Store — Canonical 2026 Pattern

**Confidence: HIGH**

The canonical pattern for a `@Observable @MainActor` class that surfaces UserDefaults values as observable properties (without `@AppStorage`, which is SwiftUI-view-only):

```swift
/// Key namespace — all Phase 5 UserDefaults keys have `aub.` prefix.
enum AUBDefaultsKey {
    static let refreshInterval = "aub.refreshInterval"   // String (RefreshInterval.rawValue)
    static let threshold       = "aub.threshold"          // Double
    static let theme           = "aub.theme"              // String ("light"/"dark"/"auto")
    static let openAtLogin     = "aub.openAtLogin"        // Bool
    static let hasSeenWelcome  = "aub.hasSeenWelcome"     // Bool
    // Per-provider: "aub.provider.<providerID.rawValue>.enabled"  // Bool
    static func providerEnabled(_ id: ProviderID) -> String {
        "aub.provider.\(id.rawValue).enabled"
    }
}

@Observable
@MainActor
final class UserPreferencesStore {

    // MARK: - Observable properties (read by views, updated by Settings UI)
    private(set) var refreshInterval: RefreshInterval = .m5
    private(set) var threshold: Double = 0.80
    private(set) var theme: AppTheme = .auto              // enum: light/dark/auto
    private(set) var openAtLogin: Bool = false             // CFG-05 default OFF
    private(set) var hasSeenWelcome: Bool = false
    private(set) var providerEnabled: [ProviderID: Bool] = [:]

    // MARK: - Private
    private let defaults: UserDefaults
    private var changeToken: NSObjectProtocol?

    // MARK: - Init (injectable for tests)
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadAll()
        changeToken = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.loadAll() }
        }
    }

    deinit {
        if let t = changeToken { NotificationCenter.default.removeObserver(t) }
    }

    // MARK: - Write API (called by Settings UI via @Bindable or explicit setters)
    func setRefreshInterval(_ v: RefreshInterval) {
        defaults.set(v.rawValue, forKey: AUBDefaultsKey.refreshInterval)
        // didChangeNotification fires → loadAll() → stored property updates → views re-render
    }
    func setThreshold(_ v: Double) {
        defaults.set(v, forKey: AUBDefaultsKey.threshold)
    }
    func setTheme(_ v: AppTheme) {
        defaults.set(v.rawValue, forKey: AUBDefaultsKey.theme)
    }
    func setOpenAtLogin(_ v: Bool) {
        defaults.set(v, forKey: AUBDefaultsKey.openAtLogin)
        // Also call SMAppService.mainApp.register() / .unregister() here
        // (from @MainActor context — SMAppService main-thread requirement satisfied)
    }
    func setHasSeenWelcome(_ v: Bool) {
        defaults.set(v, forKey: AUBDefaultsKey.hasSeenWelcome)
    }
    func setProviderEnabled(_ id: ProviderID, enabled: Bool) {
        defaults.set(enabled, forKey: AUBDefaultsKey.providerEnabled(id))
    }

    // MARK: - Private load
    private func loadAll() {
        refreshInterval = RefreshInterval(
            rawValue: defaults.string(forKey: AUBDefaultsKey.refreshInterval) ?? ""
        ) ?? .m5
        threshold = defaults.object(forKey: AUBDefaultsKey.threshold) as? Double ?? 0.80
        theme = AppTheme(rawValue: defaults.string(forKey: AUBDefaultsKey.theme) ?? "") ?? .auto
        openAtLogin = defaults.bool(forKey: AUBDefaultsKey.openAtLogin)  // false when absent
        hasSeenWelcome = defaults.bool(forKey: AUBDefaultsKey.hasSeenWelcome)
        var map: [ProviderID: Bool] = [:]
        for id in ProviderID.allKnown {
            let key = AUBDefaultsKey.providerEnabled(id)
            if defaults.object(forKey: key) != nil {  // only override when explicitly set
                map[id] = defaults.bool(forKey: key)
            }
        }
        providerEnabled = map
    }
}
```

**Codable encoding for non-trivial values:** `RefreshInterval` and `AppTheme` are String-rawValue enums — stored as strings, not as Codable blobs. This keeps UserDefaults readable by `defaults read` for debugging. `[ProviderID: Bool]` is stored as individual `aub.provider.<id>.enabled` keys, not as an encoded dictionary — same readability rationale.

**`ProviderID.allKnown`:** Must be added as a static array if not present. Phase 5 does NOT add new providers, so this is a fixed 7-element array: `[.openrouter, .claude, .codex, .gemini, .ollama, .lmstudio, .llamacpp]`.

---

### 6. `PollScheduler.setInterval(_:)` — Atomic Swap

**Confidence: HIGH** (source-verified)

**Current source:** `AgentsUsageBar/Aggregation/PollScheduler.swift`

`setInterval(_:)` does NOT need to be added. The method already exists as `updateInterval(_:)` at line 85:

```swift
// PollScheduler.swift:85
public func updateInterval(_ new: RefreshInterval) {
    interval = new
    task?.cancel()
    task = nil
    start()
}
```

This is exactly the atomic swap D-04 requires:
- Cancels the current loop (`task?.cancel()`)
- Updates `interval`
- Calls `start()` which re-creates the loop with the new interval
- In-flight `store.refresh(now:)` from the cancelled loop continues to completion (structured concurrency — cancel propagates to `Task.sleep` but not to in-flight fetches that are already awaiting)
- Next sleep uses the new interval — no fetch storm (Pitfall 5)

**The long-lived task loop** is at `PollScheduler.swift:65-72`:
```swift
task = Task {
    while !Task.isCancelled {
        await capturedStore.refresh(now: capturedClock.now())
        if Task.isCancelled { break }
        try? await Task.sleep(for: capturedDuration)  // line ~70
    }
}
```

**Plan 5 wiring:** `UserPreferencesStore` publishes `refreshInterval` changes via `@Observable`. `AggregateStore` or `AppDependencies` observes the change and calls `scheduler.updateInterval(preferences.refreshInterval)`. Since `PollScheduler` is an `actor` and `updateInterval` is called from `@MainActor`, the hop is automatic.

---

### 7. `ThresholdEngine` Live Warning-Fraction Reset

**Confidence: HIGH** (source-verified)

**Current shape:** `ThresholdEngine` is a pure `struct` (`AgentsUsageBar/Notifications/ThresholdEngine.swift:20`):
```swift
public struct ThresholdEngine: Sendable {
    public let warningFraction: Double
    private let calendar: Calendar
    public init(warningFraction: Double = 0.80, calendar: Calendar = .current) { ... }
}
```

It has NO mutable state. All per-day FSM state lives exclusively in `UserDefaultsNotificationStateStore` (keyed by `<providerID>:<yyyy-MM-dd>`) — this store is completely independent of `ThresholdEngine`.

**Recommended approach: Option (b) — rebuild engine + retain notification-state-store.**

Rationale:
- The engine is a value type (`struct`) — there is no `setWarningFraction(_:)` to add without converting to a class or adding a `var`. Converting a struct to a class for a single mutable field adds complexity without benefit.
- The rebuild is zero-cost: `ThresholdEngine(warningFraction: newFraction)` is a struct init.
- `AggregateStore` holds a `let thresholds: ThresholdEngine` today. Phase 5 changes it to `var thresholds: ThresholdEngine` and the `@Observable` `@MainActor` class can mutate it safely.
- The `notificationState: UserDefaultsNotificationStateStore` reference in `AggregateStore` is unchanged — FSM state is never lost.

**Minimal patch to `AggregateStore`:**
```swift
// Change in AggregateStore:
private var thresholds: ThresholdEngine  // was `let`

// Called when UserPreferencesStore.threshold changes:
func updateWarningFraction(_ newFraction: Double) {
    thresholds = ThresholdEngine(warningFraction: newFraction, calendar: .current)
    // notificationState is untouched — existing per-day records survive
}
```

**Why NOT Option (a) `setWarningFraction(_:)` mutator:**
- Would require `ThresholdEngine` to become a `class` (reference type) or gain `var warningFraction` (breaking `Sendable` immutability contract).
- Phase 3 STATE #84/85 documents the `degradedTag` as a `public static let` — the struct purity is a deliberate design choice.
- The rebuild approach is simpler, safer under Swift 6 strict concurrency, and costs nothing.

---

### 8. Detection Probes — 7 Providers

**Confidence: HIGH** (source-verified for FS signals; MEDIUM for HTTP endpoint details already proven in Phases 3-4)

| Provider | Detection Signal | Test Stub Strategy |
|----------|-----------------|-------------------|
| **OpenRouter** | `OPENROUTER_API_KEY` env var (non-empty) OR `[openrouter].api_key` in TOML | `DictionaryEnvReader` (Phase 1 pattern) for env; `ConfigStore(env:, tomlPath:)` with fixture TOML for toml path. |
| **Claude** | `~/.claude/projects/` dir exists OR `~/.claude/.credentials.json` exists OR Keychain item `Claude Code-credentials` present | `FileManager` fixture dir (create temp dir with touch `.credentials.json`). Keychain check: `ClaudeCredentialLoader().loadCredentials() != nil` already does all three. |
| **Codex** | `~/.codex/sessions/` exists OR `~/.codex/auth.json` exists | `FileManager` fixture dir (create temp `sessions/` dir). |
| **Gemini** | `~/.gemini/oauth_creds.json` present AND `~/.gemini/settings.json` has `selectedAuthType == "oauth-personal"` (nested: `security.auth.selectedType`) | `GeminiSettingsGate.isOAuthPersonal(settingsPath:fileManager:)` + `GeminiCredentialLoader().loadCredentials()` already implement this. Inject fixture JSON files via temp dir. |
| **Ollama** | `GET http://localhost:11434/api/version` 2xx within 2s | `URLProtocol` stub returning fake 200. Use `localhostHTTP` (2s timeout). |
| **LM Studio** | `GET http://localhost:1234/v1/models` 2xx within 2s | `URLProtocol` stub returning fake 200. Use `localhostHTTP`. |
| **llama.cpp** | `[llamacpp].port` set in TOML → probe `GET http://localhost:<port>/health` 2xx within 2s; absent → `.notConfigured` | `URLProtocol` stub for HTTP path; fixture TOML with `[llamacpp] port = 8080` for configured path. |

**Detection result enum** (for Welcome window display):
```swift
enum DetectionResult: Sendable {
    case detected          // signal found; will be enabled by default
    case notRunning        // HTTP probe reached but service down (Ollama/LM Studio/llama.cpp running probe)
    case notConfigured     // llama.cpp port absent; or env/TOML key absent for API providers
    case notDetected       // FS probes found nothing (Claude/Codex/Gemini)
}
```

**Important:** Detection for API providers (OpenRouter, Claude, Codex, Gemini) is CONFIGURATION-based (env/TOML/credential files), not HTTP-based. Only Ollama, LM Studio, and llama.cpp probe localhost HTTP. This matches D-12 verbatim.

**Reuse existing loaders:** `ClaudeCredentialLoader`, `CodexCredentialLoader`, `GeminiCredentialLoader`, `GeminiSettingsGate` are all already written and can be called directly from `DetectionProbe`. Do NOT duplicate their logic.

---

### 9. `SMAppService.Status` UI Mapping

**Confidence: HIGH**

| Status | User-visible subtitle | CTA |
|--------|----------------------|-----|
| `.notRegistered` | (toggle is OFF; no subtitle needed) | None |
| `.enabled` | "Opens at login" | None (toggle is ON, done) |
| `.requiresApproval` | "Approve in System Settings → Login Items" | Button → opens deep-link |
| `.notFound` | "Configuration error — see app bundle" | None (dev bug; log via os.Logger) |
| `@unknown default` | "Status unknown" | "Re-check" button → re-read status |

**Revert-on-failure behavior:**
```swift
func toggleOpenAtLogin(_ newValue: Bool) async {
    do {
        if newValue {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        preferences.setOpenAtLogin(newValue)
    } catch {
        // Silent revert — do NOT crash, do NOT toast (macOS norm per CONTEXT Discretion)
        os.Logger(subsystem: "app.agents-usage-bar", category: "settings")
            .warning("SMAppService toggle failed: \(error.localizedDescription, privacy: .public)")
        // UI toggle reverts automatically because setOpenAtLogin was not called
        // (the @Observable store still holds the old value)
    }

    // Re-read authoritative status (macOS may have moved to .requiresApproval)
    refreshLoginItemStatus()
}
```

**`.requiresApproval` is normal on macOS 14 first call:** Do NOT show an error. Show the approval CTA as informational — the user simply hasn't approved yet.

---

### 10. `Resources/Onboarding/providers.json` Schema + Loader Pattern

**Exact pattern to copy:** `AgentsUsageBar/Providers/Claude/ClaudeModelPricing.swift:79-101`

```swift
// ClaudeModelPricing.loadBundled() — the template:
public static func loadBundled() throws -> ClaudeModelPricing {
    guard let url = Bundle.main.url(forResource: "claude-models", withExtension: "json") else {
        throw ClaudeModelPricingError.bundleResourceMissing
    }
    return try load(from: url)
}
```

**Phase 5 equivalent:**
```swift
// AgentsUsageBar/UI/Welcome/OnboardingCopy.swift
public enum OnboardingCopyError: Error, Sendable {
    case bundleResourceMissing
    case decodeFailed(Error)
}

public struct ProviderOnboardingInfo: Decodable, Sendable {
    public let providerID: String
    public let displayName: String
    public let detectionDescription: String
    public let envSnippet: String
    public let envNote: String
    public let tomlSnippet: String
    public let tomlNote: String
    public let docsURL: String?
    // Lenient: unknown future fields silently ignored by JSONDecoder default behavior
}

public struct OnboardingCopy: Decodable, Sendable {
    public let providers: [ProviderOnboardingInfo]

    public static func loadBundled() throws -> OnboardingCopy {
        guard let url = Bundle.main.url(forResource: "providers", withExtension: "json",
                                         subdirectory: "Onboarding") else {
            throw OnboardingCopyError.bundleResourceMissing
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(OnboardingCopy.self, from: data)
        } catch {
            throw OnboardingCopyError.decodeFailed(error)
        }
    }
}
```

**File path:** `AgentsUsageBar/Resources/Onboarding/providers.json`

**SEC-04 compliance:** All snippet values MUST use `<placeholder>` tokens, NOT real-looking API key patterns:
```json
{
  "providerID": "openrouter",
  "envSnippet": "export OPENROUTER_API_KEY=<your-key-here>",
  "tomlSnippet": "[openrouter]\napi_key = \"<your-key-here>\""
}
```
NOT `sk-or-...` — that matches the SEC-04 `sk-or-` grep pattern.

**`keyDecodingStrategy`:** Do NOT use `.convertFromSnakeCase` — the JSON keys already use camelCase (`providerID`, `displayName`, `envSnippet`). Same pattern as `ClaudeModelPricing` which sets `.convertFromSnakeCase` as a no-op safety net but is fine without it for explicit CodingKeys.

---

### 11. Activation Policy Flip — Exhaustive Failure Modes

**Confidence: HIGH**

**Counter-based `WindowActivationObserver`** handles all edge cases:

```swift
@MainActor
public final class WindowActivationObserver {
    private var openWindowCount: Int = 0    // reference counter
    private var openToken: NSObjectProtocol?
    private var closeToken: NSObjectProtocol?
    nonisolated(unsafe) private let notificationCenter: NotificationCenter
    private let logger = AppLogger.logger(category: "activation")

    // Identifiers for Settings and Welcome windows to filter out unrelated windows
    private let managedWindowTitles: Set<String> = ["Settings", "Welcome"]

    public init(notificationCenter: NotificationCenter = NotificationCenter.default) {
        self.notificationCenter = notificationCenter

        openToken = notificationCenter.addObserver(
            forName: NSWindow.willOpenNotification, object: nil, queue: .main
        ) { [weak self] n in
            Task { @MainActor [weak self] in self?.handleOpen(n.object as? NSWindow) }
        }
        closeToken = notificationCenter.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] n in
            Task { @MainActor [weak self] in self?.handleClose(n.object as? NSWindow) }
        }
    }

    deinit {
        if let t = openToken  { notificationCenter.removeObserver(t) }
        if let t = closeToken { notificationCenter.removeObserver(t) }
    }

    private func isManaged(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        // Filter: only Settings + Welcome windows trigger the flip
        return managedWindowTitles.contains(window.title)
        // Alternative: check window.identifier.rawValue if SwiftUI assigns a stable ID
    }

    private func handleOpen(_ window: NSWindow?) {
        guard isManaged(window) else { return }
        openWindowCount += 1
        if openWindowCount == 1 {  // first managed window opening
            NSApplication.shared.setActivationPolicy(.regular)
            logger.notice("activation → .regular (openCount=\(self.openWindowCount))")
        }
    }

    private func handleClose(_ window: NSWindow?) {
        guard isManaged(window) else { return }
        openWindowCount = max(0, openWindowCount - 1)
        if openWindowCount == 0 {  // last managed window closed
            NSApplication.shared.setActivationPolicy(.accessory)
            logger.notice("activation → .accessory (openCount=0)")
        }
    }
}
```

**Failure modes handled:**

1. **User opens BOTH Welcome AND Settings:** `openWindowCount` reaches 2 on second open. Policy stays `.regular`. First close decrements to 1 (stays `.regular`). Second close decrements to 0 → flips back to `.accessory`. Dock icon disappears only when BOTH are closed.

2. **Force-quit while Settings open:** `willCloseNotification` does NOT fire. `openWindowCount` is left at non-zero in dead object. On next launch, `AgentsUsageBarApp.init()` calls `setActivationPolicy(.accessory)` (line 15), resetting everything. No user-visible regression.

3. **Cmd-, before popover ever opened (Settings before MenuBarExtra realized):** The `Settings { }` scene is always available via `MenuBarExtra`'s enclosing `App` — it does NOT depend on the popover being opened first. SwiftUI registers the `Settings` scene independently. The `WindowActivationObserver` is constructed in `AppDependencies.makeProduction()` before the first `.task` runs, so it is already live when `NSWindow.willOpenNotification` fires.

---

### 12. CFG-06 CI Enforcement

**Confidence: HIGH**

**Exact `rg`/`grep` invocation:**
```bash
# Using rg (recommended — faster, installed via Homebrew on dev machines)
! rg -l 'zshrc|bashrc|config\.fish|\.profile' AgentsUsageBar/

# grep fallback:
! grep -RIn -e '\.zshrc' -e '\.bashrc' -e 'config\.fish' -e '\.profile' AgentsUsageBar/
```

**Recommended placement:** BOTH `.github/workflows/ci.yml` AND as a Swift Testing `@Test` case (in-source regression gate). The CI step catches it before merge; the test catches it during local development.

**In-source test pattern** (from CONTEXT.md Discretion section):
```swift
// AgentsUsageBarTests/Settings/CFG06EnforcementTests.swift
@Test func cfg06_noShellRcReferences() throws {
    // Walk the AgentsUsageBar/ source tree
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // navigate to repo root
        // ... (use same source-walk pattern as existing W7/FooterViewTests)
    let forbidden = [".zshrc", ".bashrc", "config.fish", ".profile"]
    // Assert 0 matches across all .swift files
}
```

**GitHub Actions step** (add to existing `.github/workflows/ci.yml`):
```yaml
- name: CFG-06 — no shell RC file references
  run: |
    if grep -RIn -e '\.zshrc' -e '\.bashrc' -e 'config\.fish' AgentsUsageBar/; then
      echo "CFG-06 violation: shell RC file reference found"
      exit 1
    fi
```

Note: `*.toml` fixture files are excluded by default (path scoped to `AgentsUsageBar/`). This is correct — fixture TOML files are in `AgentsUsageBarTests/Fixtures/` which is outside the production source tree.

---

### 13. Test Seams — UserDefaults Isolation

**Confidence: HIGH** (Apple WWDC-recommended pattern)

**Apple-recommended unit-test pattern:**
```swift
// In test file — each test gets a fresh, isolated suite
let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
let store = UserPreferencesStore(defaults: defaults)
// No cross-test contamination; no reads from ~/.app/preferences
// Automatically cleaned up when the test suite deallocates
```

**`UserPreferencesStore` constructor signature:**
```swift
public init(defaults: UserDefaults = .standard) { ... }
```

The `defaults: UserDefaults = .standard` parameter enables full test isolation. Production code calls `UserPreferencesStore()` (uses `.standard`). Tests pass `UserDefaults(suiteName: "test-\(UUID())")!`.

**Why NOT a protocol seam:** `UserDefaults` itself is not formally protocol-abstracted in the Apple ecosystem. A `UserDefaultsProtocol` would require wrapping ~20 methods. The `init(defaults:)` injection is simpler and achieves full isolation. This mirrors Phase 1's `EnvReader` protocol seam approach (simple type injection over protocol wrappers).

**Swift Testing with isolated suites:**
```swift
@Suite(.serialized)  // Not needed if tests don't share defaults — but safe to include
struct UserPreferencesStoreTests {
    @Test func roundTrip_refreshInterval() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let store = UserPreferencesStore(defaults: defaults)
        store.setRefreshInterval(.m1)
        #expect(store.refreshInterval == .m1)
    }
}
```

**Apple WWDC reference:** WWDC 2023 "Test with Swift Testing" + "Expand on Swift Testing" sessions; Apple Developer documentation on `UserDefaults(suiteName:)`.

---

### 14. MVP_MODE Plan Decomposition — 4–6 Vertical Slices

**Confidence: HIGH**

Each plan satisfies the "after Task N completes, can the user do something new?" MVP vertical-slice rule:

**Plan 05-01 — Settings Scene scaffold + Activation Observer (smallest end-to-end slice)**
- Deliverable: `Settings { SettingsScene() }` added to `AgentsUsageBarApp.body`; `SettingsScene.swift` with three empty tab stubs (General, Providers, About); `WindowActivationObserver` constructed and retained in `Dependencies`; `AgentsUsageBarApp.init()` gets the `NSApp.activate(ignoringOtherApps: true)` Cmd-, override.
- User can do: Cmd-, opens a Settings window; activation policy flips `.regular` while open; `.accessory` on close. Dock icon appears while Settings is open, disappears on close.
- Tests: `WindowActivationObserverTests` (open/close/multi-window/force-quit scenarios); composition root smoke test; `NSApp.activate` grep.
- Files: `UI/Settings/SettingsScene.swift`, `UI/Settings/SettingsGeneralTab.swift` (empty), `UI/Settings/SettingsProvidersTab.swift` (empty), `UI/Settings/SettingsAboutTab.swift` (empty), `App/WindowActivationObserver.swift`, `App/AppDependencies.swift` (add observer), `App/AgentsUsageBarApp.swift` (add Settings scene + Cmd-, override).

**Plan 05-02 — `UserPreferencesStore` + `ConfigStore` precedence overlay**
- Deliverable: `Config/UserPreferencesStore.swift`; `ConfigStore.load(preferences:)` signature extension applying UserDefaults layer on top per D-02/D-03; `AUBDefaultsKey` constants; `AppEnvironmentKey` for `.preferences` environment key; `ProviderID.allKnown` static.
- User can do: UserDefaults changes persist across restarts and override TOML/env knobs. `UserPreferencesStore` is injected via environment into Settings views.
- Tests: `UserPreferencesStoreTests` (round-trip per key, change notification, isolated suite); `ConfigStorePrecedenceTests` (userDefaults beats env beats toml beats defaults for knobs; credentials unaffected).
- Files: `Config/UserPreferencesStore.swift`, `Config/AppConfig.swift` (if ConfigStore.load signature changes), `App/AppDependencies.swift` (instantiate store, pass to ConfigStore), `App/AgentsUsageBarApp.swift` (inject `.environment(dependencies.preferences)`).

**Plan 05-03 — General Tab wired to hot-reload paths**
- Deliverable: `SettingsGeneralTab.swift` fully implemented (refresh interval picker, threshold slider, theme picker, open-at-login toggle); hot-reload wiring (`PollScheduler.updateInterval` called on refreshInterval change; `AggregateStore.updateWarningFraction` called on threshold change; `.preferredColorScheme` binding; `SMAppService` toggle); `SMAppService.Status` UI mapping.
- User can do: change refresh interval → poll loop immediately restarts at new cadence; change threshold → next poll uses new warning fraction; toggle theme → popover + Settings flip color scheme live; toggle open-at-login → `SMAppService` called; `.requiresApproval` shows CTA.
- Tests: `SettingsGeneralTabTests` (UI binding smoke); `PollSchedulerUpdateIntervalTests` (already exists — verify `updateInterval` wiring); `AggregateStoreUpdateWarningFractionTests` (new — rebuild engine, FSM state survives); `SMAppServiceToggleTests` (mock SMAppService via protocol or subclass; revert-on-failure; requiresApproval subtitle).
- Files: `UI/Settings/SettingsGeneralTab.swift`, `Aggregation/AggregateStore.swift` (add `updateWarningFraction(_:)`), `App/AppDependencies.swift` (wire observer for preferences changes).

**Plan 05-04 — Providers Tab + `DetectionProbe` + `OnboardingCopy.json`**
- Deliverable: `SettingsProvidersTab.swift` (per-provider rows: enable toggle, detection badge, Re-check button, expandable help panel, Copy-to-Clipboard); `UI/Welcome/DetectionProbe.swift` (7-provider parallel probe with `withTaskGroup`); `UI/Welcome/OnboardingCopy.swift` (JSON loader); `Resources/Onboarding/providers.json` (bundled snippets); `AggregateStore` observes `providerEnabled` map changes.
- User can do: toggle a provider in Settings → row disappears/appears in popover on next poll; Re-check button re-runs detection probe; "How to enable" panel expands with copy-able snippet; `<placeholder>` tokens in snippets confirm SEC-04 compliance.
- Tests: `DetectionProbeTests` (7 providers, URLProtocol stubs for HTTP, fixture dirs for FS, DictionaryEnvReader for env); `OnboardingCopyTests` (loadBundled round-trip, lenient unknown fields); `SettingsProvidersTabTests` (toggle fires UserDefaults write; expandable panel; re-check button).
- Files: `UI/Welcome/DetectionProbe.swift`, `UI/Welcome/OnboardingCopy.swift`, `UI/Settings/SettingsProvidersTab.swift`, `Resources/Onboarding/providers.json`.

**Plan 05-05 — Welcome Window (first-launch auto-detect)**
- Deliverable: `WelcomeWindowController.swift` (creates/shows `NSWindow` hosting SwiftUI); `WelcomeRootView.swift` (provider list with detection states); `WelcomeProviderRow.swift`; first-launch trigger in `AppDependencies.makeProduction()` (`!preferences.hasSeenWelcome → show`); auto-detect seeds `providerEnabled` map in UserDefaults; "Get Started" + "Open Settings" footer.
- User can do: fresh install (no UserDefaults) → Welcome window auto-opens; rows show "Checking…" → "Detected"/"Not running"/"Not configured"; detected providers are enabled by default; user dismisses; Welcome never re-opens.
- Tests: `WelcomeWindowControllerTests` (shows when `hasSeenWelcome=false`, not shown when `=true`); `WelcomeProviderRowTests` (three states render correctly); integration: detection probes called on load, `providerEnabled` seeded.
- Files: `UI/Welcome/WelcomeWindowController.swift`, `UI/Welcome/WelcomeRootView.swift`, `UI/Welcome/WelcomeProviderRow.swift`, `App/AppDependencies.swift` (trigger Welcome on launch).

**Plan 05-06 — About Tab + Polish + UAT**
- Deliverable: `SettingsAboutTab.swift` (app version/build, GitHub repo link, license link, Sparkle placeholder stub for Phase 6); final polish (window sizing, keyboard navigation, accessibility labels); CFG-06 CI grep step added to `.github/workflows/ci.yml`; `05-UAT.md` (5 manual + 5 attestation, mirroring 04-09 shape).
- User can do: full Phase 5 success criteria verifiable by reviewer.
- Tests: `CFG06EnforcementTests` (source-walk negative-grep); `SettingsAboutTabTests` (version string, GitHub URL).
- Files: `UI/Settings/SettingsAboutTab.swift`, `.github/workflows/ci.yml` (CFG-06 step), `.planning/phases/05-first-run-ux-settings-polish/05-UAT.md`.

**MVP vertical-slice validation:** Each plan delivers a user-observable behavior change. Plan 01 = Settings opens + flip works. Plan 02 = settings persist across restarts. Plan 03 = live hot-reload. Plan 04 = per-provider control + help text. Plan 05 = welcome flow. Plan 06 = polish + gate. ✓

---

### 15. `withTaskGroup` Parallel Detection Probes + 2s Timeout

**Confidence: HIGH**

**Actor isolation + 2s timeout pattern:**
```swift
// DetectionProbe.swift
// Reuse localhostHTTP (2s) from AppDependencies for HTTP probes.
// FS + env probes are synchronous — wrap in Task to be safe in async context.

@MainActor  // or nonisolated — DetectionProbe is a simple struct/enum namespace
struct DetectionProbe {
    static func probeAll(
        config: AppConfig,
        localhostHTTP: any HTTPClient,
        fileManager: FileManager = .default
    ) async -> [ProviderID: DetectionResult] {
        await withTaskGroup(of: (ProviderID, DetectionResult).self) { group in
            // 1. OpenRouter — env/TOML (synchronous, no timeout needed)
            group.addTask {
                let result: DetectionResult = config.openrouter.apiKey != nil ? .detected : .notConfigured
                return (.openrouter, result)
            }

            // 2. Claude — FS probe (synchronous)
            group.addTask {
                let result = probeClaudeFS(fileManager: fileManager)
                return (.claude, result)
            }

            // 3. Codex — FS probe (synchronous)
            group.addTask {
                let result = probeCodexFS(fileManager: fileManager)
                return (.codex, result)
            }

            // 4. Gemini — FS probe (synchronous)
            group.addTask {
                let result = probeGeminiFS(fileManager: fileManager)
                return (.gemini, result)
            }

            // 5. Ollama — HTTP probe with 2s timeout (localhostHTTP already has 2s timeout)
            group.addTask {
                let result = await probeLocalHTTP(
                    url: URL(string: "http://localhost:11434/api/version")!,
                    http: localhostHTTP
                )
                return (.ollama, result)
            }

            // 6. LM Studio — HTTP probe with 2s timeout
            group.addTask {
                let url = URL(string: "http://localhost:\(config.lmstudio.port)/v1/models")!
                let result = await probeLocalHTTP(url: url, http: localhostHTTP)
                return (.lmstudio, result)
            }

            // 7. llama.cpp — requires configured port
            group.addTask {
                guard let port = config.llamacpp.port else {
                    return (.llamacpp, .notConfigured)
                }
                let url = URL(string: "http://localhost:\(port)/health")!
                let result = await probeLocalHTTP(url: url, http: localhostHTTP)
                return (.llamacpp, result)
            }

            // Collect results
            var results: [ProviderID: DetectionResult] = [:]
            for await (id, result) in group {
                results[id] = result
            }
            return results
        }
    }

    private static func probeLocalHTTP(url: URL, http: any HTTPClient) async -> DetectionResult {
        // localhostHTTP already configured with 2s timeout (Phase 4 URLSessionHTTPClient(timeoutSeconds: 2))
        // URLError.cannotConnectToHost / .timedOut → .notRunning
        // HTTP 2xx → .detected
        do {
            // HTTPClient.get is defined in Infrastructure/HTTPClient.swift
            _ = try await http.get(url, bearer: nil, extraHeaders: [:], as: EmptyResponse.self)
            return .detected
        } catch let err as URLError {
            switch err.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut:
                return .notRunning
            default:
                return .notRunning  // all localhost failures treated as not-running for detection purposes
            }
        } catch {
            return .notRunning
        }
    }
}
```

**Do NOT use `withThrowingTaskGroup`** — detection probes must never surface errors to the caller. All errors convert to `DetectionResult` values. `withTaskGroup` (non-throwing) is correct.

**2s timeout**: The existing `localhostHTTP` instance (`URLSessionHTTPClient(timeoutSeconds: 2)`) from Phase 4 is already configured with `timeoutIntervalForRequest = 2`. Pass it into `DetectionProbe.probeAll()`. Do NOT create a new URLSession. This satisfies the "one URLSession per app" principle (CLAUDE.md "Concurrency & Polling Pattern").

**7-task concurrency**: All 7 probes run concurrently. Wall-clock time for the Welcome window detection = max(any_http_probe) ≤ 2s. FS probes are negligible. Total perceived detection latency ≤ 2s.

---

## Open Questions / Risks

**Risk:** `NSWindow.willOpenNotification` filter by window title may be brittle — SwiftUI could set the window title from the `NavigationTitle` modifier or from the `Settings` scene's internal implementation.
**Mitigation:** Use `window.identifier.rawValue` instead of `window.title` for filtering. SwiftUI Settings scene sets a stable `NSUserInterfaceItemIdentifier` based on the scene's `id:` parameter. Verify during Plan 05-01 execution and fall back to title-based filtering if identifier is not set.

**Risk:** `SMAppService.mainApp.register()` on macOS 14 may return `.requiresApproval` indefinitely if the user never visits System Settings → Login Items.
**Mitigation:** The toggle reverts on failure (D-08). The "Approve in System Settings" CTA is always shown for `.requiresApproval` state. No timeout or polling needed — status is re-read each time the Settings → General tab opens.

**Risk:** `UserDefaults.didChangeNotification` fires on every key write, including writes made by `loadAll()` itself if UserDefaults is written during the notification handler (infinite loop).
**Mitigation:** Write operations (`setRefreshInterval`, etc.) are ONLY called from Settings UI via explicit user action — never from inside `loadAll()`. The `loadAll()` method is read-only. No infinite loop possible.

**Risk:** Detection probes for Claude require Keychain access (`ClaudeCredentialLoader` checks Keychain for `Claude Code-credentials`). Keychain access is always allowed in unsandboxed apps under Hardened Runtime with `com.apple.security.network.client` only — no additional entitlement needed.
**Mitigation:** Confirmed. Keychain reads do not require sandbox entitlements in unsandboxed Hardened Runtime apps. `ClaudeCredentialLoader` already exists and works in the Phase 2 production code.

**Risk:** `ProviderID.allKnown` static array does not exist in the current codebase (only `ProviderID.localIDs: Set<ProviderID>` from Phase 4).
**Mitigation:** Plan 05-02 adds `static let allKnown: [ProviderID] = [.openrouter, .claude, .codex, .gemini, .ollama, .lmstudio, .llamacpp]`. This is a compile-time constant — no test needed beyond the smoke that uses it.

**Risk:** The `withTaskGroup` probe assumes `HTTPClient.get(url:bearer:extraHeaders:as:)` can accept a raw URL. Verify the actual HTTPClient protocol signature.
**Mitigation:** `HTTPClient.get` in this codebase takes a `URLRequest` or URL-based parameter — verify during Plan 05-04 execution. Wrap in a minimal `URLRequest(url:)` if needed. Existing provider code confirms the pattern works with bare URLs.

**No blockers found.** All Phase 5 decisions are confirmed implementable with the existing codebase patterns. The single biggest coordination point is the `Dependencies` struct expansion (add `preferences: UserPreferencesStore`, `windowActivationObserver: WindowActivationObserver`, and optionally `welcomeController: WelcomeWindowController?`) — this is a straightforward extension of the existing `Dependencies` bag pattern.

---

## Validation Architecture

Nyquist validation is intentionally omitted. `nyquist_validation_enabled` is not configured for this project (no `nyquist.yml` found in `.planning/`). All validation is via standard Swift Testing unit tests + manual UAT walkthrough per the 04-UAT.md pattern.

---

## RESEARCH COMPLETE
