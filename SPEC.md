# SPEC — Usage history

Prior spec archived: `docs/specs/codex-accounts.md`.

AUB keeps a daily record of each provider's usage for the last 90 days: tokens, spend, quota peaks, and the accounts seen that day. Days the app missed are rebuilt where the provider still keeps the data. Notable moments (quota bands, budgets, pace, resets, sign-in lost) are recorded as usage events. Optional monthly budgets alert on spend. The history is shown by `aub stats`, exported as JSON or CSV, and drawn in a native dashboard window with a 14-day teaser in the popover.

Vocabulary is in `GLOSSARY.md` (day record, day key, sealed, observed, backfilled, gap, usage event, estimated cost, billing model, account, account key, account label, spend, API-equivalent value, budget, month spend, dashboard). Decisions with trade-offs are in `docs/adr/0001`–`0003`.

## §G

G1|Record per-provider, per-account daily usage for 90 days and show it in `aub stats`, JSON/CSV export, and a dashboard window, with usage events and monthly spend budgets, without adding polling cost.

## §C

C1|This spec lifts the CLAUDE.md v1 constraint "today only, no multi-day persistence". The aggregation window is today live plus 90 days of daily history in local files. The CLAUDE.md constraint line and `.planning/PROJECT.md` change in the same commit as this spec.
C2|This file is the contract. Implementation waits until the user invokes build.
C3|This repo is public. Tests, fixtures, and commits contain no real spend, account name, email, account id, or token. History fixtures are generated synthetic data (fake slugs, round numbers), never copied from a real store.
C4|Battery: history adds no timer, wakeup, or network call to the poll path. All history work rides the existing poll, the existing date-change detection, or a user action.
C5|Swift and SwiftUI only. No new third-party dependency. Charts use Swift Charts. The hotkey uses Carbon `RegisterEventHotKey`.
C6|Work ships in slices S0–S7 in §T order. Each slice is releasable on its own, with no feature flag. Day-file `schemaVersion` 1 and export `schemaVersion` 1 freeze at the first release that contains them. After that, fields are only added.
C7|A slice is done when CI Build-and-test is green on its PR (a local Xcode build is not proof, because local Xcode accepts code CI rejects), and then `scripts/build-local.sh` installs the app and the slice's real check passes on the installed app. `~/.local/bin/aub` points at the installed app binary.
C8|One GitHub issue per slice. Build PRs close their slice's issue.

## §I

