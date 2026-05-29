# Entitlements & ATS Configuration

This document explains **every entitlement and App Transport Security (ATS) flag** the Agents Usage Bar app declares — what is requested, why, and (just as important) what is **not** requested.

Authoritative sources:

- [`AgentsUsageBar/Resources/Entitlements.plist`](../AgentsUsageBar/Resources/Entitlements.plist)
- [`AgentsUsageBar/Resources/Info.plist`](../AgentsUsageBar/Resources/Info.plist)

These two files are the source of truth. If anything in this document drifts from them, the files win and this document is a bug.

## Summary

| Setting | Value | Reason |
| --- | --- | --- |
| `com.apple.security.app-sandbox` | **OFF** (not declared) | Must read user dotfiles outside any sandbox container |
| `com.apple.security.network.client` | **ON** | Outbound HTTPS to AI provider APIs + outbound HTTP to localhost LLM runtimes |
| Hardened Runtime | **ON** | Required for notarization (DMG distribution) |
| `NSAppTransportSecurity` → `NSAllowsLocalNetworking` | `true` | Probe localhost LLM runtimes (Ollama / LM Studio / llama.cpp) without ATS blocking cleartext-localhost |
| `com.apple.security.cs.disable-library-validation` | **NOT declared** | Sparkle 2.x on non-sandboxed Hardened Runtime does not need it |
| `com.apple.security.cs.allow-jit` | **NOT declared** | The app does not generate or execute dynamic code |
| `com.apple.security.cs.allow-dyld-environment-variables` | **NOT declared** | The app does not load any user-supplied dylibs |

This minimal posture maps to **REL-09** in [`REQUIREMENTS.md`](../.planning/REQUIREMENTS.md) ("Only required entitlement: `com.apple.security.network.client`; no `disable-library-validation`, no `allow-jit`") and **REL-08** ("Info.plist declares `NSAppTransportSecurity → NSAllowsLocalNetworking = true`").

## Entitlement: `com.apple.security.network.client`

**Declared:** Yes — see `Entitlements.plist`.

**What it grants:** The app may make outbound network connections (act as a TCP/UDP/HTTPS client). It does NOT grant the ability to accept inbound connections (that would be `com.apple.security.network.server`, which is intentionally **not** declared).

**Why it is required:**

1. **Remote AI provider APIs.** The app reads today's usage from each enabled remote provider. These calls are all outbound HTTPS:
   - Anthropic (`api.anthropic.com`) — Claude OAuth `/api/oauth/usage`.
   - OpenAI / Codex (`chatgpt.com` backend) — Codex bearer-based usage fallback when no recent rollout file exists.
   - OpenRouter (`openrouter.ai`) — `/api/v1/credits`, `/api/v1/key`.
   - Google Gemini (`cloudcode-pa.googleapis.com`, `oauth2.googleapis.com`) — quota retrieval + token refresh.

2. **Localhost LLM runtimes.** The app probes optional local LLM servers — Ollama (`http://localhost:11434`), LM Studio (`http://localhost:1234` by default), llama.cpp / llamafile (port from `config.toml`). These calls are outbound HTTP and go through the same network-client entitlement.

3. **Sparkle auto-update.** Sparkle fetches the EdDSA-signed `appcast.xml` over HTTPS from the GitHub Pages site (`SUFeedURL` in `Info.plist`) and downloads new DMGs over HTTPS from GitHub Releases.

**Why no `network.server`:** the app never listens on a socket.

## ATS: `NSAllowsLocalNetworking = true`

**Declared:** Yes — see `Info.plist` under `NSAppTransportSecurity`.

**What it grants:** App Transport Security normally forbids cleartext HTTP. This flag relaxes ATS **only for local-network hostnames** (`localhost`, `*.local`, link-local addresses, and unqualified hostnames). HTTPS requirements remain unchanged for any other destination.

**Why it is required:** Ollama, LM Studio, and llama.cpp all bind to `http://localhost:<port>` by default and do not terminate TLS. Without `NSAllowsLocalNetworking`, every localhost probe would fail with an ATS policy error. Remote calls (Anthropic, OpenRouter, Codex, Gemini) continue to require valid HTTPS — this flag does **not** lower their security posture.

**Alternatives considered (and rejected):**

- `NSAllowsArbitraryLoads = true` — would disable ATS globally; we explicitly do not want that.
- `NSExceptionDomains` keyed on `localhost` — works but is more verbose, and Apple's official replacement guidance for "I just want localhost" is `NSAllowsLocalNetworking`.

## App Sandbox: OFF

**Declared:** No — the entitlement `com.apple.security.app-sandbox` is **deliberately absent**.

**Why off:** the app's core value (a single ambient glance at today's AI usage across providers) requires reading dotfiles in the user's home directory at locations Apple does not allow a sandboxed app to reach silently:

- `~/.claude/projects/**/*.jsonl` — Claude transcript history
- `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`, `~/.codex/auth.json` — Codex rollout files and OAuth credentials
- `~/.gemini/oauth_creds.json`, `~/.gemini/settings.json` — Gemini OAuth credentials
- `~/.config/agents-usage-bar/config.toml` — the app's own config file
- `~/.ccs/...` — `ccs` (Claude Code Subsystem) instance roots

The only sandbox-compatible path to those files is `com.apple.security.temporary-exception.files.home-relative-path.read-only`, which Apple's [App Sandbox documentation](https://developer.apple.com/documentation/security/app_sandbox/accessing_files_from_the_macos_app_sandbox) explicitly calls "temporary" and "subject to removal." The supported alternative would be prompting the user with `NSOpenPanel` for `~` on first launch and persisting a security-scoped bookmark — that materially regresses the "zero-prompt ingestion" UX the project is built around.

Because the app is distributed via **notarized DMG only** (not the Mac App Store — see [`PROJECT.md`](../.planning/PROJECT.md) constraints), the sandbox is not required and shipping unsandboxed is the standard, supported path for Developer-ID-distributed menu bar utilities. Trust comes from Apple notarization + Gatekeeper, not from the sandbox badge.

## Hardened Runtime: ON

**Declared:** Yes — enabled via the Xcode build setting `ENABLE_HARDENED_RUNTIME = YES`, applied at code-sign time via `codesign --options runtime`.

**Why on:** required by Apple for notarization. With the sandbox off, Hardened Runtime + notarization is the trust signal Gatekeeper uses to allow first launch.

## Entitlements that are intentionally **NOT** declared

The Apple Code Signing & Hardened Runtime entitlement list contains several relaxations that are common in larger apps but unnecessary here. They are listed below with the reason each is omitted.

### `com.apple.security.cs.disable-library-validation` — NOT declared

This entitlement allows the process to load dynamic libraries signed by an identity other than the app's. It is sometimes added to Sparkle-using apps out of caution.

It is **not needed** for this app. Sparkle 2.x on a non-sandboxed Hardened Runtime app loads only its own bundled, correctly-signed helper binaries (`Autoupdate`, `Installer.xpc`, `Downloader.xpc`, `Updater.app`) which are re-signed automatically by `xcodebuild -exportArchive` during the release pipeline. The [official Sparkle sandboxing documentation](https://sparkle-project.github.io/documentation/sandboxing/) does not mention this entitlement for the non-sandboxed Developer-ID path, and our Phase 6 research confirmed it is not required. Declaring it would weaken Hardened Runtime in a way reviewers and security-conscious users dislike.

### `com.apple.security.cs.allow-jit` — NOT declared

Required only for processes that allocate executable pages at runtime (e.g. JavaScript JITs, emulators). The app does not generate or execute dynamic code — all Swift code is statically linked at build time.

### `com.apple.security.cs.allow-dyld-environment-variables` — NOT declared

Required only if the app needs to honor `DYLD_*` environment variables to load alternate dylibs. The app does not consume user-supplied dylibs.

### `com.apple.security.network.server` — NOT declared

The app does not listen on any socket. It is purely a network client.

### `com.apple.security.files.user-selected.read-only` / `read-write` — NOT declared

Only meaningful inside the App Sandbox. With the sandbox off, file reads use the normal POSIX permission model (the running user owns and can read their own dotfiles).

### `com.apple.security.device.audio-input`, `camera`, `location`, `contacts`, `calendars`, `reminders`, `photos` — NOT declared

The app does not access any of these device or personal-data APIs.

## Operational consequences of this posture

- **Gatekeeper:** because the binary is signed + notarized + stapled, Gatekeeper allows it to launch the first time without an internet connection.
- **Privacy:** see the Privacy section in [`README.md`](../README.md). The minimum-viable entitlement set is **the** mechanism by which the privacy promise (no telemetry, no analytics, no crash uploads) is enforced — there is no entitlement that would let the app phone home silently.
- **Auditability:** running `codesign -d --entitlements - <path-to-app>` against a built `.app` bundle should reproduce exactly the entitlements documented here. The release pipeline runs this assertion in CI.

## See also

- [`AgentsUsageBar/Resources/Entitlements.plist`](../AgentsUsageBar/Resources/Entitlements.plist) — the file
- [`AgentsUsageBar/Resources/Info.plist`](../AgentsUsageBar/Resources/Info.plist) — the file, including ATS
- [`docs/release-setup.md`](release-setup.md) — how the signing + notarization credentials that enforce this posture get provisioned
- [`SECURITY.md`](../SECURITY.md) — vulnerability disclosure policy
- [`.planning/REQUIREMENTS.md`](../.planning/REQUIREMENTS.md) — REL-08, REL-09 authoritative wording
