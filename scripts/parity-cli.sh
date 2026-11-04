#!/usr/bin/env bash
#
# parity-cli.sh: byte-for-byte comparison of the Swift `aub` and the Go `aub`.
#
#   scripts/parity-cli.sh                 run every case
#   scripts/parity-cli.sh stats           run cases whose name contains "stats"
#
# Env:
#   SWIFT_AUB     Swift binary, must be invoked as `aub` (default: `command -v aub`)
#   GO_AUB        Go binary (default: built from cli/ into the scratch dir)
#   PARITY_DIR    scratch dir for outputs (default: a new temp dir, never in the repo)
#   PARITY_LINES  diff lines printed per case (default 40; the full diff stays on disk)
#
# Cases named home-* run both binaries against synthetic homes from scripts/parity-fixtures.py,
# through HOME and CFFIXED_USER_HOME. Preferences and locale still come from the real user;
# every subcommand here only reads them.
#
# Compares stdout, stderr, and exit code. Normalizes only `asOf` and `exportedAt` JSON
# values. A case runs up to 3 times because the two binaries start at different instants:
# a reset countdown or header clock can tick, and the app can rewrite today.json, between
# them. A real difference repeats on every attempt.
#
# Only read-only subcommands run against the Swift binary, which is the user's real install.
#
# Exit 0 only when no difference remains outside scripts/parity-cli.allow, whose lines are
# `case-name | reason`.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALLOW="$ROOT/scripts/parity-cli.allow"
FILTER="${1:-}"
LINES_PER_DIFF="${PARITY_LINES:-40}"

SWIFT_AUB="${SWIFT_AUB:-$(command -v aub || true)}"
if [[ -z "$SWIFT_AUB" || ! -x "$SWIFT_AUB" ]]; then
  echo "parity: no Swift aub found; set SWIFT_AUB" >&2
  exit 2
fi
if [[ "$(basename "$SWIFT_AUB")" != "aub" ]]; then
  echo "parity: SWIFT_AUB must be named aub, or the app binary opens its GUI: $SWIFT_AUB" >&2
  exit 2
fi

OUT="${PARITY_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/aub-parity.XXXXXX")}"
mkdir -p "$OUT"

if [[ -z "${GO_AUB:-}" ]]; then
  GO_AUB="$OUT/go-bin/aub"
  (cd "$ROOT/cli" && go build -o "$GO_AUB" ./cmd/aub) || { echo "parity: go build failed" >&2; exit 2; }
fi

echo "swift: $SWIFT_AUB ($("$SWIFT_AUB" --version 2>/dev/null))"
echo "go:    $GO_AUB"
echo "out:   $OUT"

