# Requirements: Agents Usage Bar

**Defined:** 2026-05-11
**Core Value:** A single ambient glance shows accurate per-provider AI usage for today, so the user notices spend/quota issues before they bite.

## v1 Requirements

### Shell (macOS Menu Bar App)

- [x] **SHELL-01**: App launches as menu-bar-only (`LSUIElement = YES`, no Dock icon, no Cmd-Tab entry)
- [x] **SHELL-02**: App targets macOS 14+ (`@Observable`, stable `MenuBarExtra(.window)`)
- [x] **SHELL-03**: Menu bar status item shows a custom SF-Symbol icon (18×18) and opens a SwiftUI popover panel
- [x] **SHELL-04**: Popover panel uses fixed width (~360pt) with dynamic height and dismisses on click-outside, on external display, post-sleep, and with Stage Manager on
- [x] **SHELL-05**: Settings window opens via Cmd-comma; activation policy temporarily flips to `.regular` while open and back to `.accessory` on close
- [x] **SHELL-06**: Quit action available from popover (footer) and Cmd-click context menu

### Provider — Claude

- [x] **CLAUDE-01**: App parses `~/.claude/projects/**/*.jsonl` (streaming, line-by-line) and sums today's per-model input/output/cache-read/cache-create tokens
- [x] **CLAUDE-02**: App caches `lastReadOffset` per transcript file so subsequent polls read only the delta
- [x] **CLAUDE-03**: Transcript parsing uses a lenient `Codable` with `extraFields` so unknown future fields do not zero out the row
- [x] **CLAUDE-04**: If `~/.claude/.credentials.json` (or Keychain `Claude Code-credentials`) exists, app calls `GET https://api.anthropic.com/api/oauth/usage` with header `anthropic-beta: oauth-2025-04-20` and surfaces `five_hour` + `seven_day` quota windows with reset times
- [x] **CLAUDE-05**: Claude row computes today's USD cost via an embedded `models.json` price table (input / output / cache-read / cache-create per model)

### Provider — Codex

- [x] **CODEX-01**: App reads the most recent `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, locates last `event_msg.token_count` event, and extracts `total_token_usage`, `rate_limits.primary`, `rate_limits.secondary`, `credits`, `plan_type`, `resets_at`
- [x] **CODEX-02**: Codex row falls back to `GET https://chatgpt.com/backend-api/wham/usage` with bearer from `~/.codex/auth.json` when no recent rollout file exists
- [x] **CODEX-03**: Codex row renders primary + secondary windows with reset countdowns
- [x] **CODEX-04**: Codex USD cost computed from rollout-derived tokens using the embedded pricing table

### Provider — Gemini

- [ ] **GEMINI-01**: If `~/.gemini/oauth_creds.json` exists with `selectedAuthType:"oauth-personal"` in `~/.gemini/settings.json`, app refreshes the bearer via `POST https://oauth2.googleapis.com/token` when expired
- [ ] **GEMINI-02**: App calls `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` and surfaces per-model `remainingFraction` + `resetTime`
- [ ] **GEMINI-03**: Tier detection via `POST .../v1internal:loadCodeAssist` surfaces tier label in row tooltip
- [ ] **GEMINI-04**: If `v1internal` endpoint returns 4xx/5xx, row shows "Gemini usage temporarily unavailable" — does not block other providers

### Provider — OpenRouter

- [ ] **ROUTER-01**: When `OPENROUTER_API_KEY` env var is set, app calls `GET https://openrouter.ai/api/v1/credits` for `total_credits` and `total_usage`
- [ ] **ROUTER-02**: App calls `GET https://openrouter.ai/api/v1/key` for rate-limit + free-model quota
- [ ] **ROUTER-03**: Row shows balance (`total_credits − total_usage`); when `limit` is null, renders "no limit" instead of red
- [ ] **ROUTER-04**: Optional env: `OPENROUTER_API_URL`, `OPENROUTER_HTTP_REFERER`, `OPENROUTER_X_TITLE` honoured if present

