# Roadmap: Agents Usage Bar

**Created:** 2026-05-11
**Project Mode:** mvp (vertical slices, ship to validate)
**Granularity:** coarse
**Total Phases:** 6
**Total v1 Requirements:** 76 (canonical count from REQUIREMENTS.md master list)

> Note: the planning brief inherited a "70 total" figure; re-counting against the master list in REQUIREMENTS.md yields 76. The roadmap maps all 76.

## Phases

- [x] **Phase 1: Skeleton + OpenRouter Vertical Slice** — Prove every architectural seam against the lowest-friction provider; menu bar app polls OpenRouter every 5m, shows tokens/USD/quota bar, fires a stub notification at 80%.
- [x] **Phase 2: Claude Provider + Threshold/Rollover + JSONL Streaming** — De-risk the headline provider; ship the streaming JSONL primitive Codex will reuse, local-midnight rollover, and the full notification FSM with snooze. ✅ UAT approved 2026-05-15 (Tests 1-2 manual PASS; 3-10 unit-test attestation; Test 7 battery soak deferred to pre-distribution).
- [x] **Phase 3: Remote API Providers (Codex + Gemini)** — Drop in remaining hosted-AI providers using primitives from phases 1–2; cross-provider "today total" becomes meaningful. (completed 2026-05-18)
- [ ] **Phase 4: Local LLM Presence (Ollama + LM Studio + llama.cpp)** — Differentiator: tri-state running/idle rows for localhost services; "Not running" is muted, never red.
- [x] **Phase 5: First-Run UX + Settings Polish** — First-run provider detection screen, full Settings scene, refined stale indicator, theme handling, open-dashboard affordance. (completed 2026-05-21)
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

**Plans:** 7/7 plans executed — ✅ COMPLETE (UAT approved 2026-05-15)
Plans:

- [x] 02-01-PLAN.md — TranscriptReader + offset cache schema v1→v2 + directory scanner (CLAUDE-01..03) — see `02.01-SUMMARY.md`, commit `2bf5bf6`
- [x] 02-02-PLAN.md — Bundled `claude-models.json` + ClaudeModelPricing cascade-lookup cost calculator (CLAUDE-05) — see `02.02-SUMMARY.md`, commit `2bf5bf6`
- [x] 02-03-PLAN.md — Anthropic OAuth client + ClaudeCredentialLoader + KeychainReader + QuotaWindow (CLAUDE-04) — see `02.03-SUMMARY.md`, commit `2bf5bf6`
- [x] 02-04-PLAN.md — ClaudeJSONLProvider composing 02.01+02+03 + AppDependencies wiring (CLAUDE-01..05 composition) — see `02-04-SUMMARY.md`, commits e703320 + 3e3f9cf
- [x] 02-05-PLAN.md — ThresholdEngine FSM v2 (Comparable bands) + UNNotificationCategory + snooze + AggregateStore wiring (NOTIF-01..05) — see `02-05-SUMMARY.md`, commit ea07831
- [x] 02-06-PLAN.md — PowerObserver (sleep/wake) + RetryPolicy + CircuitBreaker (per-provider 5-strike + OAuth-usage 3-strike) (POLL-04..06, POLL-09) — see `02-06-SUMMARY.md`, commits 4121cfe + afc7825 + 0eed73a
- [x] 02-07-PLAN.md — UI extensions (UI-03/05/08/09) + 02-UAT.md checkpoint — ✅ UAT approved 2026-05-15 (Tests 1-2 manual PASS; 3-10 unit-test attestation; Test 7 battery soak deferred to pre-distribution) — see `02-07-SUMMARY.md`, commits 5f042c8 + 6be6396 + 4895ae8 + UAT-session hotfixes 378c531 + c84c452 + 4a5ebee

**UI hint:** yes
**Phase exit:** BLOCKED on UAT — reviewer to run `.planning/phases/02-claude-provider-threshold-rollover-jsonl-streaming/02-UAT.md` then respond `approved` (Phase 2 complete) or file failed steps for `/gsd-plan-phase 02 --gaps`.

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

**Plans:** 9/9 plans complete
Plans:

