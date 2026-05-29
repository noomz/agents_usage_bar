# Roadmap: Agents Usage Bar

**Created:** 2026-05-11
**Project Mode:** mvp (vertical slices, ship to validate)
**Granularity:** coarse
**Total Phases:** 6
**Total v1 Requirements:** 76 (canonical count from REQUIREMENTS.md master list)

> Note: the planning brief inherited a "70 total" figure; re-counting against the master list in REQUIREMENTS.md yields 76. The roadmap maps all 76.

## Phases

- [x] **Phase 1: Skeleton + OpenRouter Vertical Slice** — Prove every architectural seam against the lowest-friction provider; menu bar app polls OpenRouter every 5m, shows tokens/USD/quota bar, fires a stub notification at 80%.
- [ ] **Phase 2: Claude Provider + Threshold/Rollover + JSONL Streaming** — De-risk the headline provider; ship the streaming JSONL primitive Codex will reuse, local-midnight rollover, and the full notification FSM with snooze.
- [ ] **Phase 3: Remote API Providers (Codex + Gemini)** — Drop in remaining hosted-AI providers using primitives from phases 1–2; cross-provider "today total" becomes meaningful.
- [ ] **Phase 4: Local LLM Presence (Ollama + LM Studio + llama.cpp)** — Differentiator: tri-state running/idle rows for localhost services; "Not running" is muted, never red.
- [ ] **Phase 5: First-Run UX + Settings Polish** — First-run provider detection screen, full Settings scene, refined stale indicator, theme handling, open-dashboard affordance.
- [ ] **Phase 6: Distribution (Sign + Notarize + DMG + Sparkle + OSS hygiene)** — GitHub Actions release pipeline, notarized stapled DMG, Sparkle EdDSA appcast, README/LICENSE/SECURITY/entitlements docs.

## Phase Details

### Phase 1: Skeleton + OpenRouter Vertical Slice
**Goal:** A menu bar app polling OpenRouter every 5 minutes shows live tokens, USD, and a quota bar, with the full poll→actor→store→SwiftUI→notification skeleton exercised end-to-end.
**Mode:** mvp
**Depends on:** Nothing (first phase)
**Requirements:** SHELL-01, SHELL-02, SHELL-03, SHELL-04, SHELL-06, ROUTER-01, ROUTER-02, ROUTER-03, ROUTER-04, UI-01, UI-02, UI-04, UI-06, UI-07, UI-10, POLL-01, POLL-02, POLL-03, POLL-07, POLL-08, NOTIF-06, NOTIF-07, CFG-01, CFG-02, SEC-01, SEC-02, SEC-04, SEC-05
**Success Criteria** (what must be TRUE):
  1. User launches the app and sees a menu bar icon only — no Dock icon, no Cmd-Tab entry — that opens a ~360pt SwiftUI popover dismissible by click-outside.
  2. With `OPENROUTER_API_KEY` set in the environment or `~/.config/agents-usage-bar/config.toml`, the OpenRouter row displays today's tokens, USD spend, balance, and a colored quota bar (green/yellow/red) within seconds of popover open.
  3. The popover stays in sync because a single `PollScheduler` actor refreshes every 5 minutes (and on popover open, coalesced within 5s) — confirmable by watching the "Updated Xs ago" label tick.
  4. Quitting via the popover footer or Cmd-click context menu fully terminates the app; relaunch restores cached values immediately (no "Loading…" flash).
  5. No secret strings ever appear in `os.Logger` output or stderr; `Secret`-wrapped credentials render as `"<redacted>"` and the CI grep step rejects any source file containing literal `sk-`, `sk-or-`, or `AIza`.
