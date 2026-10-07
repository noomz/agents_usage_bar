# SPEC — Codex accounts

Prior spec archived: `docs/specs/ollama-cloud-usage.md`.

One Codex row. Auto-detect CLIProxy logins under `~/.ccs/cliproxy/auth/`. A machine with one ChatGPT login keeps today's single row, including live rollout windows and `max(primary, secondary)`. Two or more logins use the Claude header-plus-children layout. In that mode each login's quota comes from `wham/usage` with that login's own token. Today's spend stays on the header.

## §G

G1|With two or more enabled Codex logins, show each login's 5-hour quota under one Codex row. One login stays one row and keeps today's `max(primary, secondary)` quota.

## §C

C1|This file is the contract. Implementation waits until the user invokes build.
C2|No new config key. Discovery is automatic when the auth files exist.
C3|`ProviderID` stays `.codex`. Logins are `UsageSnapshot.accounts` on that one snapshot.
C4|This repo is public. This spec, tests, and fixtures contain no real access token, refresh token, id token, email, account id, or auth filename from a real machine.
C5|`CodexUsageResponse` and `CodexRolloutEvent.RateLimits` stay separate types. `wham/usage` uses singular `rate_limit.primary_window` and `limit_window_seconds`. Rollout files use plural `rate_limits.primary` and `window_minutes`.
C6|The single-account quota fix already in the working tree stays. Do not revert `CodexRolloutEvent.isPostLimitNulling`, `droppingWindowsReset(atOrBefore:)`, the parser inherit rule, or the windowless `wham/usage` overlay.
C7|A Codex commit does not take unrelated dirty hunks. Known unrelated paths at spec time: `AgentsUsageBar/CLI/AUBCommand.swift`, `AgentsUsageBarTests/CLITests/AUBCommandParseTests.swift`, `AgentsUsageBarTests/CLITests/Golden/compact-empty-cached.txt`, `README.md`, `docs/specs/aub-cli-themes.md`, plus untracked `.pi/`, `AGENTS.md`, `docs/local/`, and `scripts/__pycache__/`. `CompactTextRenderer.swift` is both unrelated-dirty and a file this spec edits. Commit only the hunks this spec requires.
C8|Do not claim the installed `aub` shows the new rows until `~/Applications/AgentsUsageBar.app` is replaced. `~/.local/bin/aub` points at that app binary.

## §I

I1|CLIProxy auth|`~/.ccs/cliproxy/auth/codex-*.json`. Fields used: `type`, `email`, `account_id`, `access_token`, `disabled`. Filename shape `codex-<8 hex>-<email>-<plan>.json`. `priority` and `expired` are ignored.
I2|Codex CLI auth|`~/.codex/auth.json` via `CodexCredentialLoader`. Subscription bearer is `tokens.access_token` plus `tokens.account_id`. Top-level `OPENAI_API_KEY` is the existing API-key path and is not a login row.
I3|Quota HTTP|`GET https://chatgpt.com/backend-api/wham/usage` with `Authorization: Bearer`. Send `ChatGPT-Account-Id` only when that login has an `account_id`. Decode with `CodexUsageResponse`. The call does not go through CLIProxy.
I4|Rollout|Today's Codex JSONL sessions stay the source of `tokensToday` and `costTodayUSD`. They do not record which login served a turn.
I5|Snapshot|`UsageSnapshot.accounts: [AccountUsage]?` in `Domain/UsageSnapshot.swift`. Nil means one row. Count >= 2 means children.
I6|Popover|`UI/ProviderRowView.swift`. Header bar uses `displayedQuota`. Children render when `accounts.count >= 2`. `AccountChildRow` currently always uses `ClaudeQuotaGlanceView`.
I7|Compact CLI|`CLI/CompactTextRenderer.swift` `usageLines` and `quotaLines`. Both account branches are gated by `p.id == .claude`. Severity is `severityLine`.
I8|Classic CLI and JSON|`CLI/UsageTextRenderer.swift` `accountLines` currently draws `claudeDualBarLine`. Usage JSON `ProviderJSON` in `CLI/UsageJSONRenderer.swift` already emits `accounts`. Quota JSON `QuotaJSONRow` has no `accounts` field today.
I9|Menu bar tint and notify|`AggregateStore.maxQuotaFraction` reads `snapshot.quota` and `snapshot.quotaWindows`. `ThresholdEngine` reads `snapshot.quota` only.

