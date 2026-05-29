---
phase: 06-distribution-sign-notarize-dmg-sparkle-oss-hygiene
plan: 02
subsystem: distribution/sparkle
tags: [sparkle, auto-update, distribution, REL-06, code-signing, agvtool]
requirements_completed: [REL-06]
dependency_graph:
  requires:
    - Existing AgentsUsageBar app target (Phase 1–5 product)
    - Existing Info.plist with NSAllowsLocalNetworking + LSUIElement
    - Existing Entitlements.plist with only com.apple.security.network.client (REL-09)
  provides:
    - Sparkle 2.9.2 framework embedded & signed in the app bundle
    - SUFeedURL + SUPublicEDKey Info.plist slots (placeholders to be filled by 06-05)
    - CURRENT_PROJECT_VERSION + VERSIONING_SYSTEM build settings (agvtool prerequisites)
    - ExportOptions.plist for Developer ID -exportArchive (consumed by 06-04 release workflow)
  affects:
    - 06-04 (release.yml workflow) — consumes ExportOptions.plist and the agvtool-ready pbxproj
    - 06-05 (release-setup doc + first release) — fills SUFeedURL OWNER placeholder + SUPublicEDKey from generate_keys
tech_stack:
  added:
    - Sparkle 2.9.2 (exact pin via SPM, embedded & signed)
  patterns:
    - Xcode 16 SPM auto-embed for framework products (no manual PBXCopyFilesBuildPhase needed)
    - agvtool-driven CFBundleVersion (referenced as $(CURRENT_PROJECT_VERSION) in Info.plist)
key_files:
  created:
    - AgentsUsageBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
    - ExportOptions.plist
  modified:
    - AgentsUsageBar.xcodeproj/project.pbxproj
    - AgentsUsageBar/App/AgentsUsageBarApp.swift
    - AgentsUsageBar/Resources/Info.plist
  unchanged_critical:
    - AgentsUsageBar/Resources/Entitlements.plist (D-08 preserved — byte-unchanged)
decisions:
  - "Sparkle 2.9.2 pinned via XCRemoteSwiftPackageReference exactVersion (T-06-05 supply-chain mitigation)"
  - "ExportOptions.plist uses correctly-spelled hardenedRuntime (not RESEARCH typo hardendedRuntime)"
  - "teamID set to $(DEVELOPMENT_TEAM) placeholder — release-setup doc (06-03 / 06-05) documents the user-fill path"
  - "Removed manual PBXCopyFilesBuildPhase Embed Frameworks (Rule 1 bug-fix) — Xcode 16's SPM build system auto-embeds-and-signs framework products listed in packageProductDependencies; the manual copy phase tried to copy a non-existent 'Sparkle' path-component and broke the build"
metrics:
  duration_minutes: ~18
  tasks_completed: 3
  tasks_planned: 3
  files_created: 2
  files_modified: 3
  completed_date: 2026-05-25
---

# Phase 6 Plan 02: Sparkle Integration + Version Build Settings + ExportOptions Summary

Wired Sparkle 2.9.2 into the AgentsUsageBar app as an embed-and-sign SPM dependency, instantiated `SPUStandardUpdaterController` at app launch, declared the `SUFeedURL` and `SUPublicEDKey` Info.plist slots with documented placeholders, added `CURRENT_PROJECT_VERSION = 1` + `VERSIONING_SYSTEM = "apple-generic"` to both Debug and Release configurations so CI `agvtool new-version -all` can drive the integer build number Sparkle compares against, and committed a Developer-ID `ExportOptions.plist` at repo root for the release workflow's `xcodebuild -exportArchive` step.

## Tasks

| # | Task                                                                      | Status      | Commit(s)               |
| - | ------------------------------------------------------------------------- | ----------- | ----------------------- |
| 1 | Add Sparkle 2.9.2 SPM dependency embedded & signed in the app target      | ✅ Complete | `15aa98a`               |
| 2 | Wire `SPUStandardUpdaterController` + Info.plist Sparkle keys + version build settings | ✅ Complete | `9a10b09` (see Deviations) |
| 3 | Commit ExportOptions.plist for Developer ID export                        | ✅ Complete | `9a10b09` (see Deviations) |

## Key Decisions