**Plans:** 9/9 plans executed — Phase 1 COMPLETE (incl. UAT gap closure) ✓ 2026-05-13
Plans:
- [x] 01.01-walking-skeleton-PLAN.md — Xcode project scaffold, Info.plist (LSUIElement=YES), Entitlements (network.client only), MenuBarExtra(.window) skeleton, SKELETON.md (SHELL-01..04, SHELL-06) ✓ 2026-05-12
- [x] 01.02-domain-infrastructure-PLAN.md — Domain value types (Secret, UsageSnapshot, Quota, ProviderID, etc.) + Infrastructure protocols (HTTPClient, Clock, CacheStore, AppLogger) + Swift Testing scaffold (SEC-01, SEC-02, UI-04, POLL-08) ✓ 2026-05-12
- [x] 01.03-config-toml-PLAN.md — Hand-rolled TOML reader + ConfigStore (env > toml > defaults precedence) (CFG-01, CFG-02, ROUTER-04, SEC-05) ✓ 2026-05-12
- [x] 01.04-openrouter-provider-PLAN.md — OpenRouterProvider actor + Codable responses + baseline-delta + cache codec (ROUTER-01..04) ✓ 2026-05-12
- [x] 01.05-aggregation-store-PLAN.md — AggregateStore @Observable @MainActor + PollScheduler actor (POLL-01, POLL-02, POLL-03, POLL-07) ✓ 2026-05-12
- [x] 01.06-popover-ui-PLAN.md — PopoverRootView + ProviderRowView + FooterView + QuotaBar/StatusDot/RelativeTimestampLabel (UI-01, UI-02, UI-06, UI-07, UI-10) ✓ 2026-05-12
- [x] 01.07-notifications-PLAN.md — ThresholdEngine value type + UNNotificationManager (lazy auth) (NOTIF-06, NOTIF-07) ✓ 2026-05-12
- [x] 01.08-composition-ci-PLAN.md — AppDependencies composition root + MenuBarExtra scene + CI workflow + README + SEC-04 grep (SEC-04) ✓ 2026-05-12
- [x] 01.09-hover-style-gap-PLAN.md — HoverableBorderedButtonStyle + FooterView modifier swap (UAT Test 2 cosmetic hover-state gap closure; B5/W7 preserved) ✓ 2026-05-13
**UI hint:** yes

### Phase 2: Claude Provider + Threshold/Rollover + JSONL Streaming
**Goal:** Claude usage from local transcripts and OAuth windows lands in the popover, "today" rolls at local midnight, and the per-provider notification FSM fires exactly once per threshold transition per day.
**Mode:** mvp
**Depends on:** Phase 1
**Requirements:** CLAUDE-01, CLAUDE-02, CLAUDE-03, CLAUDE-04, CLAUDE-05, UI-03, UI-05, UI-08, UI-09, POLL-04, POLL-05, POLL-06, POLL-09, NOTIF-01, NOTIF-02, NOTIF-03, NOTIF-04, NOTIF-05
**Success Criteria** (what must be TRUE):
  1. The Claude row shows today's per-model input/output/cache-read/cache-create tokens streamed line-by-line from `~/.claude/projects/**/*.jsonl` with cached `lastReadOffset` (no whole-file re-read, no memory spike on multi-MB sessions).
  2. When OAuth credentials are present, the Claude row additionally surfaces `five_hour` and `seven_day` quota windows with live reset countdowns; missing OAuth degrades gracefully to local-only data without an error state.
  3. At local midnight (tester verifies in `America/Los_Angeles` at 11:59pm), all "today" totals reset to zero — never UTC-bucketed and never an off-by-one across DST.
  4. Crossing 80% on any provider fires exactly one macOS notification (stable id `"<providerID>:<yyyy-MM-dd>:warn80"`); "Snooze for today" action suppresses further fires until midnight; multiple providers crossing within one poll coalesce into a single "N providers crossed 80%" notification.
  5. After 1 hour idle on battery, macOS Energy Impact reports the app as "Low"; sleep pauses polling and wake triggers a single immediate refresh with exponential backoff + jitter on 429/5xx and circuit-breaker after 5 consecutive failures.
**Plans:** TBD
**UI hint:** yes

