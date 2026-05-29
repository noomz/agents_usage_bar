---
phase: 05-first-run-ux-settings-polish
plan: 06
subsystem: ui
tags: [swiftui, ci, github-actions, about-tab, uat, cfg-06, shell-rc-enforcement, swift-6]

# Dependency graph
requires:
  - phase: 05-first-run-ux-settings-polish
    plan: 01
    provides: SettingsAboutTab stub created in UI/Settings/ group; pbxproj wired under UUID namespace AA050100
  - phase: 05-first-run-ux-settings-polish
    plan: 03
    provides: SettingsGeneralTab — General tab slot filled; General tab pattern for About tab layout
  - phase: 05-first-run-ux-settings-polish
    plan: 04
    provides: SettingsProvidersTab — Providers tab slot filled; CFG-06 source-walk test pattern
  - phase: 05-first-run-ux-settings-polish
    plan: 05
    provides: WelcomeWindowController — Phase 5 last code-producing plan before 05-06 polish
provides:
  - SettingsAboutTab — fully implemented About tab: version/build from Bundle.main, GitHub repo link, LICENSE link, Phase 6 Sparkle placeholder comment
  - CFG-06 CI enforcement — cfg-06-check job in .github/workflows/ci.yml; grep with comment-line filter rejects non-comment shell RC references in AgentsUsageBar/ Swift source
  - 05-UAT.md — Phase 5 User Acceptance Test script: 10-row outcomes table, 5 manual tests with PASS criteria, 5 attestation tests referencing Plans 05-01..05-05, Hotfixes stub, Phase 5 SC Mapping table, reviewer-signal protocol
affects:
  - 06-distribution (Phase 6) — About tab is the Sparkle integration surface; Phase 6 REL-02 replaces the placeholder comment with an SPUUpdater button

# Tech tracking
tech-stack:
  added:
    - "GitHub Actions cfg-06-check job with grep + comment-line filter pattern"
  patterns:
    - "CFG-06 comment-line filter: pipe grep output through grep -v '^[^:]*:[0-9]*:[[:space:]]*//' to exclude Swift doc-comment lines that document prohibitions — prevents false positives while still catching real code violations"
    - "Color.accentColor over .accent ShapeStyle — macOS 14 compatibility (ShapeStyle has no .accent member on macOS 14)"
    - "Bundle.main.infoDictionary computed property read at render time — no @State needed for version/build strings"

key-files:
  created:
    - ".planning/phases/05-first-run-ux-settings-polish/05-UAT.md"
  modified:
    - "AgentsUsageBar/UI/Settings/SettingsAboutTab.swift — stub replaced with full implementation"
    - ".github/workflows/ci.yml — cfg-06-check job added; test job now depends on cfg-06-check"

key-decisions:
  - "Comment-line filter added to CFG-06 grep: ConfigStore.swift and EnvReader.swift contain doc-comment lines mentioning .zshrc/.bashrc as prohibition documentation — grep -v removes pure comment lines to avoid false positives while still catching functional code violations"
  - "Color.accentColor used instead of .accent ShapeStyle: plan's exemplar used .foregroundStyle(.accent) which fails on macOS 14 — same fix as WelcomeRootView (Rule 1 pre-empted proactively based on 05-05-SUMMARY.md finding)"
  - "cfg-06-check runs as a separate parallel job (not a step inside the test job): keeps security checks co-located by type; test job declares needs: [secret-scan, cfg-06-check] so both gates must pass before compilation"
  - "No pbxproj change needed: SettingsAboutTab.swift was already wired in Plan 05-01 under UUID namespace AA050100; this plan only replaces stub content"

patterns-established:
  - "CFG-06 enforcement pattern: CI grep with comment-line filter for shell RC prohibition — reusable for any 'no X in source' enforcement that has doc-comment exceptions"

requirements-completed: [SHELL-05, CFG-03, CFG-04, CFG-05, CFG-06]

# Metrics
duration: ~35min
completed: 2026-05-21
---

# Phase 5 Plan 06: SettingsAboutTab + CFG-06 CI Enforcement + Phase 5 UAT Summary

**SettingsAboutTab replaces stub with version/build from Bundle.main + GitHub/LICENSE links + Phase 6 Sparkle placeholder; CFG-06 CI job enforces no shell RC file references in non-comment Swift source; 05-UAT.md provides the deterministic 10-test Phase 5 walkthrough script.**

## Performance

- **Duration:** ~35 min
- **Started:** 2026-05-21T17:40:00Z (approx)
- **Completed:** 2026-05-21T18:10:00Z (approx)
- **Tasks:** 2 of 2 completed
- **Files created:** 1 (.planning/phases/05-first-run-ux-settings-polish/05-UAT.md)
- **Files modified:** 2 (SettingsAboutTab.swift, .github/workflows/ci.yml)

