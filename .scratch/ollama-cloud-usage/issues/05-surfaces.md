# Surfaces: popover + CLI

Map: [Ollama Cloud usage](../map.md)
Type: grilling
Status: resolved
Blocked by: 03, 04

## Question

How the cloud usage appears in the popover row (plan badge, bars) and in `aub` compact/classic/quota views and `--json`, alongside the existing local "model loaded" line.

## Answer (2026-09-28)

- **Popover:** `ollama-cloud` is a remote row, so it uses the standard quota row: status dot, "Ollama Cloud", `mo` bar + percent, `↻` countdown or `↻ unknown`, dashboard button → `https://ollama.com/settings`. No cost/token columns.
- **Tooltip (`tooltipLabel`, Codex/Gemini precedent):** plan name (from `/api/me`, capitalised), "your last 4 weeks: $X" (from `activity.cost`), and the credential source ("via OLLAMA_API_KEY" / "via config" / "via ollama signin"). A label only, never key material.
- **CLI:** compact + classic + quota views and single-provider view render it like any quota row (no new branches); `--json` carries the same window plus raw `plan`, `ownSpendLast4WeeksUSD`, `credentialSource`.
- **Order:** participates in `provider-order`; default slot right after `ollama` in `allKnown`.