I1|Today key|`Domain/TodayHelper.swift` `formatYYYYMMDD(_:calendar:)` defaults to `Calendar.current`, so a Buddhist-calendar host gets `2569-…` keys. Callers: `Notifications/ThresholdEngine.swift`, `PaceEngine.swift`, `ResetEngine.swift`, `NotificationManager.swift` (`isoDayString`), `NotificationStateStore.swift` keys `notif.<provider>.<yyyy-MM-dd>`, `Infrastructure/PowerObserver.swift`, `Infrastructure/FileCacheStore.swift` (daily accumulator, baseline), `Aggregation/AggregateStore.swift` (snooze, threshold dispatch).
I2|Clock|`Infrastructure/Clock.swift`: `protocol Clock`, `SystemClock`, `VirtualClock` for tests.
I3|Live cache|`FileCacheStore` writes `~/Library/Application Support/AgentsUsageBar/today.json`. OpenRouter today cost is a baseline delta via `cache.baseline(for:on:)` and `maintainBaseline` in `Providers/OpenRouter/OpenRouterProvider.swift`.
I4|Poll|`AggregateStore.refresh(now:)`. Threshold dispatch is `fireThresholdNotificationsIfNeeded(now:)`. Snooze is `snoozeToday(providerID:on:)`.
I5|Snapshot|`Domain/UsageSnapshot.swift`: `UsageSnapshot` (`tokensToday`, `costTodayUSD`, `quota`, `quotaWindows`, `accounts`), `AccountUsage`.
I6|Billing model sources|Claude: the account root's `.claude.json` (`~/.claude.json` for `default`, `<ccs instance>/.claude.json`) `oauthAccount.organizationType` (`claude_max`, `claude_pro`, `claude_team`) is subscription with plan `max`, `pro`, `team`; no `oauthAccount` is metered (API key). No Keychain read. Codex subscription login vs API key (`CodexLoginDiscovery`, `CodexCredentialLoader`). Gemini tier. Ollama Cloud plan. OpenRouter and Grok credits are metered. Local runtimes are local.
I7|Account names|Claude: ccs instance slug or `default` (`Providers/Claude/ClaudeHookProvider.swift`). Codex: `CodexLoginDiscovery` labels, which can be an email (archived Codex spec V9).
I8|Estimated cost|Claude cost in `sessionReads` mode (`Domain/ClaudeUsageSource.swift`) and Codex rollout cost are tokens times the bundled price table (`Resources/Pricing/`).
I9|History dir|`~/Library/Application Support/AgentsUsageBar/history/`: `yyyy-MM-dd.json` day files and `.account-salt`.
I10|Backfill sources|Claude `~/.claude/projects/**/*.jsonl` (and ccs instance roots), kept about 30 days by Claude's cleanup default. Codex `~/.codex/sessions/YYYY/MM/DD/` rollouts (Gregorian path components). OpenRouter `GET /api/v1/activity`, the last 30 UTC days, needs a management key.
I11|OpenRouter management key|New. `OPENROUTER_MANAGEMENT_KEY` env, else `management_key` in the `[openrouter]` section of `config.toml`, the same layering as `OPENROUTER_API_KEY` in `Config/ConfigStore.swift`.
I12|Config|`Config/AppConfig.swift`, `Config/ConfigStore.swift` (`config.toml`), `Config/UserPreferencesStore.swift` (Settings values in UserDefaults win over config, like `threshold`). Settings UI in `UI/Settings/`.
I13|CLI|`CLI/AUBCommand.swift`, `CLI/AUBCommandRun.swift`, `CLI/CompactTextRenderer.swift` (palette, glyphs, severity), `CLI/CLITheme.swift`. New subcommands `stats` and `dashboard`.
I14|App shell|`App/AgentsUsageBarApp.swift` (`MenuBarExtra`), `App/WindowActivationObserver.swift` and `setActivationPolicy`, `UI/PopoverRootView.swift`. `Resources/Info.plist` has no `CFBundleURLTypes` today.
I15|Secret scan|SEC-04: `scripts/check-secrets.sh` and the scan step in `.github/workflows/ci.yml`. Today it matches API-key prefixes only.
I16|Day file v1|`{schemaVersion: 1, date, timeZone, records: [DayRecord], events: [UsageEvent], backfillChecked: [providerId]}`. `DayRecord`: `provider`, `timeZone?`, `tokens?`, `costUSD?`, `costEstimated`, `balanceUSD?`, `quota: {window: {peak, peakResetsAt?, endOfDay}}`, `accounts: [{key, label, billingModel, plan?, billingModelAssumed, costUSD?, tokens?, quota}]`, `origin`, `firstSeen?`, `lastSeen?`. `UsageEvent`: `time`, `provider?`, `kind`, `window?`, `account?`, `fraction`, `notified`, `carriedOver`. Money is a decimal string.

## §V

### Day key

V1|One day-key owner gives the current day key to every "today" consumer in I1 and to `HistoryStore`. No consumer computes a day key from `Calendar.current` itself.
V2|A day key is `yyyy-MM-dd` from a Gregorian calendar in the current time zone, whatever calendar the user's locale uses. Display labels follow the system calendar and locale. Grid math, file names, and export use day keys.
V3|On the first launch after S0, a key that `today.json` or `NotificationStateStore` stored with the old `Calendar.current` format for the same day counts as today. The upgrade does not reset the OpenRouter baseline, lose the daily accumulator, or fire a band notification a second time.
V4|The day key never decreases across polls, wake, relaunch, or a time zone change. When the wall-clock date is earlier than the newest key, polls write to the newest key and a sealed day never reopens. A date skipped forward is a gap. The newest key is the newest day file in `history/`; when there is none, the wall clock decides. No other copy of it is stored.
V5|When the wall-clock date is more than 1 day behind the newest key, history writes pause and the app logs it. The popover keeps showing live numbers.
V6|A time zone change on the same date keeps the key. The record stores the last zone id seen that day. DST days of 23 or 25 hours are stored as they are.

### Day records

