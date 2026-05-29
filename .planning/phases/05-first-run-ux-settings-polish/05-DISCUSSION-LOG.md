# Phase 5: First-Run UX + Settings Polish - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-05-21
**Phase:** 5-first-run-ux-settings-polish
**Areas discussed:** Settings persistence layer, Settings scene shape + activation, First-run welcome surface, "How to enable" CTA

---

## Settings Persistence Layer

### Q1: Where should in-app Settings changes persist?

| Option | Description | Selected |
|--------|-------------|----------|
| Hybrid: UserDefaults wins, TOML read-only | UserDefaults stores in-app overrides; TOML stays read-only (power-user / dev knob). On boot: apply TOML, then layer UserDefaults overrides. | ✓ |
| Round-trip TOML — write back to config.toml | Single source of truth, lives in `~/.config/`. Requires writing a TOML serializer; risk of clobbering user comments/formatting. | |
| UserDefaults-only — ignore TOML for writes | Simplest. TOML still seeds initial defaults; Settings UI writes only to UserDefaults. | |

**User's choice:** Hybrid: UserDefaults wins, TOML read-only
**Notes:** Avoids writing a TOML serializer; user's hand-edited TOML never clobbered; matches macOS-app convention.

### Q2: Precedence chain — where does UserDefaults slot in?

| Option | Description | Selected |
|--------|-------------|----------|
| userDefaults > env > toml > defaults | In-app Settings UI is the topmost authority. | ✓ |
| env > userDefaults > toml > defaults | Env stays king (matches existing D-17). | |
| Split: credentials env > toml; knobs userDefaults > toml > defaults | Credentials env > toml; user-mutable knobs UserDefaults topmost. | |

**User's choice:** userDefaults > env > toml > defaults
**Notes:** Settings clicks must stick — no silent env override. CONTEXT D-03 records that credentials still flow env > toml only (no Keychain UI per CFG-01), so the per-field precedence is: knobs follow D-02; credentials follow D-03.

### Q3: Hot-reload behavior on Settings change?

| Option | Description | Selected |
|--------|-------------|----------|
| Live: store observes UserDefaults, scheduler/providers reconfigure | Interval, toggles, threshold, theme, open-at-login all apply immediately. | ✓ |
| Settled: changes apply on next poll tick | Next tick reads new values. Up to 5min lag on provider toggle. | |
| Restart-required modal | "Quit and relaunch to apply" on changes. | |

**User's choice:** Live hot-reload
**Notes:** Menu bar app — restart UX is unacceptable. Plan must add `PollScheduler.setInterval(_:)` if absent.

---

## Settings Scene Shape + Activation

### Q4: How should the Settings window be hosted?

| Option | Description | Selected |
|--------|-------------|----------|
| SwiftUI `Settings { … }` scene | Native Cmd-, wiring, free preferences toolbar, multiple tabs. Known LSUIElement gotcha → explicit NSApp.activate fix. | ✓ |
| Custom NSWindowController hosted from popover | Full control; more code. | |
| Sheet attached to popover | Cramped; no Cmd-, support; conflicts with SHELL-05 spec. | |

**User's choice:** SwiftUI `Settings { … }` scene

### Q5: Activation policy flip tightness (SHELL-05)?

| Option | Description | Selected |
|--------|-------------|----------|
| Flip on Settings-open, restore on Settings-close | NSWindow.willOpen/willClose observers drive `.regular ↔ .accessory`. | ✓ |
| Stay .accessory always; rely on Cmd-, focus quirk | Violates SHELL-05 success criterion. | |
| Flip on first open, stay .regular until quit | Violates SHELL-01 menu-bar-only. | |

**User's choice:** Per-window flip
**Notes:** Same pattern reused by Welcome window (D-09).

### Q6: Settings tab structure?

| Option | Description | Selected |
|--------|-------------|----------|
| General + Providers + About | Standard macOS prefs shape; scales for v2. | ✓ |
| Single flat pane — no tabs | Cramped once 7+ providers added. | |
| General + Providers + Notifications + About | Notifications tab feels empty in v1 (single global threshold). | |

**User's choice:** General + Providers + About
**Notes:** Notifications tab deferred to v2 when per-provider threshold (TRENDS-02) lands.

### Q7: Open-at-login API?

| Option | Description | Selected |
|--------|-------------|----------|
| SMAppService.mainApp.register() / .unregister() | Modern Apple-native (macOS 13+); async-throws. | ✓ |
| sindresorhus/LaunchAtLogin SPM | Third-party wrapper around SMAppService. | |
| Manual LSSharedFileList (deprecated) | Old AppKit API, deprecated since macOS 13. | |

**User's choice:** SMAppService.mainApp
**Notes:** Must surface `.requiresApproval` state gracefully with System Settings deep-link.

---

## First-Run Welcome Surface

### Q8: Where should the first-run welcome live?

| Option | Description | Selected |
|--------|-------------|----------|
| Dedicated welcome NSWindow on first launch | ~520×480pt window; lists providers + CTAs; same activation-flip plumbing as Settings. | ✓ |
| Inline welcome card inside the popover | Cramped at ~360pt; easy to miss (user must open popover). | |
| Open Settings→Providers tab on first launch | Re-uses Settings code; no "Welcome" branding surface. | |

**User's choice:** Dedicated welcome window

### Q9: First-launch trigger?

