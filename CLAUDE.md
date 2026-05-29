<!-- GSD:project-start source:PROJECT.md -->
## Project

**Agents Usage Bar**

A macOS menu bar app that surfaces today's AI agent usage across multiple providers — Claude (via `ccs`), OpenAI Codex, Gemini, OpenRouter, and local agents (Ollama, LM Studio, llama.cpp/llamafile). One glance shows tokens used, cost spent (USD), and quota remaining per provider, with native notifications when any provider approaches its quota limit. Built for developers who juggle multiple AI tools and want a single, ambient view of "what am I burning today?".

**Core Value:** A single ambient glance shows accurate per-provider AI usage for today, so the user notices spend/quota issues before they bite.

### Constraints

- **Tech stack**: Swift + SwiftUI native macOS app — no Electron/Tauri/web wrappers
- **Distribution**: Notarized DMG via GitHub Releases — no App Store in v1
- **Aggregation window**: Today only (local-midnight reset) — no multi-day persistence in v1
- **Secrets**: No Keychain entry UI in v1 — read keys from env vars and existing CLI config files
- **Refresh**: Background poll every 1–5 min (default 5m) + on-open refresh — must not noticeably impact battery; JSONL streaming reads only the delta since last poll
- **Local file access**: Ship unsandboxed with Hardened Runtime + notarization. App Sandbox blocks reads of `~/.claude/projects/**`, `~/.codex/sessions/**`, `~/.gemini/oauth_creds.json` without temporary-exception entitlements deprecated by Apple. Since v1 is DMG-only (no MAS), unsandboxed is correct.
<!-- GSD:project-end -->

<!-- GSD:stack-start source:research/STACK.md -->
## Technology Stack

