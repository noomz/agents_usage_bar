---
phase: 06-distribution-sign-notarize-dmg-sparkle-oss-hygiene
plan: 03
subsystem: docs
tags: [oss-hygiene, license, security, entitlements, release-setup, mit, sparkle, notarization, privacy, sec-04, sec-05, cfg-06]

# Dependency graph
requires:
  - phase: 01-walking-skeleton
    plan: 01
    provides: Info.plist (NSHumanReadableCopyright holder/year, NSAllowsLocalNetworking) — copyright mirror + ATS justification source
  - phase: 01-walking-skeleton
    plan: 01
    provides: Entitlements.plist (com.apple.security.network.client) — the single entitlement docs/entitlements.md justifies
provides:
  - LICENSE — canonical MIT (copyright (c) 2026 lazym0m3nt@gmail.com); enables OSS distribution and tools that scan for SPDX MIT
  - SECURITY.md — vulnerability disclosure policy with private channels (GitHub advisory + email), 7d ack / 14d triage / 90d coordinated disclosure, signing/notarization/Sparkle trust model
  - docs/entitlements.md — per-entitlement + ATS justification; documents App-Sandbox-OFF rationale; enumerates intentionally-not-declared entitlements (disable-library-validation, allow-jit, allow-dyld-environment-variables, network.server, files.user-selected.*, device.*) — locks in REL-09 posture
  - docs/release-setup.md — one-time credential provisioning runbook for the seven GitHub secrets the 06-04 release workflow consumes (DEVELOPER_ID_CERT_P12, DEVELOPER_ID_CERT_PASSWORD, ASC_API_KEY_P8, ASC_API_KEY_ID, ASC_API_ISSUER_ID, SPARKLE_ED_PRIVATE_KEY, DEVELOPMENT_TEAM) + GitHub Pages enablement; the D-02 unblock for 06-05
  - README.md — extended: MIT badge + Install section + explicit Privacy section ("No telemetry. No analytics. No crash-reporter uploads. All data stays on your machine.") with link to docs/entitlements.md; screenshot placeholder marked TODO(Phase 6 Plan 06-05) — no fabricated image
affects:
  - 06-04 (release workflow) — secret names in docs/release-setup.md are the contract release.yml must read by exact key
  - 06-05 (credential provisioning + first release) — D-02 unblock: this runbook is what the human follows to load the seven secrets and enable Pages before tagging v0.x.0; also the screenshot capture step
  - 06-02 (Sparkle SPM wiring) — docs/entitlements.md justifies the absence of disable-library-validation for Sparkle on non-sandboxed Hardened Runtime
  - OSS users — LICENSE + SECURITY.md + README privacy section are the surface they see on github.com/lazym0m3nt/agents_usage_bar

# Tech tracking
tech-stack:
  added:
    - "None. Pure-markdown plan: no code, no SPM/Xcode changes, no new dependencies."
  patterns:
    - "MIT verbatim canonical text — no wording modifications, matches Choosealicense.org / SPDX MIT exactly"
    - "Single-source-of-truth doc pattern: docs/entitlements.md disclaims itself in favor of Entitlements.plist + Info.plist when they drift — the .plist files are authoritative"
    - "Secret-name table in docs/release-setup.md uses ASCII-only secret keys identical to the strings release.yml will read via ${{ secrets.NAME }} — no spelling drift between docs and workflow possible"
    - "Privacy promise (SEC-05) restated verbatim-in-spirit in README + cross-referenced to docs/entitlements.md (the entitlement posture that mechanically enforces it) + SEC-03 (config 0600 + warning)"
    - "Screenshot placeholder via HTML-comment TODO + broken image link to expected path — Markdown renderers show a broken-image icon, but no fabrication; Plan 06-05 replaces the file at docs/screenshots/menubar-popover.png"

