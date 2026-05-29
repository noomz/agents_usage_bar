---
phase: 06-distribution-sign-notarize-dmg-sparkle-oss-hygiene
plan: 01
subsystem: config / security
tags: [sec-03, config, permissions, hardening, swift-testing, phase-6, wave-2]
requirements: [SEC-03]
dependency_graph:
  requires:
    - "AgentsUsageBar/Config/ConfigStore.swift (Plan 01.03 — read-only TOML loader, `tomlPath`, `logger`, `load()`)"
    - "AgentsUsageBar/Infrastructure/AppLogger.swift (Plan 01.03 — `os.Logger` factory under `app.agents-usage-bar` subsystem)"
    - "AgentsUsageBarTests/ConfigTests/ConfigStoreLocalSectionsTests.swift (Plan 04-02 — Swift Testing + temp-dir/UUID test precedent)"
  provides:
    - "ConfigStore.ensureConfigFile(contents:) — POSIX 0o600 creation for ~/.config/agents-usage-bar/config.toml (idempotent)"
    - "ConfigStore.checkAndWarnPermissions() — startup warning gate (mode & 0o077 != 0); never crashes"
    - "ConfigStore.isWorldOrGroupReadable(mode:) — pure predicate test seam"
    - "Wire-up: `load()` calls `checkAndWarnPermissions()` via `defer`"
  affects:
    - "ROADMAP Phase 6 Success Criterion #5 (config.toml 0600 + warning)"
    - "REQUIREMENTS.md SEC-03 row (now traceable to AgentsUsageBar/Config/ConfigStore.swift + ConfigStorePermissionsTests.swift)"
tech-stack:
  added: []
  patterns:
    - "Defer-based startup hook: `load()` runs `checkAndWarnPermissions()` at tail via `defer` so missing/unreadable files do not block parsing"
    - "Belt-and-suspenders POSIX permission: `FileManager.createFile(attributes:)` AND `setAttributes(...)` — `createFile` is documented to silently ignore `attributes` on some filesystems"
    - "Pure-predicate test seam (Phase 1 STATE #33): `static isWorldOrGroupReadable(mode:)` exposed so unit tests assert the canonical gate without binding to a log sink"
    - "os.Logger structured warning with `privacy: .public` on path + octal mode (T-06-02 mitigation — never logs file contents or Secrets)"
key-files:
  created:
    - "AgentsUsageBarTests/ConfigTests/ConfigStorePermissionsTests.swift"
  modified:
    - "AgentsUsageBar/Config/ConfigStore.swift"
    - "AgentsUsageBar.xcodeproj/project.pbxproj"
decisions:
  - "load() remains read-only — it does NOT call ensureConfigFile(); preserves Phase 1 documented semantics. Callers explicitly request file creation."
  - "ensureConfigFile is idempotent and does NOT rechmod an existing file. A user who deliberately widens permissions on a non-secret-bearing config keeps their choice; load()'s warning still surfaces the risk."
  - "Used a `defer` block for the startup warning so an early-return / fail-soft path inside load() still runs the gate."
  - "Exposed isWorldOrGroupReadable as `public static` for the test seam — matches the Phase 1 STATE #33 source-grep precedent. Production code calls the same helper rather than duplicating the `& 0o077` mask."
  - "Allocated pbxproj UUID namespace AA060100 — fresh per the AA04xxxx precedent (AA040100 / AA040200 etc) for Plan 06-01 first test file."
metrics:
  start_time: "2026-05-25T02:24:50Z"
  duration_minutes: 8
  tasks_completed: 2
  files_created: 1
  files_modified: 2
  commits: 2
  completed: "2026-05-25T02:32:30Z"
---

# Phase 06 Plan 01: SEC-03 ConfigStore 0600 + World-Readable Warning Summary

ConfigStore now creates `~/.config/agents-usage-bar/config.toml` at POSIX mode `0o600` via the idempotent `ensureConfigFile(contents:)` method, and every `load()` call surfaces a non-fatal `os.Logger.warning` (`privacy: .public` on path + octal mode, plus a `chmod 0600` remediation) when an existing config file is world- or group-readable — closing the credential-exfiltration vector identified by SEC-03 (T-06-01).

## What Was Built

### Production code (`AgentsUsageBar/Config/ConfigStore.swift`)