V7|There is at most one day record per provider per day key. `tokens` and `costUSD` keep the highest value seen that day, so a degraded poll cannot shrink a day. Nil means unknown and is never written or shown as zero. `balanceUSD` keeps the last value seen.
V8|Quota is stored per window name: the peak fraction with the `resetsAt` at the peak, and the end-of-day fraction (the last one seen). A window that resets during the day contributes its highest value across the local day.
V9|Each account seen that day is stored with its account key, account label, billing model, plan name, and per-window peak and end-of-day quota. Account `costUSD` is stored only when the provider reports per-account cost (Claude ccs yes, Codex no). Account `tokens` is stored only when the provider reports per-account tokens (Claude yes, per ccs instance root, live and backfill; Codex no, its sessions tree is not per login) and keeps the highest value seen that day (V7).
V10|`origin` is `observed` or `backfilled`. Observed records store `firstSeen` and `lastSeen`, the times of the first and last good samples. `costEstimated` is true when the cost is tokens times the price table (I8 and all Claude and Codex backfill).
V11|A record is written for every provider with at least one `.ok` poll that day, including local runtimes with nil totals. No record means the provider was not seen.
V12|Totals are never split, prorated, or interpolated across days. Usage polled before sleep stays in the last-polled day. Days slept through are gaps.
V13|History buckets by local day key only. A provider's reset time never moves data between keys. The one exception is OpenRouter backfill: UTC day `D` goes into key `D` and the record stores `timeZone: "UTC"`. Every other record leaves `timeZone` nil; its day is the file's zone.

### Store

V14|`HistoryStore` is separate from `FileCacheStore`. It writes one file per day key in I9, holding every provider's records, the day's usage events, `backfillChecked`, and `schemaVersion`. Wiping or cold-starting `today.json` never touches `history/`.
V15|After a poll, the store merges into the open day and writes only when the merged value changed, atomically (temp file plus rename). At launch it seeds what is on disk from the open day's file. A poll with no change does no file I/O. `firstSeen` and `lastSeen` are left out of the change check: they update in memory on every good poll and reach disk with the next changed write or the seal's final merge, so after an idle quit the stored `lastSeen` can be the time of the last changed write.
V16|Sealed is derived, not stored: a file whose key is before the current day key is sealed. The first poll on a later key does a final merge into the previous key's file. After that, polling never writes a sealed file. Only backfill top-up (V31) may change it.
V17|Retention is fixed at 90 day keys, with no setting. The seal step deletes files whose key is more than 90 days before the current key.
V18|A file with an older `schemaVersion` is migrated when read and rewritten on the next write. A file that is newer, unknown, or unreadable is skipped and logged, and never deleted or overwritten. Schema 1 contains every field in I16 from S1 on; later slices fill fields, they do not add them. Exceptions: `DayRecord.timeZone?`, added in S3 before any release contained schema 1 (B6), and `DayAccount.tokens?`, optional and additive: an older file reads it as nil, with no schema bump.
V19|`aub` opens history read-only. It never creates `history/`, writes, prunes, migrates, or reads `.account-salt`. A missing `history/` is empty history. There is no locking; atomic renames are enough.
V20|History is decoded off the MainActor. The read API is `nonisolated async`. The app reads history only on a user action (dashboard open, Export…, popover open for the teaser), never on the poll path, and keeps no sealed-day cache. The dashboard holds its decoded days while it is open and drops them on close; when a poll changes the open day, only that day's file is re-read. The one poll-side exception is month spend for budgets (V66).

### Privacy

V21|A Claude account key is the ccs instance slug or `default`. A Codex account key is a short hash of `account_id` with the per-install salt in `history/.account-salt` (ADR 0003). The salt is created on the first write. If it is missing while day files exist, a new salt is made and Codex series split. A raw `account_id` is never written to history or export.
V22|An account label is never an email. When the live Codex label is an email, the stored label is the unique plan slug, else `acct-` plus the first 4 characters of the account key. Labels never come from a raw `account_id`. ccs slugs are stored as they are. Views show the newest label for a key.
V23|`history/` is mode 0700. Day files and `.account-salt` are 0600.
V24|SEC-04 (I15) also fails on any email address whose domain is not `example.com` or ends in `.test`, unless the address is on the exact allowlist in `scripts/check-secrets.sh`. The allowlist holds only public repo addresses: the copyright address in `Info.plist` and `README.md`, and the gh-pages committer `ci@github.com` in `release.yml`. It matches whole addresses, never domains.

### Spend and value

V25|Billing model (metered, subscription, local) and plan are captured per account per day at poll time from I6. A later plan change never rewrites a past day. Backfilled records take the model current at backfill time and set `billingModelAssumed`.
V26|Spend comes from metered accounts only, reported or estimated. A subscription account's token-priced cost is API-equivalent value (ADR 0001). Value is never added to a spend total, month spend, or budget, never shares a series, column, or total with spend, and is always shown with `~$`.
V65|Every `Money` amount is rounded to 6 decimal places (half away from zero) when it is created, from a provider value, a backfill sum, or a decoded day file. No binary floating-point expansion reaches a day file, an export, or a view. Sums of rounded amounts stay exact.

### Backfill