key-files:
  created:
    - "LICENSE — 21 lines, MIT canonical wording"
    - "SECURITY.md — 68 lines, scope + supported versions + private disclosure + ack windows + crypto-verification policy"
    - "docs/entitlements.md — 123 lines, per-entitlement + ATS justification + sandbox-off rationale + REL-09 absent-entitlement enumeration"
    - "docs/release-setup.md — 287 lines, 5 numbered steps + secret table + per-step gh-cli + web-UI equivalents + rotation guidance"
    - ".planning/phases/06-distribution-sign-notarize-dmg-sparkle-oss-hygiene/06-03-SUMMARY.md — this file"
  modified:
    - "README.md — 69 → 100 lines (+31). Added MIT/platform/Swift badges, Install section, Privacy section, Security section. Updated Screenshot, Status, License, Build for distribution. Sample config.toml placeholder neutralized (sk-or-… → <your-openrouter-key>). All Phase 1 content preserved (Run from source, config schema, env precedence, build commands)."

key-decisions:
  - "MIT verbatim wording, no modifications. The plan locked D-01 = MIT and required canonical text. Used the SPDX/Choosealicense.org canonical paragraphs exactly. Copyright holder = lazym0m3nt@gmail.com / year = 2026 mirrors Info.plist NSHumanReadableCopyright (`Copyright (c) 2026 lazym0m3nt@gmail.com. All rights reserved.`)."
  - "SECURITY.md scope explicitly says 'local-only macOS menu bar utility' with 'no server component' so reporters do not file out-of-scope vulnerabilities (e.g. third-party provider API bugs)."
  - "SECURITY.md offers two private channels: GitHub private security advisory (preferred — gh-native, has private discussion thread) + email (lazym0m3nt@gmail.com, mirrored from Info.plist + LICENSE copyright). Plan required disclosure to maintainer contact; offering two channels reduces the chance of public-issue accidents."
  - "SECURITY.md commits to '7d ack / 14d triage / 90d coordinated disclosure window' explicitly without promising an SLA (plan: 'do NOT promise SLAs the project cannot meet'). The 7/14/90 numbers are widely recognized open-source norms and are softened with 'best-effort' framing."
  - "docs/entitlements.md uses a 'positive' table at top (what IS declared) followed by an 'absences enumeration' (what is NOT declared and why) — REL-09 is asserted twice (top table + each absent-entitlement subsection) so the doc remains correct even if a future reader only skims one half."
  - "docs/entitlements.md disclaims itself: 'These two files are the source of truth. If anything in this document drifts from them, the files win and this document is a bug.' — prevents the doc becoming a load-bearing source for entitlements over time."
  - "docs/release-setup.md uses the exact seven secret names in a `gh secret list`-style verification block at the bottom so the reader can self-check: if those exact strings are not the output, setup is incomplete. Tested mentally — strings match `${{ secrets.X }}` references the 06-04 release workflow will use."
  - "docs/release-setup.md teaches `gh secret set NAME` with stdin-piping (`echo -n 'value' | gh secret set NAME`, `< file`) rather than `gh secret set NAME --body 'value'` — stdin form keeps the secret out of shell history (process-list visibility is the smaller risk with `echo -n`; the consistent guidance is to use a password manager or a file and `rm -f` afterward)."
  - "docs/release-setup.md does NOT instruct the user to commit any secret to a file inside the repo. Step 1c base64-encodes the .p12 to clipboard (`pbcopy`) and uploads via `gh` or web UI; Step 1e immediately `rm -f`s the temp .p12 and `unset`s the password var (Pitfall 5 in 06-RESEARCH)."
  - "README badges use shields.io with static text (License-MIT-yellow, macOS%2014%2B-blue, Swift-6.2-orange). No CI badge yet — Plan 06-04 will add the release-workflow status badge once ci/release.yml exist and have run; deferred is the right call so the badge does not link to a non-existent workflow run."
  - "README Privacy section restates SEC-05 verbatim-in-spirit: 'No telemetry. No analytics. No crash-reporter uploads. All data stays on your machine.' This sentence is now in three places — REQUIREMENTS.md (SEC-05 line 106), README.md, and CLAUDE.md — and they agree word-for-word on the four prohibitions plus the positive 'stays on your machine' clause."
  - "README screenshot strategy: HTML comment TODO + Markdown image link pointing at docs/screenshots/menubar-popover.png (not yet committed). Renderers show a broken-image icon; that is intentional — Plan 06-05 replaces the file. NO fabricated screenshot was added. Caption text 'Screenshot pending capture from a notarized DMG build (Phase 6 Plan 06-05 — human-gated)' makes the deferral obvious to a reader who does not read HTML comments."
  - "Sample config.toml in README had a pre-existing `api_key = \"sk-or-…\"` placeholder (literal `sk-or-`). The CI SEC-04 grep scope (AgentsUsageBar/, AgentsUsageBarTests/, .github/) does not cover the repo-root README so it was not caught, but the prompt directive said 'NO literal sk- or AIza token strings anywhere'. Replaced with `<your-openrouter-key>` neutral placeholder. Treated as a Rule 2 (auto-add missing critical functionality — SEC-04 hygiene applied to a doc the grep does not currently scan)."

