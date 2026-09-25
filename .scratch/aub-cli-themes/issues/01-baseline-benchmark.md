# Baseline benchmark

Map: [aub CLI themes](../map.md)
Type: task
Status: resolved
Blocked by: —

## Question

Take the performance baseline of `aub` on `main` before any change.

Measure with `hyperfine` (≥50 runs, warmup) and `/usr/bin/time -l` (peak RSS) for: `aub --cached`, `aub --cached --json`, `aub --cached quota`, and one live `aub` run (for context only). Record machine, build config, toolchain, and noise band (stddev / min-max). Output: a results table and the exact commands, so tickets 02+ reuse them.

## Answer

Baseline taken 2026-09-24 on `main` @ `8f18d6c` (Release, `CODE_SIGNING_ALLOWED=NO`, coverage off), built into an isolated derived-data dir so the installed app was untouched. Raw exports: [hyperfine table](../bench/01-hyperfine-main.md), [hyperfine JSON](../bench/01-hyperfine-main.json), [startup floor](../bench/01-hyperfine-floor.md), [peak RSS runs](../bench/01-rss-main.txt), [live runs](../bench/01-live-main.txt).

**Machine / toolchain**

| | |
|---|---|
| CPU | Apple M4 Max |
| OS | macOS 26.6.2 (25G83) |
| Xcode / Swift | Xcode 26.5 (17F42), Swift 6.3.2 |
| hyperfine | 1.20.0 (`brew install hyperfine`) |
| Cache | `~/Library/Application Support/AgentsUsageBar/today.json` = **2.5 MB**; menu-bar app running during runs |
| Output | stdout to `/dev/null` (non-TTY, so colour off) |

**Wall time** (hyperfine, `--warmup 5 --runs 60 -N`)

| Command | mean ± σ | min … max | user / sys |
|---|---|---|---|
| `aub usage --cached` | 44.9 ± 4.0 ms | 40.1 … 66.0 ms | 30.6 / 5.5 ms |
| `aub usage --cached --json` | 44.6 ± 3.0 ms | 40.0 … 57.4 ms | 30.5 / 5.6 ms |
| `aub quota --cached` | 45.0 ± 6.8 ms | 39.8 … 92.3 ms | 30.1 / 5.8 ms |
| `aub version` (process floor) | 5.6 ± 0.7 ms | 4.6 … 6.9 ms | 3.2 / 1.6 ms |
| `aub settings` | 7.1 ± 0.4 ms | 6.3 … 8.1 ms | 3.5 / 1.7 ms |

**Peak RSS** (`/usr/bin/time -l`, 5 runs each)

| Command | max RSS range |
|---|---|
| `aub usage --cached` | 28.2 … 29.6 MB |
| `aub usage --cached --json` | 27.6 … 28.6 MB |
| `aub quota --cached` | 27.0 … 28.4 MB |
| `aub version` | 11.1 MB |

**Live run** (context only, network-bound): `aub usage` 0.46–0.57 s wall, 64–68 MB peak RSS (3 runs).

**Noise band**: σ = 3–7 ms on the ~45 ms cached commands (≈7–15 %); min–max spread 17–52 ms with hyperfine flagging outliers (busy dev box, menu-bar app polling). Floor commands are tight (σ < 1 ms). RSS run-to-run spread ≈ 2 MB.

**Reading**

- The three rendered outputs are indistinguishable: text vs JSON vs quota differ by < 1 ms mean, well inside σ. Rendering is not where the time goes; ~39 ms above the 5.6 ms process floor is the cached path itself (read + decode of the 2.5 MB `today.json`, plus Foundation/AppKit-free CLI setup).
- Consequence for **02**: a whole-process `hyperfine` A/B cannot resolve a render-path delta smaller than ~3 ms. To compare (a) `aub --json | aub render` vs (b) in-process render, expect path (a) to cost roughly one extra process floor (~6 ms) plus a 4.6 KB JSON round-trip; that *is* resolvable. Sub-ms differences between in-memory theme implementations will need an in-process micro-benchmark (loop the renderer N×10³ over a fixed document) rather than hyperfine.
- Suggested gate wording for later tickets: mean wall time within +1σ (≈ +4 ms) of this baseline on the same machine, and peak RSS within +2 MB; anything inside that band is "no measurable regression".

**Exact commands** (run from repo root; `$B` = the Release binary inside the bench `.app`)

```sh
B=build/dd-bench-main/Build/Products/Release/AgentsUsageBar.app/Contents/MacOS/AgentsUsageBar
xcodebuild build -project AgentsUsageBar.xcodeproj -scheme AgentsUsageBar -configuration Release \
  -derivedDataPath build/dd-bench-main -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CLANG_COVERAGE_MAPPING=NO ENABLE_CODE_COVERAGE=NO -quiet
hyperfine --warmup 5 --runs 60 -N \
  -n 'usage --cached' "$B usage --cached" \
  -n 'usage --cached --json' "$B usage --cached --json" \
  -n 'quota --cached' "$B quota --cached" \
  --export-markdown .scratch/aub-cli-themes/bench/<NN>-hyperfine-<branch>.md
for i in 1 2 3 4 5; do /usr/bin/time -l $B usage --cached >/dev/null; done 2>&1 | grep 'maximum resident'
/usr/bin/time -l $B usage >/dev/null   # live, context only
```

Gotcha: in zsh, `$B $cmd` with `cmd="usage --cached"` passes one argv token, so `AUBMain` misses the subcommand and launches the GUI (hangs forever). Use `${=cmd}` or hyperfine `-N`.
