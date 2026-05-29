# Agents Usage Bar

## What This Is

A macOS menu bar app that surfaces today's AI agent usage across multiple providers — Claude (via `ccs`), OpenAI Codex, Gemini, OpenRouter, and local agents (Ollama, LM Studio, llama.cpp/llamafile). One glance shows tokens used, cost spent (USD), and quota remaining per provider, with native notifications when any provider approaches its quota limit. Built for developers who juggle multiple AI tools and want a single, ambient view of "what am I burning today?".

## Core Value

A single ambient glance shows accurate per-provider AI usage for today, so the user notices spend/quota issues before they bite.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Live in macOS menu bar with a SwiftUI popover panel listing every supported provider
- [ ] Track Claude usage from `~/.claude/projects/**/*.jsonl` transcripts (ccusage / ClaudeBar pattern) plus Claude OAuth usage API (`/api/oauth/usage`) when creds available
- [ ] Track OpenAI Codex usage primarily from `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` `event_msg.token_count` (no-auth) with Codex CLI RPC / OAuth API as fallback
- [ ] Track Gemini usage via OAuth-personal (`~/.gemini/oauth_creds.json`) + `cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
- [ ] Track OpenRouter usage (`/api/v1/credits` + `/api/v1/key`) — tokens, cost, remaining credits
- [ ] Track local agents — Ollama (`/api/ps`, `/api/tags`), LM Studio (`/v1/models`, `/api/v0/models`), llama.cpp (`/health`, `/slots`) — running/idle + model name. Cumulative tokens NOT tracked (requires request proxying)
- [ ] Show today's tokens, USD cost, and quota-remaining per provider, plus a cross-provider "today total" row at top
- [ ] Refresh every 1–5 minutes in background (default 5m) plus on popover open. Optional Claude Code `Stop` hook for live updates (ClaudeBar pattern)
- [ ] Read API keys / OAuth tokens from existing CLI config files and env vars (no Keychain UI in v1)
- [ ] macOS native notification on threshold transition (default 80%), per (provider, window) debounce, "snooze for today" action
- [ ] Ship as a notarized DMG via GitHub Releases with Sparkle auto-update (open-source repo)

### Out of Scope

- Windows / Linux builds — macOS menu bar is the product
- Electron / Tauri / web stack — Swift + SwiftUI only, native feel matters
- Keychain-based settings UI in v1 — env/config-file ingestion is enough to validate
- Historical charts / multi-day analytics — today-only aggregation in v1 (in-memory sparkline ring buffer allowed)
- Per-model breakdowns deeper than provider-level — v1 stays provider-level
- Cost forecasting / budgeting tools — defer; v1 only reports observed spend
- App Store distribution — DMG-only in v1
- Multi-user / team accounts — single local user
- Browser cookie scraping (Safari/Chrome/Firefox sessions) — requires Full Disk Access + Chrome Safe Storage prompts; looks like spyware
- Real-time local-agent token interception (proxying `/api/generate` etc.) — port-conflict footgun; local rows show running/idle + model only
- Shell RC file parsing (`~/.zshrc`, `~/.bashrc`, fish config) — `source` chains are arbitrary code execution; read env from `ProcessInfo.environment` only
- Auto-launch at login by default — surprises users; opt-in toggle only

## Context

- Target platform: macOS 14+ (Apple Silicon + Intel), latest two macOS versions.
- User already runs Claude Code, OpenAI Codex CLI, Gemini CLI, and local model runtimes. Credentials and usage data already exist on disk:
  - Claude transcripts: `~/.claude/projects/-${urlsafe-cwd}/*.jsonl`. OAuth creds in `~/.claude/.credentials.json` or Keychain item `Claude Code-credentials`.
  - Codex rollouts (no auth): `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` last `event_msg.token_count` event yields tokens + rate-limits + reset timestamps + plan. Auth at `~/.codex/auth.json`.
  - Gemini: `~/.gemini/oauth_creds.json` (+ `settings.json` with `selectedAuthType:"oauth-personal"`).
  - OpenRouter: `OPENROUTER_API_KEY` env var.
  - Note: `~/.ccs/` contains agent/instance/hook **configuration**, not Claude API tokens. `rtk gain` reports RTK tool-call savings, NOT Anthropic usage. Claude usage source is `~/.claude/projects/**/*.jsonl`.
- Inspiration / prior art (study, don't copy):
  - **ClaudeBar** — https://github.com/tddworks/ClaudeBar — macOS 15+, Swift 6.2, Tuist, Sparkle. Uses a Claude Code shell hook in `~/.claude/claudebar-hook-port` POSTing to `http://localhost:19847/hook` for real-time updates.
  - **CodexBar** — https://github.com/steipete/CodexBar — macOS 14+, MIT, 29 providers, default 5-min refresh, bundled CLI, WidgetKit widgets.
  - **ccusage** — https://github.com/ryoppippi/ccusage — npm tool; canonical pattern for local JSONL token+cost scan (Claude and Codex).
