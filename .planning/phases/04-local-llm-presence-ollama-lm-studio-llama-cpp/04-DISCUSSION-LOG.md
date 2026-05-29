# Phase 4: Local LLM Presence (Ollama + LM Studio + llama.cpp) - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-05-18
**Phase:** 4-local-llm-presence-ollama-lm-studio-llama-cpp
**Areas discussed:** Tri-state ↔ ProviderStatus mapping, Model name display location, Ollama multi-loaded-model UX, Unconfigured llama.cpp row visibility

---

## Gray Area Selection (multiSelect)

| Option | Description | Selected |
|--------|-------------|----------|
| Tri-state ↔ ProviderStatus mapping | LOCAL-04 says explicit tri-state. ProviderStatus has 5 cases. New case vs reuse `.unauthenticated` / `.disabled`. The 'never red, never blocking' invariant lives here. | ✓ |
| Model name display location | Local rows need loaded model name. Token/USD/balance line empty for locals. Options: secondary line / tooltipLabel / subtitle / dedicated field. Slot/VRAM info too? | ✓ |
| Ollama multi-loaded-model UX | `/api/ps` returns 0..N concurrently loaded. First-only / list / summary. Also: '0 loaded but service running' wording. | ✓ |
| Unconfigured llama.cpp row visibility | LOCAL-03 forbids scanning. If `[llamacpp].port` unset: placeholder row / hidden / disabled-styled / defer to Phase 5. | ✓ |

**User's choice:** All four selected.

---

## Tri-state ↔ ProviderStatus mapping

