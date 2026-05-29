# Phase 3 — User Acceptance Test

**Reviewer:** Siriwat Uamngamsup
**Date:** <fill-in at run time>
**Build:** d8a6a3b (Phase 3 code-complete — Wave 5 / Plan 03-09 authored on this SHA)

## Test outcomes table

| #  | Test                                                                                         | Result   | Notes |
|----|----------------------------------------------------------------------------------------------|----------|-------|
| 1  | Codex JSONL row populates from real rollout (SC #1 — CODEX-01 + CODEX-03 + CODEX-04 + D-05)   | \<pending> |       |
| 2  | Codex OAuth fallback fires when no rollout (SC #2 — CODEX-02 + D-02 + D-03 both-fail muted)   | \<pending> |       |
| 3  | Gemini row populates with per-model quotas + tier tooltip (SC #3 — GEMINI-01..03 + D-15)      | \<pending> |       |
| 4  | Gemini degraded UX on 5xx (SC #4 — GEMINI-04 + D-11 cached-dim + amber + cross-isolation)     | \<pending> |       |
| 5  | UI-11 dashboard buttons open correct URL per provider (SC #5 — UI-11 + D-13 + D-14 + D-07)    | \<pending> |       |
| 6  | Codex rollout schema correction #1 — `event_msg.payload.type == "token_count"`                | \<pending> |       |
| 7  | Codex pricing cascade — default fallback consistent + reviewer-verified at Plan 03-02         | \<pending> |       |
| 8  | Gemini settings gate keypath correction #2 — nested `security.auth.selectedType`              | \<pending> |       |
| 9  | Gemini OAuth refresh — eager 60s skew + lazy 401 retry + in-memory only + no refresh_token   | \<pending> |       |
| 10 | Today Total D-07 exclusion + ThresholdEngine D-11 suppression                                  | \<pending> |       |

**Overall outcome:** \<APPROVED / FAILED / DEFERRED — fill in after Tests 1-5>.

## Hotfixes landed during the UAT session (commits since d8a6a3b)

| Commit | Subject |
|--------|---------|
| —      | —       |

(If reviewer hits a regression during manual walkthrough, hotfix commits land here. Mirrors Phase 2's `378c531` / `c84c452` / `4a5ebee` table.)

## Phase 3 UAT — Reviewer Steps

**Pre-conditions for the test session:**

- Build the app: `xcodebuild build -project AgentsUsageBar.xcodeproj -scheme AgentsUsageBar -configuration Debug` exits 0.
- Launch the app from `~/Library/Developer/Xcode/DerivedData/AgentsUsageBar-*/Build/Products/Debug/AgentsUsageBar.app`.
- Have at least one Codex session today OR yesterday (run `codex` interactively for ~30 seconds; verify with `ls ~/.codex/sessions/$(date +%Y/%m/%d)/rollout-*.jsonl` lists at least one file, OR the equivalent path for yesterday `$(date -v-1d +%Y/%m/%d)`).
- Have `~/.codex/auth.json` populated (run `codex login` if not — required only for Test 2 OAuth-fallback step).
- Have `~/.gemini/settings.json` with `security.auth.selectedType == "oauth-personal"` AND `~/.gemini/oauth_creds.json` populated (run `gemini` interactively and complete the OAuth flow).
- Set `OPENROUTER_API_KEY` env var so the OpenRouter row also populates for cross-provider total verification.
- Have Claude Code installed locally (Phase 2 row should still populate for full popover regression).
- Recommended: open a second Terminal window with `log stream --predicate 'subsystem == "app.agents-usage-bar"' --info` running, so per-provider log lines (`codex`, `gemini-oauth`, etc.) are visible while you click.

---

### Test 1 — Codex JSONL row populates from real rollout (Phase 3 SC #1 / CODEX-01 + CODEX-03 + CODEX-04 + D-05)

1. Open the popover by clicking the menu bar icon.
2. Verify a "Codex" row exists.
3. **PASS** if the Codex row shows non-zero tokens and a non-zero "$Y.YY" USD cost within 5s of opening the popover (rollout already exists per pre-conditions).
4. **PASS** if the quota bar reflects `max(primary.used_percent, secondary.used_percent) / 100` (D-05) — open the latest rollout file (`tail -1 ~/.codex/sessions/$(date +%Y/%m/%d)/rollout-*.jsonl | jq '.event_msg.payload.rate_limits'` to read `primary.used_percent` and `secondary.used_percent`); the higher of the two should match the bar's fill / color band (green <50%, yellow 50–80%, red ≥80% per UI-03 thresholds).
5. **PASS** if hovering the "Codex" displayName shows a SwiftUI tooltip with the `plan_type` string from the rollout (e.g. "plus", "pro", "team", "enterprise"). Tooltip is silent if rollout lacks `plan_type` (D-15 silent-when-absent).
6. **PASS** if the row's "Resets — Xh Ym" countdown matches `event_msg.payload.rate_limits.primary.resets_at` (epoch seconds) — convert with `date -r <epoch>` and confirm within 1 minute drift (UI re-renders every second).

### Test 2 — Codex OAuth fallback fires when no rollout (Phase 3 SC #2 / CODEX-02 + D-02 + D-03)

1. Quit the app (popover footer "Quit" button or Cmd-click context menu).
2. `mv ~/.codex/sessions ~/.codex/sessions-backup` to remove rollouts from the scan window.
3. Relaunch the app. Open the popover.
4. **PASS** if the Codex row STILL populates with quota data sourced from `/backend-api/wham/usage` (the OAuth fallback per D-02). Tokens may show as "—" since `wham/usage` carries no token count — that is **correct** (the wham/usage shape exposes `rate_limit.primary_window` / `rate_limit.secondary_window` but no `total_token_usage`).
5. **PASS** if the row UI stays consistent (primary + secondary windows render the same way as the rollout path).
6. **PASS** if `log stream --predicate 'subsystem == "app.agents-usage-bar" AND category == "codex"'` in a side terminal shows a request to `chatgpt.com/backend-api/wham/usage` (only the path is logged per SEC-02; the bearer is `<redacted>`).
7. Restore: `mv ~/.codex/sessions-backup ~/.codex/sessions`. **PASS** if the next poll silently returns to the rollout source (the row's tokens column repopulates within one refresh cycle; no error styling appears during the transition).
8. **D-03 both-fail muted-row stretch test:** `mv ~/.codex/sessions ~/.codex/sessions-backup && mv ~/.codex/auth.json ~/.codex/auth.json-backup`, force a refresh (Cmd-R or wait for the next poll). **PASS** if the Codex row shows a neutral muted "No data yet — start a Codex session to populate" row, status dot dimmed, NOT a red error. Restore both files when done.

### Test 3 — Gemini row populates with per-model quotas + tier tooltip (Phase 3 SC #3 / GEMINI-01..03 / D-15)

1. **PASS** if a "Gemini" row exists.
2. **PASS** if the quota bar reflects `max(1 - remainingFraction)` across all per-model buckets returned by `v1internal:retrieveUserQuota` (D-06). The bar color should follow UI-03 (green <50%, yellow 50–80%, red ≥80%).
3. **PASS** if the "Resets — Xh Ym" countdown displays the next 24h boundary (`resetTime` ISO8601 from any bucket — the provider exposes the cross-bucket max-utilisation window's reset time).
4. **PASS** if hovering the "Gemini" displayName shows a SwiftUI tooltip with "Free" / "Legacy" / "Paid" depending on the reviewer's actual tier (RESEARCH correction #6: `free-tier` → "Free", `legacy-tier` → "Legacy", `standard-tier` → "Paid"). Tooltip is silent on cold-start when `currentTier` is null (Pitfall 8).
5. **PASS** if the bearer auto-refreshed at least once: run `log stream --predicate 'subsystem == "app.agents-usage-bar" AND category == "gemini-oauth"'` after ~1 hour of uptime (default Gemini bearers expire in 3599s); verify a `oauth2/token 200` log line appears. *Optional / time-bounded — mark **DEFERRED** with attestation if the reviewer can't wait a full hour; Test 9's `GeminiOAuthClientTests` covers the algorithm.*
6. **PASS** if `stat -f %m ~/.gemini/oauth_creds.json` mtime is **UNCHANGED** across the refresh (D-10 in-memory-only invariant — the app must never write back to the gemini-cli's file). Same time-bounded caveat as step 5.

### Test 4 — Gemini degraded UX on 5xx (Phase 3 SC #4 / GEMINI-04 / D-11)

1. With the Gemini row showing healthy data, force a connection-error state. Pick one:
   - `sudo sh -c "echo '127.0.0.1 cloudcode-pa.googleapis.com' >> /etc/hosts"` (forces ConnectionRefused).
   - OR turn off Wi-Fi for ≥10 minutes.
2. Click the Refresh button in the popover footer (or wait 2 polls — default refresh = 5 min → ~10 min).
3. **PASS** if within ~2 polls, the Gemini row **dims** (opacity 0.6) AND shows an **amber** status dot AND a subtitle reading exactly `"Updated Xs ago — usage temporarily unavailable"`. (Verified by `ProviderRowViewDegradedTests` source-grep; the UI is wired to render this exactly.)
4. **PASS** if NO red error styling appears on the Gemini row (D-11 invariant — degraded is amber, not red).
5. **PASS** if OTHER provider rows (OpenRouter, Claude, Codex) continue refreshing normally — their "Updated Xs ago" ticks forward, their values change as the underlying sources do. (GEMINI-04 cross-provider isolation invariant — `GeminiOAuthProvider.fetch(now:)` returns a degraded snapshot rather than throwing, so the AggregateStore-level CircuitBreaker never opens on Gemini blips.)
6. **PASS** if forcing a quota fraction crossing on a different provider (e.g. OpenRouter reaches 85%) still fires a notification for THAT provider — Gemini's D-11 suppression must NOT block siblings. (If reviewer cannot force this naturally, mark this sub-step **DEFERRED** with `AggregateStoreGeminiDegradedSuppressionTests` attestation, particularly `test_oneCodexEmitWhileGeminiSuppressed`.)
7. Remove the `/etc/hosts` entry (or re-enable Wi-Fi); click Refresh. **PASS** if within one poll cycle the Gemini row returns to normal styling (opacity 1.0, status dot returns to ok-color, subtitle disappears). Verified by `test_crossPollRecovery`.

### Test 5 — UI-11 dashboard buttons (Phase 3 SC #5 / UI-11 / D-13 / D-14 / D-07)

1. **PASS** if every provider row (OpenRouter, Claude, Codex, Gemini) has a trailing `arrow.up.right.square` SF Symbol button, **always visible** (no hover-reveal — D-13).
2. Click OpenRouter's dashboard button. **PASS** if `https://openrouter.ai/credits` opens in the default browser.
3. Click Claude's dashboard button. **PASS** if `https://console.anthropic.com/settings/usage` opens.
4. Click Codex's dashboard button. **PASS** if `https://platform.openai.com/usage` opens (an auth-wall / 403 page is the expected landing if not signed in — that proves the URL launched correctly).
5. Click Gemini's dashboard button. **PASS** if `https://aistudio.google.com/u/0/usage` opens — the `/u/0/` path pin skips Google's multi-account picker (RESEARCH safety invariant, verified by `ProviderDashboardURLTests.geminiURL_pinsFirstAccount`).
6. **PASS** if hovering any dashboard button shows a tooltip "Open \<displayName> dashboard" (accessibility help string).
7. **PASS** if the popover Totals row carries the footnote "Total excludes quota-only providers" below the tokens/cost summary — confirms the D-07 exclusion language is rendered whenever any quota-only provider (Gemini + the existing OpenRouter which also reports `hasTokens=false`) is registered.

---

### Tests 6-10 — Unit-test attestation table

Tests 6-10 cover invariants that cannot be exhaustively manually verified (schema parsing fidelity, cascade lookup over 7 models, OAuth state-machine across cache hit / file hit / refresh / 401-retry / file-byte-invariant, FSM suppression filtering across multiple poll cycles). All cited suites passed when their plans landed; the reviewer can spot-check by running `xcodebuild test -project AgentsUsageBar.xcodeproj -scheme AgentsUsageBar -only-testing AgentsUsageBarTests/<SuiteName>` if desired. Mirrors the Phase 2 02-UAT "🟡 DEFER" + attested-by-suite pattern.

> **Test 6 — Codex rollout schema correction #1 (`payload.type == "token_count"`):** Attested by `CodexRolloutParserTests` (9 cases: 2026 fixture full-field decode, 2025 legacy `resets_in_seconds` normalisation, malformed-line skip, unknown-future-field tolerance, order-independence, empty-list, `session_meta`-only file returns nil, `token_count` event with `info == nil` skipped). The decoder predicate REQUIRES `type == "event_msg"` AND `payload.type == "token_count"` AND `payload.info != nil` (RESEARCH correction #1 + Pitfall 11) — this is the canonical lock against the per-request-delta event variant that a naïve reader might pick by mistake. See `03-01-SUMMARY.md`.

> **Test 7 — Codex pricing cascade:** Attested by `CodexModelPricingTests` (9 cases including the 2026 RESEARCH fixture hand-computed at the default rate → $0.061586 ± 1e-6; cascade-lookup `.exact / .defaultFallback / .nilModel` exercised; reasoning_output_tokens not-double-counted invariant; missing-bundle graceful-degrade). Pricing values were also verified manually at Plan 03-02's BLOCKING `checkpoint:human-verify` — reviewer resolved as "pricing page inaccessible — use draft as best-effort" with rationale recorded in `codex-models.json`'s `source` field (T-03.02-03 disposition: JSON is a runtime bundle resource patchable without recompile). Phase 1 Plan 03-04's live-fixture test `rollout_2026_fixture_populates_tokens_cost_quota_tooltip` re-verifies the same $0.061586 figure end-to-end through the actor. See `03-02-SUMMARY.md` and `03-04-SUMMARY.md`.

> **Test 8 — Gemini settings gate nested keypath (correction #2):** Attested by `GeminiSettingsGateTests` (10 cases including the regression-guard test #8 — `flatKeypath_returnsFalse` — which feeds a `{ "selectedAuthType": "oauth-personal" }` shaped JSON and asserts the gate returns `false`). The decoder navigates `security.auth.selectedType` via JSONSerialization + nested Dictionary casts (RESEARCH correction #2); there is NO silent fallback to the flat keypath. Also verified by the source-grep gate `grep -cE 'selectedAuthType' GeminiSettingsGate.swift == 0` enforced by the plan's acceptance criteria. See `03-05-SUMMARY.md`.

> **Test 9 — Gemini OAuth refresh + in-memory invariant + Pitfall 10:** Attested by `GeminiOAuthClientTests` (12 cases: eager-cache hit, eager-from-file hit, expiry-imminent refresh, form-urlencoded body inspection — `client_id` / `client_secret` / `refresh_token` / `grant_type=refresh_token` with percent-encoded values, HTTP 400 → `refreshFailed(status: 400)`, HTTP 401 → `refreshFailed(status: 401)`, missing oauth_creds.json → `notSignedIn`, `retryAfter401` invalidates cache and forces refresh, **D-10 file-byte-identical-after-refresh invariant** (creds file SHA-equivalent before and after a successful refresh — locks D-10 dynamically), **Pitfall 10 static guard** (refresh response struct source-scanned post-comment-stripping to prove no `refresh_token`/`refreshToken` CodingKey exists — so we cannot accidentally consume / overwrite a token Google does not rotate), fixture SEC-04 sweep, ci.yml SEC-04 exclusion presence). D-09 + D-10 + Pitfall 10 all locked in via the same suite. See `03-05-SUMMARY.md`.

> **Test 10 — Today Total D-07 exclusion + ThresholdEngine D-11 suppression:** Attested by `AggregateStoreGeminiDegradedSuppressionTests` (8 cases: Codex warn80 emits while Gemini's crit95-with-degraded-tag is suppressed in the same poll; single degraded Gemini at exceed100 emits zero decisions; **cross-poll recovery** — degraded poll suppressed, next non-degraded poll re-applies warn80 transition; filter provider-agnostic; different note string does NOT suppress; empty raw does NOT suppress; Phase 1 back-compat overload honors filter; DRY invariant `ThresholdEngine.degradedTag == GeminiOAuthProvider.degradedNote == "usage-temporarily-unavailable"`) + `AppDependenciesCodexGeminiRegistrationTests` (6 cases including `hasAnyQuotaOnlyProvider_true` registry probe, `rollupTotals_excludesQuotaOnly` exclusion lock — Codex contributes 1000 tokens + $0.50; Gemini's fabricated 500 tokens + $99 are EXCLUDED per D-07; `store.totals.tokens == 1000` + `costUSD == 0.50` — and the relaxed `makeProduction_smoke` cross-environment composition-root check). See `03-08-SUMMARY.md`.

## Reviewer signal

Reply with one of:

- `approved` — Phase 3 complete; the executor will commit the marked-up 03-UAT.md, update STATE.md + ROADMAP.md, and the orchestrator can run `/gsd-transition` to advance to Phase 4 (Local LLM Presence).
- `failed: <test#>: <description>` — File one or more gap entries. The executor records the failed steps in this 03-UAT.md, leaves Phase 3 in BLOCKED state, and the next action is `/gsd-plan-phase 03 --gaps` to plan closure.
- `deferred: <test#>: <reason>` — Accept the test as unit-test-attested only (mirrors Phase 2 reviewer accepting Tests 3-10 as attested). Phase 3 still considered complete if Tests 1-5 manual or 6-10 attested.

## Phase 3 Success Criteria Mapping

| Success Criterion                                                                                                       | UAT Tests   |
|-------------------------------------------------------------------------------------------------------------------------|-------------|
| #1 — Codex JSONL populates from rollout with primary+secondary windows + USD (CODEX-01 + CODEX-03 + CODEX-04 + D-05)     | Test 1, 6, 7 |
| #2 — Codex OAuth fallback transparent on no-rollout (CODEX-02 + D-02 + D-03)                                             | Test 2       |
| #3 — Gemini per-model `remainingFraction` + bearer auto-refresh + tier tooltip (GEMINI-01..03 + D-09/D-10/D-15)          | Test 3, 8, 9 |
| #4 — Gemini degraded UX on 5xx without blocking other providers (GEMINI-04 + D-11 + cross-provider isolation)            | Test 4, 10   |
| #5 — Per-row "Open dashboard" button launches provider's web console (UI-11 + D-13 + D-14 + D-07 footnote)               | Test 5       |
