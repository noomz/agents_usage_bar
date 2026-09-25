#!/usr/bin/env bash
# CLI themes perf gate (SPEC V33–V36): same-session A/B of `aub` between a
# base ref (default `main`) and the current working tree, both Release.
#
# Usage: bash scripts/bench-cli-themes.sh
#   BASE_REF=main        ref to compare against (checked out in a worktree)
#   THEMES="classic compact"
#                        HEAD runs each command once per `--theme` value;
#                        empty (default) runs HEAD's plain command, for
#                        branches that predate the `--theme` flag.
#   RUNS=60              hyperfine runs per command (warmup 5)
#   OUT=build/bench      build + results directory (gitignored)
#
# Pass (every matrix row): HEAD mean ≤ base mean + 2 ms, HEAD min ≤ base
# min + 1 ms, peak RSS (max of 5) ≤ base + 2 MB. Exits 1 on any fail.
# `--cached` reads the real menu-bar cache, so the app should have run today.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
BASE_REF=${BASE_REF:-main}
THEMES=${THEMES:-}
RUNS=${RUNS:-60}
OUT=${OUT:-$ROOT/build/bench}
BASE_SRC=$OUT/src-base
APP_BIN=Build/Products/Release/AgentsUsageBar.app/Contents/MacOS/AgentsUsageBar

command -v hyperfine >/dev/null || { echo "hyperfine missing: brew install hyperfine" >&2; exit 2; }
mkdir -p "$OUT"

base_sha=$(git -C "$ROOT" rev-parse "$BASE_REF")
if [ -d "$BASE_SRC" ]; then
    git -C "$BASE_SRC" checkout -q --detach "$base_sha"
else
    git -C "$ROOT" worktree add -q --detach "$BASE_SRC" "$base_sha"
fi

build() { # $1 = source dir, $2 = derived-data dir
    xcodebuild build -project "$1/AgentsUsageBar.xcodeproj" -scheme AgentsUsageBar \
        -configuration Release -derivedDataPath "$2" -destination 'generic/platform=macOS' \
        CODE_SIGNING_ALLOWED=NO CLANG_COVERAGE_MAPPING=NO ENABLE_CODE_COVERAGE=NO -quiet
}

if [ "$(cat "$OUT/dd-base.sha" 2>/dev/null)" != "$base_sha" ]; then
    echo "building base $BASE_REF @ ${base_sha:0:7}…"
    build "$BASE_SRC" "$OUT/dd-base"
    echo "$base_sha" > "$OUT/dd-base.sha"
fi
echo "building HEAD (working tree @ $(git -C "$ROOT" rev-parse --short HEAD))…"
build "$ROOT" "$OUT/dd-head"

BASE_BIN="$OUT/dd-base/$APP_BIN" HEAD_BIN="$OUT/dd-head/$APP_BIN" \
THEMES="$THEMES" RUNS="$RUNS" OUT="$OUT" python3 - <<'PY'
import json, os, re, subprocess, sys

base_bin, head_bin = os.environ["BASE_BIN"], os.environ["HEAD_BIN"]
themes = os.environ["THEMES"].split()
runs, out = os.environ["RUNS"], os.environ["OUT"]
matrix = ["usage --cached", "quota --cached", "claude --cached", "usage --cached --json"]
floor = "version"

# (name, argv) pairs; HEAD rows point at the base row they are judged against.
cmds, pairs = [("base " + floor, [base_bin, floor]), ("head " + floor, [head_bin, floor])], []
for c in matrix:
    cmds.append(("base " + c, [base_bin, *c.split()]))
    for t in themes or [None]:
        extra = ["--theme", t] if t else []
        name = f"head {c}" + (f" --theme {t}" if t else "")
        cmds.append((name, [head_bin, *c.split(), *extra]))
        pairs.append((name, "base " + c))

hf_json = os.path.join(out, "hyperfine.json")
args = ["hyperfine", "-N", "--warmup", "5", "--runs", runs, "--style", "basic",
        "--export-json", hf_json, "--export-markdown", os.path.join(out, "hyperfine.md")]
for name, argv in cmds:
    args += ["-n", name, " ".join(argv)]
subprocess.run(args, check=True, stdout=subprocess.DEVNULL)
stats = {r["command"]: r for r in json.load(open(hf_json))["results"]}

def peak_rss(argv):
    best = 0
    for _ in range(5):
        p = subprocess.run(["/usr/bin/time", "-l", *argv], stdout=subprocess.DEVNULL,
                           stderr=subprocess.PIPE, text=True)
        m = re.search(r"(\d+)\s+maximum resident set size", p.stderr)
        best = max(best, int(m.group(1)) if m else 0)
    return best

rss = {name: peak_rss(argv) for name, argv in cmds}

ms, mb = 1000.0, 1024 * 1024
failed = False
print(f"{'command':48} {'Δmean ms':>9} {'Δmin ms':>8} {'ΔRSS MB':>8}  verdict")
for head, base in pairs:
    h, b = stats[head], stats[base]
    d_mean = (h["mean"] - b["mean"]) * ms
    d_min = (h["min"] - b["min"]) * ms
    d_rss = (rss[head] - rss[base]) / mb
    ok = d_mean <= 2.0 and d_min <= 1.0 and d_rss <= 2.0
    failed |= not ok
    print(f"{head:48} {d_mean:+9.2f} {d_min:+8.2f} {d_rss:+8.2f}  {'pass' if ok else 'FAIL'}")
fb, fh = stats["base " + floor], stats["head " + floor]
print(f"floor: base {fb['mean']*ms:.1f} ms / {rss['base ' + floor]/mb:.1f} MB, "
      f"head {fh['mean']*ms:.1f} ms / {rss['head ' + floor]/mb:.1f} MB")
print(f"raw: {hf_json}")
sys.exit(1 if failed else 0)
PY