### Phase 3: Remote API Providers (Codex + Gemini)
**Goal:** Codex (rollout-first, OAuth fallback) and Gemini (OAuth-personal quota) join the popover so the cross-provider "today total" row reflects real multi-provider state.
**Mode:** mvp
**Depends on:** Phase 2
**Requirements:** CODEX-01, CODEX-02, CODEX-03, CODEX-04, GEMINI-01, GEMINI-02, GEMINI-03, GEMINI-04, UI-11
**Success Criteria** (what must be TRUE):
  1. The Codex row populates with no Codex auth required by reading the latest `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` last `event_msg.token_count`, displaying primary + secondary windows with reset countdowns and an embedded-pricing USD figure.
  2. If no recent rollout exists, the Codex row transparently falls back to `GET https://chatgpt.com/backend-api/wham/usage` using the bearer in `~/.codex/auth.json` — the UI shows the same data shape either way.
  3. When `~/.gemini/oauth_creds.json` is present with `selectedAuthType:"oauth-personal"`, the Gemini row shows per-model `remainingFraction` + ISO `resetTime`, refreshes the bearer automatically when expired, and surfaces tier label in row tooltip.
  4. If Gemini's `v1internal:retrieveUserQuota` endpoint returns 4xx/5xx, the Gemini row reads "Gemini usage temporarily unavailable" — other provider rows continue refreshing unaffected.
  5. Every provider row has a one-click "Open dashboard" button that launches the provider's web console in the default browser.
**Plans:** TBD
**UI hint:** yes

### Phase 4: Local LLM Presence (Ollama + LM Studio + llama.cpp)
**Goal:** Localhost AI runtimes appear as tri-state presence rows (`notRunning | running | error`) showing model name only — no token tracking, no port scanning, no red error for "not installed".
**Mode:** mvp
**Depends on:** Phase 3
**Requirements:** LOCAL-01, LOCAL-02, LOCAL-03, LOCAL-04, LOCAL-05, LOCAL-06
**Success Criteria** (what must be TRUE):
  1. With Ollama running (`ollama serve`), the Ollama row shows running models from `/api/ps` plus installed-model count from `/api/tags`, refreshed on the standard 5-min cadence with a 1–2s connect timeout.
  2. With LM Studio running on its default or user-configured port, the LM Studio row shows loaded model name from `/v1/models` and `/api/v0/models`; port is overridable in `~/.config/agents-usage-bar/config.toml`.
  3. The llama.cpp row only activates when the user explicitly configures a port in `config.toml` (no scanning); when configured, it probes `/health`, `/slots`, `/v1/models`.
  4. When any localhost runtime is not running (connection refused), the row renders as muted "Not running" with model name absent — never red, never as an error message, never blocking other providers.
  5. None of the local rows ever display a cumulative-token count (LOCAL-06 anti-feature is honored); only presence + model name surfaces in the UI.
**Plans:** TBD
**UI hint:** yes

### Phase 5: First-Run UX + Settings Polish
**Goal:** A first-time user sees a "what's detected, what's missing" welcome screen and can adjust refresh interval, threshold, per-provider toggles, theme, and login behavior from a native Settings window.
**Mode:** mvp
**Depends on:** Phase 4
**Requirements:** SHELL-05, CFG-03, CFG-04, CFG-05, CFG-06
**Success Criteria** (what must be TRUE):
  1. On first launch, the app auto-detects which providers have usable credentials/configs and enables those by default; the welcome screen lists every provider with its detected state (no error styling for absent ones) and a "How to enable" CTA per missing provider.
  2. Pressing Cmd-comma from the popover opens a Settings window; activation policy flips to `.regular` while open and back to `.accessory` on close (no Dock icon flash on close).
  3. Settings exposes refresh interval picker (Manual/1m/2m/5m/15m/30m), default threshold slider, per-provider enable/disable toggles, theme (light/dark/auto), and "Open at login" toggle defaulted OFF.
  4. Theme changes apply live via `@Environment(\.colorScheme)`; light/dark/auto each render correctly on a fresh popover open.
  5. Shell RC files (`~/.zshrc`, `~/.bashrc`, fish config) are never read at any point in the first-run flow or Settings — env vars come from `ProcessInfo.environment` only (CFG-06 anti-feature is honored).
