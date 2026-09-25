# SPEC — aub CLI themes

Source: wayfinder map `.scratch/aub-cli-themes/map.md`, tickets `.scratch/aub-cli-themes/issues/01–09` (detail lives there; this spec is the contract). Prior spec archived: `docs/specs/claude-dual-limit-glance.md`.

## §G

G1|`aub` text output gets two built-in CLI themes: `compact` (new default, canvas "Compact v2") and `classic` (today's output, byte-identical), with zero measurable perf cost.
G2|User-set provider order shared by `compact` and menu-bar popover.

## §C

C1|Themes compiled in; `enum CLITheme { compact, classic }`, static switch. No loadable themes, no `aub render`, no reflection.
C2|`--json` untouched by this effort: schema, fields, array order.
C3|Colour stays orthogonal: `--no-color` / `NO_COLOR` / `TERM=dumb` / TTY decide colour for every theme.
C4|Menu-bar popover does not follow CLI theme; its only change is provider order (V30–V32).
C5|No App theme changes. No Settings-window controls for CLI theme or provider order in v1.
C6|No perf timing tests in CI (Debug + coverage, hosted runners, #4 flake history). Gate is manual A/B (V33–V36).
C7|Claude accounts not orderable; stay alphabetical.
C8|Cache decode of `today.json` (~38 ms) out of scope.

## §I

I1|CLI usage|`aub`, `aub usage`, `aub <provider>` text output (`AgentsUsageBar/CLI/UsageTextRenderer.swift` = classic, new `CompactTextRenderer.swift`).
I2|CLI quota|`aub quota`, `aub limits` text output.
I3|CLI flag/env|`--theme NAME`, `AUB_THEME` (`AUBCommand.swift`, `AUBCommandRun.swift`).
I4|CLI settings|`aub settings get/set/list` keys `cli-theme`, `provider-order` (`CLISettings.swift`).
I5|CLI themes cmd|`aub themes`, `aub themes --json`.
I6|JSON CLI|`aub --json` (`UsageJSONRenderer.swift`) — unchanged.
I7|Popover|Provider row order in `UI/PopoverRootView.swift`.
I8|Domain|`QuotaWindow` optional duration; OpenRouter snapshot `usage_daily/weekly/monthly`.
I9|Bench|`scripts/bench-cli-themes.sh`; `AUB_BENCH=1`-gated Swift Testing render bench.

## §V

### Renderer model (ticket 03)
V1|Themes render from `UsageReport`, never `UsageJSONDocument`. API: `CLITheme.render(_ report: UsageReport, view: .usage | .quota, color: Bool) -> String`.
V2|Renderer never calls `Date()`; `now` = `report.asOf`.
V3|Shared CLI primitives (bar glyphs, token/USD/percent text, reset phrase, ANSI band) extracted once, called by both themes; row layout owned per theme.
V4|`UsageTextRenderer` is `classic`: not renamed; existing `UsageTextRendererTests` unchanged and green.
V5|`classic` output byte-identical to `main` @ 8f18d6c: full-output golden test (`==`), `renderUsage` + `renderQuota`, colour on and off, rich Swift fixture (Claude multi-account, Codex windows, degraded Gemini, local placeholder, quota-only provider). Golden captured on `main` before any refactor. Fixture builder reused by compact tests.
V6|`--json` output byte-identical to `main` for the same report.

### Compact layout (ticket 05; mock `.scratch/aub-cli-themes/compact-v2-mock.txt`)
V7|Header 1: `today $<cost> spent · <tok> tok · HH:mm`; cost/tokens = providers with `contributesToTodayTotal` (Claude + Codex); tokens SI-abbreviated; time = `report.asOf` local; no cached marker.
V8|Header 2 always printed, zeros included: `N at ≥80% · N at 50–79% · N unavailable`; counts every printed bar row (each Claude account) and every `!` row.
V9|Row grammar: `<glyph> <name> <bar> <pct> <window> ↻ <reset> <money>`. Glyph `▲` ≥80 %, `△` 50–79 %, blank <50 %, `!` unavailable. Colour red/yellow/green by same bands; glyph carries severity with colour off. Cut-offs are compact's own, on consumed fraction (exactly 80 % = `▲` red); popover `QuotaBand` untouched.
V10|Bar: 10 cells base, eighth blocks `▏▎▍▌▋▊▉█`, dim `░` track. Nothing capped → text `no limit`, no bar.
V11|Window per row = highest-utilisation window, labelled `5h`/`7d`/`weekly`/`credits`; Codex label from `QuotaWindow` duration, fallback raw name (`primary`/`secondary`).
V12|Reset = shared countdown phrase without `Resets ` prefix (`2h 50m`, `3d 8h`, `now`, `<1m`); nil → `↻ unknown`.
V13|Money: Claude/Codex `$X spent`; Grok `no cost data`; OpenRouter `$<balance> left · $<usage_daily> today`. OpenRouter % = consumed: used ÷ key limit, else spent ÷ prepaid credits; label `credits`; neither → `no limit`.
V14|Compact owns short-label table per provider id (OpenRouter, Claude, Codex, Gemini, Grok, Ollama, LM Studio, llama.cpp); `engine.*`/unknown → `displayName`. Live and cached labels identical.
V15|Row order: never by severity; compact sorts rows itself via shared provider-order helper (V31); session sort untouched.
V16|Claude accounts: one row per account, alphabetical, `●` on the active-constraint account (`quotaGlance.active.accountName`, classic's `Active:`); `Claude` header row first (combined cost, no bar/%, not counted in severity line), then every account row indented the same; quota view: header row, then per account its 5h/7d rows; no accounts → single `Claude` row.
V17|Error rows: no snapshot → `!` row replaces bar row; snapshot degraded/stale → bar row + `!` line under it. Words: `unauthenticated`, `unavailable`, `stale`. `.disabled` hidden.
V18|Local line: one `local` line — `● name model` (`+N` more loaded), `◐ name loading`, `○ name idle`, `○ name stopped`; unconfigured/placeholder/disabled hidden; custom engines by name; wraps to indented continuation lines.
V19|Width: `TIOCGWINSZ` on TTY, else `$COLUMNS`, else 66 (pipes/tests deterministic). Extra width widens name column to longest label, then bar up to 20 cells. Narrow: bar shrinks to 5-cell floor, then labels truncate with `…`. Base width recomputed from widest row (OpenRouter `left · today`).
V20|`aub quota` compact: header = severity line only; one row per window, same grammar, no money (Claude 5h + 7d per account; Codex both; OpenRouter `credits` + `day`/`week`/`month` rows showing `$X spent` in the bar's place (no bar, no %, not counted in severity line); Gemini per model; Grok billing).
V21|Single provider (`aub claude`): filtered usage view; header totals + severity counts cover shown provider only.
V22|Empty: zero headers + one dim line `no providers enabled` or `no cached data yet — run aub without --cached`; exit 0.
V23|`QuotaWindow` gains optional duration; Codex providers keep parsed `window_minutes`/`limit_window_seconds`. OpenRouter snapshot surfaces `usage_daily/weekly/monthly`; spec note: `usage_daily` is UTC day, header total is local-midnight.

### Selection (ticket 06)
V24|Precedence: `--theme` > `AUB_THEME` > `cli-theme` setting > `compact`. Names case-insensitive; canonical lowercase.
V25|`--theme NAME` only (no `=`, no short form); in `AUBCommand.knownTokens`; accepted on any command, ignored where irrelevant; value validated at parse. Unknown → `AUBParseError.unknownTheme`: `error: unknown CLI theme 'x'; expected compact|classic`, exit 2.
V26|`AUB_THEME=""` = unset; invalid → same error prefixed `AUB_THEME:`, exit 2. Env + setting read lazily, text path only: `--json`, `settings`, `install` never read them.
V27|`cli-theme` setting: default `compact`; bad `set` → `invalid value 'x' for cli-theme; expected compact|classic`, exit 2; `set` stores + echoes lowercase; `get` = stored value only; garbage in UserDefaults → silent fallback `compact`.
V28|`aub themes`: row per theme — `●` on active, name, one-liner, `(default)` on compact — then `active: <name> (from flag|AUB_THEME|setting|default)`; full resolution runs (flag/env honoured, invalid env errors). `--json` → `{"themes":[{"name","description","default"}],"active","source":"flag|env|setting|default"}`. Extra arg → unexpected-argument, exit 2. Listed in help + `isSubcommand`.
V29|Help text: `--theme NAME    CLI theme: compact (default) | classic` + env line naming `AUB_THEME` and `NO_COLOR`.

### Provider order (ticket 09)
V30|UserDefaults key `provider-order`: comma list of `ProviderID.rawValue` (incl. `engine.<slug>`). `set` rejects id not in `allKnown` nor configured `engine.*`, and duplicates → exit 2 listing valid ids; case-insensitive, stored + echoed lowercase. `set provider-order ""` removes key. `get` = stored list, or full `allKnown` when unset.
V31|One shared ordering helper: listed ids first in given order; then unlisted in `allKnown` order; then `engine.*` alphabetical by slug. Stale ids skipped silently at read.
V32|Order honoured by compact (V15) + popover only. Popover drops alphabetical `displayName` sort, uses helper (unset → `allKnown`); change visible on next popover open. `classic`, `--json` array, Settings Providers tab, Welcome keep `allKnown`.

### Perf gate (ticket 07; baseline ticket 01)
V33|Same-session A/B: HEAD vs `main` Release builds, separate derived-data dirs, one hyperfine run (`-N`, warmup 5, 60 runs). Pass: HEAD mean ≤ main mean + 2 ms AND HEAD min ≤ main min + 1 ms, every matrix row.
V34|Peak RSS (max of 5 `/usr/bin/time -l`) ≤ main + 2 MB, every matrix row.
V35|In-process: `compact` render < 1 ms/iter (min-of-N, V5 fixture), `AUB_BENCH=1` Swift Testing test; skipped in CI + normal runs. Nothing bench-related ships in binary.
V36|Matrix: `usage --cached`, `quota --cached`, `claude --cached`, `usage --cached --json` (piped), each `--theme classic` and `--theme compact` on HEAD vs main's plain command; `version` floor. Gate runs at T2, T3, T4 before merge and T6 final. One re-run for noise; second fail blocks merge unless PR records measured, user-approved exception. No silent threshold widening.

## §T

id|status|task|cites
T1|x|Capture classic golden on `main` before refactor: Swift fixture builder + full-output `==` tests for `renderUsage`/`renderQuota`, colour on/off; also JSON golden for same fixture|V4,V5,V6,I1,I2,I6
T2|x|Extract shared CLI primitives; add `CLITheme` enum with `classic` only routed through it; goldens green; add `scripts/bench-cli-themes.sh` + gate run vs main|V1,V2,V3,V4,V5,V6,V33,V34,V36,I9
T3|x|Build `CompactTextRenderer` (usage, quota, single, empty views; width; labels; errors; local line) + provider changes (`QuotaWindow` duration, OpenRouter daily/weekly/monthly); compact goldens at 66 cols; `AUB_BENCH` render bench; gate run|V7,V8,V9,V10,V11,V12,V13,V14,V15,V16,V17,V18,V19,V20,V21,V22,V23,V35,V33,V34,I1,I2,I8,I9
T4|.|Selection plumbing: `--theme`, `AUB_THEME`, `cli-theme` setting, `aub themes` (+`--json`), help text, compact as default; parser + settings tests; gate run|V24,V25,V26,V27,V28,V29,V33,V34,V36,I3,I4,I5
T5|.|Provider order: shared ordering helper, `provider-order` setting + validation, compact + popover adopt helper; tests incl. classic/json order unchanged|V15,V30,V31,V32,V5,V6,I4,I7
T6|.|Final full perf gate run on HEAD vs main; results in PR|V33,V34,V35,V36,I9

## §B

id|date|cause|fix