V27|Gap-fill runs after the first poll's seal and prune at launch, and after any seal caused by a date change (wake, overnight polling). It runs as a low-priority background task, one provider at a time. It never delays the menu-bar number and never writes the open day.
V28|Reach (I10): Claude about 30 days, Codex the whole 90 days, OpenRouter 30 UTC days and only when a management key is configured (I11), with no prompt. Gemini, Ollama, Ollama Cloud, LM Studio, llama.cpp, and Grok are forward-only.
V29|Each day file lists in `backfillChecked` the providers already backfilled for that day. Launch work is the gaps plus days not yet checked for each provider, and nothing more. A provider that becomes backfill-capable later still fills its old gaps.
V30|Inside a source's reach, a day with no usage gets a backfilled record with zero totals. Outside reach, and for forward-only providers, no record is written and the day stays a gap. Backfilled records never carry quota, `firstSeen`, or `lastSeen`.
V31|Backfill never replaces an observed record. It only raises `tokens` and `costUSD` through the V7 max-merge, which recovers usage between the last poll and midnight. `origin`, quota, accounts, `firstSeen`, and `lastSeen` stay untouched.
V32|Backfill never creates usage events. All backfill writes go through `HistoryStore`.
V62|A new backfilled record lists every account known at backfill time: Claude `default` when `~/.claude.json` exists plus each ccs instance with a `.claude.json`; Codex the discovered subscription logins, else one metered `default` account. Each takes billing model and plan from I6 at backfill time with `billingModelAssumed` true, and carries no `costUSD` and no quota. Transcripts and rollouts hold no account id, so usage is never split by account.
V63|A backfill source states which day keys it holds. Gap-fill asks a source only for held keys in its reach. An unheld key gets no record, is not added to `backfillChecked`, and is tried again on a later pass. OpenRouter holds key `D` only when UTC day `D` is completed and is one of the last 30 UTC days; Claude and Codex hold every key in their reach.

### Usage events

V33|Usage event kinds are band crossing (80, 95, 100), pace warning, quota reset, auth lost, auth recovered, and budget crossing. Each event stores `time`, `provider` (nil for the total budget), `kind`, `window` (nil for a provider-level band or a budget), `account` key (only for a per-account alert), `fraction`, `notified`, and `carriedOver`.
V34|An event is the crossing, not the notification. `ThresholdEngine`, `PaceEngine`, and `ResetEngine` return every crossing. The snooze and enabled gate runs at dispatch and sets `notified`. `lastBand` advances on every crossing, so enabling notifications later the same day does not fire a band already crossed.
V35|Bands record upward crossings only. Band state is per day key, so a provider still above a band at the first poll of a new day records that crossing with `carriedOver: true`. Gap days get no events.
V36|Auth lost is a change from `.ok` to `.error(.auth)`, `.unauthenticated`, or payment required. Auth recovered is the first `.ok` after that. Network errors, breaker trips, not running, and disabled produce no event. No event is recorded at launch.
V37|A degraded snapshot (`usage-temporarily-unavailable`) produces no event. The first non-degraded poll records the crossing at its own time.
V38|Events are written into the open day's `events[]` on the same write as the records, with no per-day cap.

### Budgets

V39|Budgets are optional monthly USD caps: one per cost-reporting provider (Claude, Codex, OpenRouter) and one total. There are no daily or per-account budgets. Unset means no budget. `config.toml` `[budgets]` (`total_usd`, `<provider>_usd`) is the base; values edited in Settings win.
V40|The budget month is the local calendar month of the day keys. Month spend sums the month's spend (V26), the open day included, so a crossing can fire mid-day. Estimated metered spend counts and marks the month "includes estimated". A gap or nil cost adds nothing and marks the month incomplete; the check still runs. The total sums cost-reporting providers only.
V41|Budget crossings fire at the warning threshold (default 80%) and at 100%, upward only, through the V34 dispatch gate. Band state is per budget per month, with no carry-over into a new month. An edit is checked on the next poll: lowering a cap below spend fires at once, raising it lets the band fall back so it can fire again. Backfilled cost counts toward month spend; the next poll records any resulting crossing at its own time.
V66|`HistoryStore` reads the month's sealed day files when it opens a day key, and again on the next poll after a backfill write into that month. It holds them while that month is open. A poll adds the open day in memory and reads no file. Budget band state is seeded from the month's budget events in those files (the highest band per budget), then follows the current band on each poll, so a raised cap lets it fall without an event. Budgets have no snooze: the gate always notifies, and a budget notification has no snooze action.
V67|A notification carries its route's URL in `userInfo["url"]`. Clicking the notification opens that URL; the snooze action does not. A coalesced band notification opens Calendar on its day with no provider outlined and its band highlighted on every card. Auth events send no notification, so they have no click target.