### Provider — Local LLMs

- [ ] **LOCAL-01**: App probes Ollama at `http://localhost:11434/api/ps` (running models) and `/api/tags` (installed models) with a 1–2s connect timeout
- [ ] **LOCAL-02**: App probes LM Studio at `http://localhost:1234/v1/models` and `/api/v0/models` (configurable port)
- [ ] **LOCAL-03**: App probes llama.cpp / llamafile at `http://localhost:<port>/health`, `/slots`, `/v1/models` (port required in `~/.config/agents-usage-bar/config.toml`, no scanning)
- [ ] **LOCAL-04**: Each local row has tri-state status: `notRunning` (muted, not red) / `running` (model name + slot/VRAM info) / `error` (red w/ message)
- [ ] **LOCAL-05**: Connection refused from a localhost endpoint is treated as `notRunning`, not an error
- [ ] **LOCAL-06**: Local rows show running/idle + model name only; cumulative token tracking is NOT performed (explicit anti-feature)

### Aggregation & UI

- [ ] **UI-01**: Popover has a "Today total" row at top summing tokens + USD across enabled providers
- [ ] **UI-02**: Each provider row shows: name, today-tokens, today-USD, primary quota bar (green >50%, yellow 20–50%, red <20%, gray = depleted), reset countdown, status dot, last-updated timestamp
- [ ] **UI-03**: Quota bars use ClaudeBar threshold convention exactly (50% / 20%)
- [ ] **UI-04**: "Today" is computed using `Calendar.current.dateInterval(of: .day, for: Date())!` — never `Calendar(identifier:)` or UTC bucketing
- [ ] **UI-05**: Footer caption shows the day boundary in user's timezone (e.g. "Resets 00:00 PT")
- [ ] **UI-06**: Popover honors light / dark / auto theme via `@Environment(\.colorScheme)`
- [ ] **UI-07**: Cached last-known value renders immediately on popover open; refresh runs in background (no "Loading…" flash)
- [ ] **UI-08**: Stale-data indicator: status dot dims and "Updated 7m ago" label appears when last successful refresh is older than 2× the configured interval
- [ ] **UI-09**: Menu bar icon tints reflect highest-percent quota across enabled providers (green / yellow / red)
- [ ] **UI-10**: Manual "Refresh now" button in popover footer (also Cmd-R)
- [x] **UI-11**: Each provider row has a one-click "Open dashboard" action linking to the provider's web console

### Polling, Scheduling, and Background Behavior

- [x] **POLL-01**: A single `PollScheduler` actor drives all provider refreshes (no per-provider `Timer`)
- [x] **POLL-02**: Default refresh interval = 5 minutes; user-configurable from {Manual, 1m, 2m, 5m, 15m, 30m}
- [x] **POLL-03**: Refresh also triggers on popover open, coalesced if a refresh ran in the last 5 seconds
- [ ] **POLL-04**: Subscribed to `NSWorkspace.willSleepNotification` (pause) and `didWakeNotification` (single immediate refresh)
- [ ] **POLL-05**: Per-provider exponential backoff with jitter on 429 / 5xx; circuit breaker after 5 consecutive failures
- [ ] **POLL-06**: 4xx (other than 429) treated as terminal until config changes
- [x] **POLL-07**: In-flight requests cancelled via `Task` cancellation when popover closes for a slow tier
- [ ] **POLL-08**: `URLSession` request timeout 8s for remote APIs, 1–2s for localhost
- [ ] **POLL-09**: Energy Impact reports "Low" after 1h idle on battery (verified in Phase 4 or earlier)

### Notifications