- [x] 03-01-PLAN.md — CodexRolloutScanner (today+yesterday YYYY/MM/DD walk + symlink canonicalisation) + CodexRolloutEvent lenient Codable + CodexRolloutParser fold-to-last-token-count (CODEX-01 partial, CODEX-03 partial) — see `03-01-SUMMARY.md`, commits e2bcd5e + 6a18026 + a31b99a ✓ 2026-05-15
- [x] 03-02-PLAN.md — `Resources/Pricing/codex-models.json` bundle (7 models + default) + CodexModelPricing cascade-lookup (Codex-specialised Rate shape + reasoningOutputTokens-not-double-counted invariant) + BLOCKING checkpoint:human-verify resolved as "pricing page inaccessible — use draft as best-effort" per T-03.02-03 (CODEX-04 partial — primitive complete; full satisfaction requires Plan 03-04 composition) — see `03-02-SUMMARY.md`, commits dd160a0 + 43f97ae ✓ 2026-05-15
- [x] 03-03-PLAN.md — CodexCredentialLoader (~/.codex/auth.json: tokens.access_token + optional ChatGPT-Account-Id) + CodexOAuthClient (GET /backend-api/wham/usage) + CodexUsageResponse Codable (CODEX-02) — see `03-03-SUMMARY.md`, commits d16b180 + a5f62df ✓ 2026-05-15
- [x] 03-04-PLAN.md — CodexJSONLProvider actor composing 03-01/02/03 + UsageSnapshot.tooltipLabel extension (CODEX-01..04 composition + D-05 max(primary, secondary) + D-15 plan_type tooltip)
- [x] 03-05-PLAN.md — GeminiSettingsGate (nested security.auth.selectedType — RESEARCH correction #2) + GeminiCredentialLoader (oauth_creds.json with expiry_date epoch-ms — correction #3) + GeminiOAuthClient (eager-pre-check + lazy-401, in-memory token D-10, refresh_token never rotated Pitfall 10) (GEMINI-01) — see `03-05-SUMMARY.md`, commits df3ec24 + eb32dc4 + eaee6c6 ✓ 2026-05-15
- [x] 03-06-PLAN.md — GeminiOAuthProvider actor — concurrent quota+tier async let (STATE #25) + per-model lowest-remainingFraction fold (D-06) + tier display map (free→Free / legacy→Legacy / standard→Paid; verbatim future tiers; nil silent for Pitfall 8 cold-start) + lazy-401 single-shot retry + D-11 cached-dim degraded UX with "usage-temporarily-unavailable" marker + D-07 today-total exclusion + GEMINI-04 cross-provider isolation (only .refreshFailed propagates) + HTTPClient.postJSON bearer overload via useSnakeCaseConversion flag (camelCase preservation for v1internal:loadCodeAssist body) (GEMINI-02, GEMINI-03, GEMINI-04) — see `03-06-SUMMARY.md`, commits 8187562 + 2e76a5e + 43f6e81 ✓ 2026-05-18
- [x] 03-07-PLAN.md — ProviderDashboardURL lookup (4 hard-coded URLs per D-14) + ProviderRowView trailing arrow.up.right.square button + .help() tooltip wiring + TotalsHeaderView "excludes quota-only providers" footnote (UI-11)
- [x] 03-08-PLAN.md — AppConfig + ConfigStore [codex] / [gemini] TOML sections + AppDependencies.makeProduction() Codex/Gemini registration + AggregateStore D-07 rollupTotals exclusion + ThresholdEngine D-11 suppression (CodexConfig + GeminiConfig structs with env > toml > defaults precedence per D-17; CODEX_BEARER_TOKEN + GEMINI_PROJECT_ID env-only Secret/String? handling per STATE #22; ThresholdEngine.degradedTag public constant single-sourced + GeminiOAuthProvider.degradedNote alias; AggregateStore.hasTokensByID + hasAnyQuotaOnlyProvider + rollupTotals D-07 exclusion; Codex+Gemini registration gated on config.enabled AND (creds OR rollouts/settings-gate); seedPlaceholder fall-through ensures four-provider rows always present) (GEMINI-04) — see `03-08-SUMMARY.md`, commits 1899ccf + ade63ce + 78b7ad8 ✓ 2026-05-18
- [x] 03-09-PLAN.md — 03-UAT.md walkthrough (5 manual + 5 attestation tests mirroring Phase 2 02-UAT format) + BLOCKING reviewer checkpoint

**UI hint:** yes
**Phase exit:** BLOCKED on UAT — reviewer runs `.planning/phases/03-remote-api-providers-codex-gemini/03-UAT.md` then replies `approved` / `failed: <test>` / `deferred: <test>`.

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

**Plans:** 9/9 plans drafted 2026-05-18 — ready for `/gsd-execute-phase 04`
Plans:

- [x] 04-01-PLAN.md — Foundation: `ProviderStatus.notRunning` (non-terminal) + `UsageSnapshot.raw` key conventions + `ProviderID` constants + `ProviderError.classifyLocalhost(error:lastSuccess:)` (LOCAL-04, LOCAL-05) — Wave 1
- [x] 04-02-PLAN.md — Config: `OllamaConfig` + `LMStudioConfig` + `LlamaCppConfig` value types + `[ollama]`/`[lmstudio]`/`[llamacpp]` TOML parse + `AppConfig` extension (LOCAL-01, LOCAL-02, LOCAL-03) — Wave 1
- [x] 04-03-PLAN.md — Infrastructure: `URLSessionHTTPClient(timeoutSeconds:)` parameterization + localhost-tier 2s instance (LOCAL-01, LOCAL-02, LOCAL-03, LOCAL-05, POLL-08) — Wave 1
- [x] 04-04-PLAN.md — OllamaProvider actor (`/api/ps` + `/api/tags`) + lenient Codable + D-03 multi-model `+N more` row state (LOCAL-01) — Wave 2 (depends 04-01, 04-02, 04-03)
- [x] 04-05-PLAN.md — LMStudioProvider actor (`/api/v0/models` with `/v1/models` fallback) + lenient Codable (LOCAL-02) — Wave 2 (depends 04-01, 04-02, 04-03)
- [x] 04-06-PLAN.md — LlamaCppProvider actor (`/health` + `/slots` + `/v1/models`) + `"loading model"` row state + D-04 unconfigured placeholder seed + `seedPlaceholder(placeholderMessage:)` extension (LOCAL-03, LOCAL-04, LOCAL-05) — Wave 2 (depends 04-01, 04-02, 04-03)
- [x] 04-07-PLAN.md — UI: `ProviderRowView` secondary-line branching (D-02/D-03 five states) + `LocalRowSecondaryView` helper + `StatusDot.notRunning → .gray` + tooltip wiring + LOCAL-06 UI enforcement (LOCAL-04, LOCAL-06) — Wave 3 (depends 04-04, 04-05, 04-06)
- [x] 04-08-PLAN.md — Composition: `AppDependencies.makeProduction()` three new registration blocks + `ThresholdEngine` nil-quota skip regression + `AggregateStore.rollupTotals` D-07 regression for locals (LOCAL-01..06 composition) — Wave 3 (depends 04-02, 04-04, 04-05, 04-06)
- [x] 04-09-PLAN.md — 04-UAT.md walkthrough (5 manual + 5 unit-test attestation tests) + BLOCKING reviewer checkpoint mirroring Phase 2/3 UAT shape (LOCAL-01..06 verification) — Wave 4 (depends 04-07, 04-08)

**UI hint:** yes
**Phase exit:** BLOCKED on UAT — reviewer runs `.planning/phases/04-local-llm-presence-ollama-lm-studio-llama-cpp/04-UAT.md` then replies `approved` / `failed: <test>` / `deferred: <test>`.

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

**Plans:** 6/6 plans complete
Plans:
**Wave 1**

- [x] 05-01-PLAN.md — Settings scaffold (SettingsScene + stub tabs) + WindowActivationObserver (.accessory↔.regular flip) (SHELL-05) — Wave 1

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 05-02-PLAN.md — UserPreferencesStore (@Observable UserDefaults wrapper) + ConfigStore.load(preferences:) precedence overlay (CFG-05, CFG-06) — Wave 2 (depends 05-01)

**Wave 3** *(blocked on Wave 2 completion)*

- [x] 05-03-PLAN.md — SettingsGeneralTab (4 controls) + AggregateStore.updateWarningFraction + observePreferences hot-reload loop (SHELL-05, CFG-05) — Wave 3 (depends 05-02)
- [x] 05-04-PLAN.md — DetectionProbe (7-provider parallel) + OnboardingCopy (providers.json) + SettingsProvidersTab (CFG-03, CFG-04, CFG-06) — Wave 3 (depends 05-02, parallel with 05-03)

**Wave 4** *(blocked on Wave 3 completion)*

- [x] 05-05-PLAN.md — WelcomeWindowController + WelcomeRootView + WelcomeProviderRow + AppDependencies wiring (CFG-03, CFG-04, CFG-05) — Wave 4 (depends 05-02, 05-04)

**Wave 5** *(blocked on Wave 4 completion)*

- [x] 05-06-PLAN.md — SettingsAboutTab + CFG-06 CI grep step + 05-UAT.md walkthrough (5 manual + 5 attestation) + BLOCKING reviewer checkpoint — Wave 5 (depends 05-03, 05-04, 05-05)

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
| 1. Skeleton + OpenRouter Vertical Slice | 9/9 | ✅ Complete | 2026-05-13 |
| 2. Claude Provider + Threshold/Rollover + JSONL Streaming | 7/7 | ✅ Complete | 2026-05-15 |
| 3. Remote API Providers (Codex + Gemini) | 9/9 | Awaiting UAT | - |
| 4. Local LLM Presence (Ollama + LM Studio + llama.cpp) | 0/9 | Planned 2026-05-18 | - |
| 5. First-Run UX + Settings Polish | 6/6 | Complete   | 2026-05-21 |
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
*Roadmap created: 2026-05-11. Phase 3 planned: 2026-05-15. Phase 4 planned: 2026-05-18. Phase 5 planned: 2026-05-21. Ready for `/gsd-execute-phase 05`.*
