# Phase 4: Local LLM Presence (Ollama + LM Studio + llama.cpp) - Context

**Gathered:** 2026-05-18
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 4 ships three localhost AI-runtime rows — **Ollama** (`http://localhost:11434`), **LM Studio** (default `localhost:1234`, port overridable in `~/.config/agents-usage-bar/config.toml`), and **llama.cpp / llamafile** (port REQUIRED in TOML — no scanning) — each rendering tri-state presence (`notRunning | running | error`) plus the loaded model name. This is the differentiator phase: localhost services that aren't running render muted, never red, never blocking. Every reusable primitive from Phases 1–3 (`UsageProvider` actor, `AggregateStore`, `ThresholdEngine` FSM, `CircuitBreaker`, `HTTPClient.get(bearer: nil)` unauthenticated overload, `Secret` wrapper, `ConfigStore` env > toml > defaults precedence, placeholder-row pattern, `ProviderCapabilities.isLocal` flag, `tooltipLabel` carrier) is exercised; this phase adds NO new architectural seam.

**In scope (6 requirements from ROADMAP.md):**
LOCAL-01, LOCAL-02, LOCAL-03, LOCAL-04, LOCAL-05, LOCAL-06.

**Out of scope (deferred):**
- Cumulative token tracking for any local runtime — LOCAL-06 anti-feature, requires request proxying, port-conflict footgun
- First-run welcome screen / per-provider auto-detection card (CFG-03, CFG-04) — Phase 5
- Settings scene with per-provider port pickers + enable toggles (SHELL-05, CFG-05) — Phase 5
- Distribution / notarization / DMG (REL-*, SEC-03) — Phase 6
- Real-time activity stream from local runtimes — v2 (EXP-01)
- Per-model usage breakdown beyond model name — v2 (EXP-02)
- Custom OpenAI-compatible probe (Jan, vLLM, custom servers) — v2; v1 covers three runtimes

</domain>

<decisions>
## Implementation Decisions

### Tri-state Status Semantics

- **D-01:** **Add `ProviderStatus.notRunning` case.** Localhost-specific status semantically distinct from `.unauthenticated` (which is POLL-06-terminal — `AggregateStore.performRefresh` at `AggregateStore.swift:271` hard-skips terminal-unauth providers; the row would never recheck). `.notRunning` MUST remain **non-terminal** so the next 5-min tick re-probes and flips the row to `running` the moment the user runs `ollama serve`. `StatusDot` (`UI/Components/StatusDot.swift:48`) maps `.notRunning → .gray` (matches LOCAL-04 "muted, never red"). Every existing exhaustive `switch ProviderStatus` adds the new arm (mechanical ripple: `StatusDot.dotColor`, `StatusDot.accessibilityLabel`, `ProviderState.applyingError`, `ThresholdEngine` skip-rules, `NotificationActionHandler`, any test fixtures). Sandwich the case between `.unauthenticated` and `.disabled` in the enum declaration to keep "muted-gray-family" arms grouped.

### Model Name + Slot/VRAM Display

- **D-02:** **Secondary line carries model name (and optional slot/VRAM).** The `tokens · USD · balance` HStack in `UI/ProviderRowView.swift:72-91` renders all "—" for `isLocal=true` rows because LOCAL-06 forbids token counts. Repurpose that line for locals: `running` ⇒ `<modelName>` (e.g. `llama3:8b`) optionally suffixed with `· <vram> GB VRAM` when the probe response carries it (Ollama `/api/ps` returns `size_vram`; LM Studio + llama.cpp may not — emit model name only when absent). The view-side branch keys off `state.snapshot.providerID` (via `capabilities.isLocal`) or directly off the snapshot fields (`tokensToday == nil && quota == nil`). Tooltip (`UsageSnapshot.tooltipLabel` via `.help()`) carries deeper detail when surfaced (full per-slot breakdown, family/quantization) — same channel pattern Phase 3 used for tier label (Phase 3 D-15).
- **D-02a:** **Snapshot carrier = repurpose `raw[String: String]` for structured payload.** `UsageSnapshot.raw` (UsageSnapshot.swift:35) already exists; populate for locals with `raw["modelName"]`, `raw["modelCount"]`, `raw["vramBytes"]`. NO new domain field on `UsageSnapshot`. Keeps Phase 4 zero-touch on `Domain/UsageSnapshot.swift` apart from possibly documenting the keys. `ProviderRowView` reads keyed strings; this is the standard escape-hatch for provider-specific surface data per Phase 1 comment "Raw provider-specific fields for debugging."