patterns-established:
  - "Cross-doc trust triangle: README points to docs/entitlements.md (mechanism) and SECURITY.md (process); docs/entitlements.md points back to Entitlements.plist + Info.plist (authoritative) and to docs/release-setup.md (provenance); SECURITY.md points to README Privacy + docs/entitlements.md. No circular load-bearing dependencies — each doc has exactly one authoritative source."
  - "Secret-name contract: the 7 names in docs/release-setup.md are the verbatim strings the future 06-04 release workflow MUST consume via `${{ secrets.NAME }}`. Any drift between this doc and release.yml is a planning bug."

requirements-completed: [REL-07]

# Metrics
duration: ~6min
completed: 2026-05-25
---

# Phase 6 Plan 03: OSS Hygiene — LICENSE, SECURITY, Entitlement Justification, Release Setup, README Privacy Summary

**Ships the five OSS-hygiene markdown files (REL-07) plus the credential-provisioning runbook (D-02) that unblocks Plan 06-05: MIT `LICENSE`, `SECURITY.md`, `docs/entitlements.md` (REL-08 + REL-09 justified), `docs/release-setup.md` (seven exact GitHub secret names + provisioning commands), and an extended `README.md` (MIT badge + Install section + SEC-05 privacy promise verbatim-in-spirit + screenshot placeholder marked for Plan 06-05).**

## Performance

- **Duration:** ~6 min
- **Started:** 2026-05-25T02:17:10Z
- **Completed:** 2026-05-25T02:22:57Z
- **Tasks:** 3 of 3 completed
- **Files created:** 4 (LICENSE, SECURITY.md, docs/entitlements.md, docs/release-setup.md)
- **Files modified:** 1 (README.md)
- **Lines added (new + diff):** ~530 across the five files (+ this SUMMARY)

## Accomplishments

