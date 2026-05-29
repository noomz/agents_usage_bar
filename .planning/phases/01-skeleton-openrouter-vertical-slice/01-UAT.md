---
status: gap_closed
phase: 01-skeleton-openrouter-vertical-slice
source: [01.01-SUMMARY.md, 01.02-SUMMARY.md, 01.03-SUMMARY.md, 01.04-SUMMARY.md, 01.05-SUMMARY.md, 01.06-SUMMARY.md, 01.07-SUMMARY.md, 01.08-SUMMARY.md, 01.09-SUMMARY.md]
started: 2026-05-12T07:38:00Z
updated: 2026-05-13T00:00:00Z
---

## Current Test

[cosmetic Test 2 gap closed via 01.09; 1 blocked item outstanding (third-party)]

## Tests

### 1. Cold Start Smoke Test
expected: Quit + relaunch → menu bar icon appears, no Dock icon, no Cmd-Tab entry, popover opens with cached row instantly (no "Loading…" flash). Covers SHELL-01/02/03, UI-07.
result: pass

### 2. Popover Layout (UI fix verification)
expected: Click icon → ~360pt-wide popover. Visible chrome on Refresh + Quit buttons (bordered, not plain text). Hovering Refresh/Quit shows arrow cursor, NOT text I-beam. No overlap between "Updated Xs ago" / "Resets —" row and the footer buttons. Refresh button has refresh-icon + "Refresh" label.
result: pass
gap_closed_by: 01.09
artifact: AgentsUsageBar/UI/Components/HoverableBorderedButtonStyle.swift
note: "Cosmetic hover-state gap closed in Plan 01.09 — HoverableBorderedButtonStyle applies Color.primary.opacity 0.06→0.12→0.18 across idle→hover→pressed via explicit .onHover. Runtime visual check still required for final sign-off."

### 3. Live OpenRouter Fetch (config-driven)
expected: With `OPENROUTER_API_KEY` set in `~/.config/agents-usage-bar/config.toml` (or env), open popover. OpenRouter row shows: status dot (gray→colored), today USD spend or "—" on cold launch, balance "bal $X.XX" if account has credits, colored quota bar (gray "no limit" for unlimited tier, OR green/yellow/red bar if you set a credit cap). Covers ROUTER-01/02/03/04, CFG-01/02, UI-04/06.
result: pass

### 4. Refresh Button + "Updated Xs ago" Tick
expected: Click "Refresh" button (or press Cmd-R with popover focused). "Updated 0s ago" appears. Wait 3s → label updates to "3s ago", then "5s ago", ticking every second. After 5 minutes of inactivity an auto-poll fires (label resets to "0s ago"). Covers POLL-01/02/03/07, UI-10.
result: pass

### 5. Quit + Cache Restore
expected: Quit via footer "Quit" button (or Cmd-Q). App fully terminates (no menu bar icon, no Activity Monitor process). Relaunch → popover opens with PREVIOUS values immediately (no spinner, no "Loading…", no zero-flash). Covers SHELL-04, SHELL-06, UI-07.
result: pass

### 6. Secret Hygiene (no key leak)
expected: In a separate terminal: `log stream --predicate 'subsystem == "app.agents-usage-bar"' --level debug`. Trigger a refresh (Cmd-R). Inspect log output. Any time the API key would appear, you see `<redacted>` or no key string at all. NEVER raw `sk-or-v1-...`. Also: `grep -RIn 'sk-or-\|sk-\|AIza' AgentsUsageBar/ AgentsUsageBarTests/` in the project returns 0 lines. Covers SEC-01/02/04/05.
result: pass

### 7. Threshold Notification (80% warning)
expected: This is verifiable end-to-end ONLY if your OpenRouter account has a credit cap set AND today's usage is approaching 80% of that cap. If you can't manufacture that scenario, this test is BLOCKED. If conditions exist: a single macOS notification fires when usage crosses 80%, titled "OpenRouter at NN%", body "$X.XX of $Y.YY used today." Notification re-fires NEVER for the same day (stable ID per `<providerID>:<yyyy-MM-dd>:warn80`). Covers NOTIF-06/07. Unit tests already prove the coalescing path (1 add() for ≥2 decisions) — type "skip" or "blocked: need real spend" if you can't reproduce live.
result: blocked
blocked_by: third-party
reason: "User reported: blocked: need real spend at 80% — OpenRouter unlimited tier, no credit cap configured. Unit tests cover the coalescing path; live trigger requires real spend trajectory."

## Summary

total: 7
passed: 6
issues: 0
pending: 0
skipped: 0
blocked: 1

## Gaps

- truth: "Hovering Refresh/Quit buttons shows visual hover state (highlight/tint change) distinct from idle"
  status: closed
  closed_by: 01.09
  reason: "User reported: pass with issue — hover on button has no diff style from still button"
  severity: cosmetic
  test: 2
  root_cause: "Native .buttonStyle(.bordered) hover feedback on macOS 26 + ad-hoc-signed debug builds was too subtle to perceive."
  artifacts:
    - AgentsUsageBar/UI/Components/HoverableBorderedButtonStyle.swift
    - AgentsUsageBarTests/UITests/HoverableBorderedButtonStyleTests.swift
  missing: []
  debug_session: ""
