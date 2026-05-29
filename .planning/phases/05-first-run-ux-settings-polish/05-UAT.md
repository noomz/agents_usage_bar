# Phase 5 — User Acceptance Test

**Reviewer:** Siriwat Uamngamsup
**Date:** <fill-in at run time>
**Build:** <latest git SHA at UAT start>

## Test outcomes table

| #  | Test                                                                                                                                             | Result      | Notes |
|----|--------------------------------------------------------------------------------------------------------------------------------------------------|-------------|-------|
| 1  | Welcome window auto-opens on fresh install; provider rows show detection state (CFG-03, CFG-04, D-09, D-10)                                      | `<pending>` | |
| 2  | Cmd-, opens Settings window; activation policy flips .regular while open, .accessory on close (SHELL-05, D-05, D-06)                             | `<pending>` | |
| 3  | Settings General tab: all 4 controls hot-reload without restart (CFG-05, D-04, D-07, D-08)                                                       | `<pending>` | |
| 4  | Settings Providers tab: enable toggles, Re-check, expandable help panels, Copy button (CFG-03, CFG-04, D-14, D-16)                               | `<pending>` | |
| 5  | Shell RC files never read at any point in first-run or Settings flow (CFG-06 anti-feature)                                                       | `<pending>` | |
| 6  | WindowActivationObserver + Settings scene scaffold — activation policy flip attested (05-01 suites)                                              | `<pending>` | |
| 7  | UserPreferencesStore + ConfigStore precedence overlay — userDefaults > env > toml > defaults attested (05-02 suites)                             | `<pending>` | |
| 8  | SettingsGeneralTab + AggregateStore.updateWarningFraction — hot-reload wiring attested (05-03 suites)                                            | `<pending>` | |
| 9  | DetectionProbe + OnboardingCopy + SettingsProvidersTab — 7-provider parallel detection attested (05-04 suites)                                   | `<pending>` | |
| 10 | WelcomeWindowController — first-run gate (hasSeenWelcome) + activation policy + provider seeding attested (05-05 suites)                         | `<pending>` | |

**Overall outcome:** `<APPROVED / FAILED / DEFERRED — fill in after Tests 1-5>`

---

## Pre-conditions

Before running Tests 1-5, satisfy **all** of the following:

- **Build:** `xcodebuild build -project AgentsUsageBar.xcodeproj -scheme AgentsUsageBar -configuration Debug` exits 0.
- **Launch:** Open the app from `~/Library/Developer/Xcode/DerivedData/AgentsUsageBar-*/Build/Products/Debug/AgentsUsageBar.app`.

**For Test 1 (Welcome window — fresh install):** Delete `aub.hasSeenWelcome` from UserDefaults before launch:
```bash
defaults delete app.agents-usage-bar aub.hasSeenWelcome 2>/dev/null || true
```
Then quit and relaunch the app.

**For Test 1 (provider detection):** At minimum, have one of the following present:
- `~/.claude/projects/` directory (Claude auto-detected).
- `OPENROUTER_API_KEY` set in environment (OpenRouter detected as configured).
- Ollama running (`ollama serve`) on port 11434.

**For Test 2 (Cmd-,):** The app must be running in the foreground (popover open) when pressing Cmd-,.

**For Test 3 (General tab hot-reload):** Have the app running with a provider that has quota data (e.g. OpenRouter or Claude); threshold changes must be observable via the notification logic.

**For Test 4 (Providers tab):** Have at least one undetected provider visible (e.g. LM Studio not running) to exercise the "How to enable" panel.

**For Test 5 (CFG-06):** Can be verified by source-walk; the CI grep step enforces this automatically.

**Phase 1/2/3/4 regression baseline:**
- Keep `OPENROUTER_API_KEY` env var set so the OpenRouter row also populates.
- Have `~/.claude/projects/` with today's JSONL transcripts for the Claude row.
- Have `~/.codex/sessions/$(date +%Y/%m/%d)/rollout-*.jsonl` for the Codex row.
- Have `~/.gemini/oauth_creds.json` populated for the Gemini row.
- The full 4-row hosted-API popover should be visible alongside any detected local rows.

**Log stream (recommended):**
```
log stream --predicate 'subsystem == "app.agents-usage-bar"' --info
```

---

## Test 1 — Welcome window auto-opens on fresh install (Phase 5 SC #1 / CFG-03, CFG-04)

