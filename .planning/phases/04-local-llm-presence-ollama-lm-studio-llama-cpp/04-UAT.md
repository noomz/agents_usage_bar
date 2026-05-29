# Phase 4 — User Acceptance Test

**Reviewer:** Siriwat Uamngamsup
**Date:** <fill-in at run time>
**Build:** `883702b1dc795003d81f0584fd5b7c1c0e6aa8fd` (HEAD at UAT authoring time)

## Test outcomes table

| #  | Test                                                                                                              | Result    | Notes |
|----|-------------------------------------------------------------------------------------------------------------------|-----------|-------|
| 1  | Ollama row populates from /api/ps + /api/tags with 1–2s timeout (SC #1 — LOCAL-01 + LOCAL-04)                     | PASS      | Verified 2026-05-19 by reviewer. Ollama running with 3 models (gemma4:latest, qwen3.6:27b, embeddinggemma:latest). |
| 2  | LM Studio row populates with port override via config.toml (SC #2 — LOCAL-02 + LOCAL-04)                          | PASS      | Verified 2026-05-19 by reviewer. |
| 3  | llama.cpp row activates only with port configured; D-04 placeholder when unconfigured (SC #3 — LOCAL-03 + D-04)   | PASS      | Verified 2026-05-20. Hotfix landed mid-UAT: stale `placeholderMessage` survived in cache after port nil→8080 transition. Fixed in `ProviderState.applying`/`applyingError` + 3 regression tests. See Hotfixes table below. |
| 4  | Connection-refused → muted "Not running" — never red — does not block other providers (SC #4 — LOCAL-04 + LOCAL-05)| PASS      | Verified 2026-05-20 serialized (memory constraint prevented loading 3 models simultaneously). Hotfix H-02 landed mid-UAT: actor's `.notRunning` classification was dead code; UsageSnapshot lacked status field → store forced `.ok` → UI showed state B instead of state A. Fixed via `raw["providerStatus"] = "notRunning"` sentinel + ProviderState.applying branch. |
| 5  | No cumulative-token count ever displayed on any local row (SC #5 — LOCAL-06 anti-feature enforcement)             | PASS      | Verified 2026-05-20 via screenshot. All 3 locals showed "Not running" gray rows (post-H-02). Today total = 2,202,309 tokens reflected Claude only; no token/USD/balance figures anywhere on local rows; `Total excludes quota-only providers` footnote present. |
| 6  | ProviderStatus.notRunning foundation + URLError classifier + StatusDot.gray (Plan 04-01 Wave 1)                   | ATTESTED  | `ProviderStatusNotRunningTests` + `ProviderIDLocalConstantsTests` + `ProviderErrorLocalhostClassifierTests` + `StatusDotNotRunningTests` — 23 cases. See 04-01-SUMMARY.md. |
| 7  | Config layer — AppConfig + ConfigStore [ollama] / [lmstudio] / [llamacpp] parsing (Plan 04-02 Wave 1)             | ATTESTED  | `AppConfigLocalProvidersTests` (9 cases) + `ConfigStoreLocalSectionsTests` (8 cases). See 04-02-SUMMARY.md. |
| 8  | Per-runtime probe actors — OllamaProvider + LMStudioProvider + LlamaCppProvider (Plans 04-04/05/06 Wave 2)        | ATTESTED  | `OllamaProviderTests` (18+) + `LMStudioProviderTests` (19+) + `LlamaCppProviderTests` (15+) + three Codable suites (12+11+11 cases). See 04-04/05/06-SUMMARY.md. |
| 9  | UI row-state rendering — LocalRowSecondaryView five states + ProviderRowView branching (Plan 04-07 Wave 3)         | ATTESTED  | `LocalRowSecondaryViewTests` (16 cases) + `ProviderRowViewLocalRowTests` (7 cases). See 04-07-SUMMARY.md. |
| 10 | Composition + LOCAL-06 enforcement + ThresholdEngine skip (Plan 04-08 Wave 3)                                     | ATTESTED  | `AppDependenciesLocalRegistrationTests` (7 cases) + `ThresholdEngineLocalNilQuotaTests` (5 cases) + `AggregateStoreLocalRollupTests` (4 cases). See 04-08-SUMMARY.md. |

**Overall outcome:** **APPROVED** — 2026-05-20. All 10 tests pass (5 manual + 5 attested). Two hotfixes landed mid-UAT: H-01 (stale placeholderMessage on cache reload) and H-02 (notRunning status dead-coded — actor → UI propagation gap). Both have regression tests. Phase 4 code-complete + reviewer-signed.

---

## Pre-conditions

Before running Tests 1-5, satisfy **all** of the following:

- **Build:** `xcodebuild build -project AgentsUsageBar.xcodeproj -scheme AgentsUsageBar -configuration Debug` exits 0.
- **Launch:** Open the app from `~/Library/Developer/Xcode/DerivedData/AgentsUsageBar-*/Build/Products/Debug/AgentsUsageBar.app`. The menu bar icon should appear within 2s.

**For Test 1 (Ollama):**
- Install Ollama from https://ollama.com (or `brew install ollama`).
- Start the server: `ollama serve` in a terminal (or `brew services start ollama`).
- Pre-pull at least one model: `ollama pull llama3:8b` (or any model).
- Verify: `curl -s http://localhost:11434/api/ps | python3 -m json.tool` returns a JSON `models` array (may be empty if nothing is loaded yet).
- Verify: `curl -s http://localhost:11434/api/tags | python3 -m json.tool` returns a `models` array with at least one entry.

**For Test 2 (LM Studio):**
- Install LM Studio from https://lmstudio.ai.
- Load at least one model in the LM Studio UI via Models panel.
- Enable the local server (LM Studio Developer tab → toggle "Start server").
- Default port is **1234**; note the port shown in the LM Studio UI.
- If using a custom port: add `[lmstudio]\nport = <custom>` to `~/.config/agents-usage-bar/config.toml` before launching the app.

**For Test 3 (llama.cpp / llamafile):**
- Option A: `brew install llama.cpp` — then `llama-server -m <model.gguf> --port 8080`.
- Option B: Download a `llamafile` from https://github.com/Mozilla-Ocho/llamafile — then `./modelname.llamafile --server --port 8080`.
- Add `[llamacpp]\nport = 8080` to `~/.config/agents-usage-bar/config.toml`.
- For the state-E "loading model" sub-test (step 5), use a large model (30+ GB) so the warmup window is visible.

**For Test 4 (connection-refused):**
- Ensure all three runtimes are running first (Tests 1-3 satisfied), then stop them individually per the test steps.
- `pkill -f "ollama serve"` or `brew services stop ollama` to stop Ollama.
- Quit LM Studio app to stop LM Studio.
- `pkill -f "llama-server"` or `pkill -f ".llamafile"` to stop llama.cpp.

**Phase 1/2/3 regression baseline:**
- Keep `OPENROUTER_API_KEY` env var set so the OpenRouter row also populates.
- Have `~/.claude/projects/` with today's JSONL transcripts for the Claude row.
- Have `~/.codex/sessions/$(date +%Y/%m/%d)/rollout-*.jsonl` for the Codex row.
- Have `~/.gemini/oauth_creds.json` populated for the Gemini row.
- The full 4-row hosted-API popover should be visible alongside the 3 local rows.

**Log stream (recommended):**
Open a second Terminal window with:
```
log stream --predicate 'subsystem == "app.agents-usage-bar" AND (category == "ollama" OR category == "lmstudio" OR category == "llamacpp")' --info
```

---

## Test 1 — Ollama row populates (Phase 4 SC #1 / LOCAL-01 + LOCAL-04)

1. Open the popover by clicking the menu bar icon.
2. Verify an **"Ollama"** row exists in the popover (below the four hosted-API rows: OpenRouter, Claude, Codex, Gemini).
3. **PASS** if the Ollama row shows the loaded model name within 5s of opening (e.g. `llama3:8b`). If nothing is loaded yet, the row may read `"Idle — 0 models loaded"` (state B) — PASS if the model name appears after running `ollama run llama3:8b "hello"` in a terminal and clicking Refresh.
4. **PASS** if `/api/ps` returns a non-zero `size_vram` value, the row shows a VRAM suffix: e.g. `llama3:8b · 4.8 GB VRAM`. Confirm: `curl -s http://localhost:11434/api/ps | python3 -c "import sys,json; ps=json.load(sys.stdin); print(ps['models'][0].get('size_vram', 0))"` — if non-zero, the row must render it.
5. **PASS (multi-model, if applicable):** If running two models simultaneously (`ollama run llama3:8b` in one shell, `ollama run mistral` in another), the Ollama row shows `<firstModelName> · +1 more`. Tooltip (hover the Ollama displayName) enumerates both names. *Mark DEFERRED if the reviewer only has one model available.*
6. **PASS** if `log stream … category == "ollama"` shows `GET /api/ps → 200` and `GET /api/tags → 200` lines within each poll cycle (default 5 min, or immediately on popover-open refresh per POLL-03).
7. **2s timeout sub-test (POLL-08):** Stop Ollama (`pkill -f "ollama serve"`), then open the popover or click Refresh. **PASS** if the Ollama row transitions to `"Not running"` with a **gray** status dot within ≤ 3s (the 2s localhost timeout fires and `URLError.cannotConnectToHost` maps to `.notRunning`). Verify no error styling (never red). This sub-test overlaps with Test 4 step 2; mark PASS here if confirmed there.
8. **Recovery:** `ollama serve &` in background; click Refresh. **PASS** if the Ollama row returns to the model-name state within one poll cycle (non-terminal status re-probed every poll per POLL-06).

---

## Test 2 — LM Studio row + port override (Phase 4 SC #2 / LOCAL-02 + LOCAL-04)

1. Open the popover. Verify an **"LM Studio"** row exists.
2. **PASS** if the LM Studio row shows the loaded model id (e.g. `meta-llama-3.1-8b-instruct`) within 5s of popover-open.
3. **PASS** if `log stream … category == "lmstudio"` shows `GET /api/v0/models → 200`. If LM Studio is older (< 0.3.5), the log shows `GET /api/v0/models → 404` then `GET /v1/models → 200` (fallback path per Plan 04-05 OQ-2). Either path is PASS.
4. **PASS** if loading an additional model in the LM Studio UI (Models panel → Load) updates the row within one poll cycle: the secondary line transitions to `<firstModel> · +1 more` (D-03 multi-model state D).
5. **Port override sub-test (LOCAL-02):** Quit the app. Add or update `~/.config/agents-usage-bar/config.toml`:
   ```toml
   [lmstudio]
   port = 4321
   ```
   Restart LM Studio on port 4321 (LM Studio Developer tab → change port → restart server). Relaunch the app. **PASS** if the LM Studio row populates from port 4321 — verify via `log stream … category == "lmstudio"` that URL contains `localhost:4321`, not `localhost:1234`.
6. **Fallback sub-test (optional / OQ-2):** If the reviewer has an older LM Studio build (< 0.3.5) that does NOT expose `/api/v0/models`, **PASS** if the row STILL populates via the `/v1/models` fallback. *Mark DEFERRED if no older build is available — attested by `LMStudioProviderTests.fallbackToV1Models_whenV0Returns404` and `fallbackToV1Models_whenV0Returns500`.*

---

## Test 3 — llama.cpp row activates only with port + D-04 placeholder (Phase 4 SC #3 / LOCAL-03 + LOCAL-04 + D-04)

### 3a — Unconfigured baseline (D-04)

1. Ensure `~/.config/agents-usage-bar/config.toml` does NOT contain a `[llamacpp]` section (or `[llamacpp]` has no `port` key). Quit and relaunch the app.
2. Open the popover. Verify a **"llama.cpp"** row exists.
3. **PASS** if the llama.cpp row shows the **exact** subtitle text:
   ```
   Set [llamacpp] port in config.toml to enable
   ```
   (D-04 verbatim — this is the discoverability placeholder, attested by `AppDependenciesLocalRegistrationTests.seedPlaceholder_llamacppWithSubtitle`.)
4. **PASS** if the row status dot is **gray** (`.notRunning` mapping — attested by `ProviderStatePlaceholderMessageTests.placeholderFactory_carriesNotRunningStatus`).
5. **PASS** if `log stream … category == "llamacpp"` shows **NO** probe requests to any localhost port — confirming the LOCAL-03 no-scanning invariant (the row is a placeholder; no HTTP call is issued without an explicit port).

### 3b — Configured probe path

6. Add `[llamacpp]` section to `~/.config/agents-usage-bar/config.toml`:
   ```toml
   [llamacpp]
   port = 8080
   ```
   Start `llama-server -m <model.gguf> --port 8080` (or `./model.llamafile --server --port 8080`). Quit and relaunch the app.
7. **PASS** if the llama.cpp row transitions from the D-04 placeholder to the model basename (e.g. `llama-3-8b-instruct-Q4_K_M` — the `.gguf` extension stripped per Plan 04-06). Note: the full path like `/Users/.../models/llama-3-8b-instruct-Q4_K_M.gguf` should be trimmed to the basename only.
8. **PASS** if `log stream … category == "llamacpp"` shows requests to `/health`, `/v1/models`, and `/slots` within one poll cycle.

### 3c — State E "loading model" (optional)

9. Restart llama-server with a **large model** (30+ GB) so the warmup window is observable (10–60s). Open popover during the warmup window. **PASS** if the llama.cpp row reads `"Running — loading model…"` — NOT "Not running", NOT a red error. After loading completes, the row transitions to `<model-basename>`. *Mark DEFERRED with `LlamaCppProviderTests.loadingModelHealth_yieldsStateE` attestation if the reviewer cannot allocate setup time for a large model.*

### 3d — Port removed → back to placeholder

10. Remove `port` from the `[llamacpp]` section (or remove the whole `[llamacpp]` section). Quit and relaunch the app. **PASS** if the llama.cpp row reverts to the D-04 unconfigured placeholder subtitle.

---

## Test 4 — Connection-refused → muted "Not running"; never red; never blocking (Phase 4 SC #4 / LOCAL-04 + LOCAL-05)

1. With all three local runtimes **running** (Ollama + LM Studio + llama.cpp rows all populated with model names / running state), confirm each shows a green-or-neutral status dot and its model name.

2. **Stop Ollama:** `pkill -f "ollama serve"` (or `brew services stop ollama`). Click Refresh in the popover footer (or wait ≤ one poll). **PASS** if:
   - Ollama row transitions to `"Not running"` with a **gray** status dot.
   - Status dot is NEVER **red** (not an error state).
   - Subtitle is NEVER an error string like "Failed" or "Error".

3. **PASS (cross-provider isolation):** After stopping Ollama, confirm ALL other provider rows (OpenRouter, Claude, Codex, Gemini, LM Studio, llama.cpp) continue refreshing normally — their `"Updated Xs ago"` labels tick forward and values change as their underlying sources do. (Per GEMINI-04 generalised: local actors NEVER throw for transient failures, so `AggregateStore.performRefresh` always moves to the next provider.)

4. **Stop LM Studio:** Quit the LM Studio app. Click Refresh or wait one poll. **PASS** if the LM Studio row transitions to `"Not running"` gray within one poll cycle, and all other rows remain unaffected.

5. **Stop llama.cpp:** `pkill -f "llama-server"` (or `pkill -f ".llamafile"`). **PASS** if the llama.cpp row transitions to `"Not running"` gray within one poll cycle, and all other rows remain unaffected.

6. **Log-level check:** `log stream … category == "ollama" OR category == "lmstudio" OR category == "llamacpp"` shows **NO `.error`-level** log lines for the stopped runtimes — at most `.notice` or `.info` level (the probe records the connection-refused event at notice, not error, per the never-throws actor design in Plans 04-04..04-06).

7. **Threshold isolation sub-test (optional):** With at least one local runtime in "Not running" state, force a quota fraction crossing on a different provider (e.g. OpenRouter approaching 85%). **PASS** if the notification still fires for the REMOTE provider — the locals' `.notRunning` state (with `quota == nil`) never blocks unrelated threshold decisions. *Mark DEFERRED with `ThresholdEngineLocalNilQuotaTests` attestation if the reviewer cannot force a crossing manually.*

8. **Recovery:** `ollama serve &`; click Refresh. **PASS** if the Ollama row returns to model-name state within one poll cycle (`.notRunning` is non-terminal per D-01 — `AggregateStore.performRefresh` does NOT skip `.notRunning` providers in the terminal-skip block).

---

## Test 5 — No cumulative-token count ever displayed on local rows (Phase 4 SC #5 / LOCAL-06 anti-feature)

1. With all three local runtimes running and rendering model names, scrutinise EVERY local row (Ollama, LM Studio, llama.cpp) carefully — both the primary line (displayName) and the secondary line (model name / state text).

2. **PASS** if NO local row shows ANY of the following substrings anywhere in its rendered text:
   - `"tokens"` (any capitalisation)
   - `"USD"` or `"$"` (any cost figure)
   - `"bal"` or `"balance"`
   - `"K tokens"` or `"M tokens"`
   - Any numeric figure formatted like a token count (e.g. `"335,371"`)

3. **Acceptable secondary-line strings on a local row** (the ONLY accepted values):
   - `"Not running"` (state A)
   - `"Idle — 0 models loaded"` (state B)
   - `"Idle — no models installed"` (state B')
   - `"<modelName>"` optionally with `· X.X GB VRAM` (state C, Ollama only for VRAM)
   - `"<modelName> · +N more"` (state D)
   - `"Running — loading model…"` (state E)
   - `"Set [llamacpp] port in config.toml to enable"` (D-04 placeholder)

4. **Active usage sub-test:** Run `ollama run llama3:8b "Tell me a joke. Use lots of tokens."` in a terminal and wait ≥ 30s for the session to generate tokens. **PASS** if the Ollama row does NOT display any token figure before, during, or after generation. The secondary line must remain in one of the acceptable strings above.

5. **Today Total header check (D-07):** The `"Today total"` header at the popover top reflects ONLY remote-provider (hosted-API) totals. **PASS** if the total tokens / cost figures do NOT change when local runtimes generate tokens (they are excluded per `AggregateStore.rollupTotals()` D-07 / `hasTokens=false` local capability).

6. **Footnote check:** **PASS** if the `"Total excludes quota-only providers"` footnote appears under the Today Total row whenever any local provider is registered — confirms `AggregateStore.hasAnyQuotaOnlyProvider` returns `true` when locals are present (attested by `AggregateStoreLocalRollupTests.hasAnyQuotaOnlyProvider_trueWhenAnyLocalRegistered`).

7. **Source audit (optional):** Run:
   ```
   grep -rE 'tokensToday|tokenCount|costTodayUSD' AgentsUsageBar/Providers/Ollama/ AgentsUsageBar/Providers/LMStudio/ AgentsUsageBar/Providers/LlamaCpp/
   ```
   **PASS** if the output is empty (0 matches). This was enforced as an acceptance criterion in Plans 04-04, 04-05, and 04-06, and is also locked by `LocalRowSecondaryViewTests.noLocal06Leak_secondaryTextNeverIncludesUSD`.

---

## Tests 6-10 — Unit-test attestation

Tests 6-10 cover invariants that cannot be exhaustively manually verified (schema parsing fidelity, URLError-to-status classification, per-actor state-machine across all probe combinations, UI branch correctness without live runtime, ThresholdEngine skip on nil-quota snapshot). All cited suites passed when their plans landed; the reviewer can spot-check by running `xcodebuild test -project AgentsUsageBar.xcodeproj -scheme AgentsUsageBar -only-testing AgentsUsageBarTests/<SuiteName>` if desired. Mirrors the Phase 2 `02-UAT.md` + Phase 3 `03-UAT.md` attested-by-suite pattern.

> **Test 6 — `ProviderStatus.notRunning` foundation + URLError classifier + StatusDot.gray:** Attested by `ProviderStatusNotRunningTests` (3+ cases), `ProviderIDLocalConstantsTests` (6+ cases incl. `localIDs` Set carrier — `.ollama`, `.lmstudio`, `.llamacpp` present), `ProviderErrorLocalhostClassifierTests` (8+ parameterised cases: `.cannotConnectToHost` / `.cannotFindHost` / `.networkConnectionLost` / `.timedOut` → `.notRunning`; `.notConnectedToInternet` / HTTP 500 / `DecodingError` → `.error`), `StatusDotNotRunningTests` (4+ cases — `.notRunning` maps to gray dot, `accessibilityLabel == "Status: Not running"`). **POLL-06 non-terminal invariant:** `grep -E 'case \.notRunning' AgentsUsageBar/Aggregation/AggregateStore.swift` returns 0 matches (the case is deliberately ABSENT from the terminal-skip block — `.notRunning` providers are re-probed on every poll, as confirmed by `notRunning_providerIsReprobedOnNextRefresh` integration test asserting `fetchCallCount == 2` across two `refresh(now:)` calls). See `04-01-SUMMARY.md`.

> **Test 7 — Config layer for the three local sections:** Attested by `AppConfigLocalProvidersTests` (9 cases verifying defaults: `OllamaConfig(enabled: true)`, `LMStudioConfig(enabled: true, port: 1234)`, `LlamaCppConfig(enabled: true, port: nil)`) + `ConfigStoreLocalSectionsTests` (8 cases incl. TOML `[ollama] enabled = false` disables, `[lmstudio] port = 4321` override, `[llamacpp] port = 8080` sets non-nil, garbage-fail-soft (D-18), regression against Phase 1+3 surface). Phase 1 D-17 env > toml > defaults precedence preserved; no env override for locals per CONTEXT Discretion (no secrets — port + enable are config knobs, not credentials). `LlamaCppConfig.port: Int?` nil-default is the D-04 gating signal read by `AppDependencies.makeProduction()`. See `04-02-SUMMARY.md`.

> **Test 8 — Per-runtime probe actors (Plans 04-04, 04-05, 04-06):** Attested by:
> - `OllamaProviderTests` (18+ cases — happy path single-model state C + multi-model state D with `+N more` badge + state B idle-0-loaded + state B' no-models-installed + connection-refused → `.notRunning` + tags-failure-doesn't-abort + LOCAL-06 source-grep (0 tokensToday/cost references) + D-12 no-CircuitBreaker + bearer-always-nil). `OllamaResponsesCodableTests` (12+ cases — lenient decode with unknown future fields, snake_case CodingKeys, `sizeVram: Int64` non-zero). See `04-04-SUMMARY.md`.
> - `LMStudioProviderTests` (19+ cases — extended `/api/v0/models` endpoint primary path + `/v1/models` fallback on 404 AND on 500 (OQ-2) + `state == "loaded"` filtering + nil-state treated as loaded (old-build compat) + port override propagation + LOCAL-06 zero-ref). `LMStudioResponsesCodableTests` (12+ cases). See `04-05-SUMMARY.md`.
> - `LlamaCppProviderTests` (15+ cases — `/health` `"ok"` → state C + `"loading model"` HTTP-200 → state E (never `.error`, OQ-1) + `"error"` → `.notRunning` (connection-level error) + `"no slot available"` → running (OQ-3 lenient) + unknown status → running (OQ-3) + basename trimming via `URL.lastPathComponent` + opportunistic `/slots` ignored on failure + `placeholderFactory_carriesNotRunningStatus` asserts `status == .notRunning` AND `placeholderMessage == "Set [llamacpp] port in config.toml to enable"` verbatim). `LlamaCppResponsesCodableTests` (11+ cases). `ProviderStatePlaceholderMessageTests` (5+ cases). See `04-06-SUMMARY.md`.
> Combined LOCAL-06 enforcement: every actor's source contains **0** token/cost references — negative-grep gate is part of each plan's acceptance criteria. Combined: 62+ test cases across three actor suites + three Codable suites.

> **Test 9 — UI row-state rendering (Plan 04-07):** Attested by `LocalRowSecondaryViewTests` (16 cases — one per row state A/B/B'/C/D/E + `placeholderMessage` highest-priority branch + VRAM suffix formatting `"X.X GB VRAM"` via `vramBytes/1_073_741_824` + VRAM suppressed when `vramBytes == 0` (OQ-4) + LOCAL-06 invariant `noLocal06Leak_secondaryTextNeverIncludesUSD` source-walk assertion) + `ProviderRowViewLocalRowTests` (7 cases — `if isLocal { LocalRowSecondaryView } else { … tokenText … }` branching pattern locked; `isLocal` keyed off `ProviderID.localIDs.contains(state.id)`; `arrow.up.right.square` disabled for local IDs (D-13 `dashboardURL == nil`); Phase 3 degraded `"usage temporarily unavailable"` subtitle preserved for non-local rows (regression lock)). `StatusDot.notRunning → gray` locked by Test 6. See `04-07-SUMMARY.md`.

> **Test 10 — Composition + cross-cutting policy (Plan 04-08):** Attested by `AppDependenciesLocalRegistrationTests` (7 cases incl. Ollama registered when `config.ollama.enabled` + LM Studio registered when `config.lmstudio.enabled` + llama.cpp registered when `port != nil` (LOCAL-03 gate) + D-04 placeholder seeded with verbatim subtitle when `port == nil` + `makeProduction_smokeTest` cross-environment composition-root check — second `URLSessionHTTPClient(timeoutSeconds: 2)` injected for localhost tier (POLL-08)) + `ThresholdEngineLocalNilQuotaTests` (5 cases — locals with `quota: nil` produce 0 `NotificationDecision`s; mixed local (`.notRunning`, quota nil) + remote (`.ok`, 0.85 fraction) emits exactly 1 decision for the remote provider; same-provider re-fire suppression unaffected; Pitfall 6 lock — no notification storm from local rows) + `AggregateStoreLocalRollupTests` (4 cases — D-07 `rollupTotals()` exclusion: Ollama/LM Studio/llama.cpp snapshots excluded when `hasTokens=false`; `hasAnyQuotaOnlyProvider` returns `true` when any local is registered (footnote trigger); regression: hosted-API totals unchanged by local registration). See `04-08-SUMMARY.md`.

---

## Hotfixes landed during the UAT session

| Commit  | Subject                                                                          |
|---------|----------------------------------------------------------------------------------|
| 7b3aabc | fix(04-review): clear stale placeholderMessage on successful snapshot (H-01) — caught during Test 3 reviewer walkthrough. ProviderState.applying / applyingError carried placeholderMessage forward; cache persisted hybrid (snapshot + placeholderMessage) state; LocalRowSecondaryView priority-order rendered stale hint over live model data. Invariant established: `placeholderMessage != nil ⇒ snapshot == nil ∧ lastSuccess == nil`. 3 new regression tests in ProviderStatePlaceholderMessageTests. |
| 2dc27a5 | fix(04-review): propagate .notRunning from local actors to UI (H-02) — caught during Test 4. Cross-layer integration gap: Plans 04-04/05/06 actors classified URLError as `.notRunning`, set internal `self.lastStatus`, returned mutedNotRunningSnapshot. But `UsageSnapshot` has no status field → `AggregateStore.apply(.success)` → `ProviderState.applying` forced `.ok` → UI rendered state B "Idle — 0 models loaded" + green dot, indistinguishable from healthy probe. Actor `lastStatus` mutation was dead code. Attestation tests only checked actor internals, never end-to-end propagation. Fix: `raw["providerStatus"] = "notRunning"` sentinel + `ProviderState.applying` branches on sentinel (status `.notRunning`, lastSuccess preserved). 2 new regression tests + actor regression green. |

*(If the reviewer encounters a regression during manual walkthrough, hotfix commits land here. Mirrors Phase 3 G-01..G-04 pattern and Phase 2 `378c531` / `c84c452` / `4a5ebee` table.)*

---

## Reviewer signal

Reply with one of:

- `approved` — Phase 4 complete; the executor will commit the marked-up 04-UAT.md, update STATE.md + ROADMAP.md, and the orchestrator can run `/gsd-transition` to advance to Phase 5 (First-Run UX + Settings Polish).
- `failed: <test#>: <description>` — File one or more gap entries. The executor records the failed steps in this 04-UAT.md, leaves Phase 4 in BLOCKED state, and the next action is `/gsd-plan-phase 04 --gaps` to plan closure.
- `deferred: <test#>: <reason>` — Accept the test as unit-test-attested only (mirrors Phase 2/3 reviewer accepting attestation rows). Phase 4 still considered complete if Tests 1-5 manual or 6-10 attested.

---

## Phase 4 Success Criteria Mapping

| Success Criterion                                                                                            | UAT Tests        |
|--------------------------------------------------------------------------------------------------------------|------------------|
| #1 — Ollama row from /api/ps + /api/tags with 1–2s timeout (LOCAL-01 + LOCAL-04)                             | Test 1, 6, 8     |
| #2 — LM Studio row + port override (LOCAL-02 + LOCAL-04)                                                     | Test 2, 7, 8     |
| #3 — llama.cpp only with port + D-04 placeholder (LOCAL-03 + LOCAL-04 + D-04)                                | Test 3, 7, 8, 10 |
| #4 — Connection-refused muted, never blocking (LOCAL-04 + LOCAL-05)                                          | Test 4, 6, 8     |
| #5 — LOCAL-06 anti-feature — no token count ever (LOCAL-06)                                                  | Test 5, 8, 9, 10 |
