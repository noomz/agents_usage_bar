---
phase: 03-remote-api-providers-codex-gemini
plan: 01
subsystem: codex-provider
tags: [codex, jsonl, rollout, codable, scanner, parser, fold]
dependency_graph:
  requires: [02-01]
  provides: [provider-id-codex, codex-rollout-scanner, codex-rollout-event, codex-rollout-parser]
  affects: [Providers, Domain/ProviderID]
tech_stack:
  added:
    - CodexRoots (default ~/.codex/sessions root with override seam)
    - CodexRolloutScanner (today + yesterday YYYY/MM/DD walker, symlink canonical)
    - CodexRolloutEvent / Payload / TokenInfo / TokenUsage / RateLimits / Window / Credits (lenient Codable structs)
    - CodexRolloutParser (fold-to-last-token-count namespace enum)
  patterns:
    - Calendar.current.date(byAdding:.day, value:-1, ...) for yesterday (DST + leap safe)
    - DateComponents + String(format:"%02d", ...) for date dir path (no DateFormatter for date math)
    - url.resolvingSymlinksInPath() canonicalisation (STATE #44)
    - JSONDecoder lenient by default — unknown future fields silently dropped (no extraFields / AnyCodable)
    - Dual nonisolated(unsafe) ISO8601DateFormatter (fractional + non-fractional) — Phase 2 STATE #43 pattern, reused for parser timestamp ordering
    - try? + skip on malformed JSON (Pitfall 5)
key_files:
  created:
    - AgentsUsageBar/Providers/Codex/CodexRoots.swift
    - AgentsUsageBar/Providers/Codex/CodexRolloutScanner.swift
    - AgentsUsageBar/Providers/Codex/CodexRolloutParser.swift
    - AgentsUsageBar/Providers/Codex/Models/CodexRolloutEvent.swift
    - AgentsUsageBarTests/DomainTests/ProviderIDCodexTests.swift
    - AgentsUsageBarTests/ProvidersCodexTests/CodexRolloutScannerTests.swift
    - AgentsUsageBarTests/ProvidersCodexTests/CodexRolloutParserTests.swift
    - AgentsUsageBarTests/ProvidersCodexTests/Fixtures/codex-rollout-2026-fixture.jsonl
    - AgentsUsageBarTests/ProvidersCodexTests/Fixtures/codex-rollout-2025-legacy.jsonl
  modified:
    - AgentsUsageBar/Domain/ProviderID.swift (added .codex constant)
    - AgentsUsageBar.xcodeproj/project.pbxproj (Codex source subgroup + Models subgroup + ProvidersCodexTests group + Fixtures + build phases)
decisions:
  - "JSONDecoder is lenient by default — no AnyCodable/extraFields plumbing required for forward-compat (CLAUDE-03 / Pitfall 7). Matches Phase 2 TranscriptRecord stance; diverges from RESEARCH.md's hypothetical extraFields scaffold."
  - "CodexRolloutEvent.Window.resetsAtDate(now:) normalises both 2026 absolute (resets_at) and 2025 legacy relative (resets_in_seconds) schemas to absolute Date."
  - "Parser folds across [URL] comparing parsed ISO8601 timestamps, not file mtimes — long-running sessions whose rollout sits in yesterday's date dir but emits today are correctly handled (Pitfall 11)."
  - "Whole-file synchronous read in parser (Plan 03-04 will integrate TranscriptReader + offset cache; Codex rollout files are KB-MB range)."
  - "Test fixtures loaded via #filePath (mirrors ClaudeModelPricingTests pattern) — NOT added to PBXResourcesBuildPhase; no bundle dependency."
metrics:
  duration: "~35 minutes"
  completed: "2026-05-15"
  tasks: 3
  files_modified: 11
requirements:
  - CODEX-01 (partial — discovery + parse primitives; full Pending until Plan 03-04 composes actor)
  - CODEX-03 (partial — schema captures primary + secondary + reset windows; UI rendering Pending Plan 03-04)
---

# Phase 03 Plan 01: Codex Rollout Discovery Layer Summary

Adds the local-first Codex rollout discovery layer — a today+yesterday date-bucket scanner, a lenient `Codable` rollout event model, and a fold-to-last-token-count parser — that future Plan 03-04 will compose into `CodexJSONLProvider`. Three new source files, one model file, two test fixtures, and 23 Swift Testing cases covering DST / leap-day / symlink / malformed-line / schema-evolution / order-independence edges.

## What Was Built

### Production Files

**`AgentsUsageBar/Domain/ProviderID.swift`** — extended with `.codex` constant
- `public static let codex = ProviderID(rawValue: "codex")`
- `displayHint` switch already returned `"Codex"` for this rawValue (Phase 1 declaration); no other change to the file.

**`AgentsUsageBar/Providers/Codex/CodexRoots.swift`** — default root + override seam
- `enum CodexRoots` with `static var defaultRoot: URL?`
- Returns `~/.codex/sessions` when the directory exists on disk; otherwise `nil`.
- The `nil` path lets `CodexJSONLProvider` (Plan 03-04) render a muted "No data yet" row when both local and OAuth fallback yield nothing (Phase 1 D-03 / Phase 3 D-03).

**`AgentsUsageBar/Providers/Codex/CodexRolloutScanner.swift`** — date-bucket walker
- `struct CodexRolloutScanner: Sendable` with `init(now:fileManager:calendar:root:)`
- `func rolloutFiles() -> [URL]` — returns symlink-canonical `.jsonl` URLs from `<root>/YYYY/MM/DD` for today AND yesterday.
- Yesterday computed via `calendar.date(byAdding: .day, value: -1, to: startOfDay(for: now))` — Foundation handles DST and leap-day; no string subtraction (Pitfall 4 / STATE #16).
- Directory path components built via `DateComponents` + `String(format: "%02d", ...)` — never `DateFormatter` / `ISO8601DateFormatter` for date-bucket math (UI-04 / Pitfall 4).
- Hidden files skipped (`.skipsHiddenFiles`); non-`.jsonl` filtered.
- Missing date dirs log at `.notice` and are skipped; no throws.
- Returned URLs canonicalised via `resolvingSymlinksInPath()` so downstream cache keys (Plan 03-04 offset cache) remain stable across `/var` ↔ `/private/var` symlink forms (STATE #44).

**`AgentsUsageBar/Providers/Codex/Models/CodexRolloutEvent.swift`** — lenient Codable rollout event
- `struct CodexRolloutEvent: Decodable, Sendable, Equatable` with nested `Payload`, `TokenInfo`, `TokenUsage`, `RateLimits`, `Window`, `Credits`.
- Snake-case `CodingKeys` explicit on every type — no reliance on `JSONDecoder.keyDecodingStrategy`.
- Lenient by default: `JSONDecoder` silently ignores unknown JSON keys when the target struct does not declare them. **No `extraFields` / `AnyCodable` plumbing required** (RESEARCH.md's hypothetical extraFields scaffold is unnecessary — Phase 2 `TranscriptRecord` took the same stance).
- `Window` carries both `resetsAt: Int?` (2026 absolute Unix-seconds) AND `resetsInSeconds: Int?` (2025 legacy relative). `func resetsAtDate(now:) -> Date?` normalises either schema to absolute `Date`.

**`AgentsUsageBar/Providers/Codex/CodexRolloutParser.swift`** — fold-to-last-token-count
- `enum CodexRolloutParser` namespace with one static method:
  ```swift
  static func lastTokenCount(
      in fileURLs: [URL],
      using decoder: JSONDecoder = JSONDecoder()
  ) -> (event: CodexRolloutEvent, fileURL: URL)?
  ```
- Implementation: whole-file synchronous `String(contentsOf:encoding:.utf8)` read; line split on `\n`; each line `try? decoder.decode(...)` — malformed lines silently skipped (Pitfall 5).
- Predicate: only events with `type == "event_msg"` AND `payload.type == "token_count"` AND `payload.info != nil` qualify (RESEARCH correction #1 + Pitfall 11).
- Order-independent fold: compares parsed ISO8601 timestamps across all files using the dual fractional/non-fractional `ISO8601DateFormatter` pair (Phase 2 STATE #43 pattern). Returns the absolute-latest event regardless of `[URL]` iteration order.

### Test Files

**`AgentsUsageBarTests/DomainTests/ProviderIDCodexTests.swift`** — 2 tests
- `rawValue == "codex"` lock-in
- `displayHint == "Codex"` lock-in

**`AgentsUsageBarTests/ProvidersCodexTests/CodexRolloutScannerTests.swift`** — 12 tests
- Empty root, missing root, nil root → empty result
- Today-only, today+yesterday, three-days-back filtering
- Missing yesterday dir → today only, no throw
- DST 2026-03-08 PT → yesterday resolves to 2026/03/07
- Leap-day 2028-02-29 UTC → yesterday is 2028/02/28
- Symlink canonicalisation invariant
- Non-`.jsonl` filter; hidden-file skip

**`AgentsUsageBarTests/ProvidersCodexTests/CodexRolloutParserTests.swift`** — 9 tests
- 2026 fixture fold-to-latest (synthetic 11:57 event beats 11:56:30)
- 2026 fixture full-field decode (11:56:30 isolated → all RESEARCH fields present, `total_tokens == 556469`, `primary.usedPercent == 2`, `secondary.windowMinutes == 10080`, `planType == "plus"`)
- 2025 legacy decode: `resets_in_seconds == 300` → `resetsAtDate(now:)` ~300s in future
- Malformed truncated line skipped without throw
- Unknown future field `unknown_future_metric` tolerated (Pitfall 7)
- Order-independence: `[B, A]` input returns A's later-timestamp event
- Empty file list returns nil
- File with only `session_meta` returns nil
- `payload.type == "token_count"` event with `info == nil` skipped (Pitfall 11)

### Fixtures (loaded via `#filePath`, not bundle)

- `Fixtures/codex-rollout-2026-fixture.jsonl` — 5 lines: session_meta + response_item + complete 11:56:30 `event_msg.token_count` from RESEARCH.md §"API Schemas / Codex Rollout" + synthetic 11:57:00 small event + truncated last line (mid-write simulation per Pitfall 5).
- `Fixtures/codex-rollout-2025-legacy.jsonl` — 2 lines: session_meta + 2025-09 legacy `token_count` event using `resets_in_seconds: 300`.

## Test Suite Results

23 tests pass across all three suites (target ≥14 per plan-level success criteria — exceeded):

| Suite                          | Tests | Result |
|--------------------------------|-------|--------|
| ProviderIDCodexTests           | 2     | PASS   |
| CodexRolloutScannerTests       | 12    | PASS   |
| CodexRolloutParserTests        | 9     | PASS   |
| **Total**                      | **23**| **PASS** |

Full project build: `xcodebuild build -project AgentsUsageBar.xcodeproj -scheme AgentsUsageBar -configuration Debug` → `** BUILD SUCCEEDED **`.

## Invariant Verification

| Invariant                                                         | Result |
|-------------------------------------------------------------------|--------|
| `grep 'public static let codex' AgentsUsageBar/Domain/ProviderID.swift` | 1 hit ✓ |
| `grep 'Calendar(identifier:' AgentsUsageBar/Providers/Codex/CodexRolloutScanner.swift` | 0 hits ✓ |
| `grep 'DateFormatter\|ISO8601DateFormatter' AgentsUsageBar/Providers/Codex/CodexRolloutScanner.swift` | 0 hits ✓ |
| `grep 'resolvingSymlinksInPath' AgentsUsageBar/Providers/Codex/CodexRolloutScanner.swift` | 2 hits (≥1 required) ✓ |
| `grep 'payload.type' AgentsUsageBar/Providers/Codex/CodexRolloutParser.swift` mentions `"token_count"` | YES ✓ |
| `grep 'total_token_usage\|totalTokenUsage' …/Models/CodexRolloutEvent.swift` | 3 hits (≥2 required) ✓ |
| `grep 'resets_in_seconds\|resetsInSeconds' …/Models/CodexRolloutEvent.swift` | 5 hits (≥1 required) ✓ |

## Deviations from Plan

### 1. JSONDecoder lenient-by-default (no `AnyCodable` / `extraFields`)

- **Found during:** Task 3 implementation (CodexRolloutEvent)
- **Issue:** RESEARCH.md §"Codex Rollout JSONL Format" included hypothetical `extraFields: [String: AnyCodable]?` properties on every nested struct. The Phase 2 codebase has not adopted `AnyCodable`; `TranscriptRecord` deliberately omits it (CLAUDE-03 lenient-by-default note).
- **Decision:** Follow Phase 2 precedent — `JSONDecoder.decode(...)` already silently drops unknown keys when the target type does not declare them. No `AnyCodable` runtime dependency, no per-struct `extraFields` boilerplate.
- **Verification:** New test `unknown_future_field_does_not_break_decoding` proves forward-compat by adding a synthetic `unknown_future_metric` + `unknown_payload_key` to a JSONL line and asserting `try? decoder.decode(...)` returns the populated struct.
- **Plan compliance:** PLAN.md `<action>` explicitly directs "Do NOT include `extraFields: [String: AnyCodable]?` properties — the Phase 2 codebase has not adopted `AnyCodable` and JSONDecoder already tolerates unknown keys by default." — so this is plan-conformant; tracking it here for cross-referencing against RESEARCH.md's contrasting scaffold.

### 2. `ISO8601DateFormatter` use in `CodexRolloutParser.swift`

- **Found during:** Task 3 implementation
- **Issue:** The plan-level invariant `grep -rn 'DateFormatter\b' AgentsUsageBar/Providers/Codex/` returns 0 hits is satisfied for the scanner (date-bucket math) but the parser MUST parse the rollout event's ISO8601 `timestamp` field to fold by absolute time across files. This requires `ISO8601DateFormatter`.
- **Resolution:** This is intent-vs-literal-grep. The invariant text reads "date-bucket math is component-based only" — the parser does NOT do date-bucket math; it parses absolute UTC ISO8601 timestamps for ordering, which is the **correct** use of `ISO8601DateFormatter` (mirrors Phase 2 STATE #43 / `TranscriptRecord.parseISO8601`). The scanner, which actually does date-bucket math, has 0 hits.
- **Files affected:** `AgentsUsageBar/Providers/Codex/CodexRolloutParser.swift` — uses two `nonisolated(unsafe)` `ISO8601DateFormatter` instances for fractional + non-fractional parsing.
- **Plan compliance:** PLAN.md Task 3 `<action>` directs "parsing `event.timestamp` with the ISO8601 dual-formatter pattern" — so this is plan-conformant.

No bugs found (Rule 1), no missing critical functionality (Rule 2), no blocking issues (Rule 3), no architectural changes (Rule 4).

## Threat Surface Scan

No new threat surface beyond `<threat_model>`:

- T-03.01-01 (Tampering, decoder) — mitigated: `JSONDecoder` lenient, malformed lines skipped via `try?`.
- T-03.01-02 (DoS, whole-file read) — accepted: KB-MB range files; Plan 03-04 integrates streaming.
- T-03.01-03 (Info Disclosure, logger paths) — mitigated: `AppLogger` calls use only `lastPathComponent` with `.public`; no file content logged.
- T-03.01-04 (Tampering, symlink) — mitigated: `resolvingSymlinksInPath()` canonicalises before downstream consumption.
- T-03.01-SC (Tampering, package installs) — N/A: no SPM dependency added.

## Entry Points for Plan 03-04 (CodexJSONLProvider)

```swift
let scanner = CodexRolloutScanner(now: now)        // uses CodexRoots.defaultRoot
let files = scanner.rolloutFiles()                 // [URL] — today + yesterday
guard let pick = CodexRolloutParser.lastTokenCount(in: files) else {
    // No local rollout data → trigger OAuth fallback (Plan 03-03)
    return
}
let event = pick.event
let info = event.payload.info!                     // guaranteed by parser predicate
let primary = event.payload.rateLimits?.primary
let secondary = event.payload.rateLimits?.secondary
// Compose UsageSnapshot — primary fraction = Double(usedPercent)/100; reset = primary.resetsAtDate(now:)
```

## Commits

| Hash    | Message |
|---------|---------|
| e2bcd5e | feat(03-01): add ProviderID.codex constant + lock-in test |
| 6a18026 | feat(03-01): add CodexRoots + CodexRolloutScanner with today+yesterday walker |
| a31b99a | feat(03-01): add CodexRolloutEvent + CodexRolloutParser fold-to-last-token-count |

## Known Stubs

None — all primitives in this plan are fully wired. `CodexJSONLProvider` (the composer that consumes these) lands in Plan 03-04; until then, no user-facing UI surfaces this data. That is the documented plan boundary (PLAN.md `<objective>`: "This plan stops at scanning and parsing").

## Requirement Status

- **CODEX-01** — partial. Discovery + parse primitives delivered; full satisfaction requires Plan 03-04 (provider actor composition + UsageSnapshot wiring). Status remains Pending in REQUIREMENTS.md until 03-04 completes.
- **CODEX-03** — partial. Schema captures `primary`, `secondary`, `resetsAt`, `resetsInSeconds`; UI rendering deferred to Plan 03-04 / Plan 03-07. Status remains Pending in REQUIREMENTS.md until 03-04 completes.

## Self-Check: PASSED

- `AgentsUsageBar/Providers/Codex/CodexRoots.swift` — exists ✓
- `AgentsUsageBar/Providers/Codex/CodexRolloutScanner.swift` — exists ✓
- `AgentsUsageBar/Providers/Codex/CodexRolloutParser.swift` — exists ✓
- `AgentsUsageBar/Providers/Codex/Models/CodexRolloutEvent.swift` — exists ✓
- `AgentsUsageBarTests/DomainTests/ProviderIDCodexTests.swift` — exists ✓
- `AgentsUsageBarTests/ProvidersCodexTests/CodexRolloutScannerTests.swift` — exists ✓
- `AgentsUsageBarTests/ProvidersCodexTests/CodexRolloutParserTests.swift` — exists ✓
- `AgentsUsageBarTests/ProvidersCodexTests/Fixtures/codex-rollout-2026-fixture.jsonl` — exists ✓
- `AgentsUsageBarTests/ProvidersCodexTests/Fixtures/codex-rollout-2025-legacy.jsonl` — exists ✓
- Commit `e2bcd5e` (Task 1) — present in git log ✓
- Commit `6a18026` (Task 2) — present in git log ✓
- Commit `a31b99a` (Task 3) — present in git log ✓
- All 23 tests PASS ✓
- Project Debug build succeeds ✓