1. After `defaults delete app.agents-usage-bar aub.hasSeenWelcome`, relaunch the app.
2. **PASS** if the Welcome window appears automatically without any user action within 2 seconds of launch.
3. **PASS** if the window title reads "Welcome to Agents Usage Bar" (or the window is clearly identifiable as the welcome screen) and is non-resizable (~520×480pt).
4. **PASS** if each provider row shows "Checking…" badge initially, then transitions to one of: "Detected" (green checkmark), "Not running" (gray dot), "Not configured" (orange exclamation), or "Not detected" (gray question mark) — within 3 seconds (2s probe timeout + rendering).
5. **PASS** if any provider that shows "Detected" has its enable toggle flipped ON in UserDefaults (verify: open Settings → Providers tab after dismissing Welcome; that provider's toggle should be ON).
6. **PASS** if an undetected provider row has a disclosure chevron; clicking it expands a "How to enable" panel with env var and TOML snippets and a Copy button.
7. **PASS** if clicking "Copy" on a snippet copies it to the clipboard — verify via `pbpaste` in Terminal.
8. **PASS** if clicking "Get Started" closes the Welcome window and the Dock icon disappears (activation policy → .accessory).
9. **PASS** if relaunching the app does NOT show the Welcome window again (hasSeenWelcome = true persists in UserDefaults).
10. **PASS** if the Dock icon is absent during normal popover-only operation (no Welcome, no Settings open).

---

## Test 2 — Cmd-, opens Settings; activation policy flip (Phase 5 SC #2 / SHELL-05)

1. With the app running (menu bar icon visible, no Settings open), open the popover and press Cmd-,.
2. **PASS** if the Settings window opens and comes to the foreground with keyboard focus (no need to click the window).
3. **PASS** if a Dock icon appears while the Settings window is open.
4. **PASS** if the Settings window shows three tabs: General, Providers, About.
5. **PASS** if the Settings window title bar renders correctly (standard macOS preferences-style toolbar).
6. Close the Settings window (Cmd-W or the red close button).
7. **PASS** if the Dock icon disappears after the Settings window closes.
8. **PASS** if the menu bar icon and popover continue to function normally after Settings closes.
9. **Repeat test with Welcome window:** reset `hasSeenWelcome` and relaunch; verify the Welcome window also causes a Dock icon while open, which disappears on dismiss.
10. **Edge case:** open both Welcome AND Settings simultaneously (via "Open Settings" in Welcome footer); **PASS** if the Dock icon remains visible while either window is open, and disappears only when both are closed.

---

## Test 3 — Settings General tab: all 4 controls hot-reload without restart (Phase 5 SC #3 / CFG-05)

1. Open Settings → General tab.
2. **Refresh interval:** Change the "Poll every" picker from 5 min to 1 min. Wait 70 seconds. **PASS** if the "Updated Xs ago" label in the popover resets within ~1 minute (confirming new interval is active).
3. **Warning threshold:** Move the "Warn when usage reaches" slider. **PASS** if the percentage label updates live (e.g. "80%" → "70%"). Confirm the value persists after closing and reopening Settings.
4. **Theme:** Click "Light" in the theme picker. **PASS** if the Settings window and popover switch to light mode immediately (no restart required). Click "Dark" — **PASS** if dark mode applies. Click "Auto" — **PASS** if the system appearance is followed.
5. **Open at login:** Toggle "Open at login" ON. **PASS** if the toggle switches. If macOS shows a `.requiresApproval` state, **PASS** if a subtitle appears: "Approve in System Settings" with an "Open Login Items ↗" button. Click the button. **PASS** if System Settings opens to the Login Items pane.
6. **Silent revert on failure:** Force a failure scenario if possible (e.g. revoke login item permission in System Settings, then try to toggle again). **PASS** if the toggle silently reverts to OFF — no error alert, no crash. (If not reproducible manually, mark DEFERRED with `SettingsGeneralTabTests.settingsGeneralTab_silentRevert_noToast` attestation.)
7. Restore refresh interval to 5 min after test to avoid exhausting API quotas during remaining tests.

---

## Test 4 — Settings Providers tab: enable toggles, Re-check, help panels, Copy (Phase 5 SC #3 / CFG-03, CFG-04)

1. Open Settings → Providers tab.
2. **PASS** if all 7 provider rows appear: OpenRouter, Claude, Codex, Gemini, Ollama, LM Studio, llama.cpp.
3. **PASS** if each row shows a detection badge (Detected / Not running / Not configured / Not detected) within 3 seconds of tab open (auto Re-check on appear, D-16).
4. **Enable toggle:** Turn OFF a currently-detected provider (e.g. Codex). **PASS** if the popover no longer shows/refreshes that provider's row on next poll (within 1 minute). Turn it back ON.
5. **Re-check button:** Click the ⟳ button on an undetected provider row. **PASS** if the badge briefly shows "Checking…" and then re-renders the result.
6. **How to enable panel:** Click the disclosure chevron on an undetected/unconfigured provider row. **PASS** if the panel expands and shows: description text, env var snippet, TOML snippet, "Copy" buttons, and optionally a "Open docs ↗" link.
7. **Copy button:** Click "Copy" on the env var snippet. **PASS** if `pbpaste` in Terminal shows the snippet text (without real-looking API keys — `<placeholder>` tokens or descriptive text only).
8. **PASS** if the TOML snippet Copy button copies the TOML form of the configuration snippet.
9. **CFG-06 sub-test:** Expand every "How to enable" panel. **PASS** if no panel mentions `~/.zshrc`, `~/.bashrc`, or `config.fish` — only env var and TOML forms are shown.

---

## Test 5 — Shell RC files never read (Phase 5 SC #5 / CFG-06 anti-feature)

1. **Source audit (primary):** Run the CFG-06 CI grep locally:
   ```bash
   VIOLATIONS=$(grep -RIn \
     --include='*.swift' \
     --exclude-dir='.build' \
     --exclude-dir='DerivedData' \
     -e '\.zshrc' \
     -e '\.bashrc' \
     -e 'config\.fish' \
     AgentsUsageBar/ \
   | grep -v '^[^:]*:[0-9]*:[[:space:]]*//' || true)
   if [ -n "$VIOLATIONS" ]; then
     echo "CFG-06: FAIL"; echo "$VIOLATIONS"
   else
     echo "CFG-06: PASS — no non-comment shell RC references found"
   fi
   ```
   **PASS** if output is `CFG-06: PASS`.
2. **Runtime audit (secondary):** Launch the app with `DYLD_PRINT_FILES=1` in the environment:
   ```bash
   DYLD_PRINT_FILES=1 /path/to/AgentsUsageBar.app/Contents/MacOS/AgentsUsageBar 2>&1 | grep -i 'zshrc\|bashrc\|config\.fish'
   ```
   **PASS** if no output appears (app did not open any shell RC file at launch).
3. **PASS** if the Welcome window detection flow (Test 1) completed without opening any shell RC file.
4. **PASS** if the Settings Providers tab Re-check flow (Test 4 step 5) completed without opening any shell RC file.
5. **PASS** if the CI workflow includes a `CFG-06 — no shell RC file references in source` step (verify in `.github/workflows/ci.yml`).

---

## Tests 6-10 — Unit-test attestation

Tests 6-10 cover invariants that cannot be exhaustively manually verified. All cited suites passed when their plans landed; the reviewer can spot-check by running `xcodebuild test -project AgentsUsageBar.xcodeproj -scheme AgentsUsageBar -only-testing AgentsUsageBarTests/<SuiteName>` if desired. Mirrors the Phase 2/3/4 attested-by-suite pattern.

**Test 6 — WindowActivationObserver + Settings scene scaffold (Plan 05-01):**
Attested by:
- `WindowActivationObserverTests` (8 cases — single window open; single close; two-window keep-regular; two-window both-close; unrelated-window-ignored; force-launch reset; regained-key no-double-increment; full NotificationCenter wire integration).
- `SettingsSceneTests` / composition-root smoke: `Settings { }` scene present in `AgentsUsageBarApp.swift`; Cmd-, `CommandGroup(replacing: .appSettings)` override present; `NSApp.activate(ignoringOtherApps: true)` present; `WindowActivationObserver` retained in `Dependencies`.

See `05-01-SUMMARY.md`.

**Test 7 — UserPreferencesStore + ConfigStore precedence overlay (Plan 05-02):**
Attested by:
- `UserPreferencesStoreTests` (9+ cases — round-trip for all 5 keys; change notification fires; UserDefaults isolation via `suiteName`; `hasSeenWelcome` defaults false; `providerEnabled` per-provider round-trip).
- `ConfigStorePrecedenceTests` (5+ cases — `userDefaults > env > toml > defaults` for refreshInterval, threshold, openAtLogin; credentials NOT overridden by UserDefaults; unknown keys silently ignored).
- `AppEnvironmentKeysTests` (3+ cases — `\.preferences` environment key available; `UserPreferencesStore` injectable via `.environment`).

See `05-02-SUMMARY.md`.

**Test 8 — SettingsGeneralTab + hot-reload wiring + AggregateStore.updateWarningFraction (Plan 05-03):**
Attested by:
- `AggregateStoreUpdateWarningFractionTests` (3+ cases — engine rebuilt with new fraction; FSM state preserved; no spurious re-fire).
- `SettingsGeneralTabTests` (5+ structural cases — Slider range `0.5...0.95`; `SMAppService` deep-link URL present; Picker tags; silent revert — no Toast/Alert).
- `observePreferences` loop confirmed present in `AppDependencies.swift` (grep attestation).

See `05-03-SUMMARY.md`.

**Test 9 — DetectionProbe + OnboardingCopy + SettingsProvidersTab (Plan 05-04):**
Attested by:
- `DetectionProbeTests` (10+ cases — openrouter detected/notConfigured; claude/codex detected via FS; gemini oauth gate; ollama HTTP 200 → detected; connection-refused → notRunning; llamacpp notConfigured when port absent; probeAll returns 7 entries; CFG-06 source-walk on DetectionProbe.swift).
- `OnboardingCopyTests` (5+ cases — 7 providers loaded; all providerIDs match `ProviderID.allKnown`; no real-looking API keys; lenient decode; bundleResourceMissing error).
- `SettingsProvidersTabTests` (4+ structural cases — `ProviderID.allKnown` reference; `DisclosureGroup` present; `NSPasteboard.general` present; CFG-06 source-walk).

See `05-04-SUMMARY.md`.

**Test 10 — WelcomeWindowController + WelcomeRootView + AppDependencies wiring (Plan 05-05):**
Attested by:
- `WelcomeWindowControllerTests` (6 cases — showIfNeeded no-op when hasSeenWelcome true; opens when false; dismiss sets hasSeenWelcome true; title assertion (win.title="Welcome" for WindowActivationObserver); no direct setActivationPolicy call; willClose observer source-walk).
- `WelcomeRootViewTests` (5 structural cases — `ProviderID.allKnown` reference; `DetectionProbe.probeAll` call present; `setProviderEnabled` call present; both footer buttons present; CFG-06 source-walk).
- `AppDependencies.makeProduction()` attestation: `WelcomeWindowController` stored in `Dependencies`; `showIfNeeded()` called from `.task` in `AgentsUsageBarApp`.

See `05-05-SUMMARY.md`.

---

## Hotfixes landed during the UAT session

| Commit | Subject |
|--------|---------|
| `ffb7cd8` | H-01: add Settings entry point to menu-bar popover footer (SHELL-05). Native Settings window was unreachable from the menu bar after first run — footer had only Refresh + Quit; the showSettingsWindow:/showPreferencesWindow: selector dispatch via NSApp.sendAction(to: nil) failed silently on this LSUIElement app. Added a gear "Settings" button to FooterView using the SwiftUI @Environment(\.openSettings) action. Verified manually: popover footer button opens the Settings window with all three tabs rendering. |

*Mirrors Phase 4 H-01/H-02 pattern.*

---

## Phase 5 Success Criteria Mapping

| Success Criterion | UAT Tests |
|-------------------|-----------|
| #1 — First launch auto-detects providers; welcome screen lists detection state + How-to-enable CTA (CFG-03, CFG-04) | Test 1, 9, 10 |
| #2 — Cmd-, opens Settings; activation policy flips .regular while open, .accessory on close (SHELL-05) | Test 2, 6 |
| #3 — Settings: refresh interval picker, threshold slider, per-provider toggles, theme picker, open-at-login OFF by default (CFG-05) | Test 3, 4, 7, 8 |
| #4 — Theme changes apply live; light/dark/auto render correctly (CFG-05) | Test 3, 7 |
| #5 — Shell RC files never read at any point in first-run or Settings flow (CFG-06) | Test 5, 9 |

---

## Reviewer signal

**VERDICT: `approved` (2026-05-22).** Reviewer confirmed live: Welcome window auto-opens on fresh install (`activation → .regular`); menu-bar popover → Settings opens with all three tabs (General/Providers/About) rendering. One hotfix landed mid-walkthrough — H-01 (`ffb7cd8`, Settings entry point in popover footer); recorded in Hotfixes table above. Phase 5 complete; advance to Phase 6 (Distribution).

Reply with one of:

- `approved` — Phase 5 complete; the executor will commit the marked-up `05-UAT.md`, update `STATE.md` + `ROADMAP.md`, and the orchestrator can run `/gsd-transition` to advance to Phase 6 (Distribution).
- `failed: <test#>: <description>` — File one or more gap entries. The executor records the failed steps in this `05-UAT.md`, leaves Phase 5 in BLOCKED state, and the next action is `/gsd-plan-phase 05 --gaps`.
- `deferred: <test#>: <reason>` — Accept the test as unit-test-attested only (mirrors Phase 2/3/4 reviewer accepting attestation rows). Phase 5 still considered complete if Tests 1-5 manual or 6-10 attested.

---

*(This file authored as Plan 05-06 Task 2. Phase 5 code-complete after Plans 05-01..05-06 Task 1. Reviewer signal in this UAT determines whether Phase 5 transitions to "approved" or to gap closure via `/gsd-plan-phase 05 --gaps`.)*