## Recommended Stack
### Core Technologies
| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| **Swift** | **6.2** (toolchain), language mode `6` | App + tests | Swift 6.3 ships April 2026 but 6.2 is the conservative LTS-grade choice — strict concurrency is stable, `@MainActor` isolation matches SwiftUI well. Language mode `6` catches data races at compile time, which matters because we run a polling actor and a UI actor concurrently. |
| **Xcode** | **16.x** (16.4+ when 6.3 toolchain matures) | Build / sign / Instruments | Required for Swift 6 language mode, Swift Testing first-class support, and modern `notarytool`-aware archive workflow. |
| **macOS deployment target** | **macOS 14 Sonoma (`14.0`)** | Minimum supported runtime | Project says "latest two macOS versions." With macOS 15 Sequoia current and macOS 26 (Tahoe) shipping in fall 2025, 14.0 is the floor. **Critical reason:** `MenuBarExtra(.window)` only became reliable on macOS 14 (the 13.0 implementation has documented popover-detach and focus bugs). Targeting 14 also unlocks `Observation` macro (`@Observable`), modern `URL.appending(path:)`, and the polished `UNUserNotificationCenter` async API. |
| **SwiftUI `MenuBarExtra`** | Built-in (SwiftUI 5+, macOS 13+) | Menu bar host scene | Apple-blessed SwiftUI scene for menu bar items. Use `.menuBarExtraStyle(.window)` — this gives us a popover-style detachable panel that hosts arbitrary SwiftUI (`List`, `ProgressView`, custom rows), which is exactly the "richer per-provider rows with bars and totals" UX we committed to. **Do NOT** use `.menu` style — it forces us into traditional `NSMenu` items and we lose the layout we want. |
| **`@Observable` (Observation framework)** | macOS 14+ | View-model state | Replaces `ObservableObject` + `@Published`. Less boilerplate, plays correctly with `MainActor`, and is the official Apple direction since WWDC23. Use one `@Observable` "UsageStore" as the popover root. |
| **Foundation `URLSession`** | Built-in | HTTP client | The right call. `URLSession.shared.data(for:)` is async/await native (macOS 12+). Use a custom `URLSessionConfiguration` with `timeoutIntervalForRequest = 8s` and `waitsForConnectivity = false`, then run providers concurrently with `async let` or `withThrowingTaskGroup`. Pulls zero third-party deps. |
| **`Codable`** | Built-in | JSON parsing for both API responses and JSONL transcripts | Strongly typed per-provider response structs. For Claude/Codex JSONL transcripts: read line-by-line via `URL.lines` (`AsyncSequence` of `String`) — built into Foundation, streams large files without loading into RAM. |
| **`FileManager` + `URL` APIs** | Built-in | Dotfile enumeration / metadata | `FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")` then `contentsOfDirectory(at:includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])`. Use `.contentModificationDateKey` to skip files unchanged since last poll — essential for keeping polling cheap. |
| **`DispatchSource.makeFileSystemObjectSource`** | Built-in | Watch transcript dirs for new sessions | Lighter than FSEvents for our use case — we only need per-directory change notifications, not a recursive history stream. One source per watched root (`~/.claude`, `~/.codex`, `~/.ccs`). Coalesces nicely with our 30s poll. |
| **`UNUserNotificationCenter`** | Built-in (macOS 10.14+, async API macOS 12+) | Threshold-cross alerts | Native, no third-party deps. Request `[.alert, .sound]` once on first launch via `try await center.requestAuthorization(...)`. Identify each provider's notification with a stable identifier (e.g. `"quota.openrouter"`) so we never double-fire while still in the warning band. |
| **`Timer.publish` via Combine** OR **`AsyncTimerSequence`** | Built-in | 30–60s polling loop | Pick **one**. Recommendation: a `Task { for await _ in Timer.publish(every: 45, on: .main, in: .common).autoconnect().values { await refresh() } }` started from `.onAppear` of the popover root and an `@MainActor` `AppDelegate`-equivalent. Pure async/await, no Combine subscription bookkeeping. |
| **App Sandbox** | **DISABLED** | — | See "Sandbox Decision" section below. This is the load-bearing call. |
| **Hardened Runtime** | **ENABLED** | Notarization gate | Required by Apple for notarization (DMG distribution). Enable `com.apple.security.network.client`. With sandbox off, no file-access entitlements needed. |
### Supporting Libraries
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| **swift-log** (apple/swift-log) | 1.6.x | Structured logging | Only if `os.Logger` (built-in, recommended first) proves insufficient. Default to `Logger(subsystem: "app.agents-usage-bar", category: "...")` — it's free, shows in Console.app, and respects log levels. |
| **swift-collections** (apple/swift-collections) | 1.1.x | `OrderedDictionary` for provider ordering | Only if you want guaranteed insertion-ordered provider iteration in UI; otherwise a plain `[Provider]` array of cases is simpler. |
### Development Tools
| Tool | Purpose | Notes |
|------|---------|-------|
| **Xcode 16** | IDE, build, sign, archive | Manage signing identity, profile, and `exportOptions.plist` here. |
| **`xcodebuild`** | CI builds | `xcodebuild -scheme AgentsUsageBar -configuration Release -archivePath build/App.xcarchive archive` then `-exportArchive`. |
| **`xcrun notarytool`** | Notarization (replaces deprecated `altool`) | Use API-key auth (Issuer ID + Key ID + `.p8`) in GitHub Actions — never app-specific passwords in CI. `notarytool submit App.dmg --wait`. |
| **`xcrun stapler staple`** | Staple notarization ticket onto DMG | Run after `notarytool` completes. Lets the DMG open offline on first user launch. |
| **`codesign`** | Code signing | Sign with Developer ID Application cert. `--options runtime` for Hardened Runtime, `--timestamp` for trusted timestamping. Sign nested helpers first, then app, then DMG. |
| **`create-dmg` (shell)** | DMG packaging | **Pick this one:** [create-dmg/create-dmg](https://github.com/create-dmg/create-dmg) v1.2.3 (Nov 2025). It's a maintained shell script — gives explicit control over icon position, window size, background, no Node runtime in CI. **NOT** sindresorhus/create-dmg (Node, v8.1.0); that one is zero-config but harder to pin/reproduce. |
| **SwiftLint** | Style enforcement | Optional but recommended. SwiftPM plugin form to keep it in-tree. |
| **swift-format** (apple/swift-format) | Formatting | Optional. Swift's official formatter; v6.x tracks Swift toolchain. |
| **Swift Testing** | Unit tests | **Choose Swift Testing over XCTest for new code.** macOS 13+, Xcode 16+. Macro-based (`@Test`, `#expect`, `#require`), parallel by default, parameterized tests built-in. XCTest still allowed for legacy / `XCUITest` UI tests, but our app has no UI test surface that warrants it. |
## Installation
# Host tools — install once on the dev box and on CI runners
# Verify Apple toolchain
# GitHub Actions release workflow — essential bits
- uses: maxim-lobanov/setup-xcode@v1
- uses: apple-actions/import-codesign-certs@v3
- run: xcodebuild -scheme AgentsUsageBar -configuration Release \
- run: xcodebuild -exportArchive -archivePath build/App.xcarchive \
- run: create-dmg --volname "Agents Usage Bar" \
- run: |
## Alternatives Considered
| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| `MenuBarExtra(.window)` | `NSStatusItem` + custom `NSPopover` (AppKit) | Use the AppKit route if (a) you need to support macOS 12 or earlier, or (b) you hit a known `MenuBarExtra` papercut — e.g. popover not dismissing on click-outside in a corner case, or wanting custom transient-window animations. Wrap `NSStatusItem` via `NSApplicationDelegateAdaptor`. Pay only if forced; default is `MenuBarExtra`. |
| `URLSession` async/await | `AsyncHTTPClient` (Vapor) | Only relevant on Linux/server — irrelevant for a Mac app. |
| `Codable` | `swift-json` / `SwiftyJSON` | Heterogeneous, deeply nested, unknown-shape payloads where schemaless traversal is genuinely easier. Our provider APIs have stable schemas — Codable wins. |
| `DispatchSource` file events | `FSEvents` C API (CoreServices) | Use FSEvents if you need recursive history-replay-since-timestamp semantics. We don't — we poll on a timer anyway and only use file events to bust the cache between polls. |
| `UserDefaults` for tiny state | **JSON flat file** in `~/Library/Application Support/AgentsUsageBar/today.json` | UserDefaults is fine for the "today" rollover marker + per-provider warning-fired flags. Flat JSON is better when you want the v1 user to be able to `cat` it during debugging. Pick **UserDefaults** for v1 (simpler, atomic, no FS plumbing). Switch to flat JSON only if you grow >a few KB of state. |
| `UserDefaults` | Core Data / SwiftData | **Don't.** Today-only aggregation means we hold ≤8 providers × a handful of numbers in RAM. Any DB is overkill. SwiftData also requires macOS 14+ anyway and adds compile-time complexity for zero v1 benefit. |
| `UserDefaults` | SQLite (GRDB / SQLite.swift) | Only if/when v2 adds historical multi-day charts. Out of scope here. |
| Swift Testing | XCTest | If a team member is uncomfortable with the macro syntax, or you need `XCUITest` UI testing. XCTest is still fully supported and Apple is not deprecating it. |
| `create-dmg/create-dmg` (shell) | `sindresorhus/create-dmg` (Node) | Choose the Node one if you want zero configuration and accept a Node 20+ dependency in CI. Choose the shell one (recommended) for explicit layout control and reproducibility. |
| `xcrun notarytool` (API key) | `notarytool` with app-specific password | Use app-specific password for local one-off submissions; **never** in CI. API key (`.p8`) is the only sane CI credential. |
| No sandbox (recommended) | Sandbox + `temporary-exception.files.home-relative-path.read-only` | Use only if you ever submit to the Mac App Store. Even then, the temporary exception entitlement is officially "temporary" — Apple discourages it and reviewers push back. DMG distribution = stay unsandboxed. |
## What NOT to Use
| Avoid | Why | Use Instead |
|-------|-----|-------------|
| **Mac Catalyst** | Wrong tool — Catalyst is for porting iPad apps; our app is macOS-native with menu bar UX (which Catalyst handles poorly). | Native SwiftUI macOS target with `MenuBarExtra`. |
| **Electron / Tauri / web wrappers** | Already excluded by PROJECT.md constraints. Killers: dock icon by default, bloated binary, native menu bar parity is worse, notification appearance is non-native. | Swift + SwiftUI. |
| **`NSMenu` directly for the popover** | Cripples the UI — we need progress bars, multi-line rows, conditional spinners. `NSMenu` is hostile to that. | `MenuBarExtra(.window) { … }` with arbitrary SwiftUI inside. |
| **`@StateObject` + `ObservableObject` + `@Published`** | Pre-`Observation` pattern; verbose, easier to misuse from background actors, no fine-grained dependency tracking. | `@Observable` class as the store, `@State` to hold a reference in the root view. |
| **Combine for the polling loop** | Combine is alive but is no longer Apple's recommended primary direction; mixing it with `async/await` creates two parallel concurrency stories in one app. | Pure structured concurrency: `Task`, `AsyncSequence`, `withThrowingTaskGroup`. |
| **`DispatchQueue.main.async` from inside Swift 6 actor code** | Will trigger Swift 6 concurrency diagnostics; smells like a porting leak. | `await MainActor.run { … }` or annotate the UI store `@MainActor`. |
| **App Sandbox in v1** | Cannot transparently read `~/.ccs/`, `~/.claude/`, `~/.codex/`, `~/.config/` from inside the sandbox without per-folder user grants or the deprecated temporary-exception entitlement. Verified against Apple's App Sandbox docs (only `user-selected.*` and the discouraged `temporary-exception.files.home-relative-path.read-only` provide access). Our UX requires zero-prompt ingestion. | Ship **unsandboxed** with **Hardened Runtime + notarized DMG**. This is the standard path for Developer-ID-distributed menu bar utilities (BetterDisplay, Rectangle Pro, ClaudeBar, etc. all do this). |
| **SwiftData for "today only" state** | Schema migrations, Core-Data-backed complexity, requires `@Model`, frequent footguns with background contexts. Wildly disproportionate to needs. | `@Observable` in-memory store + `UserDefaults` for the rollover marker. |
| **App-specific password in CI** | Rotates per-developer, ties releases to one human's Apple ID. | App Store Connect API key (`.p8`) stored as a GitHub secret. |
| **`altool`** | Deprecated; sunset by Apple. | `xcrun notarytool`. |
| **`com.apple.security.cs.disable-library-validation`** unless required | Loosens Hardened Runtime in a way reviewers and security-conscious users dislike. | Leave it off — we don't load third-party plugins. |
| **Third-party "notarize-action" GitHub Actions** | The popular ones searched are 1-star, unmaintained since 2023–2024, and wrap a 10-line bash invocation. | A hand-rolled `xcrun notarytool submit … --wait` step in your workflow. |
| **Polling without `If-Modified-Since` / ETag on remote APIs** | Burns provider quota for no information gain. | Where the API supports it, send conditional headers and short-circuit on `304`. For dotfiles, gate work on the file's `contentModificationDate`. |
## Sandbox Decision (load-bearing)
| Constraint | Sandbox-on | Sandbox-off (recommended) |
|------------|------------|---------------------------|
| Read `~/.ccs/`, `~/.claude/`, `~/.codex/`, `~/.config/` silently | Requires `temporary-exception.files.home-relative-path.read-only` per path, with no wildcards, and Apple's docs explicitly call these "temporary" and "subject to removal." | Just works. |
| Make HTTP calls to `api.openai.com`, `openrouter.ai`, `generativelanguage.googleapis.com`, `localhost:11434/1234/8080` | `com.apple.security.network.client` covers remote; localhost works too. | `com.apple.security.network.client` (Hardened Runtime). |
| Notarization | Required regardless. | Required — and works fine for unsandboxed apps. |
| Mac App Store eligibility | Possible. | Impossible. Out of scope per PROJECT.md (DMG-only v1). |
| User trust signal | "Sandboxed" badge in Finder Inspector. | "Notarized by Apple" check via Gatekeeper — equally trusted by users. |
## Concurrency & Polling Pattern (prescriptive)
- **One `URLSession` instance per app**, not per request.
- Each provider's `.fetch()` is `nonisolated async` — runs off the main actor; only the writeback hops back.
- Use `URLSession(configuration: cfg)` with `timeoutIntervalForRequest = 8`, `httpMaximumConnectionsPerHost = 6`, `waitsForConnectivity = false`.
- Polling loop driven from `.task` on the popover root scene; cancelled via Swift structured concurrency when the popover scene tears down.
- Threshold detection compares previous and current snapshot — fire `UNUserNotificationCenter` only on the **transition** across 80% (not every poll while above it). Persist "warned-today" flags in `UserDefaults` keyed by `provider+localDateString`; clear on local-midnight rollover.
## SF Symbols Usage
- Use **SF Symbols 5+** (ships with macOS 14). Reference symbols by string name; SwiftUI `Image(systemName:)` handles them.
- Menu bar icon: pick a **monochrome, hierarchical-render-compatible** symbol such as `chart.bar.doc.horizontal` or `gauge.with.dots.needle.67percent`. Apply `.renderingMode(.template)` for proper menu-bar dark/light handling.
- Per-provider rows: lean on `circle.fill` colored with `.foregroundStyle` for status dots; use `bolt.fill` for "local model running."
- Do **not** use multicolor or palette rendering for the menu bar item itself — macOS expects a tintable template.
## Stack Patterns by Variant
- Replace `@Observable` with `ObservableObject` + `@Published`
- Test `MenuBarExtra(.window)` carefully — known popover-focus regressions on 13.x
- Use `Task { for try await … }` instead of relying on `Observation`-driven SwiftUI invalidation
- Net effect: roughly +10% code volume, no architectural change
- Enable App Sandbox
- Convert dotfile reads behind a one-time `NSOpenPanel` prompting for `~` (creates a security-scoped bookmark stored in `UserDefaults`)
- Persist that bookmark; resolve `URL(resolvingBookmarkData:…, options: .withSecurityScope, …)` and `startAccessingSecurityScopedResource()` on each launch
- This is a UX regression (one-time picker dialog) but it's the only sandboxed path that scales across all required dotfile roots
- Add `com.apple.security.cs.allow-dyld-environment-variables` and rethink — for now, hard-no on plug-ins keeps Hardened Runtime simple
## Version Compatibility
| Package | Compatible With | Notes |
|---------|-----------------|-------|
| Swift 6.2 toolchain | Xcode 16.2+ | Language mode `5` and `6` both selectable; project should pin to `6` to enforce strict concurrency. |
| `MenuBarExtra(.window)` | macOS 14+ recommended | Available since macOS 13.0 but with known popover edge-case bugs fixed in 14.0. |
| `@Observable` macro | macOS 14+ | Hard floor. The principal reason to target 14, not 13. |
| `URL.appending(path:)` | macOS 13+ | If targeting 12 (don't), fall back to `appendingPathComponent`. |
| Swift Testing | Xcode 16 + Swift 6 toolchain | Runs on macOS 13+ but **build** environment needs Xcode 16. |
| `xcrun notarytool` | Xcode 13+ | Replaces `altool`. Pin GitHub Actions runner to `macos-14` or `macos-15` for known-good toolchain. |
| `create-dmg/create-dmg` 1.2.3 | macOS host with `hdiutil` | Bash, no Node. Works on `macos-14` and `macos-15` runners. |
| Hardened Runtime + Sandbox | Independent flags | Enable Hardened Runtime, leave Sandbox off — verified compatible. |
## Sources
- [Apple — MenuBarExtra (SwiftUI)](https://developer.apple.com/documentation/swiftui/menubarextra) — HIGH (Apple docs)
- [Apple — MenuBarExtraStyle (.window / .menu)](https://developer.apple.com/documentation/swiftui/menubarextrastyle) — HIGH
- [Apple — App Sandbox: accessing files](https://developer.apple.com/documentation/security/app_sandbox/accessing_files_from_the_macos_app_sandbox) — HIGH (confirmed home-relative-path read-only is the only home-dotfile sandbox path, and that it is "temporary")
- [Apple — Hardened Runtime](https://developer.apple.com/documentation/security/hardened_runtime) — HIGH (required for notarization)
- [Apple — URLSession](https://developer.apple.com/documentation/foundation/urlsession) — HIGH
- [Apple — FileManager](https://developer.apple.com/documentation/foundation/filemanager) — HIGH
- [Apple — DispatchSource (`makeFileSystemObjectSource`)](https://developer.apple.com/documentation/dispatch/dispatchsource) — HIGH
- [Apple — UNUserNotificationCenter](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter) — HIGH (async authorization, local notifications on macOS)
- [Apple — Swift Testing overview](https://developer.apple.com/xcode/swift-testing/) — HIGH (Xcode 16+, parameterized, parallel by default, coexists with XCTest)
- [`swiftlang/swift-testing` releases](https://github.com/swiftlang/swift-testing/releases) — HIGH (Swift 6.3.1 release tag verified 2026-04-21 via `gh api`)
- [`create-dmg/create-dmg`](https://github.com/create-dmg/create-dmg) v1.2.3 (2025-11-18, verified via `gh release list`) — HIGH
- [`sindresorhus/create-dmg`](https://github.com/sindresorhus/create-dmg) v8.1.0 (verified via `gh api .../package.json`) — HIGH
- [`apple-actions/import-codesign-certs`](https://github.com/Apple-Actions/import-codesign-certs) — HIGH (official Apple-Actions org)
- PROJECT.md (`/Users/noomz/Projects/Opensources/agents_usage_bar/.planning/PROJECT.md`) — authoritative for constraints
- Third-party "macos-notarize-action" GitHub Actions — LOW confidence / actively recommended **against**: searched repos are ≤1 star and last pushed 2023–2024, indicating abandonment
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

Conventions not yet established. Will populate as patterns emerge during development.
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

Architecture not yet mapped. Follow existing patterns found in the codebase.
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->
## Project Skills

No project skills found. Add skills to any of: `.claude/skills/`, `.agents/skills/`, `.cursor/skills/`, `.github/skills/`, or `.codex/skills/` with a `SKILL.md` index file.
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->



<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->