- **`ensureConfigFile(contents:) throws`** — when `tomlPath` is absent:
  1. Creates the parent directory with `createDirectory(withIntermediateDirectories: true)`
  2. Calls `FileManager.createFile(atPath:contents:attributes: [.posixPermissions: 0o600])`
  3. Belt-and-suspenders: re-applies `0o600` via `setAttributes([.posixPermissions: 0o600], ofItemAtPath:)` (the `createFile` documentation notes some filesystems silently ignore the attributes dictionary)
  4. Throws `CocoaError(.fileWriteUnknown)` if `createFile` returns `false`

  When the file already exists, this method is a no-op — it does **not** overwrite contents and does **not** modify permissions.

- **`checkAndWarnPermissions()`** — reads `attributesOfItem(atPath:)[.posixPermissions]`; silent no-op when the file is absent or the attribute is unavailable (SEC-03 "never crashes"). When `mode & 0o077 != 0`, emits a structured `os.Logger.warning` with `privacy: .public` on the path and the octal mode, plus a `chmod 0600 <path>` remediation. File contents are never logged (T-06-02 mitigation).

- **`static isWorldOrGroupReadable(mode: Int) -> Bool`** — pure predicate `(mode & 0o077) != 0`. The production warning branch consumes this helper; tests assert it against canonical modes (Phase 1 STATE #33 source-grep / pure-function test seam).

- **`load()` wiring** — `defer { checkAndWarnPermissions() }` at the top of the method so every `load()` call surfaces a wide-permission file, even if an early-return / fail-soft path triggers.

- **Doc-comment update** — the existing `SEC-03 NOTE (deferred to Phase 6)` block now reads `SEC-03 (Phase 6 / Plan 06-01 — implemented here)` and lists the three new methods + the read-only `load()` invariant.

### Tests (`AgentsUsageBarTests/ConfigTests/ConfigStorePermissionsTests.swift`, NEW)

7 Swift Testing cases (`@Test`), each on a UUID-scoped temp toml path for parallel safety:

1. `ensureConfigFile_createsAt0600` — file created with mode masked-to-`0o600`
2. `ensureConfigFile_writesContentsVerbatim` — written bytes round-trip byte-exact
3. `ensureConfigFile_idempotent_noOverwrite_noRechmod` — pre-seeds a 0o644 file and asserts that a second `ensureConfigFile` call neither overwrites contents nor changes permissions
4. `isWorldOrGroupReadable_0600_isFalse` — pure predicate baseline
5. `isWorldOrGroupReadable_widePermissions_areTrue` — `0o644`, `0o604`, `0o660`, `0o610` all flag
6. `checkAndWarnPermissions_missingFile_isSilentNoOp` — no crash on absent file; subsequent `load()` still returns defaults
7. `load_doesNotCrash_onWideOpenConfigFile` — end-to-end: writes a real 0o644 file, verifies `load()` returns the parsed config and does not crash

### pbxproj wiring (`AgentsUsageBar.xcodeproj/project.pbxproj`)

Allocated fresh `AA060100` UUID namespace per the AA04xxxx precedent:

- `AA060100000000000000010A` — PBXBuildFile under the `Plan 04-02` neighbor entry
- `AA060100000000000000010B` — PBXFileReference under the `Plan 04-02` neighbor entry
- ConfigTests group membership (alongside the Plan 05-02 entries, before the Fixtures subgroup)
- AgentsUsageBarTests target's PBXSourcesBuildPhase (alongside `Plan 04-02 — ConfigStoreLocalSectionsTests`)

## Verification

```
xcodebuild test -only-testing:AgentsUsageBarTests/ConfigStorePermissionsTests ...
** TEST SUCCEEDED **
  7 cases × 2 destinations = 14 passes; 0 failures
```

```
xcodebuild build -project AgentsUsageBar.xcodeproj -scheme AgentsUsageBar -destination 'platform=macOS' ...
** BUILD SUCCEEDED **
```

(The lone `AgentsUsageBar isn't code signed but requires entitlements` warning is pre-existing — emitted because we pass `CODE_SIGN_IDENTITY=""` for the unsigned local-build test path.)

### Acceptance criteria (PLAN.md)

| Criterion | Result |
| --- | --- |
| `grep -n "posixPermissions" ConfigStore.swift` shows `0o600` in a create path | PASS — line 374 (`[.posixPermissions: 0o600]`) |
| `grep -c "0o077" ConfigStore.swift` >= 1 | PASS — 3 occurrences (predicate + 2 doc references) |
| `load()` calls `checkAndWarnPermissions()` | PASS — line 59 `defer { checkAndWarnPermissions() }` |
| No `.zshrc/.bashrc/config.fish` non-comment references introduced | PASS — only pre-existing `///` SEC-05 anti-feature doc-comment lines (10, 12) match; zero new references |
| `ConfigStorePermissionsTests.swift` exists with `import Testing` and >= 6 `@Test` functions | PASS — 7 `@Test` functions |
| `xcodebuild test -only-testing:.../ConfigStorePermissionsTests` exits 0 | PASS |
| pbxproj references new test file | PASS — PBXFileReference + PBXBuildFile + group + Sources phase entries (4 namespaces) |
| Full `xcodebuild build` succeeds | PASS |
| CFG-06 + SEC-04 guards remain green | PASS — no shell-rc references introduced; no literal `sk-`/`AIza` strings |

## Threat Mitigation

| Threat ID | Disposition | Mitigation Status |
| --- | --- | --- |
| T-06-01 (Information Disclosure — config.toml world/group readable) | mitigate | **DONE** — `ensureConfigFile` creates at `0o600`; `checkAndWarnPermissions` warns on `mode & 0o077 != 0` on every `load()` |
| T-06-02 (Information Disclosure — `os.Logger` warning leaks key material) | mitigate | **DONE** — warning interpolates path + octal mode only (`privacy: .public` because neither is a Secret); file contents NEVER logged |
| T-06-SC (Tampering — package-manager installs) | accept | N/A — pure Swift + pbxproj wiring; no new dependencies |

## Deviations from Plan

**None — plan executed exactly as written.**

Two minor implementation notes that stayed within the plan's prescription:

1. **`defer { checkAndWarnPermissions() }` instead of a tail-position call.** The plan said "wire it as the last statement of `load()`". `defer` is functionally equivalent for the happy path AND robust against any early-return / fail-soft branches the Phase 1/2/3/4 code added — the warning still fires when a wide-permission file is read but yields a parse error mid-way. This is strictly stronger than a tail call.

2. **`isWorldOrGroupReadable` returned `public static`.** RESEARCH Pattern 4 inlined the `mode & 0o077 != 0` check inside the warning branch. To satisfy the plan's test-seam requirement ("expose an internal `static func isWorldOrGroupReadable(mode:) -> Bool` helper the warning branch consumes, and unit-test that pure helper"), I extracted the mask into the static helper and call it from both `checkAndWarnPermissions()` and the tests. Identical behavior, no duplication.

## Authentication Gates

None — no Apple-signing, no notarytool, no GitHub Releases credentials touched. This plan is local Swift code + pbxproj only.

## Commits

| Type | Hash | Message |
| --- | --- | --- |
| `test` | `b161e27` | `test(06-01): add failing SEC-03 ConfigStore permissions tests` — RED gate (test file + pbxproj wiring; production methods absent → compile fails) |
| `feat` | `bc10fc0` | `feat(06-01): implement SEC-03 ConfigStore 0600 creation + world-readable warning` — GREEN gate (production methods added; all 7 tests pass) |

REFACTOR pass skipped — the implementation has no duplication or naming smell warranting a third commit. The pure helper (`isWorldOrGroupReadable`) was extracted in the GREEN commit itself because it is the test seam, not a refactor cleanup.

## TDD Gate Compliance

| Gate | Required | Status |
| --- | --- | --- |
| RED | `test(...)` commit before any `feat(...)` | PASS — `b161e27` precedes `bc10fc0` |
| GREEN | `feat(...)` commit after RED | PASS — `bc10fc0` |
| REFACTOR | Optional | SKIPPED (no changes warranted) |

## Known Stubs

None. SEC-03 is fully implemented end-to-end; no placeholder UI or empty data flows introduced.

## Self-Check: PASSED

- `AgentsUsageBarTests/ConfigTests/ConfigStorePermissionsTests.swift` — FOUND
- `AgentsUsageBar/Config/ConfigStore.swift` — FOUND (modified — 98 insertions, 3 deletions)
- `AgentsUsageBar.xcodeproj/project.pbxproj` — FOUND (modified — 4 new lines under AA060100 namespace)
- Commit `b161e27` — FOUND (`git log --oneline | grep b161e27`)
- Commit `bc10fc0` — FOUND (`git log --oneline | grep bc10fc0`)
- `xcodebuild test -only-testing:AgentsUsageBarTests/ConfigStorePermissionsTests` — exit 0, all 7 tests pass
- `xcodebuild build` — exit 0, `** BUILD SUCCEEDED **`