### CLI

V42|Bare `aub stats` prints a 14-day provider summary with columns provider, spend, tokens, peak, days (recorded/range: days with a record of any origin), and trend, then a total row of metered spend only, then one footer line per configured budget (for example `Oct spend $11.40 / $50 budget`).
V43|The trend plots daily spend for metered rows, daily quota peak % (highest window) for subscription and mixed rows, and presence for local rows. A subscription spend cell shows the plan name dimmed. A mixed provider shows metered spend plus `+plan`. The peak cell is the highest window peak in range with its window name (`92% 5h`), coloured by the existing severity bands.
V44|`aub stats <provider>` (or `--provider <id>`) prints one row per day: date, spend or value, tokens, peak, events, markers. Local runtimes are hidden unless `--provider all`, which shows presence (`used 9/14 days`). `--days N`, `--since`, and `--until` set the range. Beyond about 30 days, trend characters are equal buckets, the header names the bucket size, and a bucket containing a gap is marked incomplete, never drawn low.
V45|Markers: `~` estimated, `·` gap in a trend, `?` recorded day with no value in a trend (V64), `!` incomplete total. The legend lists only markers present. Backfilled is flagged only in the drill-down. The header says `(today open)` and today is the last trend character.
V46|`aub stats` has one layout using the compact palette and glyphs; `--theme` is accepted and ignored. Non-TTY, `NO_COLOR`, and `--no-color` drop ANSI only; sparklines stay Unicode. No history prints one line ("No history yet. The app records from first launch; backfill runs in the background") and exits 0. An unreadable store writes to stderr and exits 1. Plain `aub` never reads history.
V64|A trend separates a gap (no record) from a recorded day with no value for the plotted metric: a subscription or mixed day with no quota (every backfilled day, V30) or a metered day with nil spend. That day draws `?`, never `·` and never low. A bucket mixing values with `?` or `·` days is incomplete (`!`); a bucket of only `?` days draws `?`. Through V56 the dashboard follows the same rule: such a day is "no value", not a "no data" gap band.
V47|`aub stats --json` and `--csv` write to stdout. The default range is every retained day; `--since`/`--until` (inclusive day keys), `--days`, and `--provider` narrow it. The dashboard Export… uses the same renderer, so the bytes match for the same scope.
V48|Export JSON is `{schemaVersion: 1, exportedAt, range, days: [{date, timeZone, records, events, gaps}]}`. `gaps` lists enabled providers with no record that day. Unknown values are `null`, never 0. Money is a decimal string. Accounts export as key, label, billing model, and plan. Subscription token-priced cost exports as `valueUSD`, never as spend. Today is included with `sealed: false`. `backfillChecked`, the salt, and budgets are not exported.
V49|Default CSV has one row per provider per day: date, provider, tokens, costUSD, valueUSD, costEstimated, balanceUSD, billingModel, origin, sealed, firstSeen, lastSeen. `--csv accounts|events|quota` selects another table, one per run. Quota windows appear only in the quota table, one row per (date, provider, account, window) with peak, peakResetsAt, endOfDay. A gap is a missing row; an unknown value is an empty cell; money is a plain number. The column set is fixed per `schemaVersion`; columns can be appended; a rename or removal bumps the version. The README documents this and warns that exports may contain ccs instance names and plan names.

### Dashboard