| Option | Description | Selected |
|--------|-------------|----------|
| Add `.notRunning` case | New ProviderStatus case. Gray-muted dot. AggregateStore keeps polling (NOT terminal like `.unauthenticated`) so service-start detected next tick. Ripple across ~6 exhaustive `switch` sites. | ✓ |
| Reuse `.ok` + snapshot marker | Always `.ok(lastSuccess:)` if probe completed; raw["running"]="false". Zero ProviderStatus churn but muddies `.ok` semantics. | |
| Reuse `.disabled` | Already dim-gray. Semantically wrong (user didn't disable). Bad foundation for Phase 5 settings. | |
| Provider-internal tri-state | LocalProbeProvider keeps own enum. Still needs non-terminal non-`.ok` mapping. Loops back to option 1 or 2. | |

**User's choice:** Add `.notRunning` case (Recommended).
**Notes:** Locked as D-01 in CONTEXT.md. Non-terminal — must not be added to the POLL-06 skip block at AggregateStore.swift:271. StatusDot gets gray arm + accessibilityLabel arm.

---

## Model name display location

| Option | Description | Selected |
|--------|-------------|----------|
| Secondary line replaces tokens | The all-"—" tokens·USD·balance HStack repurposed for `<modelName> · <vram> GB VRAM`. Always visible. Preserves row layout. | ✓ |
| tooltipLabel only (.help() hover) | Zero new UI, but hidden discovery — defeats ambient glance for locals where model name IS the data. | |
| Subtitle under display name | Third text line. Asymmetric layout (taller rows for locals) or always (blank line for remotes). | |
| Both: secondary line + tooltip detail | Two-channel: at-a-glance + hover. Mirrors Phase 3 D-15. | |

**User's choice:** Secondary line replaces tokens (Recommended).
**Notes:** Locked as D-02 in CONTEXT.md. D-02a sub-decision: snapshot carrier is the existing `UsageSnapshot.raw: [String:String]` (modelName, modelCount, vramBytes keys) — no new domain field needed.

---

## Ollama multi-loaded-model UX

| Option | Description | Selected |
|--------|-------------|----------|
| First model + count badge | `<first> · +N more` when N>1; tooltip carries full list. Four explicit row states. Stable layout. | ✓ |
| Comma-joined list | Fragile to long model names; row becomes wall of text at 3+ models. | |
| Summary only | Always 'N models loaded'. Loses the actual model name from glance. | |
| Most-recently-active (by expires_at) | Loses count. More semantic but adds API-shape dependency. | |

**User's choice:** First model + count badge (Recommended).
**Notes:** Locked as D-03 in CONTEXT.md. Four explicit row states for the secondary line: `Not running` / `Idle — 0 models loaded` / `<model>` / `<first> · +N more`. LM Studio + llama.cpp inherit the same logic; `+N more` will be rare for them.

---

## Unconfigured llama.cpp row visibility

| Option | Description | Selected |
|--------|-------------|----------|
| Placeholder row + discoverability subtitle | Always present, gray `.notRunning` dot, subtitle 'Set [llamacpp] port in config.toml to enable'. Mirrors Codex/Gemini placeholders. | ✓ |
| Row hidden until configured | Breaks 'every supported provider always visible' invariant. Worse discoverability. | |
| Row present but `.disabled`-styled | Semantically wrong (user didn't disable). `.disabled` may gain other policy in Phase 5. | |
| Defer to Phase 5 first-run screen | Feature ships dark in v1 demos before Phase 5 lands. | |

**User's choice:** Placeholder row + discoverability subtitle (Recommended).
**Notes:** Locked as D-04 in CONTEXT.md. Carrier = the existing `ProviderState.placeholderMessage: String?` field (Domain/ProviderState.swift:51). Mirrors `seedPlaceholder` pattern at App/AppDependencies.swift:259-275.

---

## Claude's Discretion

User did not push back on the discretionary items enumerated in CONTEXT.md `<decisions>` → "Claude's Discretion". Planner picks the standard answer for:

- File layout (three actor dirs under `Providers/`)
- Three actors (`OllamaProvider`, `LMStudioProvider`, `LlamaCppProvider`) vs one unified `LocalProbeProvider` — three actors chosen
- 1–2s localhost timeout via second `URLSessionHTTPClient` instance (vs per-request override)
- Connection-refused detection via `URLError.Code` enumeration (`.cannotConnectToHost`, `.cannotFindHost`, `.networkConnectionLost`, `.timedOut`)
- TOML schema additions (`[ollama]`, `[lmstudio] port=1234`, `[llamacpp] port=<int|absent>`)
- `AppConfig` extension with three config structs mirroring `OpenRouterConfig`/`CodexConfig`/`GeminiConfig`
- Lenient `Codable` for all local-runtime response decoders (Pitfall 7)
- Three new `ProviderID` constants — `displayHint` switch already returns proper names
- Provider participation in standard 5-min `PollScheduler` (no special faster cadence)
- Row ordering in popover (locals after hosted-API rows)
- Test layout mirroring `ClaudeTests/`/`CodexTests/`/`GeminiTests/` with `URLProtocol` stubs + `.serialized` trait
- No `Info.plist` edit (ATS local-networking already shipped)
- No SEC-04 grep changes (locals have no secrets)
- `ProviderDashboardURL.lookup` returns nil for local IDs → button `.disabled` already wired

---

## Deferred Ideas

Captured in CONTEXT.md `<deferred>`:

- Cumulative tokens for local rows (LOCAL-06 anti-feature, requires proxying)
- Custom OpenAI-compatible probe endpoints (Jan, vLLM)
- Per-model expand-on-click breakdown for multi-model Ollama state — Phase 5 detail view or v2
- Auto-port-discovery for LM Studio / llama.cpp — LOCAL-03 forbids scanning
- Real-time slot/request stream from llama.cpp (SSE)
- Settings UI port pickers + enable toggles → Phase 5
- First-run welcome screen → Phase 5
- `.disabled` vs `.notRunning` distinction → only meaningful after Phase 5
- Tooltip dense-info polish → Phase 5 UX pass if needed
- Faster local-probe cadence → POLL-08 dictates shared scheduler; defer
- Running-but-idle threshold notification ("Ollama idle for 4h") → v2 TRENDS-* territory
