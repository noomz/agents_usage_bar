# Render pipeline prototype

Map: [aub CLI themes](../map.md)
Type: prototype
Status: resolved
Blocked by: 01

## Question

How much does a JSON-document-driven renderer cost?

Prototype two paths behind a throwaway flag: (a) `aub render --theme <name>` reading `UsageJSONDocument` JSON from stdin, i.e. `aub --json | aub render`; (b) plain `aub` building the same document in memory and rendering it directly (no encode/decode). Benchmark both against the 01 baseline with the same commands. Link the prototype branch and numbers.

## Comments

### Prototype results (2026-09-24)

Prototype: branch `prototype/02-render-pipeline` @ `d70aa37`, worktree `~/Projects/aub-proto-02`. Throwaway, every addition marked `// PROTOTYPE 02`. Raw exports: [direct](../bench/02-hyperfine-direct.md), [json](../bench/02-hyperfine-json.md), [pipe](../bench/02-hyperfine-pipe.md), [render-only](../bench/02-hyperfine-render-only.md), [RSS](../bench/02-rss.txt), [in-process bench](../bench/02-bench-render.txt).

**What it does**: `UsageJSONDocument` made `Codable` + internal; adapter doc → `UsageReport`; `aub render` reads the doc from stdin (Path A); hidden `aub bench-render` loops the in-process stages (Path B and pieces).

**Byte identity**: `usage --json` main vs proto identical; `usage --cached` vs `usage --cached --json | render` identical (4/4). Non-round-tripping fields, none affecting current output: status payloads (lastSuccess/error detail), `placeholderMessage`, `tooltipLabel`, `snapshot.asOf`, sub-second dates (can shift a `Resets Xm` by 1 min at a boundary), nil-vs-empty snapshot, `hasTokens`/`isLocal` rebuilt from provider id.

**Wall time** (hyperfine, warmup 5, 60 runs; same box/conditions as 01)

| Command | mean ± σ | min … max |
|---|---|---|
| main `usage --cached` | 42.6 ± 3.3 ms | 39.8 … 63.3 |
| proto `usage --cached` | 42.5 ± 4.1 ms | 39.0 … 72.3 |
| main `usage --cached --json` | 42.6 ± 2.0 ms | 39.5 … 47.9 |
| proto `usage --cached --json` | 44.2 ± 4.0 ms | 39.3 … 60.4 |
| proto `--json \| render` (sh) | 48.5 ± 6.4 ms | 44.4 … 82.5 |
| proto `render < doc.json` | 7.9 ± 0.6 ms | 7.0 … 9.0 |
| proto `version` (floor) | 4.7 ± 0.5 ms | 4.3 … 7.0 |

**Peak RSS**: direct 28.4 MB; `render` alone 14.2 MB; pipeline ≈ 42 MB combined (producer 28–29 + consumer 14).

**In-process** (`bench-render`, 2000 iters, best of 3)

| Stage | mean µs | min µs |
|---|---|---|
| C direct render | 37.7 | 32.6 |
| B doc → adapter → render | 58.3 | 51.7 |
| E JSON encode | 74.4 | 65.1 |
| D JSON decode | 62.7 | 53.7 |
| B2 = E + D + adapter + render | 186.3 | 163.5 |

**Reading**
- Path A (`aub --json | aub render`): **+5.8 ms mean / +5.1 ms min, +14 MB RSS**. Fails the 01 gate (+4 ms, +2 MB). The cost is the second process, not the JSON: encode+decode+adapter is 150 µs.
- Path B (build the JSON document model in memory, render from it): **+20 µs, +0 RSS**. Invisible at process level; passes the gate. So a theme interface that takes the document model costs nothing measurable, as long as it stays in-process.
- Rendering itself (37 µs) is ~1000× smaller than the cached fetch (~38 ms = read + decode of the 2.5 MB `today.json`). Any future CLI speed work goes there, not in themes.
- Consequence for 04: "external themes via `aub --json | tool`" is free for users who opt in (their own process), but `aub render` as a *default* path is out by the gate.

## Answer

Resolved as measured (user confirmed 2026-09-24). See the prototype-results comment above for tables and links.

- **In-process document-driven renderer: free.** Building `UsageJSONDocument` in memory and rendering from it costs +20 µs over today's direct render; no RSS change; invisible at process level (42.5 vs 42.6 ms). A theme interface may take the document model.
- **Separate render process (`aub --json | aub render`): out for the default path.** +5.8 ms mean / +5.1 ms min wall, +14 MB RSS (≈42 MB combined) — fails the 01 gate (+4 ms / +2 MB). The JSON round-trip itself is 150 µs; the cost is the second process (4.7 ms floor + ~3 ms CLI setup).
- Rendering (37 µs) is ~1000× smaller than the cached fetch (~38 ms, read + decode of 2.5 MB `today.json`). Themes cannot move the needle either way; the fetch is where any future CLI speed work lives.
- JSON document does not round-trip status payloads, `placeholderMessage`, `tooltipLabel`, `snapshot.asOf`, sub-second dates, nil-vs-empty snapshot — none affect current output, but 03 must decide whether the theme input is the document (and those fields get added) or the internal report.
- `bench-render`-style in-process timing is the only tool that resolves render-path deltas; hyperfine cannot. Kept as the measurement method for later tickets.

Prototype: `prototype/02-render-pipeline` @ `d70aa37`, worktree `~/Projects/aub-proto-02` (throwaway; not merged).