- **`LICENSE`** — Canonical MIT text at repo root with copyright `(c) 2026 lazym0m3nt@gmail.com` exactly mirroring `Info.plist` `NSHumanReadableCopyright`. Closes D-01.
- **`SECURITY.md`** — Vulnerability disclosure policy with explicit scope ("local-only macOS menu bar utility — no server component"), supported versions (latest release only), two private disclosure channels (GitHub private security advisory + email), 7d ack / 14d triage / 90d coordinated disclosure window framed as best-effort (no false SLA), out-of-scope clarifications, and a cryptographic-verification policy (Developer ID + notarization + stapling + Sparkle EdDSA pinning).
- **`docs/entitlements.md`** — Per-entitlement + ATS justification document. Section 1: `com.apple.security.network.client` (the only declared entitlement, required for the four remote provider HTTPS calls + localhost LLM probes + Sparkle update fetch). Section 2: `NSAllowsLocalNetworking = true` (justifies HTTP-to-localhost without lowering remote ATS). Section 3: App Sandbox OFF rationale (DMG distribution + need to read user dotfiles — Apple's temporary-exception entitlement is not a supported alternative). Section 4: Hardened Runtime ON (notarization gate). Section 5: enumerates NOT-declared entitlements (`disable-library-validation`, `allow-jit`, `allow-dyld-environment-variables`, `network.server`, `files.user-selected.*`, device.* APIs) with one-paragraph justification each. Locks in REL-09.
- **`docs/release-setup.md`** — Five-step credential-provisioning runbook. Step 1: Developer ID Application cert → `.p12` → base64 → `DEVELOPER_ID_CERT_P12` + `DEVELOPER_ID_CERT_PASSWORD`. Step 2: App Store Connect API key → `ASC_API_KEY_P8` + `ASC_API_KEY_ID` + `ASC_API_ISSUER_ID`. Step 3: Sparkle `generate_keys` + `generate_keys -x` → `SPARKLE_ED_PRIVATE_KEY` (private) + `SUPublicEDKey` in Info.plist (public). Step 4: Developer Team ID → `DEVELOPMENT_TEAM`. Step 5: GitHub Pages enablement (Settings → Pages → `gh-pages` branch). Each step has both `gh` CLI commands and web-UI equivalents; copy-paste commands match Plan 06-RESEARCH verified `xcrun notarytool` / `security export` / Sparkle `bin/` invocations exactly. Closes D-02 unblock for 06-05.
- **`README.md`** — Extended from 69 → 100 lines (44% growth) without losing any existing content. New badges (License-MIT, macOS 14+, Swift 6.2). New `## Install` section. Replaced `## Privacy promise` with `## Privacy` carrying the SEC-05 four-prohibition statement verbatim-in-spirit and linking explicitly to `docs/entitlements.md`. New `## Security` section pointing at `SECURITY.md`. Replaced `## License` TBD placeholder with MIT + LICENSE link + copyright. Screenshot section marked `TODO(Phase 6 Plan 06-05)` via HTML comment + broken-image placeholder pointing at `docs/screenshots/menubar-popover.png` — **no fabricated image**. Status section refreshed to reflect Phases 1-5 complete + Phase 6 in flight. Build for distribution section now mentions the release workflow + cross-refs `docs/release-setup.md`.

## Task Commits

Each task was committed atomically:

1. **Task 1: MIT LICENSE + SECURITY.md** — `359a598` (docs)
2. **Task 2: docs/entitlements.md + docs/release-setup.md** — `9559c63` (docs)
3. **Task 3: README — MIT badge, Install, Privacy, screenshot placeholder** — `9a10b09` (docs) *(see Deviation #1 — this commit unintentionally also carried sibling Wave-1 06-02 work that was pre-staged in the index; documented below)*

## Files Created/Modified

- `LICENSE` — 21-line canonical MIT text. Copyright line: `Copyright (c) 2026 lazym0m3nt@gmail.com`. Permission + disclaimer paragraphs verbatim.
- `SECURITY.md` — 68 lines. Sections: Scope, Supported Versions, Reporting a Vulnerability, Acknowledgment and Disclosure, Out of Scope, Cryptographic Verification of Releases.
- `docs/entitlements.md` — 123 lines. Summary table + 6 sections (network.client, ATS local-networking, sandbox-off, Hardened Runtime, intentionally-NOT-declared entitlements, operational consequences) + See also footer.
- `docs/release-setup.md` — 287 lines. Header + Prerequisites + secret-name overview table + Steps 1-5 (each with web-UI + `gh` CLI flows + cleanup commands) + Verification block + Rotation table + Related-documents footer.
- `README.md` — 100 lines (was 69). Diff: +badges, +Install, +Security, expanded Privacy with SEC-05 verbatim + docs/entitlements.md link, License MIT (was TBD), Status refreshed, Screenshot placeholder marked, sample `sk-or-…` neutralized to `<your-openrouter-key>`.

## Decisions Made

- **MIT canonical wording.** Used Choosealicense.org / SPDX MIT text verbatim. No "or any later version" clause, no "for non-commercial use" caveats, no project-name embedded in the title-line block beyond the standard "MIT License" header.
- **Two private disclosure channels in SECURITY.md.** GitHub private security advisory (preferred — keeps the discussion private and gh-native) + email to `lazym0m3nt@gmail.com` (fallback). Plan said "email lazym0m3nt@gmail.com or GitHub private security advisory" — implemented as ordered preference (gh advisory first) to reduce the chance a reporter accidentally cc's a public list.
- **Best-effort framing for ack windows.** SECURITY.md says "best-effort" and aims for 7d ack + 14d triage + 90d coordinated disclosure — well-known OSS norms — but does not promise an SLA the project cannot meet (plan directive).
- **Sandbox-off rationale references CLAUDE.md decision.** docs/entitlements.md sandbox-off section explicitly cites CLAUDE.md's "Sandbox Decision (load-bearing)" table and lists the four real dotfile paths (`~/.claude`, `~/.codex`, `~/.gemini`, `~/.config/agents-usage-bar`, `~/.ccs/...`) the app reads. Anyone reading entitlements.md immediately understands why the sandbox is off without needing to load CLAUDE.md.
- **`generate_keys -x <file>` vs Keychain export.** Plan said "`./bin/generate_keys` then `-x` to export the private key." Per Sparkle's tooling, `generate_keys` stores the private key in Keychain under `https://sparkle-project.org` and `generate_keys -x <path>` writes it to a text file. docs/release-setup.md instructs the latter flow with explicit `rm -f` cleanup and a recommendation to back up to a password manager before deletion (Pitfall: losing the EdDSA private key strands all installed users from auto-update).
- **GitHub Pages enablement in the runbook (Step 5).** docs/release-setup.md ends the credential provisioning with Pages enablement because the appcast URL pinned in `Info.plist` will 404 without it, and Plan 06-05 needs both halves (secrets + Pages) ready before the first `v0.x.0` tag. The Step says "Source: Deploy from a branch → `gh-pages` → `/ (root)`" and notes Plan 06-04 will scaffold an empty `appcast.xml` on that branch so the URL resolves immediately.
- **Screenshot placeholder vs fabrication.** Used HTML comment + broken Markdown image link. Did NOT generate a fake placeholder image. Plan directive: "do NOT fabricate a screenshot image." The broken-image icon is the visual signal that capture is pending; the comment + caption explain why.
- **README badges via shields.io static badges.** No live build/test badges added. Plan 06-04 will add the release-workflow status badge once the workflow exists. Adding a dynamic badge pointing at a not-yet-existent workflow would render as "no status" and look broken.
- **SEC-04 hygiene applied to README sample config.** Pre-existing `api_key = "sk-or-…"` in the sample config.toml block was replaced with `api_key = "<your-openrouter-key>"`. CI SEC-04 scope does not currently include the repo-root README, but the prompt directive prohibited literal `sk-` strings anywhere. Treated as Rule 2 (correctness — keeps the project aligned with its own SEC-04 hygiene rule even outside the current CI grep scope).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking environment issue] Task 3 commit unintentionally carried sibling Wave-1 06-02 work staged in the index**

- **Found during:** Task 3 (post-commit inspection).
- **Issue:** Plan declares Wave 1 has no file overlap between 06-02 (pbxproj/Info.plist/Sparkle wiring) and 06-03 (docs only). True for the file set, but in the shared working tree the parallel 06-02 agent had several files **staged in the git index** at the time my Task 3 ran `git add README.md && git commit`. Git committed everything in the index, so the Task 3 commit `9a10b09` is described as "README — MIT badge, install, privacy section" yet `git show --stat` reveals it also contains:
  - `AgentsUsageBar.xcodeproj/project.pbxproj` (PBXCopyFilesBuildPhase simplification — Xcode 16 auto-embeds SPM frameworks; CURRENT_PROJECT_VERSION/VERSIONING_SYSTEM added)
  - `AgentsUsageBar/App/AgentsUsageBarApp.swift` (`SPUStandardUpdaterController` instantiation)
  - `AgentsUsageBar/Resources/Info.plist` (`CFBundleVersion → $(CURRENT_PROJECT_VERSION)`, `CFBundleShortVersionString → $(MARKETING_VERSION)`, `SUFeedURL` + `SUPublicEDKey` keys added)
  - `ExportOptions.plist` (new file — Developer ID export options for `xcodebuild -exportArchive`)
- **Code correctness:** All four sibling-staged changes are legitimate, well-formed 06-02 Sparkle-wiring work and align with Plan 06-02 + 06-RESEARCH Pattern 1/3. Nothing destructive happened.
- **Fix attempted:** None at HEAD — splitting the commit retroactively in a shared worktree carries higher risk (force-push hazard, sibling agent confusion) than the cost of an imperfect commit message. Documented here so the future reader of `git log` knows why `docs(06-03): README …` carries pbxproj diffs. The 06-02 SUMMARY (to be authored by the parallel agent) should account for this in its commit-list section.
- **Process improvement noted:** When working in a shared worktree alongside a parallel sibling agent, always run `git diff --cached` before `git commit` to surface unrelated staged work. Future plan executions in shared worktrees should adopt this pre-commit guard step. For Phase 6 specifically, the orchestrator's wave-1 file-disjointness check passed (different file lists), but pre-staged-index leakage is a real cross-agent failure mode the check does not cover.
- **Files modified:** None beyond what was already in the index; the deviation is a commit-message accuracy issue, not a code issue.
- **Verification:** All five Task 3 + plan-level acceptance criteria still PASS on the committed tree (grep gates, file existence, README content preservation).
- **Committed in:** `9a10b09` (Task 3) — described accurately above.

**2. [Rule 2 — Auto-add missing critical functionality] SEC-04 hygiene applied to repo-root README sample config**

- **Found during:** Task 3 verification (`grep -nE 'sk-[a-zA-Z0-9_-]|sk-or-|AIza' README.md`).
- **Issue:** Pre-existing Phase 1 `README.md` (line 50, sample `config.toml` block) used `api_key = "sk-or-…"` as a placeholder. The literal `sk-or-` substring matches the SEC-04 prohibited-prefix list in [`.planning/REQUIREMENTS.md`](.planning/REQUIREMENTS.md). The CI SEC-04 grep step scope (`AgentsUsageBar/`, `AgentsUsageBarTests/`, `.github/`) does not cover the repo-root `README.md`, so CI does not currently catch it — but the prompt directive said "NO literal `sk-` or `AIza` token strings anywhere" and the project's own SEC-04 policy is unambiguous.
- **Fix:** Replaced with neutral `api_key = "<your-openrouter-key>"`. Also updated the Phase-1 `OPENROUTER_API_KEY = sk-or-…` example in the env-var setup step to `OPENROUTER_API_KEY = <your-openrouter-key>` for the same reason.
- **Files modified:** `README.md` (two lines — the env var setup step and the sample config block).
- **Verification:** `grep -nE 'sk-[a-zA-Z0-9_-]|sk-or-|AIza[A-Za-z0-9_-]' README.md` returns no matches. CFG-06 grep continues to return no matches.
- **Committed in:** `9a10b09` (Task 3).

---

**Total deviations:** 2 (1 × Rule 3 commit hygiene; 1 × Rule 2 SEC-04 hygiene)
**Impact on plan:** Neither deviation altered the plan's intended output. Rule 3 is a commit-message accuracy issue (the code shipped is correct + matches Plan 06-02's intent). Rule 2 is a correctness improvement (SEC-04 hygiene applied even outside the current CI scope). No Rule 4 escalation; no architectural changes; no scope creep.