if [[ -f "$ALLOW" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" != *" | "?* ]]; then
      echo "parity: allowlist entry has no reason: $line" >&2
      exit 2
    fi
  done <"$ALLOW"
fi

allow_reason() {
  [[ -f "$ALLOW" ]] || return 1
  local line
  while IFS= read -r line; do
    if [[ "$line" == "$1 | "* ]]; then
      printf '%s' "${line#*" | "}"
      return 0
    fi
  done <"$ALLOW"
  return 1
}

normalize() {
  sed -E 's/("(asOf|exportedAt)" : )"[^"]*"/\1"<time>"/' "$1" >"$1.norm"
}

# Each case: name, then env assignments as NAME=VALUE, then `--`, then arguments.
CASES=()
add() { CASES+=("$(printf '%s\x1f' "$@")"); }

for theme in compact classic; do
  add "usage-$theme" -- usage --cached --theme "$theme" --no-color
  add "quota-$theme" -- quota --cached --theme "$theme" --no-color
  add "limits-$theme" -- limits --cached --theme "$theme" --no-color
  add "usage-$theme-all" -- usage --cached --theme "$theme" --no-color --provider all
  add "quota-$theme-all" -- quota --cached --theme "$theme" --no-color --provider all
  add "env-theme-usage-$theme" AUB_THEME="$theme" -- usage --cached --no-color
  for id in openrouter claude codex gemini grok pi-local ollama ollama-cloud lmstudio lms-llamacpp llamacpp; do
    add "usage-$theme-$id" -- usage "$id" --cached --theme "$theme" --no-color
    add "quota-$theme-$id" -- quota "$id" --cached --theme "$theme" --no-color
  done
done
for width in 40 60 80 110 200; do
  add "usage-compact-w$width" COLUMNS="$width" -- usage --cached --theme compact --no-color
  add "quota-compact-w$width" COLUMNS="$width" -- quota --cached --theme compact --no-color
done
add usage-json -- usage --cached --json
add quota-json -- quota --cached --json
add usage-json-all -- usage --cached --json --provider all
add quota-json-all -- quota --cached --json --provider all
for id in openrouter claude codex gemini grok pi-local ollama lmstudio llamacpp nosuch; do
  add "usage-json-$id" -- usage "$id" --cached --json
  add "quota-json-$id" -- quota "$id" --cached --json
done
add bare-flag-cached -- --cached --no-color
add bare-provider -- claude --cached --no-color
add provider-flag -- --provider claude --cached --no-color
add no-color-env NO_COLOR=1 -- usage --cached
add term-dumb TERM=dumb -- usage --cached

add stats-default -- stats
add stats-no-color -- stats --no-color
add stats-all -- stats --provider all
add stats-all-pos -- stats all
for days in 1 2 7 14 30 31 60 90 400; do
  add "stats-days-$days" -- stats --days "$days"
  add "stats-days-$days-all" -- stats --days "$days" --provider all
done
add stats-since -- stats --since 2026-10-01
add stats-until -- stats --until 2026-10-15
add stats-since-until -- stats --since 2026-10-01 --until 2026-10-07
add stats-since-days -- stats --since 2026-10-01 --days 5
add stats-until-days -- stats --until 2026-10-15 --days 5
add stats-future-until -- stats --since 2026-11-01 --until 2099-01-01
add stats-past -- stats --since 2020-01-01 --until 2020-01-05
add stats-theme-ignored -- stats --theme classic
for id in openrouter claude codex gemini grok pi-local ollama ollama-cloud lmstudio lms-llamacpp llamacpp engine.nosuch; do
  add "stats-$id" -- stats "$id"
  add "stats-$id-90" -- stats "$id" --days 90
  add "stats-flag-$id" -- stats --provider "$id" --days 7
  add "stats-json-$id" -- stats "$id" --json
  add "stats-csv-$id" -- stats "$id" --csv
done
add stats-json -- stats --json
add stats-json-days -- stats --json --days 3
add stats-json-since -- stats --json --since 2026-10-01 --until 2026-10-07
for table in days accounts events quota; do
  add "stats-csv-$table" -- stats --csv "$table"
  add "stats-csv-$table-days" -- stats --csv "$table" --days 7
  add "stats-csv-$table-claude" -- stats claude --csv "$table"
done
add stats-csv-provider-as-value -- stats --csv claude

# @tty runs under a pseudo-terminal, which turns colour on and exercises terminal detection.
for theme in compact classic; do
  add "tty-usage-$theme" -- @tty usage --cached --theme "$theme"
  add "tty-quota-$theme" -- @tty quota --cached --theme "$theme"
done
add tty-usage-w60 COLUMNS=60 -- @tty usage --cached --theme compact
add tty-usage-no-color -- @tty usage --cached --no-color
add tty-usage-no-color-env NO_COLOR=1 -- @tty usage --cached
add tty-usage-dumb TERM=dumb -- @tty usage --cached
add tty-usage-all -- @tty usage --cached --provider all
add tty-stats -- @tty stats
add tty-stats-all -- @tty stats --provider all
add tty-stats-30 -- @tty stats --days 30
add tty-stats-90 -- @tty stats --days 90
add tty-stats-claude -- @tty stats claude
add tty-stats-codex -- @tty stats codex --days 30
add tty-stats-ollama -- @tty stats ollama

add themes -- themes
add themes-json -- themes --json
add themes-flag -- themes --theme classic
add themes-flag-json -- themes --json --theme classic
add themes-env AUB_THEME=classic -- themes
add themes-env-json AUB_THEME=CLASSIC -- themes --json
add themes-env-empty AUB_THEME= -- themes

add settings -- settings
add settings-json -- settings --json
add settings-list-theme-flag -- settings --theme classic
add err-settings-list-verb -- settings list
add err-settings-list-verb-json -- settings list --json
for key in refresh-interval threshold theme cli-theme provider-order pace-warnings reset-notifications \
  claude-source open-at-login has-seen-welcome provider.claude.enabled provider.gemini.enabled \
  provider.ollama-cloud.enabled provider.lms-llamacpp.enabled provider.pi-local.enabled; do
  add "settings-get-$key" -- settings get "$key"
done
add settings-get-json -- settings get theme --json

add help-long -- --help
add help-short -- -h
add help-word -- help
add help-wins -- usage --nope --help

add err-unknown-flag -- --frobnicate
add err-unknown-command -- frobnicate
add err-unknown-provider -- usage nope
add err-provider-flag -- --provider nope
add err-provider-missing -- --provider
add err-prefix-missing -- --prefix
add err-theme-missing -- --theme
add err-theme-bad -- --theme fancy
add err-theme-equals -- --theme=classic
add err-theme-env AUB_THEME=fancy -- usage --cached
add err-theme-env-themes AUB_THEME=fancy -- themes
add ok-theme-env-json AUB_THEME=fancy -- usage --cached --json
add err-usage-extra -- usage claude codex
add err-quota-extra -- quota claude codex
add err-provider-extra -- claude codex
add err-days-bad -- stats --days 0
add err-days-word -- stats --days nope
add err-days-negative -- stats --days -3
add err-days-missing -- stats --days
add err-days-on-usage -- usage --days 3
add err-since-bad -- stats --since 2026-13-01
add err-since-feb30 -- stats --since 2026-02-30
add err-since-shape -- stats --since 20261001
add err-since-missing -- stats --since
add err-until-bad -- stats --until nope
add err-until-on-quota -- quota --until 2026-10-01
add err-empty-range -- stats --since 2026-10-05 --until 2026-10-01
add err-range-three -- stats --since 2026-10-01 --until 2026-10-05 --days 2
add err-csv-json -- stats --json --csv
add err-csv-on-usage -- usage --csv
add err-stats-provider -- stats nope
add err-stats-extra -- stats claude codex
add err-settings-get-missing -- settings get
add err-settings-get-extra -- settings get theme extra
add err-settings-set-missing -- settings set
add err-settings-set-value -- settings set theme
add err-settings-set-extra -- settings set theme dark extra
add err-settings-set-unknown -- settings set nope 1
add err-settings-set-interval -- settings set refresh-interval 7m
add err-settings-set-threshold -- settings set threshold 0.40
add err-settings-set-threshold-word -- settings set threshold high
add err-settings-set-theme -- settings set theme neon
add err-settings-set-cli-theme -- settings set cli-theme fancy
add err-settings-set-bool -- settings set pace-warnings maybe
add err-settings-set-source -- settings set claude-source nope
add err-settings-set-order -- settings set provider-order codex,nope
add err-settings-set-order-dup -- settings set provider-order codex,Codex
add err-settings-get-unknown -- settings get nope
add err-settings-verb -- settings frob
add err-themes-extra -- themes classic
add err-install-extra -- install extra
add err-uninstall-extra -- uninstall extra
add err-dashboard-provider -- dashboard nope
add err-dashboard-extra -- dashboard claude codex

HOMES="$OUT/homes"
[[ -d "$HOMES" ]] && chmod -R u+rwx "$HOMES"
rm -rf "$HOMES"
python3 "$ROOT/scripts/parity-fixtures.py" "$HOMES" || { echo "parity: fixtures failed" >&2; exit 2; }

# Foundation strips /private from paths it prints, so homes use the symlink form on both sides.
HOME_ROOT="${HOMES#/private}"

in_home() { # home-name case-suffix args...
  local home="$1" suffix="$2"; shift 2
  add "home-$home-$suffix" "HOME=$HOME_ROOT/$home" "CFFIXED_USER_HOME=$HOME_ROOT/$home" -- "$@"
}

for home in full variants grok-balance grok-nothing openrouter-no-cost schema1 schema2 schema9 corrupt bad-row empty history-file history-noperm; do
  for theme in compact classic; do
    in_home "$home" "usage-$theme" usage --cached --no-color --theme "$theme"
    in_home "$home" "quota-$theme" quota --cached --no-color --theme "$theme"
    in_home "$home" "usage-all-$theme" usage --cached --no-color --theme "$theme" --provider all
    in_home "$home" "quota-all-$theme" quota --cached --no-color --theme "$theme" --provider all
  done
  in_home "$home" usage-json usage --cached --json
  in_home "$home" usage-json-all usage --cached --json --provider all
  in_home "$home" quota-json-all quota --cached --json --provider all
  in_home "$home" tty-usage @tty usage --cached
  in_home "$home" tty-usage-classic @tty usage --cached --theme classic
  in_home "$home" tty-quota @tty quota --cached
  in_home "$home" themes themes
  in_home "$home" settings settings
  in_home "$home" settings-json settings --json
  in_home "$home" stats stats --since 2026-09-01 --until 2026-09-14
  in_home "$home" stats-all stats --since 2026-09-01 --until 2026-09-30 --provider all
  in_home "$home" stats-default stats
  in_home "$home" stats-tty @tty stats --since 2026-09-01 --until 2026-09-14
  in_home "$home" stats-json stats --json --since 2026-09-01 --until 2026-09-03
  in_home "$home" stats-json-default stats --json
  for id in claude codex openrouter ollama engine.box mystery; do
    in_home "$home" "stats-$id" stats "$id" --since 2026-09-01 --until 2026-09-14
    in_home "$home" "stats-json-$id" stats "$id" --json --since 2026-09-20 --until 2026-09-22
  done
  in_home "$home" stats-claude-tty @tty stats claude --since 2026-09-01 --until 2026-09-14
  for table in days accounts events quota; do
    in_home "$home" "stats-csv-$table" stats --csv "$table" --since 2026-09-01 --until 2026-09-14
  done
done
for width in 30 40 50 60 70 80 100 120 200; do
  for home in full variants; do
    add "home-$home-w$width" "HOME=$HOME_ROOT/$home" "CFFIXED_USER_HOME=$HOME_ROOT/$home" "COLUMNS=$width" -- usage --cached --no-color --theme compact --provider all
    add "home-$home-quota-w$width" "HOME=$HOME_ROOT/$home" "CFFIXED_USER_HOME=$HOME_ROOT/$home" "COLUMNS=$width" -- quota --cached --no-color --theme compact --provider all
  done
done

pass=0; allowed=0; failed=0; total=0

run_side() { # dir binary env... -- args...
  local dir="$1" bin="$2"; shift 2
  local envs=()
  while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  mkdir -p "$dir"
  local launcher=("$bin") tty=0
  if [[ "${1:-}" == "@tty" ]]; then
    shift
    launcher=(script -q /dev/null "$bin")
    tty=1
  fi
  env -u COLUMNS -u NO_COLOR -u AUB_THEME ${envs[@]+"${envs[@]}"} "${launcher[@]}" "$@" >"$dir/stdout" 2>"$dir/stderr" </dev/null
  echo "$?" >"$dir/code"
  normalize "$dir/stdout"
  # The kernel pty sometimes doubles a \r past its 2048-byte buffer, in Swift's output alone.
  if [[ $tty == 1 ]]; then
    sed -E $'s/\r+$/\r/' "$dir/stdout.norm" >"$dir/stdout.tmp" && mv "$dir/stdout.tmp" "$dir/stdout.norm"
  fi
}

same() {
  cmp -s "$1/stdout.norm" "$2/stdout.norm" && cmp -s "$1/stderr" "$2/stderr" && cmp -s "$1/code" "$2/code"
}

for spec in "${CASES[@]}"; do
  IFS=$'\x1f' read -r -a parts <<<"$spec"
  name="${parts[0]}"
  rest=("${parts[@]:1}")
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue
  total=$((total + 1))
  dir="$OUT/cases/$name"
  ok=0
  for _attempt in 1 2 3; do
    run_side "$dir/swift" "$SWIFT_AUB" "${rest[@]}"
    run_side "$dir/go" "$GO_AUB" "${rest[@]}"
    if same "$dir/swift" "$dir/go"; then ok=1; break; fi
    sleep 1
  done
  if [[ $ok == 1 ]]; then
    pass=$((pass + 1))
    continue
  fi
  {
    diff -u "$dir/swift/code" "$dir/go/code"
    diff -u "$dir/swift/stderr" "$dir/go/stderr"
    diff -u "$dir/swift/stdout.norm" "$dir/go/stdout.norm"
  } >"$dir/diff" 2>&1
  if reason="$(allow_reason "$name")"; then
    allowed=$((allowed + 1))
    echo "ALLOWED $name: $reason"
    continue
  fi
  failed=$((failed + 1))
  echo "DIFF $name ($(wc -l <"$dir/diff" | tr -d ' ') lines; $dir/diff)"
  head -n "$LINES_PER_DIFF" "$dir/diff" | cut -c1-220
done

echo "cases=$total pass=$pass allowed=$allowed diff=$failed"
[[ $failed == 0 ]]