V50|The dashboard is one native SwiftUI window with Swift Charts. There is at most one instance, and it remembers its size and position. While it is open the app uses regular activation (Dock icon, Cmd-Tab); it returns to accessory mode when the window closes.
V51|Every entry point opens the URL `agentsusagebar://dashboard[?day=yyyy-MM-dd&provider=<id>&range=<range>&event=<kind>&window=<name>]`: the popover footer button, `aub dashboard`, the teaser, the hotkey, and notification clicks. `range` is `days7`, `days14`, `days30`, `days90`, or `thisMonth` and sets the shared range (V52). `event` is a `UsageEventKind`; with the optional `window` it names the events to highlight on the Calendar day. The URL launches the app if needed. It only shows a view and changes nothing. Invalid or unknown parameters are ignored.
V52|The window has a sidebar with Overview, one row per provider (a 14-day mini chart following the V43 trend rule, plus a budget bar when the provider has a budget), a "No cost data" section for local runtimes (each with a days-seen strip), and Calendar. Clicking a provider name in Overview selects its sidebar row. One range picker (7, 14, 30, 90 days, This month) is shared by Overview and provider detail; Calendar always shows every retained day.
V53|Overview shows tiles Spend (matches month spend and budgets; `$0.00 · no metered accounts` when none), Subscription value (`~$`, dimmed, hidden when the range has no subscription account), Tokens, and Usage events with a "not notified" count; month budget bars; Spend per day stacked by provider, metered only, collapsing to one line of text when the range has no metered account; an event lane per provider; a quota band strip (one row per provider window, one cell per day coloured by peak band <80/80/95/100); and tokens per day. Provider chips filter Overview and the Calendar heatmap with one shared selection. A "Split accounts" toggle, off by default, splits Claude and Codex into accounts (V68) in Spend per day, in the quota band strip (one row per account window, labelled with the account label), and in Tokens per day.
V54|Provider detail has tabs named by billing model (Spend, Value, or Spend & value), Tokens, Quota (end-of-day-to-peak range bars per window), and Accounts. A mixed provider draws spend (solid) and value (hatched) as two series with separate totals, never summed. A large chart sits above a usage event table (time, kind, window, notified, carried over). The account picker offers All, Split, and each account, and is the only account filter. One account narrows every tab to it. Split stacks the cost chart and Tokens by account (V68) and draws one Quota series per account in each window.
V55|Calendar shows budget rings, then month grids for every retained month, newest first. A metric picker colours days by Spend (default), Value, or Quota peak. Days show an event dot and a dashed border when partial. The selected day's panel has a card per provider with spend and value side by side, quota peak and end-of-day bars, accounts, and events. Today is marked "in progress".
V56|Markers are the same in every view: estimated is `~$` with a lighter fill, partial ranges and months get a grey "incomplete" badge, gaps are grey "no data" bands in charts and dashed borders in Calendar, backfilled records are lighter with a "backfilled" badge in the day panel. Local runtimes show presence only and are never drawn as $0.
V57|Export… is in the window toolbar and in File ▸ Export… (⌘E). It exports the current scope: Overview its range and chip selection, provider detail that provider and range, Calendar every retained day.
V58|Deep links: a band, pace, reset, or auth event opens Calendar on its day with the provider's card outlined and the event highlighted. A budget notification opens Overview on This month. The teaser opens Overview on 14 days.
V59|The popover teaser is a 14-day strip (13 sealed days plus today, marked in progress). It plots daily spend when any metered account appears in the 14 days, else daily quota peak, labelled "Spend 14d" or "Peak quota 14d". Gaps are empty slots, never zero. Budgets are not shown in the popover.
V60|The global hotkey is off by default. The user records it in Settings. It needs no Accessibility permission.

### Launch state

V61|Building the dependency graph changes no persisted state. Launch-time migration and pruning of `today.json`, notification state, and `history/` run in `Dependencies.startBackgroundServices()`, which the hosted test bundle never runs. A test that starts services injects an in-memory store, so tests never write the real `app.agents-usage-bar` defaults or Application Support.
V68|Account split: an account's cost segment is its own `costUSD`. On a day with one account of a billing model, that account takes the provider's cost for that model. Any cost left over is one `unattributed` segment per provider, so a backfilled day with several accounts (V62) is all `unattributed`. Cost is never prorated across accounts (V12). Spend and value segments never stack together (V26). Account segments are shades of the provider colour, named by the newest account label (V22); `unattributed` is grey. Tokens split the same way from account `tokens` (V9): an account's own tokens, a lone account takes the record's tokens, the rest is one `unattributed` segment, never prorated. A day recorded before account tokens existed is all `unattributed`.
V69|A record's quota window names and its accounts' window names differ: with several accounts the record keys `<label> <window>` (`personal 5h`) or one provider window (`quota`), while each account keys its own bare windows (`5h`, `primary`). Any per-account quota view (Split, one account, the Overview split strip) takes window names from the account's own quota, never from the record's. Split and per-account tests use this real shape.

## §T