**Plans:** TBD
**UI hint:** yes

### Phase 6: Distribution (Sign + Notarize + DMG + Sparkle + OSS hygiene)
**Goal:** A tagged GitHub release builds, signs, notarizes, staples, and publishes a DMG; Sparkle auto-update works against a public appcast; the repo is OSS-ready under MIT/Apache-2.0.
**Mode:** mvp
**Depends on:** Phase 5
**Requirements:** SEC-03, REL-01, REL-02, REL-03, REL-04, REL-05, REL-06, REL-07, REL-08, REL-09
**Success Criteria** (what must be TRUE):
  1. Pushing a `v*` tag triggers a GitHub Actions release workflow that builds the app, signs with the Developer ID Application certificate (Hardened Runtime ON, App Sandbox OFF), submits to `xcrun notarytool --wait` via App Store Connect API key, staples with `xcrun stapler`, and attaches the DMG to a GitHub Release — fully unattended.
  2. The stapled DMG opens on a clean macOS account offline with no Gatekeeper warning; the only declared entitlement is `com.apple.security.network.client` and `NSAppTransportSecurity → NSAllowsLocalNetworking = true` is set for localhost probes.
  3. Sparkle is wired with an EdDSA-signed `appcast.xml` hosted on GitHub Pages; the public key is pinned in `Info.plist`; an installed app from version N silently sees version N+1 and offers to update.
  4. The public repo ships under the chosen MIT or Apache-2.0 license with README (screenshots + privacy promise), LICENSE, SECURITY.md, and `docs/entitlements.md` explaining each entitlement; no telemetry or crash reporter uploads anywhere.
  5. When `~/.config/agents-usage-bar/config.toml` is created by the app, it is `chmod 0600` and the app emits a startup warning if it finds the file world-readable.
**Plans:** TBD

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Skeleton + OpenRouter Vertical Slice | 5/8 | In Progress|  |
| 2. Claude Provider + Threshold/Rollover + JSONL Streaming | 0/0 | Not started | - |
| 3. Remote API Providers (Codex + Gemini) | 0/0 | Not started | - |
| 4. Local LLM Presence (Ollama + LM Studio + llama.cpp) | 0/0 | Not started | - |
| 5. First-Run UX + Settings Polish | 0/0 | Not started | - |
| 6. Distribution (Sign + Notarize + DMG + Sparkle + OSS hygiene) | 0/0 | Not started | - |

## Coverage

- **v1 requirements:** 76 total
- **Mapped to phases:** 76
- **Unmapped:** 0
- **Status:** 100% coverage ✓

### Phase Distribution

| Phase | Requirement Count | Categories |
|-------|-------------------|------------|
| Phase 1 | 28 | SHELL ×5 (01,02,03,04,06), ROUTER ×4, UI ×5 (01,02,04,06,07,10 → 6 actually; see traceability), POLL ×5 (01,02,03,07,08), NOTIF ×2 (06,07), CFG ×2 (01,02), SEC ×4 (01,02,04,05) |
| Phase 2 | 18 | CLAUDE ×5, UI ×4 (03,05,08,09), POLL ×4 (04,05,06,09), NOTIF ×5 (01..05) |
| Phase 3 | 9 | CODEX ×4, GEMINI ×4, UI ×1 (11) |
| Phase 4 | 6 | LOCAL ×6 |
| Phase 5 | 5 | SHELL ×1 (05), CFG ×4 (03,04,05,06) |
| Phase 6 | 10 | SEC ×1 (03), REL ×9 |
| **Total** | **76** | All 76 v1 requirements covered exactly once — see REQUIREMENTS.md Traceability table for the authoritative per-requirement mapping. |

---
*Roadmap created: 2026-05-11. Ready for `/gsd-plan-phase 1`.*