- API surfaces:
  - Claude OAuth: `GET https://api.anthropic.com/api/oauth/usage` (`anthropic-beta: oauth-2025-04-20`). Web fallback: `https://claude.ai/api/organizations/{orgId}/usage`.
  - OpenAI/Codex OAuth: `GET https://chatgpt.com/backend-api/wham/usage`. Local rollout file is preferred (no auth).
  - Gemini quota: `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`. Refresh: `POST https://oauth2.googleapis.com/token`.
  - OpenRouter: `GET https://openrouter.ai/api/v1/credits` and `GET https://openrouter.ai/api/v1/key`.
- Local agents over localhost HTTP — running/idle + model name (cumulative tokens NOT feasible without proxying):
  - Ollama: `http://localhost:11434/api/ps`, `/api/tags`, `/api/version`.
  - LM Studio: `http://localhost:1234/v1/models`, `/api/v0/models`.
  - llama.cpp / llamafile: `http://localhost:8080/health`, `/slots`, `/v1/models` (port configurable; no canonical default).
- Open-source release: public README, MIT or Apache-2.0 license, codesigning + notarization via GitHub Actions (`xcrun notarytool` + `xcrun stapler staple`), Sparkle EdDSA-signed appcast hosted on GitHub Pages.

## Constraints

- **Tech stack**: Swift + SwiftUI native macOS app — no Electron/Tauri/web wrappers
- **Distribution**: Notarized DMG via GitHub Releases — no App Store in v1
- **Aggregation window**: Today only (local-midnight reset) — no multi-day persistence in v1
- **Secrets**: No Keychain entry UI in v1 — read keys from env vars and existing CLI config files
- **Refresh**: Background poll every 1–5 min (default 5m) + on-open refresh — must not noticeably impact battery; JSONL streaming reads only the delta since last poll
- **Local file access**: Ship unsandboxed with Hardened Runtime + notarization. App Sandbox blocks reads of `~/.claude/projects/**`, `~/.codex/sessions/**`, `~/.gemini/oauth_creds.json` without temporary-exception entitlements deprecated by Apple. Since v1 is DMG-only (no MAS), unsandboxed is correct.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Swift + SwiftUI native (no Tauri/Electron) | Best menu bar UX, smallest binary, native notifications | — Pending |
| macOS 14+ minimum, `MenuBarExtra(.window)` | `@Observable` requires 14+; `MenuBarExtra` style `.window` known-stable on 14+ | — Pending |
| Popover panel UI (not plain NSMenu) | Richer per-provider rows with bars and totals | — Pending |
| Today-only aggregation in v1 | Trivial reset logic; matches "ambient glance" framing | — Pending |
| Read keys/OAuth from env + existing CLI config files | Both reference apps do this; avoids settings UI scope | — Pending |
| Claude source = `~/.claude/projects/**/*.jsonl` + OAuth API; NOT `~/.ccs/` | Research: `rtk gain` reports tool-call savings, not Anthropic tokens; ccusage/ClaudeBar pattern | — Pending |
| Codex source = `~/.codex/sessions/**/rollout-*.jsonl` last `token_count` (no auth) | Faster, offline, no token refresh; OAuth API as fallback | — Pending |
| Default refresh interval = 5 min (range 1m–30m) | Matches CodexBar default; 30s JSONL re-scan drains battery | — Pending |
| Ship unsandboxed + Hardened Runtime + notarized DMG | App Sandbox blocks dotfile reads; MAS is out of scope | — Pending |
| Local LLMs = presence + model name only (no cumulative tokens) | Cumulative tokens require request proxying = anti-feature | — Pending |
| Sparkle auto-update on GitHub Pages appcast | Required for DMG distribution; EdDSA-signed | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-05-11 after initialization*
