# Quota mapping and resets

Map: [Ollama Cloud usage](../map.md)
Type: grilling
Status: resolved
Blocked by: 01, 03

## Question

Map `limits.session/weekly/monthly.usage` fractions to `QuotaWindow`s (durations 5h / 7d / 1mo). No reset timestamps in JSON → show `↻ unknown`, or derive (e.g. monthly anchor)? Which window drives the row's worst-window gauge and 80% notification? Legacy vs new plans handled by presence of keys.

## Answer (2026-09-28)

- **Windows:** monthly only. `limits.monthly.usage` → one `QuotaWindow(name: "mo", utilization: fraction, resetsAt: …, duration: 30d)`. Other `limits.*` keys (legacy `session`/`weekly`) are ignored — legacy plans out of scope. Missing `monthly` → row shows no bar (not an error).
- **Meaning:** `limits.monthly.usage` = fraction of the plan's monthly *included usage* (for team plans, the team's shared total). Confirmed against the web page: fraction × plan allowance = the "$X of $Y used" figure.
- **Resets:** the JSON has none, and the web page that shows "Resets in N" needs a browser session (key → 303 to `/signin`). So: optional `[ollama] billing_day = 1…31` in `config.toml`. Set → `resetsAt` = next local-midnight on day N (clamped to the month's last day when N > days in month; forced Gregorian calendar per the Buddhist-calendar gotcha). Unset → `resetsAt = nil` → `↻ unknown`.
- **Display:** percent only (bar + %). No dollar figures: no plan-allowance table, no allowance config.
- **`activity.cost`:** own spend over the rolling last 4 weeks (string decimal USD; distinct from the plan-level monthly usage, which is shared on team plans). Parse as `Decimal`; show only in the row tooltip ("your last 4 weeks: $X") and `--json` raw. Never in the cost column, today totals, or rollups (`hasCost` stays `false`).
- **Threshold:** the `mo` window feeds the existing 80% crossing notification like any quota window.