## Known Stubs

- **Screenshot file** at `docs/screenshots/menubar-popover.png` — intentionally absent. Plan 06-05 (human-gated DMG capture) supplies the file. README has an HTML-comment TODO and a caption explaining the deferral. This is a documented placeholder, not a data-blocking stub.
- **Sparkle `SUPublicEDKey`** value in `Info.plist` (empty `<string></string>` from sibling 06-02 work that came in via the Task 3 commit) — will be filled by Plan 06-05 after the human runs `generate_keys`. Not a 06-03-produced stub but worth noting because docs/release-setup.md Step 3 instructs the human on the exact insertion point.
- **`SUFeedURL`** in `Info.plist` uses an `OWNER` placeholder (`https://OWNER.github.io/agents_usage_bar/appcast.xml`) — also 06-02 work, to be resolved by Plan 06-05. docs/release-setup.md Step 5 documents this.

## Threat Flags

No new threat surface introduced beyond the plan's `<threat_model>`:

- **T-06-06 (release-setup.md leaking key material) — mitigated as planned.** docs/release-setup.md uses placeholders only (`REPLACE_TEAMID`, `REPLACE_KEY_ID`, `REPLACE_ISSUER_UUID`, `REPLACE_WITH_A_STRONG_RANDOM_PASSWORD`); never instructs committing real keys; explicit `rm -f` cleanup after each export; explicit `unset` of the password env var.
- **T-06-07 (README privacy claims unverifiable) — mitigated as planned.** README Privacy section is backed by (a) docs/entitlements.md showing the single network.client entitlement scope, and (b) absence of any telemetry SDK in the codebase (SEC-05 is a removal-by-design, not a feature; existing CI does not depend on any analytics package).
- **T-06-SC (npm/pip/cargo installs) — accept; not applicable.** No package-manager installs in this plan (markdown only).