| Option | Description | Selected |
|--------|-------------|----------|
| UserDefaults `hasSeenWelcome` flag | Single boolean; cheapest; survives TOML and provider changes. | ✓ |
| Absence of `~/.config/agents-usage-bar/config.toml` | TOML is optional; would re-trigger for env-only users. | |
| Both: flag AND no detected providers | Rare edge case; adds complexity for marginal value. | |

**User's choice:** `hasSeenWelcome` UserDefaults flag

### Q10: Auto-detection default-on policy (CFG-03)?

| Option | Description | Selected |
|--------|-------------|----------|
| All detected providers ON, undetected OFF | Zero-config success; no needless polling; matches CFG-03 verbatim. | ✓ |
| All providers ON regardless of detection | Wasted CPU; log spam; unnecessary placeholder rows. | |
| All providers OFF — opt-in only | Violates CFG-03; bad onboarding. | |

**User's choice:** Detected ON, undetected OFF
**Notes:** First-run-only seed — subsequent launches respect user's choices.

### Q11: Detection probe timing for localhost runtimes?

| Option | Description | Selected |
|--------|-------------|----------|
| Welcome window probes synchronously on open, spinner per row | One-shot parallel probes via `withTaskGroup`. 2s perceived welcome latency acceptable. | ✓ |
| Pre-compute during AppDependencies.makeProduction(), pass to welcome | Blocks app launch 2s if Ollama down; impacts every user including post-welcome. | |
| Skip live probe — file signals only | Localhost stays "Maybe running" — negates welcome purpose. | |

**User's choice:** Welcome-window-only synchronous probe

---

## "How to Enable" CTA

### Q12: Primary CTA action per undetected row?

| Option | Description | Selected |
|--------|-------------|----------|
| Inline expandable help panel + Copy button | Disclosure chevron reveals copyable snippet + secondary docs link. | ✓ |
| "Open docs ↗" button per provider (browser hop) | Needs internet; README anchors are fragile. | |
| Pop-up tooltip on hover | Invisible to non-hover users; no copy; truncates. | |

**User's choice:** Inline expandable + Copy button

### Q13: Where do per-provider snippets live?

| Option | Description | Selected |
|--------|-------------|----------|
| Bundled `Resources/Onboarding/providers.json` | Structured fields; single source of truth; mirrors existing `Resources/Pricing/*.json` pattern. | ✓ |
| Hard-coded in Swift `OnboardingCopy` struct | Copy edits require rebuild. | |
| Markdown files rendered via `AttributedString` | Heavier than needed; harder to extract structured fields. | |

**User's choice:** Bundled `providers.json`

### Q14: How does an undetected row update after user takes action?

| Option | Description | Selected |
|--------|-------------|----------|
| Manual "Re-check" button per row + auto-recheck on Settings→Providers open | ⟳ button per row; tab activation also re-probes. | ✓ |
| Auto-recheck on every popover open + welcome focus | Env-var changes still require restart; can mislead. | |
| Show "Restart app to apply changes" toast | Conflicts with hot-reload decision; bad menu-bar UX. | |

**User's choice:** Manual Re-check + Settings-tab auto-recheck

### Q15: How explicit about env-var vs TOML hot-reload behavior?

| Option | Description | Selected |
|--------|-------------|----------|
| Snippets include both env-var AND TOML forms; recommend TOML for hot-reload | Two snippets per provider; per-snippet note distinguishes restart vs hot-reload behavior. | ✓ |
| TOML-only snippets; mention env in docs | Ignores first-class env path from PROJECT.md. | |
| Env-only snippets; mention TOML in docs | Forces restart for every Copy-and-paste user — bad UX. | |

**User's choice:** Both forms; per-snippet note

---

## Claude's Discretion

- UserDefaults key namespacing (`aub.*` prefix)
- Theme picker shape (segmented `Picker` with Light/Dark/Auto)
- Refresh interval picker shape (segmented or menu)
- Threshold slider range (0.5–0.95, step 0.05)
- Settings + Welcome window dimensions
- `PollScheduler.setInterval(_:)` API addition
- Per-provider toggle live-disconnect UX (Task cancellation)
- `SMAppService.mainApp` activation thread + error handling
- Activation policy flip plumbing (NSWindow notification observer)
- File layout (`AgentsUsageBar/UI/Settings/` + `UI/Welcome/`)
- Test layout (`AgentsUsageBarTests/Settings/` + `Welcome/`)
- CFG-06 regression test (grep enforcement in CI)

## Deferred Ideas

- Per-provider threshold override UI in Settings — v2 (TRENDS-02)
- Notifications tab in Settings — v2
- Per-notification "Open Dashboard" button — v2
- Welcome re-appearance after major version updates — v2
- File-watch hot-reload of `config.toml` — v2
- Welcome window localization — v2 (English-only in v1)
- Per-provider primary-model selector for Gemini — v2
- Bundled CLI link in About tab — v2 (EXP-03)
- Sparkle "Check for updates" button — Phase 6
- macOS 13 backport — out of scope (deployment 14.0 per SHELL-02)
- Multi-day historical charts in Settings — v2 (TRENDS-01)
- Custom theme imports (`.itermcolors`) — v3+
- Welcome screenshot / animated demo — v2
- In-Settings Keychain entry UI — out of scope (CFG-01 anti-feature)
- Shell RC file parsing for env detection — out of scope (CFG-06 anti-feature)