- [ ] **NOTIF-01**: Per-provider FSM tracks last-notified state per day: `Normal → Warning(80%) → Critical(95%) → Exceeded(100%)`
- [ ] **NOTIF-02**: Notification fires on state transition only — never on every poll above threshold
- [ ] **NOTIF-03**: Stable identifier per notification: `"<providerID>:<yyyy-MM-dd>:warnXX"` so OS dedupes replays
- [ ] **NOTIF-04**: Default threshold = 80%; configurable per-provider in Settings (post-MVP can globalize)
- [ ] **NOTIF-05**: "Snooze for today" action on every notification persists a snooze flag cleared at local midnight
- [x] **NOTIF-06**: `UNUserNotificationCenter` authorization requested lazily on first dispatch — never at launch
- [x] **NOTIF-07**: Multiple providers crossing threshold within a single poll coalesce into one notification ("3 providers crossed 80%")

### Configuration & Onboarding

- [ ] **CFG-01**: No Keychain UI in v1. All keys/tokens read from existing CLI config files and `ProcessInfo.environment`
- [ ] **CFG-02**: App reads `~/.config/agents-usage-bar/config.toml` (optional) for per-provider toggles, threshold overrides, llama.cpp port, refresh interval
- [ ] **CFG-03**: On first launch, app auto-detects which providers have usable credentials/configs and enables them by default
- [ ] **CFG-04**: First-launch screen lists each provider's detected state with "How to enable" CTA for missing ones (no errors)
- [x] **CFG-05**: Settings scene exposes refresh interval, default threshold, per-provider enable/disable, theme, "open at login" toggle (default OFF)
- [ ] **CFG-06**: Shell RC files (`~/.zshrc`, `~/.bashrc`, fish config) are NOT parsed (explicit anti-feature — code-execution vector)

### Security

- [ ] **SEC-01**: A `Secret` value type wraps every credential; `description` returns `"<redacted>"`; never logged
- [ ] **SEC-02**: Logs use `os.Logger` with `.privacy(.private)` for any data derived from credentials; URLs logged as path+method+status only
- [ ] **SEC-03**: When `~/.config/agents-usage-bar/config.toml` is created, mode is `chmod 0600`; app warns if found world-readable
- [ ] **SEC-04**: CI grep step rejects any source file containing literal `sk-`, `sk-proj-`, `sk-admin-`, `sk-or-`, `AIza` strings
- [ ] **SEC-05**: No telemetry, no crash reporter that uploads — privacy-first; README states this explicitly

### Distribution & Release

- [ ] **REL-01**: App is signed with Developer ID Application certificate (Hardened Runtime ON, App Sandbox OFF)
- [ ] **REL-02**: Notarization via `xcrun notarytool submit --wait` using an App Store Connect API key (`.p8`) stored as GitHub secret
- [ ] **REL-03**: DMG is stapled with `xcrun stapler staple` and verified on a clean macOS account offline
- [ ] **REL-04**: DMG produced via `create-dmg/create-dmg` v1.2.3 (shell)
- [ ] **REL-05**: GitHub Actions release workflow builds, signs, notarizes, staples, attaches DMG to a GitHub Release on tag push
- [ ] **REL-06**: Sparkle integrated; EdDSA-signed `appcast.xml` hosted on GitHub Pages; public key pinned in Info.plist
- [ ] **REL-07**: Repo ships under MIT or Apache-2.0 (chosen in Phase 6) with README, screenshots, LICENSE, SECURITY.md, `docs/entitlements.md`
- [ ] **REL-08**: `Info.plist` declares `NSAppTransportSecurity → NSAllowsLocalNetworking = true` for localhost probes
- [ ] **REL-09**: Only required entitlement: `com.apple.security.network.client`; no `disable-library-validation`, no `allow-jit`

## v2 Requirements

### Activity & Trends

- **TRENDS-01**: In-row sparkline (last 24 polls in memory)
- **TRENDS-02**: Per-provider configurable thresholds in Settings UI
- **TRENDS-03**: Pace tracking ("X% deficit, runs out in 1h 12m")
- **TRENDS-04**: Activity feed of last N calls (model, time, tokens)
- **TRENDS-05**: Provider status / incident indicator via Statuspage.io

### Provider Expansion

