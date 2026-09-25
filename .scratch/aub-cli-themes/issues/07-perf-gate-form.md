# Perf gate form

Map: [aub CLI themes](../map.md)
Type: grilling
Status: resolved
Assignee: lazym0m3nt
Blocked by: 03

## Question

What form does the "no measurable regression" gate take once themes ship, and does it run in CI?

01 showed whole-process hyperfine has σ = 7–15 % on a quiet dev box (hosted CI runners are worse), so a wall-time gate in CI is doubtful. 02 showed an in-process micro-benchmark (`bench-render` style: N× render of a fixed document, µs/iter) resolves render deltas reliably. Options: (a) manual hyperfine + RSS at PR time against the 01 baseline, documented in the spec; (b) a Swift Testing perf test asserting `compact` ≤ k× `classic` render time on a fixed fixture, in CI; (c) both. Decide the threshold numbers and whether the 2.5 MB cache-decode cost (the real 38 ms) gets its own guard or stays out of scope.

## Answer

Decided 2026-09-25 (grilling, 8 questions).

**Form**: manual A/B at PR time, results pasted in the PR. **No timing test in CI**: CI runs a Debug build with coverage on shared hosted `macos-15` runners (`.github/workflows/ci.yml`), and #4 already cost a round of timing flakes; render is 37 µs, so the risk is small.

**Baseline**: same-session A/B against a `main` Release build (separate derived-data dirs, one hyperfine invocation). 01's numbers drifted 44.9 → 42.6 ms across days on the same box, so a stored baseline is noisier than the effect; [Baseline benchmark](01-baseline-benchmark.md) stays as reference.

**Pass thresholds** (all must hold)
- HEAD mean ≤ main mean + 2 ms, and HEAD min ≤ main min + 1 ms.
- Peak RSS, max of 5 `/usr/bin/time -l` runs, ≤ main + 2 MB.
- In-process: `compact` render < 1 ms/iter (min-of-N on the fixture).

**Harness**
- `scripts/bench-cli-themes.sh`: builds main + HEAD Release, runs hyperfine (`-N`, warmup 5, 60 runs) and RSS runs, prints pass/fail against the thresholds. `-N` avoids the zsh word-split gotcha from 01.
- Render bench: a Swift Testing test `.enabled(if: AUB_BENCH=1)` reusing 03's fixture builder; skipped in CI and normal runs. Nothing bench-related ships in the binary (no `aub bench-render`).

**Matrix**: `usage --cached`, `quota --cached`, `claude --cached`, `usage --cached --json` — piped (non-TTY), each with `--theme classic` and `--theme compact` on HEAD vs main's plain command; `--json` is a sanity row and must be unchanged; `version` as process floor. The extra `cli-theme` read adds one key lookup to UserDefaults that the usage path already opens (`UserPreferencesStore`, `AUBCommandRun.swift:137`).

**When**: build steps 2 (classic refactor — must be free vs main), 3 (compact) and 4 (selection plumbing) each pass before merge; step 5 is the final full run.

**On fail**: one re-run allowed for noise; a second fail blocks merge — fix it, or record a measured, user-approved exception in the PR. No silent threshold widening.

**Out of scope**: guarding or speeding up the ~38 ms cache decode of `today.json`; the A/B still catches accidental regressions there.
