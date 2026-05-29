# Phase 2 — User Acceptance Test

**Reviewer:** {user}
**Date:** {fill at test time}
**Build:** xcodebuild output of `git rev-parse --short HEAD` at session start

## Test outcomes table (fill in as you go)

| #  | Test                             | Result | Notes |
|----|----------------------------------|--------|-------|
| 1  | Claude JSONL populates           | ⬜      |       |
| 2  | OAuth quota windows              | ⬜      |       |
| 3  | Local-midnight rollover          | ⬜      |       |
| 4  | Notification FSM + snooze        | ⬜      |       |
| 5  | Multi-provider coalesced         | ⬜      |       |
| 6  | Sleep/wake refresh               | ⬜      |       |
| 7  | Energy Impact "Low"              | ⬜      |       |
| 8  | Persistent 429 circuit breaker   | ⬜      |       |
| 9  | Stale-data indicator             | ⬜      |       |
| 10 | Menu bar tint                    | ⬜      |       |

## Phase 2 UAT — Reviewer Steps

**Pre-conditions for the test session:**

- Build the app: `xcodebuild build -project AgentsUsageBar.xcodeproj -scheme AgentsUsageBar -configuration Debug` exits 0.
- Launch the app from `~/Library/Developer/Xcode/DerivedData/AgentsUsageBar-*/Build/Products/Debug/AgentsUsageBar.app`.
- Have Claude Code installed locally (so `~/.claude/projects/**/*.jsonl` populates as you use it).
- Have `~/.claude/.credentials.json` OR Keychain `Claude Code-credentials` populated (for the OAuth-quota path) — OPTIONAL.
- Set `OPENROUTER_API_KEY` env var so OpenRouter row also populates (cross-provider coalesce verification).

### Test 1 — CLAUDE row populates from local JSONL (Phase 2 SC #1)

1. Open the popover by clicking the menu bar icon.
2. Verify a "Claude" row exists.
3. Use Claude Code for ~30 seconds (any chat / tool call).
4. Wait ≤5 min OR click Refresh.
5. **PASS** if Claude row shows non-zero "X tokens" and a non-zero "$Y.YY" today's cost.

### Test 2 — CLAUDE row OAuth quota windows (Phase 2 SC #2)

1. With OAuth credentials present, observe the Claude row.
2. **PASS** if the row shows quota windows (visually verifiable as a primary bar derived from max(5h, 7d) — primary-only display per scope choice in Plan 02.04).
3. Move the credentials.json file aside; quit + relaunch the app.
4. **PASS** if Claude row STILL shows tokens/cost from local JSONL (no error styling). Quota windows absent (or quota nil → gray no-limit bar).

### Test 3 — Local midnight rollover (Phase 2 SC #3)

1. Change system clock to 23:58 local time. Open popover; note current today-tokens for Claude row.
2. Wait until system clock advances past midnight (or set clock to 00:01).
3. Click Refresh OR wait 5 min for next poll.
4. **PASS** if Claude row's tokens reset to 0 (or to whatever transcripts were written after midnight). UI-05 footer caption updates if you also crossed timezone.
5. **PASS** if FSM state for the previous day expires implicitly (UserDefaults date-keyed; no explicit reset).
6. **DST corner case (deferred / informational):** for the 2026-03-08 spring-forward in PT, the same procedure should yield "Resets 00:00 PDT" caption AFTER the spring-forward; before, "Resets 00:00 PST". Unit tests in Plan 02.07 Task 1 cover this; manual verification is not required unless the reviewer is in PT on 2026-03-08.

### Test 4 — Notification FSM + snooze (Phase 2 SC #4)