## Accomplishments

- **SettingsAboutTab** is fully implemented: app icon (SF Symbol), version + build number from `Bundle.main.infoDictionary`, GitHub repo `Link`, LICENSE `Link`, Phase 6 Sparkle placeholder comment. All three Settings tabs (General / Providers / About) are now content-complete — Phase 5 settings surface is done.
- **CFG-06 CI job** (`cfg-06-check`) added to `.github/workflows/ci.yml`: grep scans `AgentsUsageBar/**/*.swift` for `.zshrc`, `.bashrc`, `config.fish` references; comment-line filter (`grep -v '^[^:]*:[0-9]*:[[:space:]]*//'`) prevents false positives from doc-comment prohibition text already present in `ConfigStore.swift` and `EnvReader.swift`. Both negative test (0 violations on current tree) and positive test (catches real violation) confirmed.
- **05-UAT.md** authored with exact Phase 4 `04-UAT.md` structural shape: 10-row outcomes table (5 manual + 5 attestation), numbered per-test PASS criteria sections for Tests 1-5, attestation paragraphs for Tests 6-10 referencing named suites from all five prior plans, Phase 5 Success Criteria Mapping table, Hotfixes stub, and reviewer-signal protocol (`approved` / `failed:<test#>` / `deferred:<test#>`).

## Task Commits

Each task was committed atomically:

1. **Task 1: SettingsAboutTab + CFG-06 CI step** — `e6c888f` (feat)
2. **Task 2: Author 05-UAT.md** — `386486e` (docs)

## Files Created/Modified

- `AgentsUsageBar/UI/Settings/SettingsAboutTab.swift` — Stub replaced. `VStack` with app icon (`chart.bar.doc.horizontal` SF Symbol), version/build computed properties from `Bundle.main.infoDictionary`, two `Link` views (GitHub + LICENSE), Phase 6 `// TODO(Phase 6 REL-02)` placeholder text. Uses `Color.accentColor` (not `.accent` ShapeStyle — macOS 14 compat). `frame(minWidth: 360, minHeight: 300)`.
- `.github/workflows/ci.yml` — New `cfg-06-check` job added between `secret-scan` and `test`. Uses `grep -RIn --include='*.swift'` with three patterns (`\.zshrc`, `\.bashrc`, `config\.fish`) scoped to `AgentsUsageBar/`; pipes through comment-line filter; exits 1 on violations. `test` job `needs` updated to `[secret-scan, cfg-06-check]`.
- `.planning/phases/05-first-run-ux-settings-polish/05-UAT.md` — 229-line UAT script. Header with reviewer/date/build fields. 10-row test outcomes table pre-populated with `<pending>`. Per-test sections for Tests 1-5 with explicit numbered PASS criteria. Tests 6-10 attestation paragraphs naming specific test suites and case counts from Plans 05-01..05-05. Pre-conditions checklist. Hotfixes stub table. Phase 5 Success Criteria Mapping. Reviewer signal block.

## Decisions Made

- **Comment-line filter for CFG-06 grep.** The plan specified a straightforward `grep -RIn` pattern that would have matched doc-comment lines in `ConfigStore.swift` ("NO reads of ~/.zshrc...") and `EnvReader.swift` ("DO NOT read ~/.zshrc..."). These are prohibition documentation comments — exactly the right thing to have. Added a `grep -v` pipe to filter out lines whose first non-space content is `//`. Confirmed: negative test passes (0 non-comment violations on current tree), positive test passes (a real code violation is caught). This is a Rule 1 auto-fix (the grep as specified produced false positives that would have broken CI on every push).
- **Color.accentColor not .accent.** Plan's exemplar used `.foregroundStyle(.accent)`. Based on 05-01-SUMMARY.md and 05-05-SUMMARY.md both documenting this same macOS 14 compile error, the fix was applied proactively. Rule 1 pre-empt.
- **No pbxproj change.** `SettingsAboutTab.swift` was already registered in the Xcode project under Plan 05-01 (UUID `AA050100000000000000005A/B`). Only the file content needed replacing.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] CFG-06 grep produced false positives on doc-comment lines**
- **Found during:** Task 1 verification (CFG-06 grep self-test)
- **Issue:** `grep -RIn -e '\.zshrc' -e '\.bashrc' -e 'config\.fish' AgentsUsageBar/` matched doc-comment lines in `ConfigStore.swift` (line 10: `///   - NO reads of ~/.zshrc...`) and `EnvReader.swift` (line 23: `/// DO NOT read ~/.zshrc...`). These lines document the CFG-06 prohibition — they are correct and must stay. The plain grep would have caused CI to fail on every push.
- **Fix:** Added `grep -v '^[^:]*:[0-9]*:[[:space:]]*//'` pipe to filter out pure Swift comment lines from the matches. Both the CI step and the UAT Test 5 command updated with the filter.
- **Files modified:** `.github/workflows/ci.yml`
- **Verification:** Negative test: 0 violations on current source tree. Positive test: a fixture file with `let bad = FileManager.default.contentsAtPath("~/.zshrc")` is correctly flagged.
- **Committed in:** `e6c888f` (Task 1 commit)

