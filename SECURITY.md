# Security Policy

## Scope

Agents Usage Bar is a local-only macOS menu bar utility. It has **no server component**, runs entirely on the user's machine, and only makes outbound HTTPS calls to the AI provider APIs the user has configured (Anthropic, OpenAI, OpenRouter, Google Gemini) and to localhost endpoints for local LLM runtimes (Ollama, LM Studio, llama.cpp). No telemetry, analytics, or crash-reporter uploads are performed (see [`README.md`](README.md) Privacy section and [`docs/entitlements.md`](docs/entitlements.md) for the entitlement justification).

This scope means the realistic threat surface is:

- Local file reads of AI-tool dotfiles (`~/.claude/`, `~/.codex/`, `~/.gemini/`, `~/.config/agents-usage-bar/config.toml`)
- Outbound HTTPS to the provider APIs above
- The local config file's POSIX permissions (must remain `0600` — the app warns when it isn't)

Vulnerabilities outside that scope (for example, in third-party AI provider APIs themselves, or in macOS) should be reported to the responsible vendor rather than to this project.

## Supported Versions

Only the **latest released version** is supported. Older versions do not receive security fixes; please update via the in-app Sparkle update prompt or by downloading the newest signed and notarized DMG from the [GitHub Releases page](https://github.com/lazym0m3nt/agents_usage_bar/releases).

| Version          | Supported          |
| ---------------- | ------------------ |
| Latest release   | Yes                |
| Older releases   | No                 |

## Reporting a Vulnerability

Please report vulnerabilities **privately**. Do not open a public GitHub issue for security reports.

Preferred channels (in order):

1. **GitHub private security advisory** — Open a draft advisory at [Security → Advisories → New draft security advisory](https://github.com/lazym0m3nt/agents_usage_bar/security/advisories/new) on this repository.
2. **Email** — `lazym0m3nt@gmail.com` with the subject line `[security] agents-usage-bar: <short summary>`.

Please include:

- A description of the issue and the impact you believe it has.
- Steps to reproduce (or a proof-of-concept) — minimal is fine.
- The version of the app you reproduced it against (Settings → About shows the version + build).
- Your macOS version.
- Whether you would like to be credited in the release notes once the fix ships, and the name/handle to use.

## Acknowledgment and Disclosure

This is a small open-source project maintained on a best-effort basis. No formal SLA is offered, but I will aim to:

- **Acknowledge** receipt of your report within **7 days**.
- Confirm whether the report is in scope and share a rough timeline for a fix within **14 days** of acknowledgment.
- **Coordinate disclosure** with you — please give a reasonable embargo window (typically 90 days, or until a fix ships, whichever comes first) before any public discussion.

If you do not hear back within those windows, please escalate by emailing again with `[security][followup]` in the subject line.

## Out of Scope

The following are **not** treated as security vulnerabilities in this project:

- Issues in third-party AI provider APIs or their authentication systems (report directly to the provider).
- Issues that require the attacker to already have local code execution as the same user (the app reads user-owned dotfiles and runs in user space — anyone with that level of access already has the same data).
- Provider API keys appearing in the app's UI when the user has configured them via env var or `config.toml`. The credential surface is documented in [`docs/entitlements.md`](docs/entitlements.md) and [`README.md`](README.md).
- Bugs that do not affect confidentiality, integrity, or availability — please file a normal issue for those.

## Cryptographic Verification of Releases

Released DMGs are:

- **Signed** with the project's Apple Developer ID Application certificate (Hardened Runtime ON, App Sandbox OFF).
- **Notarized** by Apple via `xcrun notarytool` and **stapled** so Gatekeeper validation succeeds offline on first launch.
- **Verified by Sparkle** for auto-updates using an Ed25519 (EdDSA) signature whose public key is pinned in the app's `Info.plist`.

Do not run unsigned or unnotarized builds claiming to be releases of this app.