id|status|task|cites
T1|x|S0: Add the day-key owner: Gregorian `yyyy-MM-dd` in the current zone from an injected `Clock`, plus same-day matching of legacy `Calendar.current` keys. Wall clock only; no history yet.|V1,V2,V3,I1,I2
T2|x|S0: Route every I1 consumer through the owner. Tests with `VirtualClock`, a Buddhist-calendar locale, and an upgrade day with legacy keys in `today.json` and notification state. No behavior change on Gregorian hosts.|V1,V2,V3,I1,I3
T3|x|S0 gate: Move notification-state migrate and prune into `startBackgroundServices` with an injected state store (B1). Clear the stale `dayKeyMigration.notif.` marker on this host. CI green, install, confirm the popover today totals, OpenRouter baseline, and today's fired bands survive the upgrade on this Buddhist-calendar host.|C7,V3,V61
T4|x|S1: `HistoryStore` types for the full v1 day file, `schemaVersion` handling, and a read-only view. Reads are `nonisolated async`.|V14,V18,V19,V20,I9,I16
T5|x|S1: Merge each poll into the open day (max totals, last balance, quota peak and end-of-day, presence), write only on change, seed at launch, seal on the first later key, prune past 90 days.|V7,V8,V11,V12,V13,V15,V16,V17,C4,I4,I5
T6|x|S1: Monotonic day key from the newest day file, and the more-than-1-day pause. Regression tests with a fixed `Clock`: sleep Mon→Thu, Tokyo→Honolulu, Honolulu→Tokyo, `America/New_York` DST spring and fall, clock set back 10 days.|V4,V5,V6,V12,ADR0002
T7|x|S1: Accounts: account key and salt, account label rules, billing model and plan at poll time, `costEstimated` for observed estimated cost.|V9,V10,V21,V22,V25,I6,I7,I8,ADR0003
T8|x|S1: `history/` 0700 and files 0600. SEC-04 email scan in `check-secrets.sh` and `ci.yml`. A synthetic day-file generator for fixtures.|V23,V24,C3,I15
T9|x|S1 gate: CI green, install, run across at least one poll, inspect today's day file and its modes.|C7
T10|x|S2: `aub stats` summary, drill-down, ranges, buckets, markers, legend, edge output. Golden tests on synthetic history.|V26,V42,V43,V44,V45,V46,I13
T11|x|S2: `--json` and `--csv` renderers (all four CSV tables) and the README export section.|V26,V47,V48,V49
T12|x|S2 gate: CI green, install, `aub stats`, `aub stats claude`, `aub stats --json` and `--csv` on real history.|C7
T13|x|S3: Gap-fill scheduler: triggers, low priority, one provider at a time, `backfillChecked`, zero records inside reach, top-up only on observed days, no events.|V27,V29,V30,V31,V32
T14|x|S3: Claude and Codex backfill sources with estimated cost and assumed billing model.|V10,V25,V28,V62,I8,I10
T15|x|S3: OpenRouter `/activity` source and the management key config.|V13,V18,V28,V63,I10,I11,I16
T16|x|S3 gate: CI green, install, delete a synthetic test day's file in a scratch history copy or wait for a missed day, confirm gap-fill writes it.|C7
T17|x|S4: Engines return every crossing; the dispatch gate sets `notified`; `lastBand` advances on every crossing. Existing notification tests stay green.|V34,V35,I4
T18|x|S4: Record band, pace, reset, and auth events into `events[]`, with carry-over and the degraded rule.|V33,V35,V36,V37,V38
T19|x|S4 gate: CI green, install, confirm an event lands in today's file when a band is crossed.|C7
T20|x|S5: `[budgets]` config, Settings fields, month spend.|V39,V40,I12
T21|x|S5: Budget crossing events through the dispatch gate, and the `aub stats` budget footer.|V26,V41,V42,V66
T22|x|S5 gate: CI green, install, set a low budget, confirm the event, the notification, and the footer.|C7
T23|x|S6: Dashboard window, activation switching, URL scheme in `Info.plist`, route handling, `aub dashboard`, popover footer button.|V50,V51,I14
T24|x|S6: Sidebar, shared range, and Overview.|V20,V26,V52,V53,V56
T25|x|S6: Provider detail.|V26,V54,V56
T26|x|S6: Calendar.|V2,V55,V56
T27|x|S6: Export… using the S2 renderer.|V47,V57
T28|x|S6 gate: CI green, install, open via each S6 entry point, check every section against real history, export.|C7
T29|x|S7: Popover teaser.|V20,V59
T30|x|S7: Optional global hotkey in Settings.|V60,C5
T31|x|S7: Notification-click deep links, teaser and budget ranges.|V51,V58,V67
T32|x|S7 gate: CI green, install, teaser, hotkey, and a notification click each open the right view.|C7
T33|x|Fix trend cells: no-record gap vs recorded-no-value `?`, bucket rule, legend entry; golden test with a backfilled subscription day and a nil-cost metered day.|V42,V45,V64
T34|x|Round `Money` to 6 decimal places at its one initializer; tests for a noisy Double-derived amount, decode of a noisy stored string, and encode output.|V65,I16
T35|x|Split: provider detail account picker gains Split; cost chart stacks by account with `unattributed`; Quota draws one series per account per window. Tests on synthetic history: ccs per-account cost, a single-account Codex day, a backfilled day.|V12,V26,V54,V62,V68
T36|x|Split: Overview "Split accounts" toggle for Spend per day and the quota band strip.|V26,V53,V68
T37|~|Split gate: CI green, install, check split views against real history for Claude and Codex.|C7
T38|.|Account tokens: `AccountUsage` gains today's tokens; Claude hook and session reads fill it per ccs instance root, Claude backfill per root; `DayAccount.tokens?` merges max (V7). Tests: two-instance day, old file without the field reads nil.|V7,V9,V18,I16
T39|.|Split Tokens: provider detail Split and Overview Split accounts stack tokens by account with `unattributed`. Tests: per-account tokens, lone account, pre-T38 day all unattributed, totals match unsplit.|V12,V53,V54,V68
T40|.|Account tokens gate: CI green, install, run across a poll, confirm today's file has account tokens and split Tokens shows per account.|C7