## §V

### Single login, unchanged except the credential source

V1|The rollout parser copies an older rate-limit window forward only when the newer event is post-limit nulling. Post-limit nulling means both windows are null and either `limit_id == "premium"` or `rate_limit_reached_type` is set. A CLIProxy null window keeps `limit_id` `codex` and does not inherit.
V2|After that copy, the parser drops a window whose reset is at or before the newer event's time.
V3|Zero subscription logins leaves today's provider behavior in place. That includes the API-key `~/.codex/auth.json` path, a missing auth file, and a rollout-only row.
V4|One subscription login produces `accounts == nil`. Its quota stays `max(primary, secondary)`, from the live rollout windows when those exist. `wham/usage` is not required in that case. A windowless rollout overlays quota from `wham/usage` for that one login and keeps the rollout's `tokensToday` and `costTodayUSD`. A failed overlay leaves the rollout row with no quota bar. Primary-only rows and a required per-login `wham/usage` call apply only when two or more logins exist.
V5|The one login's token is the token `wham/usage` uses. A lone CLIProxy file is enough when `~/.codex/auth.json` is absent. When the same `account_id` exists in both stores, the CLIProxy file supplies the token and `~/.codex/auth.json` is not a second login.

### Which logins exist

V6|CLIProxy discovery reads `codex-*.json` in `~/.ccs/cliproxy/auth/`. A missing directory means zero CLIProxy logins. A file is skipped when `disabled` is true, when `type` is present and not `codex`, when `access_token` is missing or empty, when `account_id` is missing or empty, or when the JSON cannot be read. Skipped files do not drop the others.
V7|`~/.codex/auth.json` is an extra login only when `tokens.access_token` is non-empty, `tokens.account_id` is non-empty, and that `account_id` is not already in the enabled CLIProxy set. An API-key auth file is never a login. A subscription auth file with no `account_id` is a login only when the enabled CLIProxy set is empty. That lone login omits `ChatGPT-Account-Id`, matching `CodexOAuthClient`.
V8|Two CLIProxy files with the same `account_id` produce one login. The lexicographically smaller filename wins.
V9|Each login's final label is unique, because `AccountUsage.id` is `name` and `ProviderRowView` uses that id in `ForEach`. The plan slug set is `plus`, `pro`, `team`, `business`, `enterprise`, `edu`, `free`, `guest`, compared case-insensitively and shown in lowercase. A CLIProxy file tries, in order: the filename's last `-` segment when it is a plan slug and that slug is unique, then a non-empty `email` that no other login uses, then `acct-` plus the first 8 characters of `account_id`, then `acct-` plus the full `account_id`. A missing or duplicate email skips to the next candidate. An extra `~/.codex/auth.json` row tries lowercased `plan_type` when that string is unique, then the same `acct-` fallbacks. After every login has a candidate, any label still shared by two logins moves each of those logins to its next fallback. Labels are sorted ascending with `<` before they are stored, so the popover and the CLI show the same order.
V10|Logs, snapshots, tooltips, and `raw` never contain `access_token`, `refresh_token`, or `id_token`.

### Two or more logins

V11|Two or more enabled subscription logins produce one Codex snapshot whose `accounts.count` equals the login count. `tokensToday` and `costTodayUSD` stay the rollout totals on the header. Each `AccountUsage.costTodayUSD` is nil. Spend is not split.
V12|Each login is one independent `wham/usage` call with that login's access token and `ChatGPT-Account-Id`. One failure does not cancel the other calls and does not throw for the provider. The provider status stays `.ok` when the snapshot is returned. A failed login still has a row. Its `quota` is nil and its usage line is `unavailable`, not `no limit`.
V13|A successful login stores `AccountUsage.quota` from `rate_limit.primary_window.used_percent` as a 0...1 fraction. `quotaWindows` holds `primary` then `secondary` when those objects exist, with `duration` taken from `limit_window_seconds` and the existing window names `primary` and `secondary`. A missing primary window makes the usage row unavailable. The secondary window does not fill in for it.
V14|On a multi-login snapshot, `snapshot.quota` is the max primary fraction across logins that returned one, or nil when none did. `snapshot.quotaWindows` is nil. Menu-bar tint and the threshold notification therefore follow the 5-hour primary, because both read `snapshot.quota` once the header windows are nil. The weekly window stays on each account and is shown only in quota detail.
V15|`●` marks the login with the highest primary fraction among logins that have one. An equal fraction uses the sooner primary `resetsAt`. A nil reset is later than any known reset, matching `QuotaGlance.select`. If the resets also tie, or both are nil, the alphabetically first label gets the mark. When no login has a primary fraction, no login gets `●`. A failed login is not eligible.

