# Map: aub CLI themes

Label: wayfinder:map

## Destination

A spec, ready to implement, for **CLI themes** in `aub`: `compact` (new default, the blind-vote winner "Compact v2" on the design canvas) and `classic` (today's output, byte-identical), selectable by `--theme` > `AUB_THEME` > `cli-theme` setting > `compact`. Hard gate: no measurable wall-time or peak-RSS regression vs the `main` baseline. Widened 2026-09-25: one popover change rides along — a user-set provider order shared by `compact` and the menu-bar popover (ticket 09).

## Notes

- Domain: `aub` CLI output rendering (`AgentsUsageBar/CLI/UsageTextRenderer.swift`, `AUBCommand.swift`, `CLISettings.swift`, `UsageJSONRenderer.swift`). Glossary: root `CONTEXT.md` (**CLI theme** vs **App theme**).
- Design source of truth: canvas https://claude.ai/artifact/6GLyBUiMZ2KWUpeRUwnWEk — board "Compact v2 — winner" plus the vote-results sticky.
- Skills for grilling tickets: `mattpocock-skills:grilling` + `mattpocock-skills:domain-modeling`.
- Standing preferences:
  - CLI must stay fast: no slower, no more memory. Every perf claim is measured (`hyperfine`, `/usr/bin/time -l`) against the `main` baseline; `--cached` isolates rendering from network noise.
  - Themes are built-in and compiled in; theme choice is a static switch (no reflection, no runtime template loading) unless ticket 04 proves otherwise at zero cost.
  - `--json` ignores CLI theme and is untouched by this effort. `classic` byte-identity is guarded by a new full-output golden test captured on `main` before any refactor (existing `UsageTextRendererTests` are substring asserts, not golden — corrected by 03).
  - GSD is deprecated for this repo — do not route handoff through GSD.
- Settled at charting (grilling rounds 1–2): planning-only map; theme = whole layout (colour on/off stays orthogonal via `--no-color`/`NO_COLOR`/TTY); ship `compact` + `classic`; applies to `aub`/`usage`/`quota`/single-provider view; CLI only (menu bar popover untouched); name "CLI theme", setting key `cli-theme`, flag `--theme`, env `AUB_THEME`.

## Decisions so far

<!-- one line per resolved ticket: [title](issues/NN-slug.md): gist -->
- [Baseline benchmark](issues/01-baseline-benchmark.md): `main` @ 8f18d6c on M4 Max — cached usage/json/quota all ≈45 ms ± 3–7 ms, 27–30 MB peak RSS; process floor 5.6 ms / 11 MB; rendering cost invisible at hyperfine resolution (02 needs in-process timing for sub-ms deltas). Commands + raw exports in `bench/`.
- [Render pipeline prototype](issues/02-render-pipeline-prototype.md): in-process document-driven render is free (+20 µs, +0 RSS); `aub --json | aub render` costs +6 ms / +14 MB and fails the gate — out for the default path. Render is ~1000× smaller than the 38 ms cache decode. Branch `prototype/02-render-pipeline` @ d70aa37.
- [Renderer input model](issues/03-renderer-input-model.md): themes render from `UsageReport` (not the JSON doc); `enum CLITheme { compact, classic }` with `render(report, view: usage|quota, color:)`; single-provider = filtered usage view; `now` = `report.asOf`; shared CLI formatting primitives, layout per theme; `color: Bool` kept; `UsageTextRenderer` stays as classic + new `CompactTextRenderer`; full-output golden test with a Swift fixture builder guards classic.
- [Custom themes scope](issues/04-custom-themes-scope.md): custom CLI themes out of scope; only `compact` + `classic`, compiled in. User layouts go through `aub --json | tool`; no `aub render`, no loadable theme files, no `--json` enrichment now.
- [Compact theme edge cases](issues/05-compact-theme-edge-cases.md): every compact rendering rule pinned — header (Claude+Codex total, always-on severity line), row grammar and glyphs, 10-cell eighth-block bars, worst-window-per-row with derived Codex `5h/7d`, `↻ unknown`, error rows in place, local line, Claude account rows (alphabetical, ● active), fixed known-provider order, adaptive width (TTY → widen names then bar; 66 when piped), quota/single/empty views. Two provider changes carried: `QuotaWindow` duration; OpenRouter `usage_daily/weekly/monthly` surfaced.
- [Theme selection ux](issues/06-theme-selection-ux.md): `--theme NAME` (validated at parse on any command) > `AUB_THEME` (empty=unset) > `cli-theme` setting > `compact`; unknown flag/env name = exit 2 listing names; names case-insensitive, stored lowercase; env+setting read lazily on the text path only; new `aub themes` (+`--json`) shows names and the active theme with its source; no Settings-window picker.
- [Perf gate form](issues/07-perf-gate-form.md): manual same-session A/B vs a `main` Release build at build steps 2–4 (no CI timing test); pass = mean +2 ms, min +1 ms, RSS +2 MB, compact render < 1 ms/iter; harness `scripts/bench-cli-themes.sh` + `AUB_BENCH=1`-gated Swift Testing bench; second fail blocks merge.
- [Provider order setting](issues/09-provider-order-setting.md): UserDefaults `provider-order` comma list, set-time validation (unknown/dup → exit 2, lowercase), stale ids skipped at read; listed first, rest in `allKnown` then `engine.*` by slug; accounts stay alphabetical; honoured by compact + popover only (popover drops alphabetical sort, defaults to `allKnown`); CLI-only writer; `set ""` resets.
- [OpenRouter usage fields](issues/08-openrouter-usage-fields.md): `GET /api/v1/key` (normal key) returns all-time `usage`, `usage_daily` (UTC day), `usage_weekly`, `usage_monthly`, `limit`, `limit_remaining`, `limit_reset`; `/credits` and `/activity` need a management key. aub decodes the daily/weekly/monthly fields but shows none. Findings: `research/08-openrouter-usage-fields.md`.

## Not yet specified

_Empty — every ticket closed 2026-09-25; the way to the spec is clear._

Build order for the spec (from 03, uncontested, extended by 06/07/09):
1. Golden capture of `classic` full output on `main` (Swift fixture builder).
2. Extract shared CLI formatting primitives + `CLITheme` enum with `classic` only; golden green; perf gate vs `main`.
3. `CompactTextRenderer` per [Compact theme edge cases](issues/05-compact-theme-edge-cases.md), incl. `QuotaWindow` duration and surfacing OpenRouter `usage_daily/weekly/monthly`; perf gate.
4. Selection plumbing per [Theme selection ux](issues/06-theme-selection-ux.md): `--theme`, `AUB_THEME`, `cli-theme`, `aub themes`; perf gate.
5. Provider order per [Provider order setting](issues/09-provider-order-setting.md): shared ordering helper, `provider-order` setting, compact + popover adopt it.
6. Final full perf run per [Perf gate form](issues/07-perf-gate-form.md).

## Out of scope

- Proposed-default table as a `-v`/verbose theme, and the other canvas layouts (Sentences, Ledger, Panels, Hybrid) as shipped themes.
- Menu bar popover following the CLI theme (the shared provider *order* of ticket 09 is the one popover change in scope).
- App theme (light/dark/auto) changes.
- User-defined CLI themes — loadable theme files and an `aub render` process — ruled out by [Custom themes scope](issues/04-custom-themes-scope.md): unmeasured/failed-gate cost, contradicts static switch.
- Enriching `--json` with the text renderer's derived fields for external-tool parity with `compact` — separate effort if ever wanted (same ticket).
- Guarding or speeding up the ~38 ms `today.json` cache decode — themes don't touch it; own effort if wanted ([Perf gate form](issues/07-perf-gate-form.md)).