## §B

id|date|cause|fix
B1|2026-10-22|Hosted test bundle shares the app's bundle id and real UserDefaults. `makeProduction()` ran `migrateLegacyDayKeys` during composition, before the `isHostingTests` guard. Test plan `region: US` made the legacy calendar Gregorian, so `2569-…` keys rekeyed to themselves and the run-once marker was stamped. The installed app would skip migration and re-fire today's bands.|V61
B2|2026-10-22|Spec gap found planning T5: V10 `lastSeen` moves on every good poll, so V15 "a poll with no change does no file I/O" could never hold while any provider was `.ok`.|V15
B3|2026-10-22|Spec gap found planning T7: I6 named Claude `subscriptionType` from the credential loader, but hook mode (default, ccs instances) never loads credentials and per-instance credentials sit in Keychain, which re-prompts on ad-hoc builds.|I6
B4|2026-10-22|Spec gap found planning T8: V24 had no room for the public addresses already in the repo (copyright address in `Info.plist` and `README.md`, gh-pages committer in `release.yml`), so the scan would fail on day one.|V24
B5|2026-10-22|Spec gap found planning T14: V25 named the billing model of backfilled records but not which accounts they list. Transcripts and rollouts carry no account id, and ccs instance `projects/` dirs can symlink into one shared context group, so per-file attribution is ambiguous.|V62
B6|2026-10-22|Spec gap found planning T15: V13 said OpenRouter backfilled records store time zone id `UTC`, but I16 `DayRecord` had no zone field; the file's `timeZone` is the local zone.|V13,V18,I16
B7|2026-10-22|Spec gap found planning T15: `/activity` serves only completed UTC days. In zones ahead of UTC the newest sealed key can be the in-progress UTC day, so gap-fill would write a zero record for it and mark it checked forever.|V63
B8|2026-10-22|Found at T16 gate on real history: `ProviderStats.trend` mapped both a missing record and a record with no value for the row's metric to nil, so every backfilled subscription day (no quota, V30) and every metered day with nil cost drew the `·` gap marker. Claude and Codex showed `14/14` days beside 13 gap dots. V42 "days (observed/range)" also read as origin `observed`, while `seenDays` counts backfilled records.|V42,V45,V64
B9|2026-10-22|Found at T16 gate on real history: money strings like `1272.601569999999994351616` and `0.0421083310000085504`. `Decimal(Double)` keeps the full binary expansion, and OpenRouter's baseline delta and the Claude/Codex backfill price sums are float arithmetic. Only the Claude hook path rounded (`%.6f`).|V65
B10|2026-10-25|Spec gap found planning T21: V40 month spend includes the month's sealed days and V41 checks it on every poll, but V20 said the poll path never reads history. Where budget band state lives across relaunch was unstated, and snooze (per provider per day) has no meaning for a monthly or total budget.|V20,V41,V66
B11|2026-10-26|Spec gap found planning T31: V58 sends a budget click to Overview on This month, the teaser to 14 days, and a band, pace, or reset click to a highlighted event, but the V51 URL named only `day` and `provider`. It could not carry a range or an event, and nothing said how a notification knows its route.|V51,V67
B12|2026-10-26|Found at T37 gate on real history: provider detail Split Quota was empty for Claude and Codex. `quotaWindows` read window names from the record (`personal 5h`, `quota`) and looked them up in account quota keyed `5h`/`primary`. Synthetic fixtures used the same keys at both levels, so tests passed.|V54,V68,V69
