# Phase 5: First-Run UX + Settings Polish - Context

**Gathered:** 2026-05-21
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 5 ships the write-side of configuration — a first-launch **Welcome window** (auto-detects providers, lists state, copy-to-clipboard CTAs for missing ones) and a native **SwiftUI `Settings { … }` scene** (Cmd-, opens it; refresh interval, default threshold, per-provider enable/disable toggles, theme picker, open-at-login). Activation policy flips `.accessory ↔ .regular` while Settings is open (SHELL-05). Settings changes hot-reload into the running poll loop without app restart. Phases 1–4 locked the read-side (`ConfigStore` env > toml > defaults); Phase 5 layers a `UserDefaults` overlay on top with strictly highest precedence for user-mutable knobs, while credentials still flow env > toml. **No Keychain UI in v1** (CFG-01 anti-feature reaffirmed) and **shell RC files (`~/.zshrc`, `~/.bashrc`, fish config) NEVER parsed** (CFG-06 anti-feature reaffirmed).

**In scope (5 requirements from ROADMAP.md):**
SHELL-05, CFG-03, CFG-04, CFG-05, CFG-06.

**Out of scope (deferred):**
- Distribution / notarization / DMG / Sparkle (SEC-03, REL-*) — Phase 6
- Per-provider threshold override UI in Settings (TRENDS-02) — v2
- Notifications tab in Settings (single global threshold knob in v1 doesn't justify own tab) — v2
- Keychain entry UI (CFG-01 anti-feature) — out of scope forever in v1
- Shell RC file parsing (CFG-06 anti-feature) — out of scope forever
- Settings live-edit detection of TOML changes (file-watch hot-reload of `~/.config/agents-usage-bar/config.toml`) — v2
- Per-provider primary-model selector for Gemini (`[gemini].primary_model` knob) — Phase 3 deferred → v2
- Welcome re-appearance after major updates (release-note welcome) — v2
- Welcome window localization — defer until v2 (English-only in v1)

</domain>

<decisions>
## Implementation Decisions

### Settings Persistence Layer

- **D-01:** **Hybrid: UserDefaults wins, TOML stays read-only.** UserDefaults stores in-app overrides (refresh interval, threshold, per-provider `.enabled`, theme, open-at-login). TOML continues as power-user / dev knob — read only, never written. On boot, ConfigStore applies TOML over defaults, then layers UserDefaults overrides on top. Pros: no TOML serializer to write; atomic native API; in-app changes never clobber user's hand-edited TOML. Cons: two surfaces — `cat config.toml` may show values that the in-app Settings has since overridden. Mitigation: README documents the precedence chain.
- **D-02:** **Precedence chain = `userDefaults > env > toml > defaults`** for user-mutable knobs. Settings-UI clicks are topmost authority — env vars for those knobs (e.g., a hypothetical `AGENTS_USAGE_BAR_THRESHOLD`) get overridden by what the user clicks. Rationale: user clicks slider and it must stick — no silent env-var override surprise.
- **D-03:** **Credentials still flow env > toml only.** API keys / bearer tokens / OAuth secrets are NOT subject to the UserDefaults overlay (no Keychain UI per CFG-01). The hybrid precedence applies only to **knobs**: `refreshInterval`, `threshold`, per-provider `enabled`, `theme`, `openAtLogin`. Wire this as explicit per-field precedence in `ConfigStore` — not a blanket "UserDefaults always wins."
- **D-04:** **Hot-reload, not restart-required.** Store observes UserDefaults via NotificationCenter (`UserDefaults.didChangeNotification`); on relevant key changes:
  - Refresh interval → `PollScheduler.setInterval(_:)` (already in scheduler — verify or add).
  - Per-provider toggle → store hides/shows row + scheduler skips that provider on next tick + in-flight Task for the just-disabled provider is cancelled.
  - Theme → SwiftUI `.preferredColorScheme(_:)` binding flips live.
  - Threshold → `ThresholdEngine` rebuilt with new fraction; existing per-day FSM state preserved (no spurious re-fire).
  - Open-at-login → `SMAppService.mainApp.register()` / `.unregister()` called immediately.

### Settings Scene Shape + Activation

- **D-05:** **SwiftUI `Settings { … }` scene.** Native macOS Cmd-, wiring; free preferences-toolbar styling; multiple tabs. Apple-blessed minimum-code path. **Known LSUIElement gotcha mitigation:** when Cmd-, fires, also call `NSApp.activate(ignoringOtherApps: true)` so window comes forward + receives focus. Verify on macOS 14.0 + 14.x + 15.x during research.
- **D-06:** **Activation policy flips tight per Settings window lifecycle.** Subscribe to the Settings window's `NSWindow.willOpenNotification` → set `.regular` + brief Dock icon appearance. On `willCloseNotification` → set `.accessory` + Dock icon disappears. Plumbing via an `NSWindowDelegate` attached to the Settings window after first open. SHELL-05 verbatim.
- **D-07:** **Three Settings tabs: General + Providers + About.**
  - **General:** refresh interval picker (Manual / 1m / 2m / 5m / 15m / 30m), default threshold slider (with live preview of the warning band), theme picker (light / dark / auto), open-at-login toggle (default OFF per CFG-05 spec).
  - **Providers:** per-provider rows mirroring the Welcome window — detection state badge, enable toggle, "How to enable" expandable help panel, manual "Re-check" button per row.
  - **About:** version, build, link to GitHub repo, license link. Foundation for Phase 6 "View release notes" / "Check for updates" Sparkle wiring.
  - **No Notifications tab in v1** — single global threshold lives in General; per-provider threshold + snooze policy = v2.
- **D-08:** **`SMAppService.mainApp.register() / .unregister()` for open-at-login.** Native macOS 13+ API. Status read via `SMAppService.mainApp.status`. Surface `.requiresApproval` state in UI with a "Open Login Items in System Settings" button that opens `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`. **Default OFF** per CFG-05 — only flips on when user toggles in Settings.

### First-Run Welcome Surface

- **D-09:** **Dedicated Welcome NSWindow on first launch** (~520×480pt). Opens automatically when UserDefaults `hasSeenWelcome == false`. Lists each provider with detected-state badge + "How to enable" CTA + footer with "Get started" (closes + sets flag) and "Open Settings" (closes + opens Settings → Providers tab + sets flag). Uses the same activation-policy flip plumbing as Settings (D-06). Same window-host pattern; different content view.
- **D-10:** **Trigger = UserDefaults `hasSeenWelcome` flag.** Single boolean. Absent → show welcome. User dismisses via either footer button → set `true`. **Do NOT** tie trigger to TOML file presence (TOML is optional; would re-trigger every launch for env-only users). **Do NOT** tie to "no detected providers" (rare edge case; UserDefaults flag is sufficient and predictable).
- **D-11:** **Auto-detection enables detected providers, leaves undetected OFF (CFG-03 verbatim).** On first launch, ConfigStore consults the detection probes (see D-12) and seeds `[provider].enabled = true` in UserDefaults for every provider that passes detection; undetected providers stay `enabled = false`. Subsequent launches respect the user's choices — auto-detect is a first-run-only seed, not a continuous overwrite.
- **D-12:** **Welcome window probes detection synchronously per-row, with spinner.** On welcome window load, fire detection probes in parallel (`withTaskGroup`). Each row shows `Checking…` → `Detected` / `Not running` / `Not configured`. Detection signals:
  - **OpenRouter:** `OPENROUTER_API_KEY` env var OR `[openrouter].api_key` in TOML.
  - **Claude:** `~/.claude/projects/**` directory exists OR `~/.claude/.credentials.json` exists OR Keychain item `Claude Code-credentials` present.
  - **Codex:** `~/.codex/sessions/` exists OR `~/.codex/auth.json` exists.
  - **Gemini:** `~/.gemini/oauth_creds.json` present AND `~/.gemini/settings.json` has `selectedAuthType == "oauth-personal"`.
  - **Ollama:** `GET http://localhost:11434/api/version` returns 2xx within 2s.
  - **LM Studio:** `GET http://localhost:1234/v1/models` returns 2xx within 2s.
  - **llama.cpp:** `[llamacpp].port` set in TOML → probe `/health` within 2s; absent → "Not configured" (D-04 from Phase 4 placeholder messaging applies).
- **D-13:** **Pre-compute detection during welcome load (NOT during `AppDependencies.makeProduction`).** Composition root stays fast — localhost detection is welcome-window-only work to avoid blocking app launch on Ollama timeouts. 2s perceived welcome latency is acceptable for a one-time screen.

### "How to Enable" CTA

- **D-14:** **Inline expandable help panel + Copy button per undetected row.** Each row has a disclosure chevron → reveals a panel with: 2–3 line how-to-enable text + monospace snippet + Copy-to-Clipboard button + optional "Open docs ↗" secondary link. Snippet covers both **env-var form** (with restart note) AND **TOML form** (with "hot-reloads after save" note) — see D-15. NO browser hop for primary path.
- **D-15:** **Snippets bundled as `Resources/Onboarding/providers.json`.** Schema (per provider):
  ```json
  {
    "providerID": "openrouter",
    "displayName": "OpenRouter",
    "detectionDescription": "Set OPENROUTER_API_KEY env var or add [openrouter].api_key to ~/.config/agents-usage-bar/config.toml.",
    "envSnippet": "export OPENROUTER_API_KEY=sk-or-...",
    "envNote": "Restart Agents Usage Bar to apply env-var changes.",
    "tomlSnippet": "[openrouter]\napi_key = \"sk-or-...\"",
    "tomlNote": "Save the file — changes apply on next poll.",
    "docsURL": "https://github.com/<user>/agents-usage-bar#provider-openrouter"
  }
  ```
  Mirrors existing `Resources/Pricing/*.json` pattern (Phase 2 P-02). Adding a v2 provider = JSON edit, no code change. Welcome + Settings → Providers tab both consume the same JSON.
- **D-16:** **Re-check button per undetected row + auto-recheck on Settings → Providers tab open.** Each undetected row in Welcome AND Settings has a ⟳ button → re-runs that provider's detection probe (same logic as D-12). Settings → Providers tab activation also fires a parallel re-check of all undetected rows so the user gets instant feedback after editing TOML or copying snippets. **Caveat: env-var changes still require app restart** (env reads happen at `AppDependencies.makeProduction`); the re-check button shows this honestly in the snippet's `envNote` (D-15) so user knows when to restart vs. when changes hot-reload.

### Claude's Discretion

Items NOT discussed — planner / researcher picks the standard answer:

- **UserDefaults key namespacing:** prefix all v1 keys with `aub.` (e.g., `aub.refreshInterval`, `aub.threshold`, `aub.theme`, `aub.openAtLogin`, `aub.provider.openrouter.enabled`, `aub.hasSeenWelcome`). Codable-encode non-trivial values (e.g., `RefreshInterval` enum rawValue as String).
- **Theme picker shape:** SwiftUI `Picker(...) { ... }.pickerStyle(.segmented)` with three options (Light / Dark / Auto). Theme applied globally via `.preferredColorScheme(theme.colorScheme)` on the menu bar root view + Settings + Welcome windows.
- **Refresh interval picker shape:** `Picker(...) { ... }` segmented or menu style — planner picks; values strictly from `{Manual, 1m, 2m, 5m, 15m, 30m}` per POLL-02.
- **Threshold slider granularity:** `Slider(value: $threshold, in: 0.5...0.95, step: 0.05)` with `.percent` formatting; live label "Warn at 80%". Range 0.5–0.95 prevents trivially-bad values (no 1% threshold or 100% threshold).
- **Settings window size:** `~520×400pt` for General tab; Providers tab grows vertically with row count (use `ScrollView` for safety). Hardcoded; no resize persistence in v1.
- **Welcome window size:** `~520×480pt`, fixed; centered on main screen; not resizable.
- **`PollScheduler.setInterval(_:)` API:** if not present, add it — atomic swap of the `interval` value + signal the long-lived task to recompute its next sleep. Cancellation of in-flight fetches NOT required for interval change (provider mid-fetch finishes; next tick uses new interval).
- **Per-provider toggle live-disconnect UX:** when user toggles a provider OFF and a fetch is in-flight, cancel the Task via structured concurrency (already supported per Phase 1 POLL-07); set row to `.disabled` immediately; subsequent ticks skip that provider.
- **`SMAppService.mainApp` activation:** must call `SMAppService.mainApp.register()` from the main thread; surface `try` errors via an os.Logger warning + revert UI toggle on failure (don't crash; don't toast — silent revert with log is the macOS norm).
- **Activation policy flip plumbing:** use `NSApplication.shared.setActivationPolicy(.regular)` inside `NSWindow.willOpenNotification` observer; `setActivationPolicy(.accessory)` inside `NSWindow.willCloseNotification`. Observer lifetime = app lifetime (retained by Dependencies). Tighten to specific Settings + Welcome windows via the notification's `object` filter.
- **File layout:**
  - `AgentsUsageBar/UI/Settings/` directory: `SettingsScene.swift`, `SettingsGeneralTab.swift`, `SettingsProvidersTab.swift`, `SettingsAboutTab.swift`.
  - `AgentsUsageBar/UI/Welcome/` directory: `WelcomeWindowController.swift`, `WelcomeRootView.swift`, `WelcomeProviderRow.swift`, `OnboardingCopy.swift` (JSON loader + struct), `DetectionProbe.swift` (per-provider detection logic).
  - `AgentsUsageBar/Config/UserPreferencesStore.swift`: `@Observable` typed wrapper over UserDefaults; consumed by Settings views via `@Environment` + by `ConfigStore` layering logic.
  - `AgentsUsageBar/Resources/Onboarding/providers.json`: bundled snippets.
- **Test layout:** `AgentsUsageBarTests/Settings/` + `Welcome/` mirroring the source structure. Detection probes tested with `URLProtocol` stubs (Phase 2 STATE #19 pattern). UserDefaults tested with isolated suite domains via `UserDefaults(suiteName:)` (Apple-recommended for unit tests).
- **CFG-06 enforcement:** add a regression test asserting no source file under `AgentsUsageBar/` ever opens `.zshrc`, `.bashrc`, `.config/fish/config.fish`, or any file matching `*rc` under the home directory. Grep-in-test fails CI if violated.
- **SEC-04 grep:** NO new patterns. Settings + Welcome carry no new secrets.
- **No `Info.plist` change.** No new entitlements required. `SMAppService.mainApp` works under the existing entitlement set.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents (researcher, planner, executor) MUST read these before planning or implementing.**

### Project Specs (root)
- `.planning/PROJECT.md` — Core value, constraints. §"Out of Scope" reaffirms: Keychain UI (CFG-01), shell RC parsing (CFG-06), auto-launch-at-login-by-default (CFG-05 default OFF) all explicitly forbidden in v1
- `.planning/REQUIREMENTS.md` §"Shell" SHELL-05, §"Configuration & Onboarding" CFG-03..06 — the 5 Phase 5 line items; CFG-01 (no Keychain) + CFG-06 (no shell RC parsing) are explicit anti-features that Phase 5 MUST honor
- `.planning/ROADMAP.md` §"Phase 5: First-Run UX + Settings Polish" — goal + 5 success criteria; verification must satisfy each
- `.planning/STATE.md` §"Accumulated Context" Decisions #1..#90+ (Phases 1–4 patterns); §"Risk Register" (LSUIElement + activation-policy quirks are Phase 5 risks)

### Architecture & Stack
- `.planning/research/ARCHITECTURE.md` — Composition Root + Protocol Seams (UserPreferencesStore slots in alongside ConfigStore); `@Observable` MainActor Store; `MenuBarExtra(.window)` scene host pattern
- `.planning/research/STACK.md` — `URLSession` config, `Codable` rules, async/await + structured concurrency
- `CLAUDE.md` — "Recommended Stack" (`SMAppService` is the modern open-at-login path); "Sandbox Decision" (sandbox-off lets us read `~/.zshrc`-adjacent locations IF we wanted to — we explicitly don't per CFG-06); "Concurrency & Polling Pattern" (hot-reload via Task cancellation + interval reset)

### Pitfalls (avoid in Phase 5)
- `.planning/research/PITFALLS.md` §"Pitfall 1" (MenuBarExtra + LSUIElement quirks — `SwiftUI Settings { … }` is known-quirky on LSUIElement apps; explicit `NSApp.activate(ignoringOtherApps: true)` required on macOS 14+)
- `.planning/research/PITFALLS.md` §"Pitfall 2" (LSUIElement + activation policy — Phase 5 toggles activation policy at runtime; verify the flip works on macOS 14.0/14.x/15.x)
- `.planning/research/PITFALLS.md` §"Pitfall 4" (observer lifetime — `NSWindow.willOpenNotification` / `willCloseNotification` observer MUST be retained strongly in Dependencies, mirroring PowerObserver from Phase 2)
- `.planning/research/PITFALLS.md` §"Pitfall 5" (polling battery — hot-reload of refresh interval MUST not cause a fetch storm; new interval applies starting from next tick)
- `.planning/research/PITFALLS.md` §"Pitfall 11" (secret leakage — Settings UI must NOT render `Secret`-wrapped values verbatim; status only)

### Prior Phase Context
- `.planning/phases/01-skeleton-openrouter-vertical-slice/01-CONTEXT.md` — Phase 1 anchor decisions D-15..D-19 (TOML schema + env > toml > defaults precedence — Phase 5 extends with UserDefaults layer per D-02)
- `.planning/phases/03-remote-api-providers-codex-gemini/03-CONTEXT.md` — Phase 3 D-13/D-14 (Open Dashboard URL map — pattern for OnboardingCopy URL map); D-15 (`tooltipLabel` channel — pattern for surfacing per-provider state in Settings Providers tab)
- `.planning/phases/04-local-llm-presence-ollama-lm-studio-llama-cpp/04-CONTEXT.md` — Phase 4 D-04 (llama.cpp unconfigured placeholder discoverability subtitle pattern — extends to Welcome window CTA copy verbatim)
- `.planning/phases/04-local-llm-presence-ollama-lm-studio-llama-cpp/04-09-PLAN.md` (and 04-UAT.md) — most recent UAT shape; mirror its 5 manual + 5 attestation pattern for `05-UAT.md`

### Apple Platform Docs (high-confidence, re-verify in research step)
- `SMAppService.mainApp` (open-at-login) — https://developer.apple.com/documentation/servicemanagement/smappservice
- `SMAppService.Status` (`.notRegistered` / `.enabled` / `.requiresApproval` / `.notFound`) — https://developer.apple.com/documentation/servicemanagement/smappservice/status
- SwiftUI `Settings { … }` scene — https://developer.apple.com/documentation/swiftui/settings
- `NSApplication.activate(ignoringOtherApps:)` — https://developer.apple.com/documentation/appkit/nsapplication/1428468-activate (Cmd-, focus fix on LSUIElement apps)
- `NSApplication.ActivationPolicy` (.regular ↔ .accessory) — https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy
- `NSWindow.willOpenNotification` / `willCloseNotification` — https://developer.apple.com/documentation/appkit/nswindow
- `UserDefaults.didChangeNotification` — https://developer.apple.com/documentation/foundation/userdefaults/1408206-didchangenotification
- `Picker(_:selection:)` `.pickerStyle(.segmented)` — https://developer.apple.com/documentation/swiftui/pickerstyle/segmented
- `View.preferredColorScheme(_:)` — https://developer.apple.com/documentation/swiftui/view/preferredcolorscheme(_:)
- `NSPasteboard.general.setString(_:forType:)` (Copy button) — https://developer.apple.com/documentation/appkit/nspasteboard
- `x-apple.systempreferences:com.apple.LoginItems-Settings.extension` deep link (System Settings → Login Items) — Apple System Settings URL scheme

### Prior Art (study, do NOT copy)
- **ClaudeBar** — https://github.com/tddworks/ClaudeBar — closest LSUIElement + SwiftUI Settings scene + Sparkle wiring reference
- **CodexBar** — https://github.com/steipete/CodexBar — 29-provider per-provider toggle pattern in Settings; bundled CLI reference (out of scope here)
- **macOS Reminders / Things / 1Password 7** — established Welcome window patterns for menu bar / Dock apps (visual reference, not code)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets

- **`AgentsUsageBar/Config/ConfigStore.swift` + `AppConfig.swift` + `TomlReader.swift` + `EnvReader.swift`** — read-only chain established Phase 1 D-15..D-19. Phase 5 adds a **`UserPreferencesStore`** wrapper that layers UserDefaults overrides on top per D-02. ConfigStore.load() signature changes to accept the prefs store as a parameter; precedence applied per-field per D-03.
- **`AgentsUsageBar/App/AppDependencies.swift` `makeProduction()`** (line 86: `ConfigStore(env: ProcessInfoEnvReader()).load()`) — Phase 5 wires the new `UserPreferencesStore` into composition root + retains the new `WindowActivationObserver` + `WelcomeWindowController` (when shown) on `Dependencies` per Pitfall 4 observer-lifetime rule.
- **`AgentsUsageBar/App/AgentsUsageBarApp.swift`** — Phase 5 adds the `Settings { SettingsScene().environment(dependencies.preferences) }` scene next to the existing `MenuBarExtra { … }`. The init() block already sets `setActivationPolicy(.accessory)` (line ~23) — Phase 5 leaves the launch state as `.accessory`; the flip is window-lifecycle-driven (D-06).
- **`AgentsUsageBar/Aggregation/AggregateStore.swift` `seedPlaceholder(...)`** — Phase 5 calls this when a previously-enabled provider is toggled OFF live; placeholder replaces the live state so the row remains visible (or is removed entirely, per planner choice).
- **`AgentsUsageBar/Infrastructure/PowerObserver.swift`** (Phase 2 P-06) — direct precedent for `WindowActivationObserver` (NSWindow open/close → `setActivationPolicy` flip). Same constructor pattern: takes `scheduler`/`store`/`clock`-style refs, retained strongly in Dependencies.
- **`AgentsUsageBar/Aggregation/PollScheduler`** (Phase 1 P-05) — Phase 5 must add `setInterval(_:)` if not present; verify in research. Hot-reload of refresh interval (D-04) needs an atomic interval swap + next-tick reschedule (no fetch storm — Pitfall 5).
- **`AgentsUsageBar/Notifications/ThresholdEngine.swift`** (Phase 1+2) — Phase 5 must support live threshold-fraction reset without losing the per-day FSM state. Either rebuild the engine and re-attach to store (FSM state preserved in `UserDefaultsNotificationStateStore`, already keyed by `<providerID>:<yyyy-MM-dd>` so survives) or expose a `setWarningFraction(_:)` mutator on the engine.
- **`AgentsUsageBar/Resources/Pricing/*.json` + bundled-JSON-loader pattern** (Phase 2 P-02) — direct template for `Resources/Onboarding/providers.json` and `OnboardingCopy.loadBundled()`.

### Established Patterns

- **`@Observable` `@MainActor` store + `@Environment` injection** (Phase 1 STATE #14) — `UserPreferencesStore` is `@Observable @MainActor`; injected via `.environment(\.preferences, …)` so SwiftUI views read-and-react to changes without ObservableObject boilerplate.
- **One `URLSession` per tier** (CLAUDE.md "Concurrency & Polling Pattern") — Detection probes reuse the existing 2s `localhostHTTP` instance (Phase 4) for Ollama / LM Studio / llama.cpp detection; the 8s remote-tier instance for OpenRouter (when probing the API key validity is desired — research call). NO new URLSession.
- **Lenient `Codable` for bundled JSON** (Phase 2 STATE #37) — `providers.json` decoder MUST tolerate unknown future fields.
- **Composition Root + retain observers in `Dependencies`** (Pitfall 4 / PowerObserver precedent) — new `WindowActivationObserver` + `WelcomeWindowController` references MUST live in `Dependencies` for the app's lifetime.
- **Exhaustive switch over `ProviderID`** — every site that switches over ProviderID needs no new arms in Phase 5 (no new providers); but Settings → Providers tab iterates over `ProviderID.allKnown` (or equivalent) to render rows. Add a static `ProviderID.allKnown: [ProviderID]` if not present.
- **`Calendar.current` everywhere** (Phase 1 D-04 / `gotcha_buddhist_calendar_path_components` memory) — N/A for Phase 5 (no date-math in UI surface), but a regression test on any date-formatting site (e.g., "Last updated" in Welcome detection rows) is cheap.

### Integration Points

- **`AppDependencies.makeProduction()`** — new lines: instantiate `UserPreferencesStore`; pass into `ConfigStore.load(preferences:)`; instantiate `WindowActivationObserver` after `Settings` scene scaffolding; optionally instantiate `WelcomeWindowController` and show it when `!preferences.hasSeenWelcome`; retain both observers on `Dependencies`.
- **`AgentsUsageBarApp.body`** — add `Settings { SettingsScene() }` scene; both scenes share the same `environment(dependencies.store)` + new `environment(dependencies.preferences)` + `environment(\.clockService, dependencies.clock)` chain.
- **`ConfigStore.load`** — signature changes to `load(preferences: UserPreferencesStore?) -> AppConfig`; precedence applied per-field per D-03.
- **`PollScheduler`** — add `setInterval(_:)` if absent; observed by Dependencies → reacts to `preferences.refreshInterval` change.
- **`AggregateStore`** — observe `preferences.providerEnabled` map; on transition true → false, cancel in-flight Task for that provider + remove row (or hide via a UI flag).
- **`ThresholdEngine`** — observe `preferences.threshold`; rebuild engine (or mutate) on change.
- **No new `Info.plist` change.** No new entitlements.
- **No new SEC-04 grep rules.** Settings + Welcome carry no new secrets.
- **`.github/workflows/ci.yml`** — add a CFG-06 enforcement step: `! grep -RIn -e 'zshrc' -e 'bashrc' -e 'config\.fish' AgentsUsageBar/` (Settings + Welcome must never reference shell RC files).

</code_context>

<specifics>
## Specific Ideas

- **ClaudeBar `MenuBarExtra(.window)` + `Settings { … }` co-existence** — study its activation-policy flip code if it implements one; Phase 5's `WindowActivationObserver` should mirror that shape. https://github.com/tddworks/ClaudeBar
- **`SMAppService.mainApp` `.requiresApproval` case must surface gracefully** — when System Settings denies (or hasn't granted) the login-item registration, the toggle should revert silently + show a one-line subtitle "Approve in System Settings → Login Items" with a deep-link button. macOS 14 routinely lands in `.requiresApproval` on first call.
- **Welcome window must NOT auto-close after detection completes** — user reads the page; closes via Get Started / Open Settings. No timeout.
- **Snippets in `providers.json` use placeholder `<your-key-here>` not real-looking keys** — to avoid SEC-04 grep tripping on bundled JSON (`sk-or-...` matches `sk-or-`). Use literal `<placeholder>` tokens; document in providers.json's top-level comment field.
- **Theme picker labels** — "Light / Dark / Auto" (Auto = follow system). Use `.preferredColorScheme(theme.colorScheme)` where `theme.colorScheme` returns `.light` / `.dark` / `nil` (nil = follow system).
- **Test-driven** for `UserPreferencesStore` (UserDefaults round-trip + change notifications), `ConfigStore.load(preferences:)` precedence chain, `DetectionProbe` per-provider logic with `URLProtocol` stubs, `WindowActivationObserver` flip plumbing (via `NSWindow.willOpenNotification` post-and-assert). Swift Testing `@Test` with `.serialized` trait when stubs are shared.
- **Memory: `feature_claude_quota_detail_view`** — Phase 5 is a candidate phase to ship the per-provider expand-on-click detail view. Defer if it bloats the Providers tab; revisit after Phase 5 ships.

</specifics>

<deferred>
## Deferred Ideas

- **Per-provider threshold override UI in Settings** — v2 (TRENDS-02). v1 ships a single global threshold per CFG-05.
- **Notifications tab in Settings** — v2. Single-control tab in v1 doesn't justify the tab; lives in General.
- **Per-notification "Open Dashboard" button** — v2 (Phase 3 D-16 reaffirms Phase 1 D-13).
- **Welcome re-appearance after major version updates** — v2; v1 shows welcome exactly once per UserDefaults domain.
- **File-watch hot-reload of `~/.config/agents-usage-bar/config.toml`** — v2; current model is "TOML applied at launch + UserDefaults overrides hot-reload." Settings → Providers tab "Re-check" gives the manual escape hatch.
- **Welcome window localization** — v2; English-only in v1.
- **Per-provider primary-model selector for Gemini** (`[gemini].primary_model` knob) — Phase 3 deferred → v2.
- **Bundled CLI (`agents-usage` or `aub`)** — v2 (EXP-03); Settings → About can link to v2 install instructions when shipped.
- **Sparkle "Check for updates" button in About tab** — Phase 6 wiring; About tab leaves a placeholder spot.
- **macOS 13 backport** — explicitly out of scope (deployment target = 14.0 per SHELL-02).
- **Multi-day historical charts / Sparkline integration in Settings** — v2 (TRENDS-01).
- **Custom theme imports (`.itermcolors`)** — v3+ per REQUIREMENTS.md Future.
- **Welcome window screenshot / animated demo** — v2; v1 ships plain-text-only welcome.
- **In-Settings Keychain entry UI** — explicitly out of scope (CFG-01 anti-feature, reaffirmed).
- **Shell RC file parsing for env detection** — explicitly out of scope (CFG-06 anti-feature, reaffirmed; CI grep enforces).

</deferred>

---

*Phase: 5-first-run-ux-settings-polish*
*Context gathered: 2026-05-21*
