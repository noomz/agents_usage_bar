# Compact theme edge cases

Map: [aub CLI themes](../map.md)
Type: grilling
Status: resolved
Blocked by: —

## Question

Pin every rendering rule of the `compact` CLI theme beyond the canvas mock.

Cover: unknown reset (`↻ unknown`); header total that excludes OpenRouter credit spend (label it or include it); sort order and ties; provider/account names longer than the name column; bars with colour off; single-provider view (`aub claude`); `aub quota`; error/unavailable rows; local runtimes line; empty state. Verify in code (zoom as needed) the assumptions behind the mock: Codex primary = 5h / secondary = 7d, and OpenRouter % direction (used vs remaining).

## Comments

### Grilling progress (2026-09-25, in session; not yet resolved)

Mock transcription + rules: [compact-v2-mock.txt](../compact-v2-mock.txt). Research spun off: [OpenRouter usage fields](08-openrouter-usage-fields.md).

Settled so far:
- Q1 bar: 10 cells, eighth-block glyphs.
- Q2 severity line: always printed, zeros included (`0 at ≥80% · 0 at 50–79% · 0 unavailable`).
- Q3/Q5/Q7 width: adaptive. Width = TIOCGWINSZ on TTY, else `$COLUMNS`, else 66 (pipes, tests). Extra columns widen the name column to the longest name first, then the bar up to 20 cells. Narrow: bar shrinks to a 5-cell floor, then names truncate with `…`.
- Q4 window per row: highest-utilisation window, labelled (`5h`, `7d`, `weekly`, `credits`).
- Q6 header: keep; time = `asOf` local HH:mm; no cached marker.
- Q8/Q15 order: fixed, not by severity. Compact applies known-provider order itself (session sort untouched so classic stays byte-identical); user wants a manual re-order facility on top — pending fact on existing order prefs, then clarify.
- Q9 quota view: same row grammar, one row per window, no money column; header = severity line only.
- Q10 single-provider: filtered usage, header totals reflect only the shown provider.
- Q11 empty: zero header + one dim line (`no providers enabled` / `no cached data yet — run aub without --cached`), exit 0.
- Q12 total: Claude + Codex only (code: `hasTokens`), no footnote; OpenRouter money is labelled `left`. User asked for research on OpenRouter day/week/total spend fields → ticket 08.
- Q13 Codex label: derive `5h`/`7d` from window length when the provider keeps it, else raw name (`primary`/`secondary`). Provider change noted for the spec.
- Q14 OpenRouter row: `credits` + `$X left · $Y spent` (today's spend shown too); `no limit`, no bar, when neither key limit nor credits.

Open (waiting on code facts): error/unavailable captions, `↻ unknown` vs reset-now, local runtimes line data, Grok weekly, Codex window-minutes availability, manual order mechanism.

## Answer

Resolved 2026-09-25 after 22 questions (progress log in Comments). Source of truth: [compact-v2-mock.txt](../compact-v2-mock.txt) (canvas board "Compact v2 — winner" + "Output rules"). Code facts from a read-only pass; research on OpenRouter fields in [OpenRouter usage fields](08-openrouter-usage-fields.md).

### Layout
- **Header line 1**: `today $<cost> spent · <tok> tok · HH:mm`. Cost/tokens = Claude + Codex only (providers with `hasTokens`; code rule `contributesToTodayTotal`). Time = `report.asOf` local, no cached marker. Tokens SI-abbreviated (`232.4M`).
- **Header line 2**: severity summary, **always printed with zeros**: `N at ≥80% · N at 50–79% · N unavailable`. Counts every printed bar row (each Claude account separately) and every `!` row.
- **No footnote** about excluded providers; the OpenRouter row's money grammar (`left`) carries that meaning.
- **Rows**: `<glyph> <name> <bar> <pct> <window> ↻ <reset> <money>`. Glyph `▲` ≥80 %, `△` 50–79 %, none <50 %, `!` unavailable. Colour red/yellow/green by the same bands; glyphs carry severity when colour is off.
- **Bar**: 10 cells base, eighth-block glyphs (`▏▎▍▌▋▊▉█`), dim `░` track. `no limit` text and no bar when nothing is capped.
- **Window per row**: the highest-utilisation window, labelled (`5h`, `7d`, `weekly`, `credits`). Codex label derived from window length (needs `QuotaWindow` to keep the parsed `window_minutes`/`limit_window_seconds`; provider change for the spec); falls back to the raw name (`primary`/`secondary`).
- **Reset**: shared countdown phrase without the `Resets ` prefix (`2h 50m`, `3d 8h`, `now`, `<1m`); nil → `↻ unknown`.
- **Money**: Claude/Codex `$X spent`; Grok `no cost data`; OpenRouter `$<balance> left · $<usage_daily> today`. OpenRouter % is consumed: used ÷ key limit when the key has one, else spent ÷ prepaid credits; label `credits`; neither → `no limit`.
- **Labels**: compact owns a short-label table per provider id (OpenRouter, Claude, Codex, Gemini, Grok, Ollama, LM Studio, llama.cpp); `engine.*`/unknown ids use `displayName`. Fixes the live `Claude Code` vs cached `Claude` mismatch inside the theme only.
- **Order**: fixed, never by severity. Compact sorts rows itself by known-provider order (`ProviderID.allKnown`) so cached and live agree; the session sort is untouched (classic byte-identical). A user-set order on top → ticket 09.
- **Claude accounts**: one row per account, alphabetical, `●` on the active one wherever it falls; `Claude` label on the first account row, others indented. No accounts array → a single plain `Claude` row.
- **Error rows**: no snapshot → `!` row replaces the bar row; snapshot present but degraded/stale → bar row plus a `!` line directly under it. Vocabulary: `unauthenticated`, `unavailable` (error/degraded), `stale`. `.disabled` hidden. (Code today has no status branch; compact introduces one.)
- **Local runtimes**: one `local` line: `● name model` (+`+N` when more loaded), `◐ name loading`, `○ name idle`, `○ name stopped`; unconfigured/placeholder and disabled hidden; custom engines by name; wraps onto indented continuation lines when wider than the row.
- **Width**: adaptive. Width = `TIOCGWINSZ` on a TTY, else `$COLUMNS`, else 66 (pipes, tests → deterministic goldens). Extra columns widen the name column to the longest label first, then the bar up to 20 cells. Narrow: bar shrinks to a 5-cell floor, then labels truncate with `…`. Base width is whatever the widest row needs at 12-char names / 10-cell bar; the OpenRouter row (`left · today`) is now the widest, so the spec recomputes the base from it.

### Views
- **`aub quota`**: header = severity line only; one row per window with the same grammar, no money column (Claude 5h and 7d each a row per account; Codex both windows; OpenRouter `credits` plus `day`/`week`/`month` rows from `usage_daily/weekly/monthly`; Gemini per-model windows; Grok billing window).
- **Single provider (`aub claude`)**: filtered usage; header totals and severity counts reflect only the shown provider.
- **Empty**: zero header (`today $0.00 spent · 0 tok · HH:mm`, `0 at ≥80% · 0 at 50–79% · 0 unavailable`) plus one dim line: `no providers enabled` or `no cached data yet — run aub without --cached`. Exit 0.

### Provider changes the spec must carry
1. `QuotaWindow` gains an optional duration; Codex providers keep the parsed window length.
2. OpenRouter snapshot surfaces `usage_daily`, `usage_weekly`, `usage_monthly` (already decoded, unused). `usage_daily` is a UTC day; the header total is local-midnight — spec notes the mismatch.