- **EXP-01**: LM Studio + llama.cpp parity with Ollama (full multi-runtime in v1; this row is for richer details like live slot tokens)
- **EXP-02**: Per-model breakdown via row-expansion disclosure
- **EXP-03**: Bundled CLI (`agents-usage` or `aub`) for scripting
- **EXP-04**: Claude Code `Stop` hook integration for real-time updates (ClaudeBar pattern, replaces 5-min polling for Claude)

## Future (v3+)

- Multi-day persistence + historical charts
- Cost forecasting / budgeting tools
- WidgetKit widgets (4 widgets: Usage, History, Switcher, Compact)
- Custom theme imports (`.itermcolors`)
- Browser-cookie providers (Cursor, Manus, Copilot subscriptions)
- Vertex AI / Azure OpenAI / Bedrock for enterprise
- CCS-aware provider — track `~/.ccs/instances/{personal,work}` separately for per-instance accounting

## Out of Scope

| Feature | Reason |
|---------|--------|
| Windows / Linux builds | macOS menu bar IS the product |
| Electron / Tauri / web stack | Native feel matters; Swift+SwiftUI only |
| App Store distribution | Sandbox blocks dotfile reads; DMG-only in v1 |
| Keychain settings UI in v1 | Files + env are sufficient; adds ACL prompts / lock breakage |
| Multi-day historical charts in v1 | Schema migrations; in-memory sparkline ring buffer covers it |
| Per-model breakdown as default rows | Fragile to model-name churn; provider-level v1 |
| Cost forecasting / budgeting | Conflicts with today-only aggregation |
| Multi-user / team accounts | Different product |
| Browser cookie scraping | Requires Full Disk Access + Chrome Safe Storage prompts; looks like spyware |
| Real-time local-agent token interception (proxy `/api/generate`) | Port conflicts; LOCAL-06 covers this |
| Shell RC file parsing | `source` chains are arbitrary code execution |
| Auto-launch at login by default | Surprises users; opt-in toggle only |
| `rtk gain` as Claude data source | `rtk gain` reports RTK tool-call savings, NOT Anthropic tokens — Claude data is `~/.claude/projects/**/*.jsonl` |
| 30–60s polling cadence | Re-parses multi-MB JSONL, drains battery, trips App Nap; 5m default |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| SHELL-01 | Phase 1 | Complete |
| SHELL-02 | Phase 1 | Complete |
| SHELL-03 | Phase 1 | Complete |
| SHELL-04 | Phase 1 | Complete |
| SHELL-05 | Phase 5 | Complete |
| SHELL-06 | Phase 1 | Complete |
| CLAUDE-01 | Phase 2 | Complete |
| CLAUDE-02 | Phase 2 | Complete |
| CLAUDE-03 | Phase 2 | Complete |
| CLAUDE-04 | Phase 2 | Complete |
| CLAUDE-05 | Phase 2 | Complete |
| CODEX-01 | Phase 3 | Complete |
| CODEX-02 | Phase 3 | Complete |
| CODEX-03 | Phase 3 | Complete |
| CODEX-04 | Phase 3 | Complete |
| GEMINI-01 | Phase 3 | Pending |
| GEMINI-02 | Phase 3 | Pending |
| GEMINI-03 | Phase 3 | Pending |
| GEMINI-04 | Phase 3 | Pending |
| ROUTER-01 | Phase 1 | Complete |
| ROUTER-02 | Phase 1 | Complete |
| ROUTER-03 | Phase 1 | Complete |
| ROUTER-04 | Phase 1 | Complete |
| LOCAL-01 | Phase 4 | Pending |
| LOCAL-02 | Phase 4 | Pending |
| LOCAL-03 | Phase 4 | Pending |
| LOCAL-04 | Phase 4 | Pending |
| LOCAL-05 | Phase 4 | Pending |
| LOCAL-06 | Phase 4 | Pending |
| UI-01 | Phase 1 | Complete |
| UI-02 | Phase 1 | Complete |
| UI-03 | Phase 2 | Pending |
| UI-04 | Phase 1 | Pending |
| UI-05 | Phase 2 | Pending |
| UI-06 | Phase 1 | Complete |
| UI-07 | Phase 1 | Complete |
| UI-08 | Phase 2 | Pending |
| UI-09 | Phase 2 | Pending |
| UI-10 | Phase 1 | Complete |
| UI-11 | Phase 3 | Complete |
| POLL-01 | Phase 1 | Complete |
| POLL-02 | Phase 1 | Complete |
| POLL-03 | Phase 1 | Complete |
| POLL-04 | Phase 2 | Pending |
| POLL-05 | Phase 2 | Pending |
| POLL-06 | Phase 2 | Pending |
| POLL-07 | Phase 1 | Complete |
| POLL-08 | Phase 1 | Complete |
| POLL-09 | Phase 2 | Pending |
| NOTIF-01 | Phase 2 | Pending |
| NOTIF-02 | Phase 2 | Pending |
| NOTIF-03 | Phase 2 | Pending |
| NOTIF-04 | Phase 2 | Pending |
| NOTIF-05 | Phase 2 | Pending |
| NOTIF-06 | Phase 1 | Complete |
| NOTIF-07 | Phase 1 | Complete |
| CFG-01 | Phase 1 | Complete |
| CFG-02 | Phase 1 | Complete |
| CFG-03 | Phase 5 | Pending |
| CFG-04 | Phase 5 | Pending |
| CFG-05 | Phase 5 | Complete |
| CFG-06 | Phase 5 | Pending |
| SEC-01 | Phase 1 | Pending |
| SEC-02 | Phase 1 | Pending |
| SEC-03 | Phase 6 | Pending |
| SEC-04 | Phase 1 | Complete |
| SEC-05 | Phase 1 | Complete |
| REL-01 | Phase 6 | Pending |
| REL-02 | Phase 6 | Pending |
| REL-03 | Phase 6 | Pending |
| REL-04 | Phase 6 | Pending |
| REL-05 | Phase 6 | Pending |
| REL-06 | Phase 6 | Pending |
| REL-07 | Phase 6 | Pending |
| REL-08 | Phase 6 | Pending |
| REL-09 | Phase 6 | Pending |