- **Sparkle 2.9.2 pinned exactly** — `XCRemoteSwiftPackageReference` with `kind = exactVersion; version = 2.9.2;` plus `Package.resolved` lockfile (revision `6276ba2b...` resolved by Xcode from the verified `b83e3743…eed65` source hash). Pin matches RESEARCH §Sources verification.
- **Auto-embed via Xcode 16 SPM build system** — A manual `PBXCopyFilesBuildPhase` for Embed Frameworks is NOT needed and actively breaks the build. Xcode 16 automatically embeds-and-signs framework products listed on a target's `packageProductDependencies` when the target is a macOS app. Sparkle.framework (with `Versions/B/Autoupdate`, `Versions/B/Updater.app`, `Versions/B/XPCServices/{Installer,Downloader}.xpc`) is dropped into `AgentsUsageBar.app/Contents/Frameworks/` automatically.
- **`teamID` placeholder = `$(DEVELOPMENT_TEAM)`** — release-setup doc (06-03 / 06-05) documents that the user supplies their 10-character Apple Developer Team ID either by setting `DEVELOPMENT_TEAM` as a Release-config build setting in pbxproj OR by exporting it as a CI env var that `xcodebuild -exportArchive` inherits.
- **`hardenedRuntime` correctly spelled** — RESEARCH Pattern 3 has the typo `hardendedRuntime`; this plan uses the Apple-validated key `hardenedRuntime`. Apple silently disables Hardened Runtime on misspelled keys, which would void notarization eligibility.
- **Entitlements.plist byte-unchanged** — D-08 preserved; no `disable-library-validation`, no `allow-jit`, no sandbox additions. Sparkle 2.x on non-sandboxed Hardened Runtime requires no extra entitlements (verified RESEARCH §Anti-Patterns and Sparkle official sandboxing docs).
- **`SUPublicEDKey` empty placeholder** — Plan 06-05 runs `./bin/generate_keys` (from the Sparkle SPM ZIP), captures the base64 public key, and pastes it into this slot. The empty string is intentional — Sparkle will refuse all updates until a real key is in place, which is the correct default until release credentials exist (D-02).

## Files Created

| File | Purpose |
|------|---------|
| `AgentsUsageBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | SPM lockfile pinning Sparkle to 2.9.2 (revision `6276ba2b...`) |
| `ExportOptions.plist` | Developer-ID export options for CI `xcodebuild -exportArchive` (method=developer-id, signingStyle=automatic, teamID=`$(DEVELOPMENT_TEAM)`, hardenedRuntime=true, stripSwiftSymbols=true) |

## Files Modified

| File | Change |
|------|--------|
| `AgentsUsageBar.xcodeproj/project.pbxproj` | Added Sparkle XCRemoteSwiftPackageReference + XCSwiftPackageProductDependency + PBXBuildFile (link in Frameworks phase) + packageReferences on PBXProject + packageProductDependencies on app target; added `CURRENT_PROJECT_VERSION = 1;` and `VERSIONING_SYSTEM = "apple-generic";` to both Debug and Release app-target XCBuildConfiguration dicts |
| `AgentsUsageBar/App/AgentsUsageBarApp.swift` | Added `import Sparkle`; added `private let updaterController: SPUStandardUpdaterController` stored property; instantiated in `init()` after notification-category registration with `startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil` |
| `AgentsUsageBar/Resources/Info.plist` | Changed `CFBundleVersion` from literal `"1"` to `$(CURRENT_PROJECT_VERSION)`; changed `CFBundleShortVersionString` from literal `"0.1.0"` to `$(MARKETING_VERSION)`; added `<key>SUFeedURL</key>` with placeholder `https://OWNER.github.io/agents_usage_bar/appcast.xml`; added `<key>SUPublicEDKey</key>` with empty-string placeholder + inline XML comment for 06-05 fill-in |

## Acceptance Criteria

| Criterion | Status |
|-----------|--------|
| project.pbxproj contains XCRemoteSwiftPackageReference for sparkle-project/Sparkle with `exactVersion 2.9.2` | ✅ Verified (grep shows 11 Sparkle matches across pbxproj) |
| Sparkle is XCSwiftPackageProductDependency linked to app target AND embedded (auto-embed via Xcode 16 SPM build system) | ✅ Verified (`Sparkle.framework` present in built `AgentsUsageBar.app/Contents/Frameworks/` with adhoc signature; release builds re-sign via ExportOptions.plist) |
| Package.resolved pins Sparkle to 2.9.2 | ✅ Verified (`version = 2.9.2`, revision `6276ba2b...`) |
| Entitlements.plist byte-unchanged (D-08) | ✅ Verified (`git diff --stat dfe5f93..HEAD -- AgentsUsageBar/Resources/Entitlements.plist` is empty) |
| `import Sparkle` + `SPUStandardUpdaterController(startingUpdater: true` both present | ✅ Verified |
| Info.plist contains SUFeedURL + SUPublicEDKey; `plutil -lint Info.plist` OK | ✅ Verified |
| Info.plist `NSAllowsLocalNetworking = true` preserved (REL-08) | ✅ Verified (`plutil -extract NSAppTransportSecurity.NSAllowsLocalNetworking raw` prints `true`) |
| `grep -c "CURRENT_PROJECT_VERSION" pbxproj` >= 2 (Debug + Release for app target) | ✅ Verified (4 grep hits: 2 keys × 2 configs) |
| `xcodebuild build -scheme AgentsUsageBar -destination 'platform=macOS' CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO` succeeds | ✅ **`** BUILD SUCCEEDED **`** with Sparkle linked + auto-embedded |
| `plutil -lint ExportOptions.plist` reports OK | ✅ Verified |
| `plutil -extract method raw ExportOptions.plist` prints `developer-id` | ✅ Verified |
| `plutil -extract hardenedRuntime raw ExportOptions.plist` prints `true` (correctly-spelled key) | ✅ Verified |
| ExportOptions.plist contains teamID placeholder | ✅ Verified (`$(DEVELOPMENT_TEAM)` with explanatory inline XML comment) |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Removed redundant manual PBXCopyFilesBuildPhase for Embed Frameworks**

