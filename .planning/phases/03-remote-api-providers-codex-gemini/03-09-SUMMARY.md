---
phase: 03-remote-api-providers-codex-gemini
plan: 09
subsystem: phase-3-uat
tags: [uat, phase-3, reviewer-script, attestation, codex, gemini, ui-11, d-07, d-11]
dependency_graph:
  requires: [03-01, 03-02, 03-03, 03-04, 03-05, 03-06, 03-07, 03-08]
  provides:
    - phase-3-uat-script
  affects:
    - .planning/phases/03-remote-api-providers-codex-gemini/03-UAT.md
tech_stack:
  added:
    - Phase 3 UAT walkthrough (10-test reviewer script)
  patterns:
    - Mirrors Phase 2 02-UAT.md template (frontmatter, ## Current Test, outcomes table, per-test PASS criteria, attestation block, reviewer signal)
    - Tests 1-5 manual; Tests 6-10 unit-test attestation citing Wave 1-4 suites
    - Per-test PASS criteria are concrete (URL launches, log-stream predicates, mtime checks, stat calls)
    - Reviewer signal protocol: approved / failed:<test#> / deferred:<test#>
    - Stretch sub-step for Codex both-fail muted row (D-03) inside Test 2
    - Time-bounded sub-steps in Test 3 (bearer auto-refresh + mtime invariant) explicitly tagged as DEFERRED-with-attestation if reviewer can't wait 1h
key_files:
  created:
    - .planning/phases/03-remote-api-providers-codex-gemini/03-UAT.md
  modified:
    - .planning/STATE.md (Plan 03-09 advance + Phase 3 plan-count)
    - .planning/ROADMAP.md (Phase 3 progress 9/9)
decisions:
  - "Mirrored Phase 2 02-UAT.md shape verbatim — same outcomes-table column layout (#/Test/Result/Notes), same per-test PASS-criteria numbering, same attestation-block prose for Tests 6-10, same 'Reviewer outcome' / 'Reviewer signal' final section. Pattern proved out for Phase 2 (approved 2026-05-15); Phase 3 inherits without modification."
  - "All 5 Phase 3 ROADMAP success criteria mapped to manual Tests 1-5 with explicit per-step PASS gates. Each test cites the source requirement IDs (CODEX-*/GEMINI-*/UI-11) and locked decisions (D-02/D-03/D-05/D-06/D-07/D-09/D-10/D-11/D-13/D-14/D-15) so any reviewer failure produces a sharp gap entry for /gsd-plan-phase 03 --gaps."
  - "Tests 6-10 cite 8 named unit-test suites: CodexRolloutParserTests, CodexModelPricingTests, GeminiSettingsGateTests, GeminiOAuthClientTests, AggregateStoreGeminiDegradedSuppressionTests, AppDependenciesCodexGeminiRegistrationTests (primary attestation citations) + Plan 03-04's CodexJSONLProviderTests live-fixture cross-check + ProviderRowViewDegradedTests source-grep lock for Test 4 step 3. Each citation includes assertion count so a reviewer can verify suite size matches expectation."
  - "Test 2 stretch sub-step covers the D-03 both-fail muted row UX (sessions + auth.json BOTH absent → muted 'No data yet' row, NOT red) — explicitly called out because it was the deferred edge of CODEX-02 reviewer-verification scope at Plan 03-04 boundary."
  - "Test 3 steps 5 + 6 (bearer auto-refresh + mtime invariant) are explicitly marked 'time-bounded / can be DEFERRED with GeminiOAuthClientTests attestation' since a reviewer running a 30-min UAT session cannot reasonably wait for a 3599s bearer to expire. Mirrors Phase 2 Test 7's energy-soak deferral pattern."
  - "Build SHA pinned as d8a6a3b in the header (the SHA at UAT-script authoring time). Reviewer is instructed to leave it as-is — hotfix commits landed DURING the UAT session populate the dedicated 'Hotfixes' table below the header (mirrors Phase 2's c84c452 + 378c531 + 4a5ebee table)."
  - "Reviewer signal protocol explicitly enumerates approved / failed:<test#> / deferred:<test#> — same three replies Phase 2 enumerated. The deferred case is critical for Tests 6-10 which the reviewer typically defers en masse to unit-test attestation."
  - "Pre-conditions section adapted from Phase 2 verbatim plus three Phase 3-specific additions: at least one Codex session today/yesterday, gemini-cli oauth-personal authenticated, OPENROUTER_API_KEY env set for cross-provider total verification. Claude Code installation retained as 'Phase 2 row should still populate for full popover regression' so the reviewer can also spot Phase 1+2 regression."
metrics:
  duration: "~10 minutes (1 task — author 03-UAT.md; checkpoint deferred to reviewer post-merge)"
  completed: "2026-05-18"
  tasks: 1
  files_modified: 1
  tests_added: 0
requirements: []
---

# Phase 03 Plan 09: Phase 3 UAT Script Summary

Authors the Phase 3 User Acceptance Test walkthrough at `.planning/phases/03-remote-api-providers-codex-gemini/03-UAT.md` — a reviewer-runnable Markdown script that mirrors the Phase 2 `02-UAT.md` shape that earned the "approved 2026-05-15" gate. Five manual tests cover the five ROADMAP Phase 3 success criteria (Codex rollout, Codex OAuth fallback, Gemini OAuth + tier tooltip, Gemini degraded UX, UI-11 dashboard buttons); five attestation tests cite the named Wave 1-4 unit-test suites that lock in the schema corrections, the pricing cascade, the OAuth state machine, and the cross-cutting D-07 + D-11 invariants.

Plan 03-09's `checkpoint:human-verify` is the actual reviewer session — the executor's job ends when the script is reviewer-ready and committed. Per the operating directive (no-clarify mode, plan declared `autonomous: false` because the artifact is a reviewer-facing checkpoint script), execution proceeds inline through Task 1 and stops at the checkpoint boundary. The orchestrator's post-merge step will solicit the reviewer's `approved` / `failed: <test#>` / `deferred: <test#>` signal.

## What Was Built

### Single artifact

**`.planning/phases/03-remote-api-providers-codex-gemini/03-UAT.md`** (130 lines)

- **Header:** Reviewer name (Siriwat Uamngamsup), Date (\<fill-in at run time>), Build (d8a6a3b — the SHA at UAT-script authoring time).
- **Test outcomes table:** 10-row table with `# / Test / Result / Notes` columns; Result column pre-populated with `<pending>` for reviewer fill-in; rows 1-5 manual, rows 6-10 attestation; column wording mirrors Phase 2's PASS / DEFER / FAIL convention.
- **Overall outcome stub:** `**Overall outcome:** <APPROVED / FAILED / DEFERRED — fill in after Tests 1-5>.`
- **Hotfixes table:** Empty stub that mirrors Phase 2's "Hotfixes landed during the UAT session (commits since 510f41a)" table — populated only if reviewer hits a regression during manual walkthrough that requires a hot-fix commit before approval.
- **Pre-conditions:** 7-bullet checklist adapted from Phase 2 + Phase 3 specific additions (Codex session today/yesterday, gemini-cli OAuth flow complete, OPENROUTER_API_KEY env set for cross-provider verification, Claude Code installed for Phase 2 row regression check, optional log-stream side terminal).
- **Test 1 — Codex JSONL row populates from real rollout (Phase 3 SC #1):** 6 PASS criteria covering token count, USD cost, max(primary, secondary) quota bar per D-05, plan_type tooltip via D-15, primary.resets_at countdown.
- **Test 2 — Codex OAuth fallback fires when no rollout (Phase 3 SC #2):** 8 steps including the `mv ~/.codex/sessions` removal, log-stream verification of `chatgpt.com/backend-api/wham/usage`, restore-to-rollout transition silence, and the D-03 both-fail stretch sub-step.
- **Test 3 — Gemini row populates with per-model quotas + tier tooltip (Phase 3 SC #3):** 6 PASS criteria covering quota bar (D-06), reset countdown, tier tooltip (RESEARCH correction #6), bearer auto-refresh (time-bounded / DEFERRED-with-attestation), D-10 mtime invariant.
- **Test 4 — Gemini degraded UX on 5xx (Phase 3 SC #4):** 7 steps covering /etc/hosts spoof, opacity dim, amber status dot, exact "Updated Xs ago — usage temporarily unavailable" subtitle, NO red styling invariant, cross-provider isolation (other rows continue refreshing), notification firing for siblings, restore transition.
- **Test 5 — UI-11 dashboard buttons (Phase 3 SC #5):** 7 steps covering button presence (always visible per D-13), each of 4 dashboard URL launches, accessibility help string, D-07 "Total excludes quota-only providers" footnote.
- **Tests 6-10 — Unit-test attestation block:** Per-test blockquote citing the named suite + assertion count + decision references. 8 distinct suites cited; cross-reference to source SUMMARYs.
- **Reviewer signal section:** Explicit `approved` / `failed: <test#>: <description>` / `deferred: <test#>: <reason>` reply protocol with downstream action mapping (`/gsd-transition` vs `/gsd-plan-phase 03 --gaps`).
- **Phase 3 Success Criteria Mapping table:** Five-row matrix mapping each ROADMAP success criterion to the UAT tests that verify it (one-to-many — e.g. SC #1 covered by Tests 1, 6, 7).

## Test Suite Results

N/A — Plan 03-09 ships zero code. The artifact is a Markdown document only. The Wave 1-4 test suites cited in the UAT attestation block all passed when their plans landed (see `03-01-SUMMARY.md` through `03-08-SUMMARY.md`).

## Invariant Verification (acceptance criteria from plan)

| Invariant                                                                                          | Result |
|----------------------------------------------------------------------------------------------------|--------|
| `.planning/phases/03-remote-api-providers-codex-gemini/03-UAT.md` exists and is non-empty           | 130 lines ✓ |
| File contains literal heading `# Phase 3 — User Acceptance Test`                                    | line 1 ✓ |
| 10-row test outcomes table (`grep -c '^| [0-9 ]'`)                                                  | 10 ✓ |
| Per-test sections for Tests 1-5 with level-3 or bold heading mentioning SC reference                | 5 ✓ (lines 47, 56, 65, 74, 84 — all `### Test N — ... (Phase 3 SC #M / ...)`) |
| All four dashboard URLs verbatim (openrouter.ai/credits, console.anthropic.com/settings/usage, platform.openai.com/usage, aistudio.google.com/u/0/usage) | 4 ✓ |
| At least 4 RESEARCH corrections cited (#1 payload.type, #2 nested keypath, #3 epoch ms, #5 wham/usage singular keys, #6 tier display map) | 5 ✓ — corrections #1 (Test 6 + Test 1 step 4 implicit), #2 (Test 8), #3 (Test 3 step 6 implicit + Test 9 expiry-imminent), #5 (Test 2 step 4 wham/usage shape note), #6 (Test 3 step 4 + Test 8 free/legacy/standard mapping) |
| At least 6 named unit-test suites for Tests 6-10                                                   | 8 ✓ — CodexRolloutParserTests, CodexModelPricingTests, GeminiSettingsGateTests, GeminiOAuthClientTests, AggregateStoreGeminiDegradedSuppressionTests, AppDependenciesCodexGeminiRegistrationTests, CodexJSONLProviderTests (Plan 03-04 cross-check), ProviderRowViewDegradedTests (Test 4 step 3 lock) |
| `## Reviewer signal` section present with `approved` / `failed` / `deferred` reply protocol         | line 114 ✓ |
| Phase 3 Success Criteria Mapping table present                                                      | line 125+ ✓ |

## Deviations from Plan

### 1. Force-add required for gitignored `.planning/` directory

- **Found during:** Task 1 commit step.
- **Issue:** The root `.gitignore` lists `.planning/` (the directory exists as planning artefacts, not source). `git add` refused with `paths are ignored by one of your .gitignore files`.
- **Fix:** Used `git add -f .planning/phases/03-remote-api-providers-codex-gemini/03-UAT.md` — direct Phase 2 precedent (commits `4895ae8` `docs(02-07): Phase 2 UAT script` and `a442a0a` `docs(02): Phase 2 UAT approved — close out tracking` were both force-added the same way; `git log --diff-filter=A` confirmed for 02-UAT.md). This is the documented planning-artifact pattern for this repo.
- **Files affected:** `.planning/phases/03-remote-api-providers-codex-gemini/03-UAT.md` (added via `-f`).
- **Commit:** `e192b0a` (docs(03-09): add Phase 3 UAT walkthrough).
- **Rule:** Rule 3 (auto-fixed blocking issue — established repo convention).

### 2. Task 2 (checkpoint) deferred to reviewer post-merge

- **Found during:** Plan-execution flow.
- **Issue:** Plan 03-09 Task 2 is the `checkpoint:human-verify` reviewer session itself. The operating directive (`autonomous: false` declared for reviewer-facing artifacts; no-clarify mode "proceed inline without checkpoint return") tells the executor to author Task 1's artifact, commit, and stop. The reviewer's signal is captured in a follow-up commit AFTER the reviewer runs the script (mirrors Phase 2's flow: commit `4895ae8` shipped 02-UAT.md; commit `a442a0a` four days later carried the approval close-out edits).
- **Decision:** Executor concludes Plan 03-09 at the Task-1 boundary. Phase 3 plan-count advances 8 → 9 in STATE.md / ROADMAP.md (the plan is "executed" — the artifact ships). Phase 3 itself does NOT advance to "Complete" — that's the reviewer's gate. Mirrors Phase 2 precedent where ROADMAP showed `7/7 plans executed` BEFORE the reviewer's `approved` reply and Phase 2 marked "Complete" AFTER.

### 3. Plan 03-09 frontmatter declared `requirements: []`

- **Found during:** Reading the plan frontmatter for STATE.md `requirements mark-complete` step.
- **Issue:** Empty `requirements` array means no REQUIREMENTS.md checkboxes flip in this commit.
- **Rationale:** Phase 3 v1 requirements (CODEX-01..04, GEMINI-01..04, UI-11) are all already marked complete by prior plans (03-04 / 03-06 / 03-07) — checked the existing REQUIREMENTS.md state above. The UAT is verification ONLY; it doesn't add requirement coverage. This is consistent with Plan 02-07's UAT having empty `requirements:` too (Phase 2 closed REQUIREMENTS.md ticks at Plans 02-04/05/06 level, not at the UAT artifact level).
- **Action:** No `gsd-sdk query requirements mark-complete` call needed.

No bugs found (Rule 1), no missing critical functionality (Rule 2), no architectural changes (Rule 4).

## Authentication Gates

None encountered during executor work. The reviewer session WILL encounter authentication gates as planned: `codex login` (for Test 2 OAuth fallback), `gemini` OAuth flow (for Test 3), `OPENROUTER_API_KEY` env var (for cross-provider total verification). These are documented in the pre-conditions section so the reviewer can resolve them BEFORE starting the timed manual walkthrough.

## Threat Surface Scan

No new threat surface. Plan 03-09's `<threat_model>` lists three threats (T-03.09-01..02 plus T-03.09-SC); the artifact-only nature of this plan means all three remain at their planned dispositions:

- **T-03.09-01 (Repudiation, reviewer signal not captured) — mitigate:** Reviewer signal protocol explicitly enumerates the three valid replies; the executor's post-reviewer commit (mirrors Phase 2 `a442a0a`) will quote the reviewer's reply verbatim in this SUMMARY's "Hotfixes" / "Outcome" section.
- **T-03.09-02 (Tampering, UAT altered post-approval) — accept:** Git commit history is the audit trail; the UAT-script commit (`e192b0a`) is immutable, and any post-reviewer edit will land as its own commit with the reviewer's reply quoted in the message.
- **T-03.09-SC (Tampering, npm/pip/cargo installs) — mitigate:** No package installs in this plan.

## Reviewer Reply

**Not yet received.** Reply will be appended here (verbatim) by the executor's follow-up commit after the reviewer runs the script. Format will mirror Phase 2's "Hotfixes landed during the UAT session" table + a verbatim quoted block of the reviewer's `approved` / `failed: <test#>` / `deferred: <test#>` reply.

## Known Stubs

None. The UAT artifact is fully reviewer-ready — every Test row has explicit PASS criteria, every attestation block cites a real (passing) test suite, every dashboard URL is the verified D-14 value, every D-07/D-11 invariant maps to its source decision. The reviewer's Result column entries (currently `<pending>`) are the only intentionally-blank fields, by design.

## Requirement Status

No requirements close in this commit — see Deviation #3.

Phase 3 requirement state at end of Plan 03-09 executor pass:

- **CODEX-01..04** — complete (Plan 03-04 closed loop).
- **GEMINI-01** — closed at primitives layer (Plan 03-05); composition closed at provider layer (Plan 03-06).
- **GEMINI-02..04** — closed at provider + composition layer (Plan 03-06 + 03-08).
- **UI-11** — closed at row layer (Plan 03-07).

REQUIREMENTS.md ticks for GEMINI-01..04 advance from "Pending" → "Complete" via the reviewer-approval close-out commit (mirrors Phase 2 close-out pattern), NOT in this commit.

## Composition Entry Point for Reviewer Session

```text
Reviewer pre-flight (run BEFORE opening 03-UAT.md):
1. xcodebuild build -project AgentsUsageBar.xcodeproj -scheme AgentsUsageBar -configuration Debug
2. Verify ~/.codex/sessions/$(date +%Y/%m/%d)/rollout-*.jsonl OR yesterday's path lists ≥1 file
3. Verify ~/.codex/auth.json exists (if not: `codex login`)
4. Verify ~/.gemini/oauth_creds.json + ~/.gemini/settings.json (security.auth.selectedType="oauth-personal")
5. Set OPENROUTER_API_KEY for cross-provider total
6. (Optional) Side terminal: `log stream --predicate 'subsystem == "app.agents-usage-bar"' --info`

Then open .planning/phases/03-remote-api-providers-codex-gemini/03-UAT.md and run Tests 1-5.

Time budget: ~30 min if pre-conditions already satisfied. Tests 6-10 read-through (skim attestation): ~5 min.
```

## Commits

| Hash    | Message                                                          |
|---------|------------------------------------------------------------------|
| e192b0a | docs(03-09): add Phase 3 UAT walkthrough (5 manual + 5 attestation) |

## Self-Check: PASSED

- `.planning/phases/03-remote-api-providers-codex-gemini/03-UAT.md` — exists (130 lines) ✓
- Commit `e192b0a` (Task 1 — UAT script) — present in git log ✓
- 10-row outcomes table grep ✓
- All 4 dashboard URL verbatim grep ✓
- 8 named unit-test suites cited (≥ 6 required) ✓
- `## Reviewer signal` section present ✓
- Phase 3 Success Criteria Mapping table present ✓
- Phase 2 02-UAT.md template shape preserved (header / outcomes table / hotfixes / pre-conditions / per-test sections / attestation block / reviewer signal / SC mapping) ✓
- No Plan 03-09 code changes (artifact-only plan boundary respected) ✓