1. Force a quota fraction of 0.85 (set OPENROUTER_API_KEY for an account near limit OR mock via dev override).
2. **PASS** if a notification banner appears: title "OpenRouter at 85%", body "$X.XX of $Y.YY used today.", with a "Snooze for today" action button.
3. Click "Snooze for today".
4. Force quota fraction to 0.96 (cross critical band).
5. **PASS** if NO new notification fires (snooze suppresses all bands per default decision #2).
6. Force quota fraction to 1.05.
7. **PASS** if still no notification (snooze active).
8. Wait until midnight rollover (or change system clock).
9. Force quota fraction back to 0.85.
10. **PASS** if a new notification fires (snooze cleared by day-rollover).

### Test 5 — Multi-provider coalesced notification

1. Configure both OpenRouter (with OPENROUTER_API_KEY) AND Claude (with credentials) so both can cross threshold simultaneously.
2. Force both providers to fraction 0.85 in a single poll cycle (engineering setup: dev-override).
3. **PASS** if ONE notification fires titled "2 providers crossed 80%" with body "OpenRouter, Claude".

### Test 6 — Sleep/wake (Phase 2 SC #5 part 1)

1. Open popover; observe last-update timestamp ticking ("Updated Xs ago").
2. Close laptop lid (or invoke `pmset sleepnow`).
3. Wait 5 min.
4. Open laptop lid (wake event).
5. **PASS** if within ~1 second of wake, the "Updated" timestamp resets to "Updated 0s ago" (single immediate refresh per POLL-04).
6. **PASS** if subsequent polls resume on the configured cadence.

### Test 7 — Energy Impact "Low" (Phase 2 SC #5 part 2 / POLL-09)

1. Disconnect AC power (battery only).
2. Leave the app running idle for 1 hour (do not interact with the popover).
3. Open Activity Monitor → Energy tab.
4. **PASS** if AgentsUsageBar's "Energy Impact" column shows "Low" or "Very Low" (NOT "High"). Average Energy Impact (12h) should be < 1.0.

### Test 8 — Persistent 429 circuit breaker (Pitfall 5 + default decision #4)

1. If your Anthropic account hits the persistent-429 path (Claude Max — see GitHub issue #30930), observe the Claude row over 3+ polls.
2. **PASS** if after 3 consecutive 429s, no further `/api/oauth/usage` calls fire for ~5 min (verify via `log stream --predicate 'subsystem == "app.agents-usage-bar" AND category == "claude"'` showing "circuit breaker open" notice).
3. **PASS** if local JSONL data continues to update; only the 5h/7d quota windows are absent.

### Test 9 — Stale-data indicator (UI-08)

1. Set refresh interval to `.m1` (1 minute) via TOML config (or temp dev override).
2. Trigger a network failure scenario (disconnect Wi-Fi for 3 minutes).
3. **PASS** if after 2 × 60 = 120 seconds since last success, the OpenRouter row's status dot dims (opacity 0.4) AND the "Updated Xm ago" label switches to tertiary text style (visually fainter).
4. Reconnect Wi-Fi; next refresh restores normal styling.

### Test 10 — Menu bar tint reflects max quota (UI-09)

1. With both providers configured, observe the menu bar icon color while quota fractions are < 80%.
2. **PASS** if icon is green-tinted.
3. Force one provider to ≥ 80% (e.g., OpenRouter limit nearly used).
4. **PASS** if icon transitions to yellow within one poll.
5. Force one provider to ≥ 95%.
6. **PASS** if icon transitions to red.
7. (Snap transition is acceptable per Pitfall 9.)

## Reviewer outcome

- **All 10 tests pass** → respond `approved` to the checkpoint.
- **Any test fails** → describe which step + observed behavior; halt phase; gap-closure plan via `/gsd-plan-phase 02 --gaps`.

## Phase 2 Success Criteria Mapping

| Success Criterion                                                                   | UAT Tests   |
|-------------------------------------------------------------------------------------|-------------|
| #1 — Claude tokens + cost populate from JSONL (CLAUDE-01/02/03/05)                  | Test 1      |
| #2 — Claude 5h + 7d quota windows from OAuth, degrade-to-local on failure (CLAUDE-04) | Test 2    |
| #3 — Today rolls at local midnight, DST-correct (UI-04 + Pitfall 7)                 | Test 3      |
| #4 — Notification FSM (warning/critical/exceeded), snooze, coalesce (NOTIF-01..07)  | Tests 4, 5  |
| #5 — Sleep pauses, wake refreshes, breaker survives flake, Energy Impact "Low" (POLL-04..06, POLL-09) | Tests 6, 7, 8 |
| Plan 02.07 add-ons — Stale dimming (UI-08) + menu bar tint (UI-09) + reset caption (UI-05) | Tests 9, 10 |
