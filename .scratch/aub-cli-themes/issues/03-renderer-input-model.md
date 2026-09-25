# Renderer input model

Map: [aub CLI themes](../map.md)
Type: grilling
Status: resolved
Blocked by: 02

## Question

What is the single input a CLI theme renders from — the JSON document model (`UsageJSONDocument`) or the internal snapshot types the current renderer uses — and what is the theme interface (e.g. `(Document, ColorMode) -> String`)?

Must keep `classic` byte-identical and pass the perf gate per 02's numbers.

## Answer

Grilled 2026-09-24/25 (two rounds, user answered each point). Facts came from a read-only pass over `UsageTextRenderer.swift`, `UsageJSONRenderer.swift`, `CLIUsageSession.swift`, Domain types and `CLITests/`.

**Decisions**

1. **Input = `UsageReport`** (the internal struct today's renderer consumes). Not `UsageJSONDocument`, not a new render model. Reasons: `classic` already reads it, so byte-identity is trivial; the renderer reads ~8 derived members the JSON lacks (`quotaGlance`, `displayedQuota`, `quotaUsageCaption`, `localSecondaryCaption`, `placeholderMessage`, degraded tag via `raw["note"]`, `isLocal`, `hasAnyQuotaOnlyProvider`), which a document-driven design would push into the public `--json` contract; 02 showed the doc path buys nothing on the default path. `--json` stays a separate projection and is **untouched** by this effort (04 may revisit for external themes).
2. **Interface**: `enum CLITheme { case compact, classic }` with `render(_ report: UsageReport, view: .usage | .quota, color: Bool) -> String`. Static switch dispatch. Single-provider (`aub claude`) is the `usage` view with a one-row filter, header included; a distinct one-provider layout exists only if 05 finds one on the canvas.
3. **`now`** is `report.asOf` (renderer never calls `Date()`; fact from code). Themes inherit this; deterministic for tests.
4. **Primitives shared, layout per theme.** A CLI formatting helper (bar glyphs, token/USD/percent text, reset countdown wrapper, ANSI band) is extracted and called by both themes. Row/line layout lives inside each theme. Domain helpers already shared with the app (`ResetCountdown`, `QuotaBand`, `QuotaGlance`, captions) stay where they are.
5. **Colour**: keep `color: Bool`; themes emit ANSI through the shared band helper. No styling sink.
6. **Naming**: `UsageTextRenderer` stays and *is* `classic` (no rename, tests untouched); `CompactTextRenderer` is new; `CLITheme` switches between them.
7. **Byte-identity guard**: a full-output golden test, captured on `main` *before* any refactor, asserting `==` for `renderUsage` and `renderQuota`, colour on and off, over a rich fixture (Claude multi-account, Codex windows, degraded Gemini, local placeholder row, quota-only provider). Fixture is a Swift builder in test code, reused later by `compact` tests. **Premise fix**: the existing `UsageTextRendererTests` are substring asserts (9 tests), not a golden suite — the map Notes were wrong.

**Facts recorded for other tickets**
- Renderer ignores `report.source`; cached and live text identical.
- Codex "primary/secondary" names come from the Codex provider's window names, not the model or renderer (05 must open the provider).
- Only consumer of `source` is the JSON encoder.