### Multi-Model UX (Ollama-specific)

- **D-03:** **First model name + `+N more` badge when Ollama `/api/ps` returns >1 concurrently-loaded model.** Four explicit row states for the secondary line:
  - `Not running` — probe returned connection-refused (`URLError.cannotConnectToHost` / `.cannotFindHost`)
  - `Idle — 0 models loaded` — server up (HTTP 200 from `/api/ps`), but `models[]` is empty AND `/api/tags` reports installed models (so "configured, just nothing loaded right now")
  - `<modelName>` — exactly one model loaded (LM Studio + llama.cpp default to this)
  - `<firstModelName> · +N more` — Ollama with N>1 loaded; tooltip enumerates all names
  - LM Studio / llama.cpp: same shape but `+N more` will be rare (single-model runtimes); same logic, no special-casing needed.

### Unconfigured llama.cpp Discoverability

- **D-04:** **llama.cpp row ALWAYS present as a placeholder when `[llamacpp].port` is unset.** Mirror the Codex/Gemini placeholder pattern from `App/AppDependencies.swift:259-275`. Row status = `.notRunning`. Display name `llama.cpp`. The placeholder surfaces a discoverability subtitle: `"Set [llamacpp] port in config.toml to enable"`. Same shape as the existing `seedPlaceholder` calls. Carrier = the existing `ProviderState.placeholderMessage` field (already declared, `Domain/ProviderState.swift:51`). LOCAL-03's "no scanning" invariant is preserved — we do NOT probe a port we didn't read from config; we just render the row so users discover the feature exists without reading docs. Ollama (`localhost:11434`) and LM Studio (`localhost:1234`) have safe well-known defaults so they get probed unconditionally when `[ollama].enabled` / `[lmstudio].enabled` is true (default true).

### Claude's Discretion

Items NOT discussed — planner / researcher picks the standard answer:

