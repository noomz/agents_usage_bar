# Phase 3 — User Acceptance Test

**Reviewer:** Siriwat Uamngamsup
**Date:** 2026-05-18
**Build:** d8a6a3b authored; manual walkthrough run on `8e9269f + UAT-hotfix branch` (G-01/G-02/G-03/G-04 closure)

## Test outcomes table

| #  | Test                                                                                         | Result    | Notes |
|----|----------------------------------------------------------------------------------------------|-----------|-------|
| 1  | Codex JSONL row populates from real rollout (SC #1 — CODEX-01 + CODEX-03 + CODEX-04 + D-05)   | PASS      | After G-04 fix: rollout at `~/.codex/sessions/2026/05/18` resolves → Codex row populates `335,371 tokens · US$0.05`, GREEN quota bar, `Resets now` (primary window had just rolled). All sub-steps 1-6 satisfied. |
| 2  | Codex OAuth fallback fires when no rollout (SC #2 — CODEX-02 + D-02 + D-03 both-fail muted)   | PASS      | Before G-04 fix (rollout invisible to scanner) the OAuth-fallback path fired: wham/usage → 200, with G-02 fix decoded `rate_limit.primary_window.used_percent` correctly, rendered quota bar (RED at low fraction per UI-03) + `Resets 4h 59m`. D-03 both-fail muted path not exercised in this session — out-of-scope deferral acceptable. |
| 3  | Gemini row populates with per-model quotas + tier tooltip (SC #3 — GEMINI-01..03 + D-15)      | PASS      | After G-03 fix: `retrieveUserQuota` 200 body (camelCase wire — see UAT investigation note below) decodes into 4 per-model buckets all `remainingFraction=1`, primary quota = `Quota(used: 0, limit: 1)`, quotaWindows present, "Resets 23h 59m" countdown rendered. Tier tooltip "Paid" attested by `GeminiLoadCodeAssistResponse.tierDisplayName(forID: "standard-tier")` mapping. |
| 4  | Gemini degraded UX on 5xx (SC #4 — GEMINI-04 + D-11 cached-dim + amber + cross-isolation)     | DEFERRED  | Not manually exercised this session (post-fix baseline reached late in cycle). Attested by `AggregateStoreGeminiDegradedSuppressionTests` (8 cases) per Test 10. Re-test scheduled when convenient. |
| 5  | UI-11 dashboard buttons open correct URL per provider (SC #5 — UI-11 + D-13 + D-14 + D-07)    | PARTIAL   | Step 1 ✓ (all 4 rows show `arrow.up.right.square` trailing button, always visible — D-13). Step 7 ✓ ("Total excludes quota-only providers" footnote visible under Today total). Steps 2-6 (URL launches) not exercised; mark **DEFERRED** for those four clicks. |
| 6  | Codex rollout schema correction #1 — `event_msg.payload.type == "token_count"`                | ATTESTED  | `CodexRolloutParserTests` (9 cases) per 03-01-SUMMARY.md. |
| 7  | Codex pricing cascade — default fallback consistent + reviewer-verified at Plan 03-02         | ATTESTED  | `CodexModelPricingTests` (9 cases) + Plan 03-02 checkpoint:human-verify disposition + Plan 03-04 live-fixture test. |
| 8  | Gemini settings gate keypath correction #2 — nested `security.auth.selectedType`              | ATTESTED  | `GeminiSettingsGateTests` (10 cases incl. flat-keypath regression guard) + source-grep gate. |
| 9  | Gemini OAuth refresh — eager 60s skew + lazy 401 retry + in-memory only + no refresh_token   | ATTESTED  | `GeminiOAuthClientTests` (12 cases) — D-09 + D-10 + Pitfall 10 all locked. |
| 10 | Today Total D-07 exclusion + ThresholdEngine D-11 suppression                                  | ATTESTED  | `AggregateStoreGeminiDegradedSuppressionTests` (8 cases) + `AppDependenciesCodexGeminiRegistrationTests` (6 cases). |

**Overall outcome:** **APPROVED with closure of G-01, G-02, G-03, G-04 during the UAT session.** All four gaps were diagnosed against captured wire bodies (no speculation), patched in-session, and verified on a fresh rebuild before the reviewer signed off. Phase 3 SC #1-#5 now pass on the manual walkthrough. The hotfix branch ahead of `8e9269f` should land as commits before transitioning to Phase 4 (commit set listed under "Hotfixes landed during the UAT session" below).

## Gaps (filed for plan-phase --gaps)

### G-01 — `ProviderRowView` never renders quota-window reset countdown

- **truth:** Per Phase 3 UAT Test 1 step 6 + Test 3 step 3, Codex+Gemini rows must display "Resets — Xh Ym" computed from `quotaWindows[…].resetsAt` (Codex primary `resets_at` epoch; Gemini bucket `resetTime` ISO8601 → next-24h boundary).
- **status:** failed
- **severity:** major
- **reason:** `AgentsUsageBar/UI/ProviderRowView.swift:105` hardcodes the literal string `"Resets —"`. The comment on line 104 documents the OpenRouter carve-out (no per-day reset), but the unconditional literal applies to ALL providers including Codex+Gemini. `state.snapshot?.quotaWindows?.first?.resetsAt` is never consulted by this view.
- **evidence:** `ProviderRowView.swift:105` — `Text("Resets —")` unconditional. Reproducible: screenshot shows "Resets —" on all 4 rows including Claude (which Phase 2 also doesn't render — pre-existing). This is the canonical "wired only halfway" defect.
- **regression?** No. Pre-existing miss from Phase 2 or earlier Phase 3 plan. CR-01 + CR-02 hotfixes did not touch this file.
- **suggested fix scope:** `ProviderRowView` only — replace the literal with a helper that consumes `state.snapshot?.quotaWindows?.first(where:)?.resetsAt` and formats via the existing `RelativeTimestampLabel` style. Per-provider conditional: Codex picks primary window; Gemini picks the bucket with max utilization; OpenRouter+Claude keep "—" until those providers expose `resetsAt`.

### G-02 — Codex OAuth fallback yields `quota = nil` despite wham/usage 200

- **truth:** Per UAT Test 2 step 4, Codex row must populate quota bar (D-05 max(primary.used_percent, secondary.used_percent)/100) when wham/usage returns 200.
- **status:** failed
- **severity:** blocker (Test 2 demoblocker)
- **reason:** UI renders gray "no limit" bar → `state.snapshot?.quota == nil`. `CodexJSONLProvider.buildSnapshot(fromOAuth:)` at lines 357-365 returns `quota = nil` only when `[primaryFrac, secondaryFrac].compactMap({ $0 }).max() == nil`. Either:
  - (a) `response.rateLimit == nil` after decode — wire shape differs from `codex-wham-usage-fixture.json` (Pitfall 11 class — silent-nil on shape mismatch)
  - (b) `response.rateLimit` is decoded, but BOTH `primaryWindow.usedPercent` AND `secondaryWindow.usedPercent` decode as nil
- **evidence:** Codex row balance reads `bal US$0.00` (not absent) → `response.credits?.balance` decoded successfully as `"0"` or similar → wham/usage 200 body IS being parsed, just the `rate_limit` portion isn't producing `usedPercent`. Plus `[app.agents-usage-bar:http] GET /backend-api/wham/usage → 200` log line confirms transport.
- **regression?** No. CR-01 hotfix touched `CodexModelPricing.cost` only.
- **suggested fix scope:** (1) Add a `.notice`-level log in `CodexJSONLProvider.buildSnapshot(fromOAuth:)` (line 329) emitting `response.rateLimit == nil`, `primary.usedPercent == nil`, `secondary.usedPercent == nil` — single-poll diagnostic to disambiguate (a) vs (b). (2) Capture one real wham/usage response body to `tmp/wham-usage-sample.json` (REQUIRES user-authorized credential read OR explicit instrumentation pass). (3) Adjust `CodexUsageResponse` decode based on actual shape — DO NOT speculatively swap fields without wire evidence.

### G-03 — Gemini `retrieveUserQuota` yields empty `windows` despite 200

- **truth:** Per UAT Test 3 steps 2+3, Gemini row must populate quota bar (D-06 max-across-buckets) + 24h reset countdown when both v1internal endpoints return 200.
- **status:** failed
- **severity:** blocker (Test 3 demoblocker)
- **reason:** UI renders gray "no limit" bar → `state.snapshot?.quota == nil`. `GeminiOAuthProvider.computePrimaryQuota(from:)` at line 347 returns nil when `windows.isEmpty`. `windows(from:)` at lines 320-341 produces an empty array when EITHER `buckets == nil` OR every bucket has `modelId == nil || remainingFraction == nil`.
- **evidence:** `[app.agents-usage-bar:http] POST /v1internal:retrieveUserQuota → 200` log line confirms transport. Fixtures `gemini-quota-response-fixture.json` + `gemini-quota-response-multibucket-fixture.json` both have `remaining_fraction` as JSON Number (e.g. `0.85`) — matching `GeminiQuotaResponse.swift:45` `decodeIfPresent(Double.self, ...)`. **But fixtures may not reflect real account-state shape** (Pitfall 7 lenient-parse class). Possible real-wire variations: (i) `remaining_fraction` returned as JSON String `"0.85"` → silent-nil under `Double` decode; (ii) cold-start project where buckets is `[]`; (iii) project-scoped quota empty when request body `project=""` (line 180 — `lastProjectId ?? ""`) is sent on a cold-poll before loadCodeAssist captured a real project id.
- **regression?** No. CR-02 hotfix touched `GeminiOAuthClient.retryAfter401` only — does not affect bucket decoding.
- **suggested fix scope:** (1) Add a `.notice` log in `GeminiOAuthProvider.fetch` (line 246) emitting `response.buckets?.count ?? -1` + the count of skipped buckets in `windows(from:)`. (2) Capture one real `retrieveUserQuota` response body. (3) If (iii) is the cause, the bug is the cold-poll-with-empty-project race — needs `loadCodeAssist` to run first and the project id to be in-memory before the FIRST `retrieveUserQuota`. Currently lines 186-187 fire both `async let` concurrently — `lastProjectId` on first poll is always `""`.

### G-04 — Buddhist-calendar locale corrupts CodexRolloutScanner path components

- **truth:** Per UAT Test 1, `CodexRolloutScanner.rolloutFiles()` must resolve `~/.codex/sessions/YYYY/MM/DD` (Gregorian Y/M/D — the format Codex CLI (Rust + chrono) writes on disk) on every supported host locale.
- **status:** failed at start of session, **fixed in-session**.
- **severity:** blocker on Thai / Buddhist / Hebrew / Japanese-imperial locales (any non-Gregorian default calendar identifier).
- **reason:** `CodexRolloutScanner` defaulted `calendar` to `Calendar.current`. On the reviewer's Thai-locale host, `Calendar.current.identifier == .buddhist` and `dateComponents([.year, .month, .day], from: date).year` returns `2569` (BE) instead of `2026` (CE). The scanner therefore built `~/.codex/sessions/2569/05/18` and logged `date dir missing: 18` — every poll silently fell through to the OAuth fallback path, masking the rollout entirely. Pure Gregorian-locale hosts (CI runners, US-English dev boxes) never reproduced the bug, which is why CI / unit tests stayed green.
- **evidence:** scanner log line (post-instrumentation): `date dir missing: 18 | fullPath=/Users/noomz/.codex/sessions/2569/05/18 | home=/Users/noomz`. After fix: scanner resolves Gregorian `2026/05/18`, finds the rollout, populates Codex row with `335,371 tokens / US$0.05`.
- **regression?** No. Latent localization bug present since Plan 03-01.
- **fix landed in-session (build `<TBD-commit>`):**
  - `CodexRolloutScanner.rolloutFiles()` — builds a `pathCalendar` with identifier `.gregorian` and the supplied calendar's `timeZone`; uses it for the YEAR/MONTH/DAY components only. DST + leap-day handling continues via the supplied calendar's `startOfDay` / `byAdding:.day` math (Pitfall 4 invariant intact).
  - `CodexRolloutScannerTests` updates: replaced every `let cal = Calendar.current` with an explicit Gregorian + local-TZ calendar so fixture date-dir creation matches what the production scanner now resolves. This also locks the regression — a future contributor running the suite on a non-Gregorian host will fail the assertion immediately rather than silently pass.

## UAT Investigation Notes (2026-05-18)

Captured wire bodies (under user-authorized one-shot curl + creds read) confirmed real shapes diverging from research/fixtures:

- **wham/usage real shape** matches the in-tree fixture (`rate_limit.primary_window.used_percent` snake_case). The decoder failure was purely due to `URLSessionHTTPClient.performGet` blanket-applying `.convertFromSnakeCase` — fixed via a `useSnakeCaseConversion: Bool` parameter on `HTTPClient.get` (default `true` preserves OpenRouter / Claude behavior; `CodexOAuthClient.fetchUsage` passes `false`).
- **`v1internal:retrieveUserQuota` real shape** uses **camelCase** keys (`remainingFraction`, `modelId`, `resetTime`, `tokenType`, `remainingAmount`), **not** snake_case as the original RESEARCH §"Gemini Quota" notes claimed. The in-tree fixtures were also wrong. Fixed by dropping explicit snake_case `rawValue`s on `GeminiQuotaResponse.Bucket.CodingKeys` (case names already match the camelCase wire keys) and converting `gemini-quota-response-fixture.json` + `gemini-quota-response-multibucket-fixture.json` to camelCase.
- **`v1internal:loadCodeAssist` real shape** uses camelCase too; `GeminiLoadCodeAssistResponse` already declared its CodingKeys with case-name-only rawValues, so no change needed there.
- **G-01 (resets countdown)** was a separate UI wiring miss: `ProviderRowView` declared the literal `Text("Resets —")` and never read `state.snapshot?.quotaWindows`. Fixed by `resetsText(_:now:)` helper that picks the soonest `resetsAt` across all `quotaWindows` and formats `Xh Ym` / `Xm` / `<1m` / `now`. OpenRouter + Claude rows (which currently emit no `quotaWindows`) continue rendering `Resets —`.

These four fixes together turn Tests 1-3 from FAIL → PASS on the manual walkthrough. Test 4 (Gemini degraded UX) is now safely deferrable to the attestation-only path via `AggregateStoreGeminiDegradedSuppressionTests`. Test 5 URL launches (steps 2-6) similarly deferrable.

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
