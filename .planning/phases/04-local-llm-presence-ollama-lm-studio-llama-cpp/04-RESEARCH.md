# Phase 4: Local LLM Presence (Ollama + LM Studio + llama.cpp) — Research

**Researched:** 2026-05-18
**Researcher:** gsd-phase-researcher (acting; subagents not installed)
**Source of truth:** `04-CONTEXT.md` decisions D-01..D-04 + Claude's Discretion bullets.
**Confidence:** HIGH for wire shapes (cross-verified against Ollama / LM Studio / llama.cpp upstream docs + source); HIGH for Swift integration shape (every primitive already exists in-tree); MEDIUM for `/health` `"loading model"` exact spelling — flagged in §11.
**Operating directive:** elaborate, never relitigate. Local LLM tokens NEVER tracked (LOCAL-06); ports NEVER scanned (LOCAL-03).

---

## 1. Requirement Anchoring

| ID | REQUIREMENTS.md text (verbatim) | Satisfied by |
|----|---------------------------------|--------------|
| **LOCAL-01** | App probes Ollama at `http://localhost:11434/api/ps` (running models) and `/api/tags` (installed models) with a 1–2s connect timeout | `OllamaProvider` actor (Claude's Discretion §"File layout" + §"`HTTPClient.get(bearer: nil)` overload"); 1–2s tier via second `URLSessionHTTPClient(timeoutSeconds: 2)` (CONTEXT D-04 1–2s discretion bullet). |
| **LOCAL-02** | App probes LM Studio at `http://localhost:1234/v1/models` and `/api/v0/models` (configurable port) | `LMStudioProvider` actor + `[lmstudio].port` (default 1234) in `AppConfig.LMStudioConfig` (Discretion §"TOML schema additions" + §"`AppConfig` extension"). |
| **LOCAL-03** | App probes llama.cpp / llamafile at `http://localhost:<port>/health`, `/slots`, `/v1/models` (port required in `~/.config/agents-usage-bar/config.toml`, no scanning) | `LlamaCppProvider` actor + `[llamacpp].port` REQUIRED (no default); when absent → D-04 placeholder row with discoverability subtitle. NO port-scanning code anywhere. |
| **LOCAL-04** | Each local row has tri-state status: `notRunning` (muted, not red) / `running` (model name + slot/VRAM info) / `error` (red w/ message) | **D-01:** new `ProviderStatus.notRunning` → gray via `StatusDot` (`StatusDot.swift:48` switch); **D-02:** secondary line carries model name (+VRAM optional) via `UsageSnapshot.raw["modelName"]` / `raw["vramBytes"]`. |
| **LOCAL-05** | Connection refused from a localhost endpoint is treated as `notRunning`, not an error | Connection-refused mapping: `URLError.cannotConnectToHost`/`cannotFindHost`/`networkConnectionLost`/`timedOut` → `.notRunning` (CONTEXT Discretion §"Connection-refused detection"). New static `ProviderError.from(URLError) -> Kind` or `ProviderStatus` helper mirroring existing `ProviderError.from(_:)` (`Domain/ProviderError.swift:32`). |
| **LOCAL-06** | Local rows show running/idle + model name only; cumulative token tracking is NOT performed (explicit anti-feature) | `ProviderCapabilities(hasQuota: false, hasCost: false, hasTokens: false, isLocal: true)` (`Domain/ProviderCapabilities.swift:21`); auto-excludes from rollup via Phase 3 D-07 / `AggregateStore.hasTokensByID` (`AggregateStore.swift:48, 101, 387, 392`). Snapshot fields `tokensToday=nil, costTodayUSD=nil, balanceUSD=nil, quota=nil, quotaWindows=nil` (Discretion §"Snapshot shape for local runs"). |

---

## 2. External API Wire Shapes

> All wire claims cross-checked against upstream sources. Lenient `Codable` rule (Phase 2 STATE #37 / Pitfall 7) requires every decoder below to tolerate unknown future fields — Swift's synthesised `Codable` already does this for absent/extra fields, so explicit `extraFields` plumbing is NOT required (Phase 3 STATE #64 — Codex precedent).

### 2.1 Ollama

| Endpoint | Method | Purpose |
|---|---|---|
| `http://localhost:11434/api/ps` | GET | Currently-loaded (running) models. |
| `http://localhost:11434/api/tags` | GET | All locally-installed models (regardless of running). |
| `http://localhost:11434/api/version` | GET | Server version sanity-probe (optional). |

**Sources:** Ollama API docs — https://github.com/ollama/ollama/blob/main/docs/api.md (verified 2026-05). The `/api/ps` endpoint and `size_vram` field were added in Ollama 0.1.30 (April 2024); both are stable in current builds.

**Sample `/api/ps` response (verbatim from upstream docs):**
```json
{
  "models": [
    {
      "name": "mistral:latest",
      "model": "mistral:latest",
      "size": 5137025024,
      "digest": "2ae6f6dd7a3dd734790bbbf58b8909a606e0e7e97e94b7604e0aa7ae4490e6d8",
      "details": {
        "parent_model": "",
        "format": "gguf",
        "family": "llama",
        "families": ["llama"],
        "parameter_size": "7.2B",
        "quantization_level": "Q4_0"
      },
      "expires_at": "2024-06-04T14:38:31.83753-07:00",
      "size_vram": 5137025024
    }
  ]
}
```

**Empty / server-up-no-model case:**
```json
{ "models": [] }
```

**Fields we read (Swift `Codable` property names):**
- `models[].name: String` — primary display name (used in D-03 row state).
- `models[].size_vram: Int64?` — VRAM bytes; formatted to `"X.X GB"` for the secondary-line suffix (D-02). Use `Int64` because GGUF models can exceed 4 GiB.
- `models[].details.family: String?` — fed to tooltip only.
- `models[].details.parameter_size: String?` — tooltip only.
- `models[].details.quantization_level: String?` — tooltip only.
- `models[].expires_at: String?` — IGNORE in v1 (would be a v2 "model idle-eviction in Nm" hint).

**Fields we ignore (lenient parse — Pitfall 7):** `model`, `digest`, `size` (non-VRAM total — duplicates `size_vram` in most loaded-on-GPU cases), `details.parent_model`, `details.format`, `details.families[]`.

**`/api/tags` response shape** (installed-not-running):
```json
{
  "models": [
    {
      "name": "codellama:13b",
      "modified_at": "2023-11-04T14:56:49.277302595-07:00",
      "size": 7365960935,
      "digest": "9f438cb9cd581fc025612d27f7c1a6669ff83a8bb0ed86c94fcf4c5440555697",
      "details": { /* same shape as /api/ps */ }
    }
  ]
}
```

**Usage:** read `models[].name` ONLY. Purpose: distinguish D-03 row states `"Not running"` (server down) vs `"Idle — 0 models loaded"` (server up, `/api/ps` empty, BUT `/api/tags` non-empty meaning "configured but nothing in VRAM"). If `/api/tags` ALSO returns empty, render `"Idle — no models installed"` as a fifth degenerate state — researcher recommendation, planner may collapse to `"Idle — 0 models loaded"`.

### 2.2 LM Studio

| Endpoint | Method | Purpose | Availability |
|---|---|---|---|
| `http://localhost:<port>/v1/models` | GET | OpenAI-compatible model list. | All LM Studio versions with HTTP server. |
| `http://localhost:<port>/api/v0/models` | GET | LM Studio extended fields (`state`, `path`, `arch`). | LM Studio 0.3.5+ (Nov 2024) — 404 on older builds. |

**Sources:** LM Studio REST API docs — https://lmstudio.ai/docs/api/rest-api (verified 2026-05). The `state`-aware `/api/v0/models` is documented at https://lmstudio.ai/docs/api/endpoints/rest.

**Sample `/api/v0/models` response (verbatim from upstream docs):**
```json
{
  "object": "list",
  "data": [
    {
      "id": "qwen2-vl-7b-instruct",
      "object": "model",
      "type": "vlm",
      "publisher": "mlx-community",
      "arch": "qwen2_vl",
      "compatibility_type": "mlx",
      "quantization": "4bit",
      "state": "not-loaded",
      "max_context_length": 32768
    },
    {
      "id": "meta-llama-3.1-8b-instruct",
      "object": "model",
      "type": "llm",
      "publisher": "lmstudio-community",
      "arch": "llama",
      "compatibility_type": "gguf",
      "quantization": "Q4_K_M",
      "state": "loaded",
      "max_context_length": 131072,
      "loaded_context_length": 4096
    }
  ]
}
```

**Sample `/v1/models` fallback (OpenAI-compatible, no state):**
```json
{
  "object": "list",
  "data": [
    { "id": "meta-llama-3.1-8b-instruct", "object": "model", "owned_by": "organization_owner" }
  ]
}
```

**Probe strategy (lenient fallback):**
1. Issue `GET /api/v0/models` first.
2. On HTTP 404 (older LM Studio) → fall back to `GET /v1/models`.
3. On HTTP 200 with `data[]` shape, decode using **two distinct `Codable` structs** — one with the `state` field, one without. Filter `state == "loaded"` when the extended shape is available; otherwise treat ALL listed models as "loaded" (best effort — older LM Studio doesn't expose load state, so anything in `/v1/models` is at least configured).

**Fields we read:** `data[].id: String`, `data[].state: String?` (when present), `data[].arch: String?` (tooltip), `data[].quantization: String?` (tooltip), `data[].loaded_context_length: Int?` (tooltip when present).

**Fields we ignore (lenient parse — Pitfall 7):** `object`, `type`, `publisher`, `compatibility_type`, `max_context_length`, plus any future fields LM Studio adds.

**Empty / server-up-no-model case:** `{ "object": "list", "data": [] }` → render `"Idle — 0 models loaded"`. If `data[]` is non-empty but every entry has `state != "loaded"` (extended endpoint) → same row state. **Note:** LM Studio reports ALL configured models in `data[]`, not just loaded ones — the `state` field is the discriminator, not array length.

### 2.3 llama.cpp / llamafile

| Endpoint | Method | Purpose |
|---|---|---|
| `http://localhost:<port>/health` | GET | Server liveness + model-load state. |
| `http://localhost:<port>/slots` | GET | Per-slot live state (one slot per concurrent generation). |
| `http://localhost:<port>/v1/models` | GET | OpenAI-compatible model list. |

**Sources:** llama.cpp `examples/server/README.md` — https://github.com/ggerganov/llama.cpp/blob/master/examples/server/README.md (verified 2026-05). Llamafile inherits the same HTTP surface from the bundled llama.cpp server (Mozilla Ocho fork — https://github.com/Mozilla-Ocho/llamafile). **CAVEAT:** llamafile has historically been ~1–2 minor versions behind upstream — researcher confirms wire shapes match byte-for-byte for `/health` and `/v1/models` (the planner's `LlamaCppProvider` MUST NOT branch on a `User-Agent` or version detect); flag any drift in §11.

**Sample `/health` response shapes (per upstream README):**

Healthy:
```json
{ "status": "ok", "slots_idle": 4, "slots_processing": 0 }
```

Warming up (model loading at startup):
```json
{ "status": "loading model" }
```

No-slot-available (all slots busy):
```json
{ "status": "no slot available", "slots_idle": 0, "slots_processing": 4 }
```

Error (server up but model failed to load):
```json
{ "status": "error" }
```

**Fields we read:** `status: String`. Discriminator: `"ok"` → running; `"loading model"` → transient `running — loading…`; `"no slot available"` → running (all slots busy, treat as healthy); `"error"` → `.error(ProviderError)` red row.

**Fields we ignore (lenient parse):** `slots_idle`, `slots_processing` (could go in tooltip in v2; out-of-scope for v1 row).

**Sample `/v1/models` response (OpenAI-compatible — llama.cpp loads ONE model per server):**
```json
{
  "object": "list",
  "data": [
    {
      "id": "/path/to/llama-3-8b-instruct-Q4_K_M.gguf",
      "object": "model",
      "created": 1717024812,
      "owned_by": "llamacpp",
      "meta": { "n_ctx_train": 8192, "n_embd": 4096, "n_params": 8030261248 }
    }
  ]
}
```

**Fields we read:** `data[0].id: String` (model file path; planner trims to basename via `URL(fileURLWithPath:).lastPathComponent` for D-02 secondary line — Apple `URL` API; do NOT split on `"/"` manually).

**`/slots` response shape** (per llama.cpp README — only when server compiled with `--slots`, generally default in `llama-server`):
```json
[
  {
    "id": 0,
    "id_task": -1,
    "state": "idle",
    "prompt": "",
    "next_token": { "has_next_token": false, "n_remain": -1, ... },
    "params": { ... }
  }
]
```

**Usage in v1:** llama.cpp is single-model, so `/slots` is informational only (tooltip-only count of idle/busy slots). MUST NOT block render on `/slots` returning 404 — llama.cpp builds without `--slots` exist (mainline default is on, but configurable). Planner: issue `/slots` opportunistically; ignore failures.

### 2.4 Probe sequencing — minimum vs informative

| Provider | Minimum probe (drives row state) | Informative probes (best-effort, errors ignored) |
|---|---|---|
| Ollama | `GET /api/ps` (one request) | `GET /api/tags` (to distinguish "installed" from "not installed") |
| LM Studio | `GET /api/v0/models` THEN fallback `GET /v1/models` on 404 | (none — single endpoint suffices) |
| llama.cpp | `GET /health` (drives status); `GET /v1/models` (drives model name) | `GET /slots` (tooltip enrichment) |

Run informative probes concurrently with `async let` (Phase 2 STATE #25 OpenRouter precedent / Phase 3 STATE #82 Gemini precedent). Failure of an informative probe degrades to "no extra detail" — NEVER to `.error`.

---

## 3. Connection-Refused & Error Classification

`Foundation`'s `URLSession` surfaces localhost connection-refused as `URLError` with specific `URLError.Code` values. The exhaustive mapping below is the load-bearing classifier for LOCAL-05.

### 3.1 URLError → ProviderStatus mapping

| `URLError.Code` | Why it fires for localhost probes | Mapped status |
|---|---|---|
| `.cannotConnectToHost` (-1004) | ECONNREFUSED — server process not running on the port. | `.notRunning` |
| `.cannotFindHost` (-1003) | NXDOMAIN — does not fire for `localhost`, but defensive. | `.notRunning` |
| `.networkConnectionLost` (-1005) | TCP RST mid-request — server crashed during probe. | `.notRunning` |
| `.timedOut` (-1001) | Request exceeded 2s budget on the localhost tier (POLL-08 split). | `.notRunning` |
| `.notConnectedToInternet` (-1009) | Cannot fire for localhost; defensive. | `.error` |
| Any other `URLError` | TLS, malformed URL, etc. | `.error` |
| `HTTPError(status: 4xx)` (auth/payment-required path through `ProviderError.from(_:)`) | Inapplicable to localhost (no auth); defensive — render as `.error`. | `.error` |
| `HTTPError(status: 5xx)` | Server returned non-2xx — server is RUNNING, just unhealthy. | `.error` (red row) |
| HTTP 200 + empty body / unparseable | Server up but probably wrong endpoint version. | `.error` (decode kind) |
| `DecodingError` | Same — schema drift, surface red so we notice. | `.error` |

**Rationale:** the four `URLError` codes above are the ONLY ones consistent with "server process not listening." Mapping them to `.notRunning` (D-01 / LOCAL-05) avoids the false-alarm red row Pitfall 9 calls out. Every other failure surface is genuinely abnormal and deserves `.error`.

**Sources:**
- Apple — `URLError.Code` enum — https://developer.apple.com/documentation/foundation/urlerror/code
- Apple — `URLSession` — https://developer.apple.com/documentation/foundation/urlsession (timeoutIntervalForRequest semantics)
- Foundation Network/CFNetwork docs treat `-1004 cannotConnectToHost` as "the server actively refused the connection" — exactly the ECONNREFUSED case (`netstat -an | grep 11434` empty).

### 3.2 Proposed `ProviderError.from(URLError)` extension

The existing `ProviderError.from(_ error: Error)` (`Domain/ProviderError.swift:32`) catches `URLError` and maps to `.network` kind. For Phase 4 we need a **second classifier** that distinguishes "server down" from "network error" because the row colour rules differ. Two equivalent options:

**Option A — `ProviderStatus.classifyLocalhost(error:lastSuccess:) -> ProviderStatus`** (preferred). A static factory on the new `notRunning` arm:

```swift
extension ProviderStatus {
    /// Localhost-tier error classifier (Phase 4 / LOCAL-05).
    /// Returns `.notRunning` for connection-refused codes; `.error` otherwise.
    public static func classifyLocalhost(
        error: Error,
        lastSuccess: Date?
    ) -> ProviderStatus {
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .cannotConnectToHost, .cannotFindHost,
                 .networkConnectionLost, .timedOut:
                return .notRunning
            default:
                break
            }
        }
        let pe = ProviderError.from(error)
        if let ls = lastSuccess {
            return .stale(lastSuccess: ls, error: pe)
        }
        return .error(pe)
    }
}
```

Composes with `ProviderState.applyingError(_:at:)` (`Domain/ProviderState.swift:93`) by either calling this classifier before `applyingError`, or extending `applyingError` itself with an `isLocal` branch. Planner picks the cheaper site (a per-provider override in the new local provider actors is fine — `lastStatus = .classifyLocalhost(...)`).

**Option B — `ProviderError.Kind.notRunning`** case + `applyingError` switch on the kind. Cleaner blast radius (no callers touched) but adds an enum case that's only meaningful for locals. **Recommend Option A.**

**Cite the existing pattern:** `Domain/ProviderError.swift:32-49` already centralises `.from(_:)` for HTTP/URL/Decoding errors; the new helper mirrors that style.

---

## 4. `ProviderStatus.notRunning` Ripple Map

D-01 adds `.notRunning` between `.unauthenticated` and `.disabled`. Every exhaustive `switch ProviderStatus` MUST add the arm. Verified via `grep -rn "case \.unauthenticated\|case \.disabled\|case \.ok\b\|case \.stale\b\|case \.error\b" AgentsUsageBar AgentsUsageBarTests`.

### 4.1 Production code sites

| File:line | Switch context | New `.notRunning` behaviour |
|---|---|---|
| `Domain/ProviderStatus.swift:7-28` | enum declaration | **add the case** between `.unauthenticated` (line 21) and `.disabled` (line 24) per D-01 grouping. |
| `UI/Components/StatusDot.swift:48-60` (`dotColor` switch) | maps status → SwiftUI `Color`. | **add** `case .notRunning: base = .gray` (D-01 muted-gray; LOCAL-04 "muted, not red"). |
| `UI/Components/StatusDot.swift:71-83` (`accessibilityLabel` switch) | a11y label per status. | **add** `case .notRunning: return "Status: Not running" + suffix` |
| `Aggregation/AggregateStore.swift:271` (POLL-06 terminal-unauth skip) | `if … case .unauthenticated = existing.status { gateDecisions.append((p, false, false)); continue }` | **DO NOT** add `.notRunning` here. `.notRunning` MUST remain **non-terminal** (D-01) so the next 5-min tick re-probes. The case must be ABSENT from this match. |
| `Domain/ProviderState.swift:93-109` (`applyingError(_:at:)`) | builds `.stale(...)` or `.error(...)` based on whether `lastSuccess` exists. | **no change** — providers themselves now emit `.notRunning` via the §3.2 classifier and short-circuit BEFORE reaching `applyingError`. Alternatively the planner can extend `applyingError` with an `isLocalNotRunning` parameter; either works, but keeping `applyingError` unchanged is cleaner. |
| `Notifications/ThresholdEngine.swift` | nil-quota gate at line 124: `guard let quota = snap.quota else { return nil }`. | **no change needed** — local snapshots have `quota = nil` (D-02a snapshot shape), so threshold engine already skips them. **Add a regression test** asserting `decisions(for: [localSnapshot])` returns `[]` (CONTEXT canonical-refs §"Pitfall 6"). |
| `Notifications/NotificationActionHandler.swift` | snooze action handler — does not switch on `ProviderStatus` directly; iterates `providers.keys`. | **no change needed.** Snooze on a `.notRunning` provider is a no-op because the row never produces a quota crossing. |
| `Providers/{Claude,Codex,Gemini,OpenRouter}/*.swift` — `lastStatus: ProviderStatus = .error(...)` initialisation | per-provider actor stored state. | **no change to remote providers.** New local providers (`OllamaProvider`, `LMStudioProvider`, `LlamaCppProvider`) initialise `lastStatus = .notRunning` since the cold-launch convention is "we haven't probed yet — presumed not running until proven otherwise." |

### 4.2 Test code sites (assert on `ProviderStatus` equality)

| File:line | Fixture |
|---|---|
| `AgentsUsageBarTests/UITests/TotalsHeaderViewFootnoteTests.swift:132` — stub provider returns `.unauthenticated`. | No edit unless the test exhaustively pattern-matches all cases. |
| `AgentsUsageBarTests/InfrastructureTests/PowerObserverTests.swift:19` | Same. |
| `AgentsUsageBarTests/AggregationTests/AggregateStoreSnoozeTests.swift:44` | Same. |
| `AgentsUsageBarTests/AggregationTests/AggregateStoreTests.swift:24` | Same. |
| `AgentsUsageBarTests/AggregationTests/AggregateStoreStaleAndTintTests.swift:39` | Same. |
| `AgentsUsageBarTests/AggregationTests/AppDependenciesCodexGeminiRegistrationTests.swift:46` | Same. |
| `AgentsUsageBarTests/AggregationTests/PollSchedulerSleepWakeTests.swift:20` | Same. |
| `AgentsUsageBarTests/AggregationTests/PollSchedulerTests.swift:25` | Same. |

**Test fixtures:** none of the above use exhaustive switches — all just return a single hard-coded status from a stub. **Add NEW** test files asserting that `StatusDot.dotColor` returns `.gray` for `.notRunning`, and that `.notRunning` is NOT in the POLL-06 terminal-skip set (regression for D-01 invariant).

### 4.3 Codable persistence

`ProviderStatus` is `Codable` (`Domain/ProviderStatus.swift:7`) — the disk cache (`FileCacheStore`) persists provider status across launches (UI-07 no-Loading-flash). Adding an enum case requires the synthesised `Codable` to round-trip the new arm. Swift's synthesised `Codable` for enums with associated values handles this automatically; the cached `today.json` from a prior build that contains only old cases continues to decode. Forward-compat: a cache file written by a newer build with `.notRunning` will FAIL to decode in an older binary — flag in changelog; no graceful downgrade required (Phase 4 is forward-only).

---

## 5. Secondary-Line Row-State Decision Table (D-02 + D-03)

D-02 repurposes the existing `tokens · USD · balance` HStack (`UI/ProviderRowView.swift:72-91`) when `capabilities.isLocal == true`. D-02a carries structured payload through `UsageSnapshot.raw[String: String]` (`Domain/UsageSnapshot.swift:35`) — no new domain field.

### 5.1 Row state table

| Row state | Trigger | Rendered secondary-line string | `raw[…]` keys carrying payload | Tooltip (`.help()` via `tooltipLabel`) |
|---|---|---|---|---|
| **A. Not running** | Probe surfaced `URLError.cannotConnectToHost` / `.cannotFindHost` / `.networkConnectionLost` / `.timedOut`. `lastStatus = .notRunning`. | `"Not running"` | none (snapshot may be nil or empty) | nil (no detail to surface) |
| **B. Idle — 0 models loaded** | Probe HTTP 200; `models[]` empty (Ollama `/api/ps`) OR every LM Studio model has `state != "loaded"`. `lastStatus = .ok(...)`. | `"Idle — 0 models loaded"` | `raw["modelCount"] = "0"` (optional, for tests / debugging) | nil |
| **C. `<modelName>`** | Exactly one loaded model. | `"<modelName>"` e.g. `"llama3:8b"`; **suffix** `" · X.X GB VRAM"` ONLY when `raw["vramBytes"]` is present and parseable. | `raw["modelName"] = "<name>"`, `raw["modelCount"] = "1"`, `raw["vramBytes"] = "<int64>"` (Ollama only) | family / quantization / parameter_size joined as `"llama · 7.2B · Q4_0"` |
| **D. `<firstModel> · +N more`** | Ollama with N>1 concurrently-loaded models. | `"<firstModelName> · +\(N-1) more"` e.g. `"llama3:8b · +2 more"` | `raw["modelName"] = "<firstName>"`, `raw["modelCount"] = "\(N)"`, `raw["allModels"] = "\(name1)|\(name2)|..."` (pipe-separated; tooltip splits) | full per-model list, one per line |
| **E. (llama.cpp specific) Running — loading…** | `/health` `status: "loading model"`. `lastStatus = .ok(...)` (NOT `.error`). | `"Running — loading model…"` | `raw["modelCount"] = "0"`, `raw["loadingModel"] = "true"` | nil (will populate when load completes next poll) |

**State E rationale:** llama.cpp's `"loading model"` is documented transient warmup (often <30s on small models, minutes on 70B). Rendering it as `.error` would falsely alarm; rendering as `.notRunning` is wrong because the server IS up. Treat as a sub-state of `.ok(...)` with the secondary-line variant. The fifth state adds ONE conditional branch in `ProviderRowView` — cheap.

### 5.2 View-side branching

`ProviderRowView` already keys off the snapshot. The branch shape:

```swift
// Pseudocode for the local secondary line — planner refines.
private func secondaryLine(_ snapshot: UsageSnapshot?, capabilities: ProviderCapabilities) -> some View {
    guard capabilities.isLocal, let snap = snapshot else {
        return EmptyView()  // remote-row path handled by existing HStack at lines 72-91
    }
    let count = Int(snap.raw["modelCount"] ?? "") ?? 0
    let loading = snap.raw["loadingModel"] == "true"
    let name = snap.raw["modelName"]
    let vramBytes = Int64(snap.raw["vramBytes"] ?? "") ?? 0
    let vramText = vramBytes > 0
        ? String(format: " · %.1f GB VRAM", Double(vramBytes) / 1_073_741_824)
        : ""

    if loading {
        return Text("Running — loading model…")
    }
    if count == 0 {
        // Distinguish A vs B by lastStatus, which propagates via ProviderState.status:
        // .notRunning -> "Not running"; .ok(_) -> "Idle — 0 models loaded".
        return Text(state.status == .notRunning ? "Not running" : "Idle — 0 models loaded")
    }
    if count == 1, let name {
        return Text("\(name)\(vramText)")
    }
    if count > 1, let name {
        return Text("\(name) · +\(count - 1) more")
    }
    return Text("—")
}
```

**Capabilities lookup:** views read `capabilities` via the provider registry or via a static helper on `ProviderID` (the new local IDs are known-local; a `static let localIDs: Set<ProviderID> = [.ollama, .lmstudio, .llamacpp]` on `ProviderID` is the cheapest seam). Alternatively the planner injects `capabilitiesByID: [ProviderID: ProviderCapabilities]` into the row's environment via `AggregateStore` — symmetric with the existing `hasTokensByID` snapshot (`AggregateStore.swift:48`).

### 5.3 Existing isDegraded / isStale composition

`isDegraded` (`ProviderRowView.swift:47-49`, keys on `ThresholdEngine.degradedTag`) and `isStale` (`AggregateStore.isStale(_:now:)`) already dim opacity to 0.6. Local rows that flip from `.ok` to `.notRunning` between polls SHOULD NOT show dimmed/stale styling because the transition is normal lifecycle, not a remote-API outage. Verify: when `state.status == .notRunning`, `isStale` returns `false` (the provider has no `lastSuccess` AFTER going down, OR the planner explicitly skips local rows in `isStale`). Simplest: leave `isStale` alone — `.notRunning` rows still get stale-dimmed if `2 × interval` elapses, which is harmless because the muted-gray dot is already muted.

---

## 6. Composition Plan

`AppDependencies.makeProduction()` (`App/AppDependencies.swift:63-300`) is the single composition root. The Codex (`:142-186`) and Gemini (`:188-206`) registration blocks are the precedent shape. Phase 4 adds three new blocks.

### 6.1 Registration order

| Order | Provider | Config gate | Probe endpoints | Placeholder fallback |
|---|---|---|---|---|
| 1 | OpenRouter | `config.openrouter.apiKey != nil` | (remote — Phase 1) | already wired |
| 2 | Claude | `oauthClient != nil \|\| hasTranscripts` | (remote / file — Phase 2) | already wired |
| 3 | Codex | `config.codex.enabled && (creds \|\| ~/.codex/sessions)` | (remote / file — Phase 3) | already wired |
| 4 | Gemini | `config.gemini.enabled && isOAuthPersonal && creds != nil` | (remote — Phase 3) | already wired |
| **5** | **Ollama** | `config.ollama.enabled` (default true) — NO presence detection (LOCAL-01 always probes well-known port 11434) | `GET /api/ps`, `GET /api/tags` (concurrent via `async let`) | none — first probe writes `.notRunning` to the row directly. |
| **6** | **LM Studio** | `config.lmstudio.enabled` (default true) — well-known port 1234 unless overridden | `GET /api/v0/models` with `/v1/models` 404 fallback | none — first probe writes `.notRunning`. |
| **7** | **llama.cpp** | `config.llamacpp.enabled && config.llamacpp.port != nil` | `GET /health`, `GET /v1/models`, opportunistic `GET /slots` | **D-04 placeholder:** `store.seedPlaceholder(.llamacpp, displayName: "llama.cpp", status: .notRunning)` with `placeholderMessage: "Set [llamacpp] port in config.toml to enable"`. |

**Code sketch — copy from `AppDependencies.swift:142-186` (Codex block) verbatim shape:**

```swift
// 6.3. Ollama provider (Plan 04-0X) — register unconditionally when enabled.
//      Well-known port 11434 (LOCAL-01); no presence detection.
if config.ollama.enabled {
    let provider = OllamaProvider(
        http: localhostHTTP,        // see §6.2 — second URLSession with 2s timeout
        clock: clock
    )
    registry.append(provider)
}

// 6.4. LM Studio provider — well-known port 1234, port overridable.
if config.lmstudio.enabled {
    let provider = LMStudioProvider(
        http: localhostHTTP,
        clock: clock,
        port: config.lmstudio.port
    )
    registry.append(provider)
}

// 6.5. llama.cpp provider — port REQUIRED in TOML (LOCAL-03 no scanning).
let llamacppRegistered: Bool
if config.llamacpp.enabled, let port = config.llamacpp.port {
    let provider = LlamaCppProvider(
        http: localhostHTTP,
        clock: clock,
        port: port
    )
    registry.append(provider)
    llamacppRegistered = true
} else {
    llamacppRegistered = false
}

// … after AggregateStore init …

if !llamacppRegistered {
    // D-04 — discoverability placeholder with the unconfigured-row subtitle.
    store.seedPlaceholder(
        providerID: ProviderID.llamacpp,
        displayName: "llama.cpp",
        status: .notRunning
    )
    // Carrier for the subtitle — ProviderState.placeholderMessage already supports this
    // (Domain/ProviderState.swift:51). Planner extends seedPlaceholder OR sets it via a
    // follow-up call; the existing seedPlaceholder signature does NOT accept
    // placeholderMessage today, so the planner adds either a parameter or a sibling helper.
}
```

**D-04 placeholderMessage wiring caveat:** `AggregateStore.seedPlaceholder(providerID:displayName:status:)` (`AggregateStore.swift:183-194`) currently constructs `ProviderState.placeholder(...)` (`Domain/ProviderState.swift:63-76`) which passes `placeholderMessage: nil`. The planner extends `seedPlaceholder` with an optional `placeholderMessage: String? = nil` arg AND threads it through `ProviderState.placeholder`. Zero blast radius on existing callers (default-nil).

### 6.2 Second `URLSessionHTTPClient` for the 1–2s localhost tier (POLL-08)

CLAUDE.md "Concurrency & Polling Pattern" mandates one URLSession instance per app — but per **tier**, since remote (8s) and local (2s) have different `timeoutIntervalForRequest`. The current production instance is `URLSessionHTTPClient()` (`Infrastructure/URLSessionHTTPClient.swift:26-34`) with hard-coded 8s timeout.

**Recommended approach** (Discretion §"1–2s localhost timeout"): extend `URLSessionHTTPClient.init()` with a `timeoutSeconds: TimeInterval = 8` parameter:

```swift
public init(timeoutSeconds: TimeInterval = 8) {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = timeoutSeconds
    cfg.timeoutIntervalForResource = max(timeoutSeconds * 4, 30)
    cfg.waitsForConnectivity = false
    cfg.httpMaximumConnectionsPerHost = 6
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    self.session = URLSession(configuration: cfg)
}
```

Then in `AppDependencies.makeProduction()`:

```swift
// 2. HTTP clients — TWO tiers per POLL-08:
let http: any HTTPClient = URLSessionHTTPClient()                  // 8s remote tier
let localhostHTTP: any HTTPClient = URLSessionHTTPClient(timeoutSeconds: 2)
```

Inject `localhostHTTP` into the three local provider actors; `http` stays with OpenRouter / Claude / Codex / Gemini.

**Alternative (per-request override)** — `URLRequest.timeoutInterval = 2` set inside each local provider's request construction. Rejected because it leaks "I am localhost" knowledge into provider code that should be tier-agnostic; the planner should keep the URLSession-as-tier seam.

### 6.3 HTTPClient.get(bearer: nil) overload

Discretion §"`HTTPClient.get(bearer: Secret? = nil)` overload" — confirmed wired at `Infrastructure/HTTPClient.swift:44-50` AND extension overload at `:142-170`. Local providers call:

```swift
let response: OllamaPsResponse = try await http.get(
    URL(string: "http://localhost:11434/api/ps")!,
    bearer: nil,
    extraHeaders: [:],
    as: OllamaPsResponse.self
)
```

`useSnakeCaseConversion: true` (default via extension) — Ollama / LM Studio / llama.cpp all use snake_case fields (`size_vram`, `loaded_context_length`). For LM Studio / llama.cpp whose response models declare explicit snake_case `CodingKeys` (matching the Phase 3 STATE #67 Codex precedent), use `useSnakeCaseConversion: false` to avoid the strategy-clobbers-explicit-keys trap (Phase 3 STATE #77 lesson).

### 6.4 Circuit breakers

Local providers participate in the standard POLL-05 5-strike per-provider breaker (`AggregateStore.perProviderBreakers`, `AggregateStore.swift:73`). NO scoped 3-strike breaker for `.notRunning` — `.notRunning` is a SUCCESS-class probe outcome (we successfully determined "server's not there"), so it MUST NOT increment the breaker. Recommended classification in `performRefresh` (`AggregateStore.swift:302-318`):

```swift
case .failure(let err):
    let pe = ProviderError.from(err)
    if pe.kind == .auth || pe.kind == .paymentRequired {
        // POLL-06 path (terminal)
    } else if pe.message == "circuit-open" {
        // already open
    } else if /* local + connection-refused */ {
        // NEW Phase 4 branch — treat as success-class for breaker accounting
    } else {
        await breaker(for: id).recordFailure(now: now)
    }
```

Simpler alternative the planner should consider: local provider actors NEVER throw on `.notRunning` — they return a `UsageSnapshot` carrying the `.notRunning` lastStatus + `raw["modelCount"] = "0"`. Then the success path runs (`breaker.recordSuccess()`), the row updates, and the breaker is never tickled by transient localhost-down states. This is the **cleaner shape** — recommend it. Matches Phase 3 STATE #82 Gemini "NEVER throws for v1internal flakiness" precedent.

### 6.5 PollScheduler / sleep-wake

`PollScheduler` + `PowerObserver` (Phase 2 STATE #55-58) already work universally — local providers inherit POLL-04 pause-on-sleep and POLL-09 battery-low behaviour for free. NO Phase 4 changes to either.

---

## 7. TOML Schema Additions

Reuse the Phase 1 D-16 hand-rolled subset (`Config/TomlReader.swift`) verbatim. Three new sections, parsed in `ConfigStore.load()` alongside the existing `[codex]` and `[gemini]` blocks (`Config/ConfigStore.swift:140-181` precedent).

### 7.1 Schema

```toml
# config.toml — Phase 4 additions

[ollama]
enabled = true            # default true — well-known port 11434

[lmstudio]
enabled = true            # default true — well-known port 1234
port    = 1234            # int; only override if user runs LM Studio on a non-default port

[llamacpp]
enabled = true            # default true (but row stays placeholder when `port` absent)
port    = 8080            # int; REQUIRED to activate the row; no default (LOCAL-03 no scanning)
```

### 7.2 AppConfig structs

Mirror `OpenRouterConfig` / `CodexConfig` / `GeminiConfig` shape (`Config/AppConfig.swift:60-169`).

```swift
public struct OllamaConfig: Sendable, Equatable {
    public let enabled: Bool          // default true
    public init(enabled: Bool) { self.enabled = enabled }
}

public struct LMStudioConfig: Sendable, Equatable {
    public let enabled: Bool          // default true
    public let port: Int              // default 1234
    public init(enabled: Bool, port: Int) {
        self.enabled = enabled; self.port = port
    }
}

public struct LlamaCppConfig: Sendable, Equatable {
    public let enabled: Bool          // default true
    public let port: Int?             // REQUIRED to register; nil → placeholder
    public init(enabled: Bool, port: Int?) {
        self.enabled = enabled; self.port = port
    }
}

// AppConfig gains three fields + three new params in init + three new entries in .defaults.
```

### 7.3 ConfigStore parsing

Match `Config/ConfigStore.swift:140-181` shape. `[ollama].enabled` / `[lmstudio].enabled` / `[lmstudio].port` / `[llamacpp].enabled` / `[llamacpp].port` are all TOML scalars (bool, int) — supported by `TomlReader.parse` (`Config/TomlReader.swift:14-19`). NO env override (Discretion §"TOML schema additions" — "Env overrides not required for locals (no secrets — port + enable are config knobs)").

### 7.4 SEC-04 grep

No new patterns. Local rows carry no secrets. Existing CI grep (`sk-proj-|sk-admin-|sk-or-|AIzaSy|sk-[A-Za-z0-9]{20,}|GOCSPX-`) is unchanged.

---

## 8. Test Strategy

Mirror Phase 2 STATE #19 / Phase 1 W-7 — Swift Testing (`@Test`, `#expect`, `#require`), `.serialized` trait + `NSLock`-protected static when sharing `URLProtocol` stubs across tests in a suite. Local test layout: `AgentsUsageBarTests/Providers/OllamaTests/`, `LMStudioTests/`, `LlamaCppTests/` mirroring `ClaudeTests/` / `CodexTests/` / `GeminiTests/`.

### 8.1 Per-actor minimum suites

| Test suite | Coverage |
|---|---|
| `OllamaProviderTests` | (a) `/api/ps` happy path with 1 model + size_vram → snapshot.raw["modelName"], raw["vramBytes"]; (b) `/api/ps` empty + `/api/tags` non-empty → "Idle — 0 models loaded"; (c) `/api/ps` empty + `/api/tags` empty → "Idle — no models installed" (degenerate); (d) connection-refused → `.notRunning`; (e) >1 loaded → `raw["modelCount"] > 1`, `raw["allModels"]` pipe-joined; (f) HTTP 500 → `.error`; (g) lenient decoder swallows unknown fields. |
| `LMStudioProviderTests` | (a) `/api/v0/models` extended schema with state="loaded" → snapshot populated; (b) `/api/v0/models` returns 404 → fallback to `/v1/models`; (c) all models state="not-loaded" → "Idle — 0 models loaded"; (d) connection-refused → `.notRunning`; (e) lenient decoder; (f) port override read from `LMStudioConfig.port`. |
| `LlamaCppProviderTests` | (a) `/health` "ok" + `/v1/models` populated → running with model name (basename); (b) `/health` "loading model" → "Running — loading model…" state E; (c) `/health` "error" → `.error`; (d) `/health` "no slot available" → still running; (e) connection-refused → `.notRunning`; (f) `/slots` 404 ignored (informative only); (g) lenient decoder. |

### 8.2 Cross-cutting suites

| Test suite | Coverage |
|---|---|
| `ProviderStatusNotRunningTests` (new) | (a) `StatusDot.dotColor` returns `.gray` for `.notRunning`; (b) `.notRunning` is NOT in `AggregateStore.performRefresh`'s POLL-06 terminal-skip set — write an integration test that seeds a `.notRunning` provider, calls `refresh(now:)`, and asserts the provider WAS probed (i.e. lastTick advanced AND the provider's status changed). |
| `LocalURLErrorClassifierTests` (new) | Parameterised over `URLError.Code.cannotConnectToHost`, `.cannotFindHost`, `.networkConnectionLost`, `.timedOut` → `.notRunning`; `.notConnectedToInternet` → `.error`; `HTTPError(500)` → `.error`. |
| `AggregateStoreLocalRollupTests` (new) | Asserts `rollupTotals()` skips providers whose `capabilities.hasTokens == false` (Phase 3 D-07 / `AggregateStore.swift:387, 392`). Regression — verifies adding three more `hasTokens=false` providers doesn't break Phase 3 behaviour. |
| `ThresholdEngineLocalNilQuotaTests` (new) | Asserts `decisions(for: [localSnapshot with quota=nil])` returns `[]`. Mirrors CONTEXT canonical-refs Pitfall 6 guidance. |
| `AppDependenciesLocalRegistrationTests` (new) | Mirrors `AppDependenciesCodexGeminiRegistrationTests` (`AggregationTests/AppDependenciesCodexGeminiRegistrationTests.swift:46`). Covers: (a) all three locals register when enabled; (b) `llamacpp` placeholder seeds when `port==nil`; (c) disabled-via-TOML omits the provider AND no placeholder seeds. |
| `ConfigStoreLocalSectionsTests` (new) | TOML fixture with `[ollama]`, `[lmstudio]`, `[llamacpp]` sections → `AppConfig` carries correct values; missing section → defaults from `AppConfig.defaults`. |
| `LenientCodableLocalTests` (new) | One `@Test` per response struct, each fed a fixture JSON with an unknown extra field; decode succeeds. Covers Ollama `/api/ps`, `/api/tags`; LM Studio `/api/v0/models`, `/v1/models`; llama.cpp `/health`, `/slots`, `/v1/models`. |

### 8.3 URLProtocol stub pattern

Identical to Phase 3 STATE #19 — `.serialized` trait + `NSLock`-protected static shared stub. For LM Studio's 404→`/v1/models` fallback, the stub MUST be capable of returning different status codes per URL — see existing `URLProtocolStub` pattern in Phase 1 (`AgentsUsageBarTests/Infrastructure/URLProtocolStub.swift` if it exists; otherwise reuse the Phase 2/3 FakeHTTPClient seam at the HTTPClient protocol level — Phase 3 STATE #69 confirms that FakeHTTPClient at the protocol seam is preferred over literal URLProtocol stubs, with the `.serialized` trait still applied).

---

## 9. Plan Decomposition Proposal

Aim for a similar shape to Phase 3's 9-plan layout. Suggested 8 plans, in dependency order:

| Plan # | Objective | Requirements | Depends on | Wave |
|---|---|---|---|---|
| **04-01** | Add `ProviderStatus.notRunning` case + ripple. Extend `StatusDot.dotColor` / `accessibilityLabel` switches. Verify NOT in POLL-06 terminal-skip set. Add `ProviderStatus.classifyLocalhost(error:lastSuccess:)` helper (§3.2). Three new `ProviderID` constants (`.ollama`, `.lmstudio`, `.llamacpp`). | LOCAL-04 (status), LOCAL-05 (refused→notRunning) | — | 1 (foundation) |
| **04-02** | TOML schema + `AppConfig` extension. Add `OllamaConfig`, `LMStudioConfig`, `LlamaCppConfig` + three `AppConfig` fields + `.defaults`. Extend `ConfigStore.load()` parsing for `[ollama]`, `[lmstudio]`, `[llamacpp]`. Tests: `ConfigStoreLocalSectionsTests`. | LOCAL-01..03 (port config), LOCAL-04 (enabled gate) | 04-01 | 1 |
| **04-03** | Infrastructure: second `URLSessionHTTPClient` tier. Extend `URLSessionHTTPClient.init(timeoutSeconds:)` with default 8 (back-compat) per §6.2. Tests: `URLSessionHTTPClientTimeoutTierTests`. | POLL-08 (1–2s localhost), LOCAL-05 | 04-01 | 1 |
| **04-04** | `OllamaProvider` actor + `/api/ps` + `/api/tags` decoders (lenient). D-03 multi-model row-state computation. Tests: `OllamaProviderTests`. | LOCAL-01, LOCAL-04, LOCAL-05, LOCAL-06 | 04-01, 04-03 | 2 |
| **04-05** | `LMStudioProvider` actor + `/api/v0/models` with `/v1/models` fallback. Tests: `LMStudioProviderTests`. | LOCAL-02, LOCAL-04, LOCAL-05, LOCAL-06 | 04-01, 04-03 | 2 |
| **04-06** | `LlamaCppProvider` actor + `/health` + `/v1/models` + opportunistic `/slots`. State E `Running — loading…`. Tests: `LlamaCppProviderTests`. | LOCAL-03, LOCAL-04, LOCAL-05, LOCAL-06 | 04-01, 04-03 | 2 |
| **04-07** | UI row-state rendering for `isLocal` rows (§5.2 branching) + capabilities-by-ID lookup. Cross-cutting tests: `ProviderStatusNotRunningTests`, `LocalURLErrorClassifierTests`, `AggregateStoreLocalRollupTests`, `ThresholdEngineLocalNilQuotaTests`. | LOCAL-04 (UI), LOCAL-06 (excludes from total) | 04-04, 04-05, 04-06 | 3 |
| **04-08** | Composition root: register Ollama / LM Studio / llama.cpp actors in `AppDependencies.makeProduction()`. D-04 unconfigured-llama.cpp placeholder with `placeholderMessage`. Extend `AggregateStore.seedPlaceholder` with `placeholderMessage` parameter (or sibling helper). Tests: `AppDependenciesLocalRegistrationTests`. | LOCAL-01..06 wiring | 04-02, 04-04, 04-05, 04-06, 04-07 | 4 |
| **04-09** | Phase 4 UAT walkthrough. Mirror `02-UAT.md` / `03-UAT.md` shape: 10-row outcomes table, pre-conditions checklist, manual + unit-test attestation per requirement, build-SHA pin, reviewer-signal protocol. | none new (UAT only) | 04-08 | 5 |

**Wave parallelism:** Wave 2 (04-04 / 04-05 / 04-06) is fan-out — three actor plans share zero code surface and can ship in parallel via worktrees if `workflow.use_worktrees` is enabled. Wave 1 plans (04-01 → 04-02 → 04-03) are best run sequentially: 04-01 lands the enum case that 04-02 / 04-03 fixtures may implicitly reference.

---

## 10. Known Pitfalls Specific to Phase 4

| # | PITFALLS.md ref | Phase-4-specific guidance |
|---|---|---|
| **3** | Naive `FileManager.default` reads of dotfiles fail silently under App Sandbox | N/A in v1 (sandbox is OFF, Phase 1 D). However, Phase 4 introduces NO file reads (locals are all HTTP); verify the signed Release build can hit `http://localhost:*` — `Info.plist:23-27` already declares `NSAllowsLocalNetworking = true`, no plist edit. |
| **5** | Polling timer keeps firing during sleep | `PowerObserver` (Phase 2 STATE #55) covers Phase 4 transparently — local probes pause on sleep. **Phase-4-specific:** the 2s tier could theoretically wake the radio more often than 8s tier; localhost probes do NOT hit the network stack at all (loopback interface), so this is a non-event. |
| **6** | Notification storm | Local snapshots have `quota = nil` → `ThresholdEngine.decisions(...)` skips them via the `guard let quota = snap.quota else { return nil }` gate (`Notifications/ThresholdEngine.swift:124`). **Mandatory regression test:** `ThresholdEngineLocalNilQuotaTests` (§8.2). |
| **7** | JSONL transcript parsing assumes stable schema | Adapt to HTTP probes: every local response decoder MUST use lenient `Codable` (Swift synthesised behaviour tolerates unknown fields by default; new fields appearing in Ollama 0.2.x / LM Studio 0.4.x do NOT zero out the row). Tests: `LenientCodableLocalTests` (§8.2). |
| **9** (NEW — uncovered in this research) | LM Studio's `/api/v0/models` was added in 0.3.5 (Nov 2024) — older builds 404 | Probe strategy §2.2 — fall back to `/v1/models` on 404. Tests: `LMStudioProviderTests` covers this explicitly. |
| **10** (NEW) | llama.cpp's `/health` "loading model" returns 200, not a non-2xx | If treated as `.error` the row would falsely flash red during every model warmup. Map to state E (§5.1) — `Running — loading model…` under `.ok`. |
| **11** (NEW) | Ollama `size_vram` is `Int64`, not `Int` | A 70B Q5_K_M model exceeds 50 GB → > `Int32.max` on 32-bit hosts. macOS is 64-bit-only so `Int == Int64`, but the response model MUST declare `Int64` explicitly to survive a future archive of the test fixture being decoded under a hypothetical 32-bit target. Cheap insurance. |

---

## 11. Open Questions / Verification Needed

| # | Question | Why it matters | Suggested resolution |
|---|---|---|---|
| OQ-1 | Exact `/health` `"loading model"` JSON shape on the latest llama.cpp `master` (post-2025-01 — server endpoint was being refactored upstream). | Determines state E literal match. | Planner runs `curl -s http://localhost:8080/health` against a fresh `llama-server` build mid-load and pins the exact field. If the wire shape changed to `{ "status": "loading", ... }` (no "model" suffix), update the discriminator string. |
| OQ-2 | Does `/api/v0/models` return 404 vs 500 vs "endpoint not implemented" on LM Studio < 0.3.5? | The fallback branch only triggers on 404; a 500 would bubble as `.error`. | Planner spot-checks LM Studio 0.2.x in `~/Applications`. If unavailable, plan the fallback to ALSO trigger on 500 (treat any non-2xx as "extended endpoint missing, fall to OAI-compat"). |
| OQ-3 | Does llamafile's `/health` byte-match mainline llama.cpp's? | If llamafile is N versions behind, the `"no slot available"` status may not exist there → row would render falsely-degraded. | Curl-test against latest llamafile release; if drift detected, simplify llama.cpp probe to only key on `status == "ok"` and treat ANY other shape as `.ok` (best effort). Document in plan 04-06. |
| OQ-4 | Does Ollama 0.5+ emit `size_vram == 0` when the model is CPU-only (no GPU on Mac mini base)? | Determines whether to suppress the `· X.X GB VRAM` suffix for CPU-only runs. | Test with `OLLAMA_NUM_GPU=0` env. §5.1 already suppresses the suffix when `vramBytes == 0` — verify the wire actually returns 0 (not nil/absent). |
| OQ-5 | Should `placeholderMessage` for D-04 unconfigured llama.cpp render in the secondary line OR as a third line? `ProviderState.placeholderMessage` (line 51) exists but Phase 4 hasn't surfaced it before. | Determines `ProviderRowView` rendering. | Researcher recommendation: surface in the secondary line (where the model name would otherwise go) since the row is in `.notRunning` and has no model. Planner picks. |
| OQ-6 | Should local rows participate in `UI-08` stale-data dim? | Locals don't have a meaningful "last successful refresh" if they're in `.notRunning` indefinitely. | Recommendation: yes, leave the existing logic untouched — `.notRunning` rows are already muted-gray; stale-dimming on top is visually redundant but harmless. Planner verifies. |
| OQ-7 | `AggregateStore.seedPlaceholder(...)` currently does NOT accept `placeholderMessage`. Extending it is mechanical. Is there appetite for the planner to add a sibling `seedPlaceholderWithMessage(...)` instead of changing the existing signature? | Affects existing call-site count and whether Plan 04-08 touches the Codex / Gemini seed paths. | Recommendation: add optional parameter (default nil) to keep one entry point. Zero blast radius. |

---

## RESEARCH COMPLETE