- **File layout:** new `AgentsUsageBar/Providers/Ollama/`, `Providers/LMStudio/`, `Providers/LlamaCpp/` directories mirroring `Providers/Claude/` and `Providers/OpenRouter/` layouts.
- **`ProviderID` additions:** three constants `.ollama`, `.lmstudio`, `.llamacpp`. The `displayHint` switch in `Domain/ProviderID.swift:39-50` already returns "Ollama", "LM Studio", "llama.cpp" for these rawValues — no edit needed.
- **One actor per runtime vs one unified `LocalProbeProvider`:** **three actors.** `OllamaProvider`, `LMStudioProvider`, `LlamaCppProvider`. Mirrors the per-provider-actor pattern (Phase 1 STATE #24). Each actor returns `nonisolated var capabilities = ProviderCapabilities(hasQuota: false, hasCost: false, hasTokens: false, isLocal: true)` so the `AggregateStore` rollup (D-07 from Phase 3 / `AggregateStore.swift:387`) excludes them from "Today total" automatically (zero churn on rollup logic).
- **`ProviderCapabilities` flag:** `isLocal: true`, `hasQuota: false`, `hasCost: false`, `hasTokens: false` — `hasTokens=false` auto-excludes from "Today total" (Phase 3 D-07), and the footnote toggle `AggregateStore.hasAnyQuotaOnlyProvider` already flips on when any registered provider has `hasTokens=false` (it currently triggers for Gemini; will keep firing for locals — no change needed).
- **`HTTPClient.get(bearer: Secret? = nil)` overload (HTTPClient.swift:44)** is the unauthenticated probe vehicle. No new HTTPClient methods.
- **1–2s localhost timeout (POLL-08):** separate `URLSessionHTTPClient` instance with `timeoutIntervalForRequest = 2` for local probes, OR a per-request timeout override. Planner picks the cheaper of the two given Swift 6 actor isolation. **Default recommendation:** a second `URLSessionHTTPClient(timeoutSeconds: 2)` instance injected via `AppDependencies.makeProduction()` — preserves the "one session per app" rule per-tier (remote 8s and local 2s are different `URLSession` instances by necessity per POLL-08 split).
- **Connection-refused detection:** map `URLError.Code.cannotConnectToHost`, `.cannotFindHost`, `.networkConnectionLost`, `.timedOut` (within the 1–2s window) → `notRunning`. Every other `URLError` and any non-2xx HTTP → `.error`. Add a static helper on `ProviderError` mirroring the existing `.from(_:)` pattern.
- **TOML schema additions:** `[ollama] enabled = true`, `[lmstudio] enabled = true, port = 1234`, `[llamacpp] enabled = true, port = <int|absent>`. Env overrides not required for locals (no secrets — port + enable are config knobs).
- **`AppConfig` extension:** add `OllamaConfig`, `LMStudioConfig`, `LlamaCppConfig` value-type structs mirroring `OpenRouterConfig` / `CodexConfig` / `GeminiConfig` shape (`Config/AppConfig.swift:60-169`). Default values: ollama `enabled=true`; lmstudio `enabled=true, port=1234`; llamacpp `enabled=true, port=nil`.
- **`AppDependencies.makeProduction()`:** three new conditional registration blocks. Gate Ollama + LM Studio on `enabled` only (probe always allowed at well-known port). Gate llama.cpp on `enabled && port != nil`; otherwise seed the D-04 placeholder.
- **Snapshot shape for local runs:** `tokensToday = nil`, `costTodayUSD = nil`, `balanceUSD = nil`, `quota = nil`, `quotaWindows = nil`. The row never participates in threshold notifications (`ThresholdEngine.decisions(for:)` already skips snapshots without quota — `Phase 1 D-14` precedent). `tooltipLabel` optional for deep-detail hover.
- **Test layout:** `AgentsUsageBarTests/Providers/OllamaTests/`, `LMStudioTests/`, `LlamaCppTests/` mirroring `ClaudeTests/` / `CodexTests/` / `GeminiTests/`. `URLProtocol` stubs with `.serialized` trait + `NSLock`-protected static (Phase 2 STATE #19 / Phase 1 W-7 pattern).
- **Lenient `Codable` for `/api/ps`, `/api/tags`, `/v1/models`, `/api/v0/models`, `/health`, `/slots`** — tolerate unknown future fields (Phase 2 Pitfall 7).
- **SEC-04 grep:** NO new patterns. Locals have no secrets to leak.
- **`ProviderDashboardURL.lookup(_:)`** (`UI/ProviderDashboardURL.swift:44`) returns `nil` for the three new IDs; the `arrow.up.right.square` button is `.disabled` in `ProviderRowView.swift:142`. Already correctly handled — no edit.
- **`Info.plist` `NSAllowsLocalNetworking = true`** is ALREADY set (`AgentsUsageBar/Resources/Info.plist:23-27`). No plist edit in Phase 4.
- **Caching:** local snapshots cache through the existing `FileCacheStore` like every other provider — gives UI-07 no-Loading-flash on cold launch. Cache loads `Not running` from prior poll cleanly; next poll updates the row.
- **Local providers participate in the standard 5-min `PollScheduler` cycle** — no special faster cadence. Popover-open coalesced refresh (POLL-03) already gives fast feedback when user opens the panel after starting `ollama serve`.
- **Row ordering in popover:** local rows render AFTER the four hosted-API rows (OpenRouter, Claude, Codex, Gemini) so the "active spend" providers stay top-of-list. `AggregateStore.providers` is a dictionary, so the ordering is established in `PopoverRootView` via the rendering loop's sort key — planner picks the sort (suggest: `isLocal` ascending, then alphabetic by `displayName`, OR enforce a fixed `ProviderID` order array; either is fine).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents (researcher, planner, executor) MUST read these before planning or implementing.**

### Project Specs (root)
- `.planning/PROJECT.md` — Core value, constraints. §"Out of Scope" explicitly forbids "Real-time local-agent token interception (proxying `/api/generate` etc.) — port-conflict footgun; local rows show running/idle + model only" — this is LOCAL-06 reaffirmed
- `.planning/REQUIREMENTS.md` §"Provider — Local LLMs" (LOCAL-01..06) — the 6 Phase 4 line items; §"Polling" POLL-08 (8s remote / 1–2s localhost split) is now actually exercised
- `.planning/ROADMAP.md` §"Phase 4: Local LLM Presence" — goal + 5 success criteria; verification must satisfy each
- `.planning/STATE.md` §"Accumulated Context" Decisions #1–63 (Phase 1-2-3 patterns); §"Performance Metrics" (durations & file counts of Phase 3 plans as benchmark)

### Architecture & Stack
- `.planning/research/ARCHITECTURE.md` — Provider Protocol + Per-Provider Actor pattern (apply once per runtime — three actors); `AggregateStore` registration; Composition Root + Protocol Seams; "Recommended Project Structure"
- `.planning/research/STACK.md` — `URLSession` config, `Codable` rules, async/await + structured concurrency
- `CLAUDE.md` — Recommended Stack (POLL-08 1–2s localhost timeout explicit), "Sandbox Decision" (localhost reads work because sandbox is OFF), "Concurrency & Polling Pattern" (separate URLSession instance per timeout tier acceptable)

### Pitfalls (avoid in Phase 4)
- `.planning/research/PITFALLS.md` §"Pitfall 3" (sandbox-off — verify localhost works in signed Release build; ATS `NSAllowsLocalNetworking` already shipped)
- `.planning/research/PITFALLS.md` §"Pitfall 5" (polling battery — sleep/wake handled by Phase 2's `PowerObserver`; localhost probes inherit the same pause-on-sleep behaviour)
- `.planning/research/PITFALLS.md` §"Pitfall 6" (notification storm — locals have no quota so they never reach `ThresholdEngine.decisions`; confirm with a Phase 4 regression test that `localRow.snapshot.quota == nil` excludes the row from notification dispatch)
- `.planning/research/PITFALLS.md` §"Pitfall 7" (lenient parsing — every local-runtime response decoder uses lenient `Codable`; unknown future fields preserved)
- `.planning/research/PITFALLS.md` §"Phase-0 Verification Tasks" — re-verify Ollama `/api/ps` + `/api/tags` response shapes, LM Studio `/api/v0/models` shape, llama.cpp `/health` + `/slots` shapes before lockdown

### Prior Phase Context
- `.planning/phases/01-skeleton-openrouter-vertical-slice/01-CONTEXT.md` — Phase 1 anchor decisions D-01..D-19 (today.json shape, cache codec, threshold engine scope, TOML precedence — all carry into Phase 4)
- `.planning/phases/02-claude-provider-threshold-rollover-jsonl-streaming/02-04-SUMMARY.md` — `ClaudeJSONLProvider` composition + `AppDependencies` wiring (template for three new local providers — same shape, replace JSONL pipeline with HTTP probe)
- `.planning/phases/02-claude-provider-threshold-rollover-jsonl-streaming/02-06-SUMMARY.md` — `CircuitBreaker` per-provider 5-strike — applies to local providers unchanged
- `.planning/phases/02-claude-provider-threshold-rollover-jsonl-streaming/02-07-SUMMARY.md` — UI extensions (UI-08 stale-data, UI-09 menu-tint) — local rows inherit both; menu-tint `maxQuotaFraction` aggregation already returns `nil` for snapshots without quota so locals never tint the menu bar
- `.planning/phases/03-remote-api-providers-codex-gemini/03-CONTEXT.md` — Phase 3 anchor decisions especially **D-07** (cross-provider total excludes `hasTokens=false` providers — locals piggy-back this), **D-13/D-14** (open-dashboard `.disabled` for nil URL — already handles locals), **D-15** (`tooltipLabel` channel — locals reuse for deep detail)
- `.planning/phases/03-remote-api-providers-codex-gemini/03-RESEARCH.md` — provider-actor + composition-root patterns crystallised here; closest research analogue for Phase 4

### External APIs (re-verify in research step)
- **Ollama:** `GET http://localhost:11434/api/ps` (response: `{models: [{name, model, size, size_vram, expires_at, details: {family, parameter_size, quantization_level}}]}`); `GET /api/tags` (installed models list); `GET /api/version` (sanity)
- **LM Studio:** `GET http://localhost:<port>/v1/models` (OpenAI-compatible: `{data: [{id, object, owned_by}]}`); `GET /api/v0/models` (LM Studio extended fields — loaded state + path)
- **llama.cpp / llamafile:** `GET http://localhost:<port>/health` (`{status: "ok"|"loading model"|"no slot available"}`); `GET /slots` (per-slot live state); `GET /v1/models` (OpenAI-compatible)

### Apple Platform Docs (high-confidence)
- `URLSession` async/await + `timeoutIntervalForRequest` per session — https://developer.apple.com/documentation/foundation/urlsessionconfiguration/1408259-timeoutintervalforrequest
- `URLError.Code` — `.cannotConnectToHost`, `.cannotFindHost`, `.networkConnectionLost`, `.timedOut` — https://developer.apple.com/documentation/foundation/urlerror/code
- `MenuBarExtra` / `@Observable` — unchanged from Phase 1

### Prior Art (study, do NOT copy)
- **CodexBar** — https://github.com/steipete/CodexBar — 29-provider toggle pattern; reference for how a menu-bar app surfaces multiple localhost runtimes (it bundles Ollama support)
- **Ollama CLI source** — https://github.com/ollama/ollama — `/api/ps` + `/api/tags` schema source-of-truth
- **LM Studio docs** — https://lmstudio.ai/docs — `/api/v0/models` extended endpoint reference

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets

- **`Infrastructure/URLSessionHTTPClient.swift` + `HTTPClient.get(bearer: Secret? = nil, …)` overload (HTTPClient.swift:44)** — unauthenticated GET vehicle for localhost probes. NO new HTTPClient API. Construct a second instance for the 1–2s localhost timeout per POLL-08.
- **`Infrastructure/CircuitBreaker.swift`** (Phase 2 P-06) — 5-strike per-provider default fits localhost too; transient `notRunning` shouldn't trip the breaker (planner: classify `.notRunning` differently from `.error` in `AggregateStore.performRefresh` — `notRunning` is a success-class outcome from the probe's POV).
- **`Aggregation/AggregateStore.swift` `hasTokensByID` map (AggregateStore.swift:48, 101) + `rollupTotals()` exclusion (387) + `hasAnyQuotaOnlyProvider` flag (407)** — locals (`hasTokens=false`) auto-excluded from "Today total"; footnote already lights up. Phase 3 D-07 carries through unchanged.
- **`UI/ProviderRowView.swift`** — `isDegraded`/`isStale` opacity composition + `.disabled(dashboardURL == nil)` (line 142) already handle locals correctly. Modification surface: secondary line content for `isLocal=true` and rendering the four D-03 row states.
- **`UI/Components/StatusDot.swift`** — add `.notRunning → .gray` arm (line 48 switch); `forceAmber` not needed here.
- **`UI/ProviderDashboardURL.swift:44`** — returns nil for local IDs already (any rawValue outside the four known ones falls through). No edit.
- **`Domain/UsageSnapshot.swift` `raw: [String: String]`** (line 35) — carrier for `modelName`, `modelCount`, `vramBytes`. NO new domain field. Pre-existing precedent.
- **`Domain/ProviderState.swift` `placeholderMessage: String?`** (line 51) — carrier for the D-04 unconfigured-llama.cpp discoverability subtitle. Already wired into UI.
- **`Domain/ProviderCapabilities.swift`** — `isLocal: Bool` flag already declared (line 18). Set `true` for the three new providers.
- **`Domain/ProviderID.swift`** — `displayHint` switch already returns "Ollama" / "LM Studio" / "llama.cpp" for those rawValues (line 46-48). Just add the three `static let` constants.
- **`Config/ConfigStore.swift` + `AppConfig.swift` + `TomlReader.swift`** — env > toml > defaults precedence (Phase 1 D-15..D-19) extends naturally. Add `OllamaConfig`, `LMStudioConfig`, `LlamaCppConfig` structs.
- **`App/AppDependencies.swift` `seedPlaceholder` pattern** (line 259-275 for Codex; 270-275 for Gemini) — copy verbatim for llama.cpp unconfigured row (D-04).
- **`Resources/Info.plist`** — `NSAppTransportSecurity > NSAllowsLocalNetworking = true` ALREADY shipped (line 23-27). Phase 4 does NOT touch plist.

### Established Patterns

- **`Actor` provider protocol** (Phase 1 STATE #24) — three new actors `OllamaProvider`, `LMStudioProvider`, `LlamaCppProvider` conforming to `UsageProvider`.
- **One `URLSession` instance per tier** (CLAUDE.md "Concurrency & Polling Pattern") — Phase 4 introduces a second `URLSessionHTTPClient` for the 1–2s localhost tier. The 8s remote-tier instance stays as is.
- **Lenient `Codable` with synthesised optional `init(from:)`** (CLAUDE-03 / Phase 2 STATE #37 / Pitfall 7) — every local-runtime response decoder MUST tolerate unknown future fields. Capture `extraFields: [String: AnyCodable]` per Phase 2 convention.
- **`Calendar.current` everywhere** (Phase 1 D-04 / Phase 2 STATE #16) — N/A for Phase 4 (no date math); included only as guardrail against accidental `Calendar(identifier:)` use anywhere a timestamp formats.
- **`@MainActor` write-back only** — provider actors run `nonisolated async`; only writeback hops to MainActor via `AggregateStore`.
- **Exhaustive `switch ProviderStatus`** — every site updates with the new `.notRunning` arm. Phase 4 ripple: `StatusDot.dotColor`, `StatusDot.accessibilityLabel`, `ProviderState.applyingError`, `ThresholdEngine` skip-set, `NotificationActionHandler`, all test fixtures asserting on status equality.

### Integration Points

- **`Domain/ProviderID.swift`** — add `.ollama`, `.lmstudio`, `.llamacpp` constants. The `displayHint` switch arms already exist (line 46-48). NO edit to `displayHint`.
- **`Domain/ProviderStatus.swift`** — add `case notRunning` (D-01). Mark it non-terminal in `AggregateStore.performRefresh` (do NOT pattern-match against it in the POLL-06 skip block at AggregateStore.swift:271).
- **`Config/AppConfig.swift`** — append `OllamaConfig` / `LMStudioConfig` / `LlamaCppConfig` structs + 3 new fields on `AppConfig`. Defaults: ollama enabled=true; lmstudio enabled=true port=1234; llamacpp enabled=true port=nil.
- **`Config/TomlReader.swift` + `Config/ConfigStore.swift`** — parse `[ollama]`, `[lmstudio]`, `[llamacpp]` sections. Reuse Phase 1 D-16 hand-rolled TOML subset (`key = value`, `[section]`, `#` comments, scalars).
- **`App/AppDependencies.swift` `makeProduction()`** — three conditional registration blocks mirroring Codex/Gemini at lines 142-206. Each branch builds the runtime-specific actor; placeholder seeds for unconfigured llamacpp (D-04).
- **`UI/ProviderRowView.swift`** — branch on `state.snapshot?.providerID` (or `isLocal` capability derivable via the provider registry); render the D-02 / D-03 secondary line states for locals.
- **`UI/Components/StatusDot.swift`** — `.notRunning → .gray` arm; `accessibilityLabel` arm `"Status: Not running"`.
- **`Notifications/ThresholdEngine.swift`** — verify locals (snapshot.quota == nil) are skipped by existing logic; add a regression test asserting `decisions(for: [localSnapshot])` returns `[]`.
- **No new SEC-04 grep rules.** Locals carry no secrets.
- **No `Info.plist` change.** ATS local-networking flag already present.

</code_context>

<specifics>
## Specific Ideas

- **CodexBar as reference** for how a Mac menu-bar app surfaces a localhost runtime row alongside hosted-API rows — study row layout, not their probe code. https://github.com/steipete/CodexBar
- **Ollama `/api/ps` response carries rich metadata** (`size_vram`, `details.family`, `details.parameter_size`, `details.quantization_level`, `expires_at`) — surface `size_vram` in secondary line when present; everything else goes in tooltip for deep-hover discovery.
- **LM Studio `/api/v0/models`** has a `state` field per model (`"loaded" | "not-loaded"`) and `path` — use `state == "loaded"` to determine the loaded-name list; gracefully fall back to `/v1/models` (OpenAI-compatible plain list, no state info) when `/api/v0/models` 404s on older LM Studio builds.
- **llama.cpp `/health` returns `"loading model"`** during model warmup — render that as a transient `Running — loading…` (NOT `.error`); add `loadingModel` row state if researcher confirms the wire shape is `{status:"loading model"}`.
- **Connection-refused error mapping** test cases must include `URLError.cannotConnectToHost` (default macOS Foundation localhost-refusal code), `.cannotFindHost`, `.networkConnectionLost`, and `.timedOut` within the 1–2s window. Plus the negative case: HTTP 5xx → `.error` (red), not `.notRunning`.
- **Test-driven** for `ProviderError.from(URLError)` mapping, all three runtime decoders (lenient Codable), `OllamaProvider` multi-model row-state computation, llamacpp unconfigured placeholder seeding. Swift Testing (`@Test`, `#expect`) with `.serialized` trait + `NSLock`-protected static for shared `URLProtocol` stubs (Phase 2 STATE #19).
- **Memory: macos-Calendar(BE) gotcha** does NOT bite Phase 4 (no path-component date math) — but a test that exercises the rollover-friendly `Calendar.current.startOfDay(for:)` on any local-row code is a cheap regression. See `~/.ccs/instances/personal/projects/-Users-noomz-Projects-Opensources-agents-usage-bar/memory/gotcha_buddhist_calendar_path_components.md`.

</specifics>

<deferred>
## Deferred Ideas

- **Cumulative token counts for local rows** — explicitly rejected (LOCAL-06 anti-feature). Requires per-request proxying (port-conflict footgun) and contradicts the "ambient glance" framing. v2 conversation only.
- **Custom OpenAI-compatible probe endpoint** (Jan, vLLM, custom servers) — v2. Phase 4 covers the three well-known runtimes.
- **Per-model expand-on-click breakdown for Ollama multi-model state** — Phase 5 detail view OR v2 (memory candidate `feature_claude_quota_detail_view` extends to local providers too).
- **Auto-port-discovery for LM Studio / llama.cpp** — explicitly out of scope. LOCAL-03 says "no scanning". v2 if user feedback demands.
- **Real-time slot/request stream from llama.cpp** (Server-Sent Events on `/v1/chat/completions`) — way out of scope; cumulative tokens anti-feature applies.
- **Settings UI port pickers + per-provider enable toggles** — Phase 5 (CFG-05).
- **First-run welcome screen with localhost auto-detection card** — Phase 5 (CFG-03, CFG-04).
- **`.disabled` distinct from `.notRunning` for user-toggled-off providers** — relevant only after Phase 5 settings ships. Phase 4 doesn't need to differentiate.
- **Tooltip showing full multi-model list with VRAM per model** — defer to Phase 5 UX polish if `.help()` text turns out to be too dense.
- **Faster cadence for local probes** (e.g. 30s for locals, 5m for remotes) — defer. POLL-08 dictates one shared `PollScheduler`; local probes are cheap on the standard 5m cycle. Popover-open coalesced refresh (POLL-03) already gives fast manual feedback.
- **Running-but-no-model-loaded threshold notification** ("Ollama running but idle for 4h") — out of scope; this is a usage-pattern alert, not a quota alert. v2 trend tracking territory (TRENDS-*).

</deferred>

---

*Phase: 4-local-llm-presence-ollama-lm-studio-llama-cpp*
*Context gathered: 2026-05-18*