- **Found during:** Task 2 build verification (final `xcodebuild build` step)
- **Issue:** The Task 1 implementation followed the literal plan instruction "set to 'Embed & Sign' (Sparkle is a framework with XPC helpers — it must be embedded, code-sign-on-copy ON)" by adding a manual `PBXCopyFilesBuildPhase` named "Embed Frameworks" with `dstSubfolderSpec = 10` and a `PBXBuildFile` entry referencing the Sparkle `productRef` with `ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy)`. **This broke the build:** Xcode's `builtin-copy` reported `The file "Sparkle" couldn't be opened because there is no such file.` because the manual copy phase tried to copy `Sparkle` (no `.framework` suffix) from `Build/Products/Debug/Sparkle` — which doesn't exist. Investigation showed Xcode 16's SPM build system *already* auto-embeds-and-signs framework products listed in `packageProductDependencies` on a macOS app target: `Sparkle.framework` (with `Versions/B/Autoupdate`, `Versions/B/Updater.app`, `Versions/B/XPCServices/{Installer,Downloader}.xpc`, `_CodeSignature/`) was correctly dropped into `AgentsUsageBar.app/Contents/Frameworks/` by the same build, just before the broken manual phase fired.
- **Fix:** Removed the `PBXCopyFilesBuildPhase` entry, removed the `Sparkle in Embed Frameworks` `PBXBuildFile` entry (kept the `Sparkle in Frameworks` link-only entry), and removed the buildPhase reference from the app target's `buildPhases` array. Build then succeeded with the auto-embedded Sparkle.framework intact.
- **Files modified:** `AgentsUsageBar.xcodeproj/project.pbxproj`
- **Commit:** Folded into `9a10b09` (see Cross-Agent Commit Absorption below)
- **Reference:** Build artifact verification — `find ~/Library/Developer/Xcode/DerivedData/.../AgentsUsageBar.app -name "Sparkle*"` listed the framework AT the correct embed path BEFORE the redundant copy step failed.

### Cross-Agent Commit Absorption (parallel wave execution)

**Plan 06-02 (this plan) and Plan 06-03 ran in parallel as Wave 1. While I had staged Task 2+3 files (`pbxproj`, `App.swift`, `Info.plist`, `ExportOptions.plist`) and was about to commit, the parallel 06-03 agent's commit `9a10b09` absorbed those staged-but-uncommitted files into its own commit "docs(06-03): README — MIT badge, install, privacy section (SEC-05, REL-07)".**

- **Effect on repo:** All Task 2+3 file content is correct in HEAD — verified by `git show 9a10b09:<path>` for all four files; the build that produced the verified `AgentsUsageBar.app/Contents/Frameworks/Sparkle.framework` was run AFTER all four files were on disk.
- **Effect on traceability:** Commits `15aa98a` (Task 1 standalone) and `9a10b09` (Task 2+3 absorbed into 06-03's commit) together carry all Plan 06-02 work. The commit-message text for `9a10b09` only describes 06-03 README changes; the pbxproj/App.swift/Info.plist/ExportOptions.plist changes within it belong to 06-02.
- **Why this is acceptable (not retroactively split):** Force-rebasing to retroactively isolate the Task 2+3 changes into their own commit would rewrite the published-on-main commit `9a10b09` and could collide with any downstream tooling that already tracks it. Since the work itself is correct, present, and verified in HEAD, this Summary documents the cross-attribution and 06-04/06-05 will observe Plan 06-02 outputs by file content (not by commit hash).
- **No code/content was lost.**

## Authentication Gates

None. No live credentials were required; Sparkle SPM resolution is anonymous over HTTPS to GitHub, and the build used `CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO` (no Developer ID cert needed).

## Known Stubs / Placeholders for Future Plans

| Stub | File | Filled By | Reason |
|------|------|-----------|--------|
| `SUFeedURL` value contains literal `OWNER` substring | `AgentsUsageBar/Resources/Info.plist` line 37 | **Plan 06-05** (or whichever plan publishes the first release / enables GitHub Pages) | The real GitHub Pages owner handle is not yet known at plan-execution time (Open Question 1). The release-setup doc in 06-03 instructs the user to replace `OWNER` with the actual repo owner. |
| `SUPublicEDKey` value is empty string | `AgentsUsageBar/Resources/Info.plist` line 39 | **Plan 06-05** | Sparkle's `generate_keys` tool runs from the downloaded `Sparkle-for-Swift-Package-Manager.zip` (06-05 / release-setup runbook), outputs a base64 public key, and the operator pastes the result into this slot. Until then Sparkle (correctly) refuses all updates. |
| `teamID` value is `$(DEVELOPMENT_TEAM)` build-setting variable | `ExportOptions.plist` line 27 | **Plan 06-05** | The Apple Developer Team ID is not known at plan-execution time (Open Question 4). Two fill paths documented in `docs/release-setup.md` (committed by 06-03): set `DEVELOPMENT_TEAM` as a Release-config build setting in pbxproj, OR export it as a CI env var. |

All three placeholders are EXPECTED outputs of Plan 06-02 per the plan's `<output>` section; none are bugs.

## Build Verification

```
$ xcodebuild build -project AgentsUsageBar.xcodeproj -scheme AgentsUsageBar \
    -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