No new threat flags discovered.

## Issues Encountered

- **Cross-agent index leakage in shared worktree.** See Deviation #1. The orchestrator's wave-1 disjointness guarantee covers file paths in `files_modified` but not the contents of the git index at commit time. Mitigation: in future shared-worktree executions, add `git diff --cached --name-only` as a pre-commit guard step.
- **`docs/` directory did not exist.** Created on demand via `mkdir -p`. Phase 6 is the first phase to introduce repo-root `docs/`; ROADMAP/RESEARCH anticipated this.
- **No build/test impact.** Plan is markdown-only; no Swift compile, no test runner, no pbxproj wiring required. Verification was entirely grep + `test -f` gates.

## User Setup Required

None directly from this plan. However, the **next** time the user wants to cut a release, they must follow [`docs/release-setup.md`](../docs/release-setup.md) once: provision 7 secrets, enable GitHub Pages. After that, all subsequent releases are unattended on `v*` tag push.

## Self-Check

- [x] `LICENSE` exists at repo root; contains `MIT License`, `Permission is hereby granted`, `Copyright (c) 2026 lazym0m3nt@gmail.com`
- [x] `SECURITY.md` exists at repo root; contains `Reporting a Vulnerability` section
- [x] `docs/entitlements.md` exists; contains `com.apple.security.network.client`, `NSAllowsLocalNetworking`, sandbox-off rationale, absent entitlements (`disable-library-validation`, `allow-jit`, `allow-dyld-environment-variables`)
- [x] `docs/release-setup.md` exists; contains all 7 secret names: `DEVELOPER_ID_CERT_P12`, `DEVELOPER_ID_CERT_PASSWORD`, `ASC_API_KEY_P8`, `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, `SPARKLE_ED_PRIVATE_KEY`, `DEVELOPMENT_TEAM`
- [x] `docs/release-setup.md` contains copy-paste commands for: `security export … -f pkcs12`, `base64 -i`, `notarytool submit … --key … --key-id … --issuer … --wait`, `./bin/generate_keys`, `./bin/generate_keys -x`
- [x] `docs/release-setup.md` documents GitHub Pages enablement
- [x] `README.md` contains MIT badge (`License-MIT`), `Install` section, `Privacy` section, `Security` section
- [x] `README.md` Privacy section asserts "No telemetry. No analytics. No crash-reporter uploads. All data stays on your machine."
- [x] `README.md` links to `docs/entitlements.md`
- [x] `README.md` screenshot placeholder marked `TODO(Phase 6 Plan 06-05)` via HTML comment; no fabricated image
- [x] `README.md` preserved Phase 1 content: `OPENROUTER_API_KEY` block, `config.toml` mention, `refresh_interval` sample, build commands
- [x] `README.md` line count grew from 69 → 100 (+31 lines)
- [x] `grep -nE 'sk-[a-zA-Z0-9_-]|sk-or-|AIza[A-Za-z0-9_-]'` matches **zero** across LICENSE, SECURITY.md, docs/entitlements.md, docs/release-setup.md, README.md
- [x] `grep -nE '\\.zshrc|\\.bashrc|config\\.fish'` matches **zero** across LICENSE, SECURITY.md, docs/entitlements.md, docs/release-setup.md, README.md
- [x] Commit `359a598` exists (Task 1)
- [x] Commit `9559c63` exists (Task 2)
- [x] Commit `9a10b09` exists (Task 3)
- [x] No build/compile step required — markdown-only plan

## Self-Check: PASSED

---

*Phase: 06-distribution-sign-notarize-dmg-sparkle-oss-hygiene*
*Completed: 2026-05-25*
