# Agents Usage Bar

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-blue)](https://developer.apple.com/macos/)
[![Build: Swift 6.2](https://img.shields.io/badge/Swift-6.2-orange)](https://swift.org)

A macOS menu bar app showing today's AI agent usage across providers — tokens, USD spent, and quota remaining at a glance.

## Screenshot

<!-- TODO(Phase 6 Plan 06-05): replace this placeholder with a real capture of the menu bar popover. This is awaiting the human-gated screenshot capture in Plan 06-05; do NOT fabricate the image. Expected path: docs/screenshots/menubar-popover.png at ~360pt popover width. -->

![Menu bar popover — pending capture in Phase 6 Plan 06-05](docs/screenshots/menubar-popover.png)

_Screenshot pending capture from a notarized DMG build (Phase 6 Plan 06-05 — human-gated)._

## Status

All v1 functionality (Claude, Codex, Gemini, OpenRouter, local LLMs, settings + welcome window) is complete; Phase 6 ships notarized DMG distribution, Sparkle auto-update, and OSS hygiene. See [`.planning/ROADMAP.md`](.planning/ROADMAP.md) for phase-by-phase status.

## Install

Once a signed and notarized release ships:

1. Download the latest `AgentsUsageBar-<version>.dmg` from the [GitHub Releases page](https://github.com/lazym0m3nt/agents_usage_bar/releases).
2. Open the DMG and drag **Agents Usage Bar** into `/Applications`.
3. Launch it. Gatekeeper validates the Apple notarization stamp and opens the app on first launch with no warning (offline-OK thanks to stapling).
4. The menu bar icon (`chart.bar.doc.horizontal`) appears in the top-right of the screen. Click it for the per-provider popover. First-launch Welcome window walks you through which providers are detected and what is still missing.

Subsequent updates are delivered automatically via **Sparkle** — when a new EdDSA-signed release is published the app prompts to install it the next time it polls the appcast (Sparkle public key is pinned in `Info.plist`; see [`docs/entitlements.md`](docs/entitlements.md) for the trust model).

**Requirements:** macOS 14 Sonoma or newer.

## Privacy

**Agents Usage Bar is privacy-first by design.**

- **No telemetry. No analytics. No crash-reporter uploads. All data stays on your machine.**
- Crashes are written only to the local macOS crash reporter.
- The only network traffic the app makes is **outbound HTTPS to the AI provider APIs you have configured** (Anthropic, OpenAI / Codex, OpenRouter, Google Gemini) plus **outbound HTTP to localhost** for the local LLM runtimes you have enabled (Ollama, LM Studio, llama.cpp). Nothing else.
- **No Keychain UI in v1.** Credentials are read from environment variables and existing CLI config files (e.g. `~/.config/agents-usage-bar/config.toml`, which is created with `0600` permissions and warned about if found world-readable). See SEC-03 in [`.planning/REQUIREMENTS.md`](.planning/REQUIREMENTS.md).

This promise is enforced by a deliberately minimal entitlement posture: the app declares **only** `com.apple.security.network.client` (no library-validation bypass, no JIT, no analytics frameworks) and runs under the Hardened Runtime. See [`docs/entitlements.md`](docs/entitlements.md) for the full why-unsandboxed + what-is-not-declared rationale, and [`SECURITY.md`](SECURITY.md) for the disclosure policy.

(SEC-05 in [`.planning/REQUIREMENTS.md`](.planning/REQUIREMENTS.md).)

## Run from source

**Requirements:**
- macOS 14 Sonoma or newer
- Xcode 16.4 or newer
- An OpenRouter API key — https://openrouter.ai/keys (read-only is sufficient) — and/or signed-in `claude`, `codex`, `gemini` CLIs; and/or a running local LLM runtime (Ollama / LM Studio / llama.cpp)

**Steps:**

1. Open `AgentsUsageBar.xcodeproj` in Xcode.
2. Set the `OPENROUTER_API_KEY` environment variable for the scheme:
   Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables → add `OPENROUTER_API_KEY = <your-openrouter-key>`
3. Press ⌘R to build and run. The menu bar icon (`chart.bar.doc.horizontal`) appears in the top-right of the screen.
4. Click the icon. The popover shows one row per detected provider — USD spent today, tokens, balance, quota bar, and reset time.

If `OPENROUTER_API_KEY` is not set, the app still launches and shows an "OpenRouter — not configured" placeholder row.

**Quit:** Click "Quit Agents Usage Bar" in the popover footer, or press ⌘Q with the popover focused.

## Configuration (optional)

Place a `config.toml` file at `~/.config/agents-usage-bar/config.toml`:

```toml
refresh_interval = "5m"   # 1m, 2m, 5m, 15m, 30m, or manual
threshold = 0.80           # 0.0–1.0 — quota fraction that triggers a warning notification

[openrouter]
api_key   = "<your-openrouter-key>"  # overridden by OPENROUTER_API_KEY env var
```

Environment variables take precedence over `config.toml` values (env > toml > defaults).

## Build for distribution

Releases are produced by the GitHub Actions release workflow (`.github/workflows/release.yml`) on `v*` tag push: archive → sign with Developer ID → export → DMG via `create-dmg/create-dmg` → notarize via `xcrun notarytool` → staple → EdDSA-sign for Sparkle → publish to GitHub Releases + update appcast on `gh-pages`. The one-time credential provisioning (Apple Developer ID `.p12`, App Store Connect API `.p8`, Sparkle EdDSA key pair, etc.) is documented in [`docs/release-setup.md`](docs/release-setup.md).

For ad-hoc local builds (unsigned):

```bash
xcodebuild build \
  -project AgentsUsageBar.xcodeproj \
  -scheme AgentsUsageBar \
  -configuration Release \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
```

## Security

To report a vulnerability **privately**, see [`SECURITY.md`](SECURITY.md). Do not file public issues for security reports.

## License

Released under the [MIT License](LICENSE). Copyright (c) 2026 lazym0m3nt@gmail.com.