**2. [Rule 1 - Bug] `.accent` ShapeStyle does not exist on macOS 14 (pre-empted)**
- **Found during:** Task 1 (SettingsAboutTab implementation) — pre-empted based on identical Rule 1 fix documented in 05-05-SUMMARY.md
- **Issue:** Plan's exemplar used `.foregroundStyle(.accent)`. `ShapeStyle` has no `accent` member on macOS 14.
- **Fix:** Used `Color.accentColor` (valid `ShapeStyle` on macOS 14+) instead.
- **Files modified:** `AgentsUsageBar/UI/Settings/SettingsAboutTab.swift`
- **Verification:** Build succeeded with no errors.
- **Committed in:** `e6c888f` (Task 1 commit)

---

**Total deviations:** 2 auto-fixed (2 × Rule 1 bug)
**Impact on plan:** Both auto-fixes necessary for CI correctness and compilation. No scope creep; no architectural changes; no Rule 4 escalation.

## Known Stubs

- **Phase 6 Sparkle placeholder** in `SettingsAboutTab.swift` (line ~49): `Text("Automatic updates available in a future release.")` with `// TODO(Phase 6 REL-02)` comment. Intentional — plan explicitly specifies this as a placeholder; Phase 6 REL-02 will replace it with an `SPUUpdater` button. Not a data-blocking stub (the About tab goal is version/build + links, which are fully wired).

## Threat Flags

No new threat surface beyond what is documented in the plan's threat model:
- `SettingsAboutTab` external links: two static hardcoded URLs, user-initiated navigation only (T-05-06-01 accept).
- CFG-06 grep: read-only source scan scoped to `AgentsUsageBar/` (T-05-06-02 mitigated by scope restriction).

## Issues Encountered

- **RTK output filtering** made `git status --short` appear empty (RTK returned "ok"). Resolved by using `rtk proxy git status` to bypass filtering. No impact on correctness.
- **`.planning/` in .gitignore** required `git add --force` to stage `05-UAT.md`. Consistent with how all prior phase summaries and UAT files were committed (verified from `docs(05-05)` commit pattern).

## User Setup Required

None. No new entitlements, no new env vars, no Info.plist changes, no new CI secrets. The CFG-06 CI step runs automatically on push/PR.

## Self-Check

- [x] `AgentsUsageBar/UI/Settings/SettingsAboutTab.swift` exists with full implementation
- [x] `grep -c 'struct SettingsAboutTab'` returns 1
- [x] `grep -c 'CFBundleShortVersionString'` returns 1 (version read from Bundle.main)
- [x] `grep -c 'Color.accentColor'` returns 1 (not `.accent` — macOS 14 compat)
- [x] `grep -c 'Phase 6 REL-02'` returns 1 (Sparkle placeholder comment present)
- [x] `grep -c 'github.com'` returns 2 (GitHub repo + LICENSE links)
- [x] `SettingsScene.swift` contains all three tabs (General, Providers, About) — unchanged from Plan 05-01
- [x] `.github/workflows/ci.yml` has `cfg-06-check` job with `zshrc`/`bashrc`/`config.fish` patterns
- [x] CFG-06 comment-line filter passes on current source tree (0 non-comment violations)
- [x] CFG-06 positive test confirms real violation would be caught
- [x] `.planning/phases/05-first-run-ux-settings-polish/05-UAT.md` exists
- [x] `05-UAT.md` has 10 test rows (| 1 | through | 10 |)
- [x] `05-UAT.md` references all 5 Phase 5 requirements: SHELL-05, CFG-03, CFG-04, CFG-05, CFG-06
- [x] `05-UAT.md` contains `Reviewer signal` section
- [x] `05-UAT.md` contains `Hotfixes` stub table
- [x] `05-UAT.md` contains `Phase 5 Success Criteria Mapping` table
- [x] Commit `e6c888f` exists (Task 1)
- [x] Commit `386486e` exists (Task 2)
- [x] Build succeeded (BUILD SUCCEEDED — pre-existing warnings only)

## Self-Check: PASSED

---
*Phase: 05-first-run-ux-settings-polish*
*Completed: 2026-05-21*