### How the row looks

V16|Compact `aub usage` for multi-login Codex matches the Claude account shape. The header gauge is text, the header has no percent, and the header money is today's rollout spend. `severityLine` therefore does not count the header. Each child is indented like a Claude account row, shows a bar of its primary fraction, a duration-derived `5h` label, and that window's reset. The child V15 marks ends its name with `●`. When V15 marks nobody, no child name has `●`. A failed child is a problem line with the word `unavailable`.
V17|The popover header keeps today's tokens, today's cost, and one bar of `displayedQuota`, which is the max primary fraction. The header reset caption stays hidden when `accounts.count >= 2`, which is the existing gate. Each child shows its label, one `QuotaBar` of its primary fraction, and its primary reset. A child shows no dollar amount. A failed child shows the label and `unavailable` and does not draw a healthy empty bar. Codex children do not use `ClaudeQuotaGlanceView`.
V18|Classic `aub usage` draws the header as one single bar of the max primary fraction, not the Claude dual-glyph bar. Each child is the label, one single primary bar, and the primary reset, with no per-login cost. Compact and classic `aub quota` list each login's `primary` and `secondary` windows under that login's label.
V19|Usage JSON `accounts` is null when fewer than two logins exist. With two or more, each account has `name`, `costTodayUSD: null`, `quota` equal to the primary fraction, and `quotaWindows` for primary and secondary. Header `tokensToday` and `costTodayUSD` remain the rollout totals. Quota JSON gains the same `accounts` array, without `costTodayUSD`, because V14 leaves header `quotaWindows` nil and `QuotaJSONRow` would otherwise drop the per-login windows. Below two logins, quota JSON stays free of `accounts`.
V20|Claude's own header, dual-lane glance, and account rows stay on `p.id == .claude`. This spec adds a Codex branch. It does not route Codex through `claudeWindow` or `claudeDualBarLine`.

## §T

id|status|task|cites
T1|x|Discover CLIProxy files and the optional `~/.codex/auth.json` login. Dedupe, skip, and label per V6-V10. Injectable directory and auth path. Synthetic fixtures only.|V6,V7,V8,V9,V10,C2,C4,I1,I2
T2|x|One login keeps `accounts == nil`. Windowless overlay and the no-rollout fallback call `wham/usage` with that login's token. Live rollout windows still win. Existing parser tests stay green.|V1,V2,V3,V4,V5,C5,C6,I3,I4
T3|x|Two or more logins build one snapshot. Independent `wham/usage` calls. Header tokens and cost from the rollout. Child cost nil. Isolate a failed login. Set header `quota` to the max primary and header `quotaWindows` to nil.|V11,V12,V13,V14,V15,I3,I4,I5,I9
T4|.|Compact usage and quota render the Codex header and children. Severity ignores the header. `●` marks the highest primary. Failed child counts as unavailable.|V15,V16,V18,V20,I7
T5|.|Popover children use a single primary `QuotaBar`. No child cost. No Claude glance. Header reset stays hidden at two or more accounts.|V14,V17,V20,I6
T6|.|Classic usage and quota follow V18. Usage JSON and quota JSON follow V19, including `accounts` on quota JSON when two or more logins exist. Update goldens only for the Codex account branch.|V18,V19,V20,C7,I8
T7|.|Regression tests for dedupe, disabled file, one login, two logins, one failed `wham/usage`, equal primary percents, and the parser inherit rules.|V1,V2,V4,V5,V6,V7,V8,V12,V15,C4
T8|.|Replace `~/Applications/AgentsUsageBar.app` from this tree and confirm `~/.local/bin/aub` points at the new binary before calling the rows done.|C8

## §B

id|date|cause|fix
