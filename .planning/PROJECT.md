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
- [ ] Track Claude usage by reading `ccs` / Claude Code transcript data (study ClaudeBar approach)
- [ ] Track OpenAI Codex usage from Codex CLI logs **and** OpenAI usage API
- [ ] Track Gemini usage (Gemini CLI logs and/or API)
- [ ] Track OpenRouter usage (API: tokens, cost, remaining credits)
- [ ] Track local agents — Ollama, LM Studio, llama.cpp/llamafile — for tokens and running state
- [ ] Show today's tokens, USD cost, and quota-remaining per provider
- [ ] Refresh every 30–60s in the background plus on popover open
- [ ] Read API keys / endpoints from env vars and existing CLI config files (no Keychain UI in v1)
- [ ] macOS native notification when any provider quota reaches a warning threshold (default 80%)
- [ ] Ship as a notarized DMG on a GitHub Releases page (open-source repo)

### Out of Scope

- Windows / Linux builds — macOS menu bar is the product
- Electron / Tauri / web stack — Swift + SwiftUI only, native feel matters
- Keychain-based settings UI in v1 — env/config-file ingestion is enough to validate
- Historical charts / multi-day analytics — today-only aggregation in v1
- Per-model breakdowns deeper than provider-level — v1 stays provider-level
- Cost forecasting / budgeting tools — defer; v1 only reports observed spend
- App Store distribution — DMG-only in v1
- Multi-user / team accounts — single local user

## Context

- Target platform: macOS (Apple Silicon + Intel), latest two macOS versions.
- User already runs `ccs` (per CLAUDE.md), Claude Code, Codex CLI, and the Gemini CLI, plus local model runtimes. Configs and keys already exist on disk in well-known locations (`~/.ccs/`, `~/.claude/`, `~/.codex/`, `~/.config/`, shell rc files).
- Inspiration / prior art to study and learn from (NOT copy): **ClaudeBar** (Claude menu bar), **CodexBar** (Codex menu bar). Their parsing approaches for transcripts and CLI session data are the closest reference for the Claude and Codex providers.
- OpenRouter exposes `/api/v1/auth/key` and `/api/v1/credits` for balance/limits; OpenAI exposes a usage endpoint for daily totals.
- Local agents typically expose HTTP servers on `localhost`:
  - Ollama: `http://localhost:11434` (`/api/ps`, `/api/tags`)
  - LM Studio: `http://localhost:1234/v1` (OpenAI-compatible)
  - llama.cpp / llamafile: configurable port, usually `8080`
- Open-source release implies a public-facing README, license, and a story for codesigning + notarization on GitHub Actions.

## Constraints

- **Tech stack**: Swift + SwiftUI native macOS app — no Electron/Tauri/web wrappers
- **Distribution**: Notarized DMG via GitHub Releases — no App Store in v1
- **Aggregation window**: Today only (local-midnight reset) — no multi-day persistence in v1
- **Secrets**: No Keychain entry UI in v1 — read keys from env vars and existing CLI config files
- **Refresh**: Background poll every 30–60s + on-open refresh — must not noticeably impact battery
- **Local file access**: Must work inside the macOS sandbox model the app chooses (consider whether app sandbox can be enabled given the need to read `~/.ccs/`, `~/.claude/`, etc.)

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Swift + SwiftUI native (no Tauri/Electron) | Best menu bar UX, smallest binary, native notifications | — Pending |
| Popover panel UI (not plain NSMenu) | Richer per-provider rows with bars and totals justify SwiftUI panel | — Pending |
| Today-only aggregation in v1 | Keeps storage and reset logic trivial; matches "ambient glance" framing | — Pending |
| Read keys from env / config files (no Keychain UI) | User already has working CLI keys on disk; avoids settings UI scope in v1 | — Pending |
| Codex: CLI logs + OpenAI usage API (both) | CLI logs are real-time; API confirms billable totals | — Pending |
| Claude usage: study ClaudeBar / CodexBar prior art | Proven parsing approaches for transcript/session data | — Pending |
| DMG release on GitHub (no App Store) | Faster iteration, no review cycle, open-source friendly | — Pending |

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