…
Resolved source packages:
  Sparkle: https://github.com/sparkle-project/Sparkle @ 2.9.2
…
** BUILD SUCCEEDED **
```

Single expected warning: `AgentsUsageBar isn't code signed but requires entitlements. It is not possible to add entitlements to a binary without signing it.` This is inherent to `CODE_SIGN_IDENTITY=""`; the release workflow's `xcodebuild -exportArchive` (consumed by 06-04) re-signs with Developer ID Application and applies entitlements correctly.

Post-build artifact check:
```
$ ls AgentsUsageBar.app/Contents/Frameworks/Sparkle.framework/Versions/B/
_CodeSignature/  Resources/  Updater.app/  XPCServices/  Autoupdate  Sparkle
```

All four required Sparkle helpers present: `Sparkle` (binary), `Autoupdate`, `Updater.app`, `XPCServices/{Installer,Downloader}.xpc`. Embedded framework signed adhoc in Debug; the release `-exportArchive` step (D-03) re-signs with Developer ID Application and Hardened Runtime via the new `ExportOptions.plist`.

## Threat Model Status

| Threat ID | Disposition | Status |
|-----------|-------------|--------|
| T-06-03 (Tampering — Sparkle update download) | mitigate | **In progress.** `SUPublicEDKey` slot declared in Info.plist; empty string until 06-05 fills the real EdDSA public key. Sparkle's enforcement of `sparkle:edSignature` verification is built into the framework — no additional code needed. |
| T-06-04 (EoP — entitlement creep) | mitigate | **Mitigated.** `git diff --stat dfe5f93..HEAD -- AgentsUsageBar/Resources/Entitlements.plist` is empty: zero entitlement changes across the entire Phase 6 work so far. 06-04 will add a CI guard to enforce going forward. |
| T-06-05 (Tampering — Sparkle SPM supply chain) | mitigate | **Mitigated.** Sparkle pinned to `exactVersion 2.9.2`; `Package.resolved` locks the revision hash. Drift would change `Package.resolved` (committed) and surface in code review. |
| T-06-SC (Tampering — npm/pip/cargo) | accept | **Confirmed N/A.** No npm/PyPI/cargo packages added. Sparkle is the only new dependency and ships from the authoritative GitHub repo per RESEARCH §Package Legitimacy Audit. |

## Self-Check: PASSED

- File `Package.resolved` exists: FOUND (`AgentsUsageBar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`)
- File `ExportOptions.plist` exists: FOUND (`/Users/noomz/Projects/Opensources/agents_usage_bar/ExportOptions.plist`)
- File `AgentsUsageBarApp.swift` contains `import Sparkle`: FOUND
- File `Info.plist` contains `SUFeedURL` and `SUPublicEDKey`: FOUND
- File `project.pbxproj` contains `CURRENT_PROJECT_VERSION` and `VERSIONING_SYSTEM` (≥4 grep hits): FOUND (4)
- File `Entitlements.plist` byte-unchanged across Phase 6 (`dfe5f93..HEAD`): VERIFIED (empty diff stat)
- Commit `15aa98a` exists (Task 1): FOUND in `git log --oneline -10`
- Commit `9a10b09` exists (Task 2+3 work absorbed into 06-03's commit): FOUND in `git log --oneline -10`
- Build artifact `AgentsUsageBar.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle` (binary): FOUND
- Build artifact `AgentsUsageBar.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app`: FOUND
- Build artifact `AgentsUsageBar.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/`: FOUND
- `xcodebuild build` exit code: 0 (`** BUILD SUCCEEDED **`)