**Coverage:**
- v1 requirements: 76 total (canonical count from master list above: SHELL 6 + CLAUDE 5 + CODEX 4 + GEMINI 4 + ROUTER 4 + LOCAL 6 + UI 11 + POLL 9 + NOTIF 7 + CFG 6 + SEC 5 + REL 9 = 76)
- Mapped to phases: 76
- Unmapped: 0
- Status: 100% coverage ✓

> Note on initial count: the original requirements footer stated "70 total" — re-counting against the canonical line items yields 76. The roadmap planning brief inherited the "70" figure; the authoritative number is **76** and every line item in the master list is mapped exactly once below.

### Phase Distribution

| Phase | Count | Categories |
|-------|-------|------------|
| Phase 1 | 28 | SHELL ×5, ROUTER ×4, UI ×5, POLL ×5, NOTIF ×2, CFG ×2, SEC ×4, plus SHELL-06 |
| Phase 2 | 18 | CLAUDE ×5, UI ×4 (UI-03, UI-05, UI-08, UI-09), POLL ×4 (POLL-04, POLL-05, POLL-06, POLL-09), NOTIF ×5 (NOTIF-01..05) |
| Phase 3 | 9 | CODEX ×4, GEMINI ×4, UI ×1 (UI-11) |
| Phase 4 | 6 | LOCAL ×6 |
| Phase 5 | 5 | SHELL ×1 (SHELL-05), CFG ×4 (CFG-03..06) |
| Phase 6 | 10 | SEC ×1 (SEC-03), REL ×9 |
| **Total** | **76** | All 76 v1 requirements mapped — no orphans, no duplicates |

---
*Requirements defined: 2026-05-11*
*Last updated: 2026-05-11 after roadmap creation — traceability populated (100% coverage of 76 v1 requirements).*
