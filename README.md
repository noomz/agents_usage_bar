# Agents Usage Bar

A macOS menu bar app showing today's AI agent usage across providers — tokens, USD spent, and quota remaining at a glance.

## Screenshot

_Phase 1 walking skeleton — screenshot will be added in Phase 6._

## Status

Phase 1 — Walking Skeleton + OpenRouter provider. Other providers (Claude, Codex, Gemini, local LLMs) land in subsequent phases.

## Privacy promise

- **No telemetry.** The app does not phone home, ever.
- **No crash-reporter uploads.** Crashes are written to your local macOS crash reporter only.
- **No data leaves your machine** except direct HTTPS calls to the AI provider APIs you have configured (Phase 1: OpenRouter's `/api/v1/credits` and `/api/v1/key` endpoints).
- **No Keychain UI in v1.** Credentials are read from environment variables and existing CLI config files only.

(SEC-05 — privacy-first; SECURITY.md with the full data-flow diagram ships in Phase 6.)

## Run from source (Phase 1)

**Requirements:**
- macOS 14 Sonoma or newer
- Xcode 16.4 or newer
- An OpenRouter API key — https://openrouter.ai/keys (read-only is sufficient)

**Steps:**

1. Open `AgentsUsageBar.xcodeproj` in Xcode.
2. Set the `OPENROUTER_API_KEY` environment variable for the scheme:
   Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables → add `OPENROUTER_API_KEY = sk-or-…`
3. Press ⌘R to build and run. The menu bar icon (`chart.bar.doc.horizontal`) appears in the top-right of the screen.
4. Click the icon. The popover shows your OpenRouter row with USD spent today, balance, and a quota bar.

If `OPENROUTER_API_KEY` is not set, the app still launches and shows an "OpenRouter — not configured" placeholder row.

**Quit:** Click "Quit Agents Usage Bar" in the popover footer, or press ⌘Q with the popover focused.

## Configuration (optional)

Place a `config.toml` file at `~/.config/agents-usage-bar/config.toml`:

```toml
refresh_interval = "5m"   # 1m, 2m, 5m, 15m, 30m, or manual
threshold = 0.80           # 0.0–1.0 — quota fraction that triggers a warning notification

[openrouter]
api_key   = "sk-or-…"     # overridden by OPENROUTER_API_KEY env var
```

Environment variables take precedence over `config.toml` values (env > toml > defaults).

## Build for distribution

Phase 6 will add notarized DMG packaging. For now, build from source via Xcode or:

```bash
xcodebuild build \
  -project AgentsUsageBar.xcodeproj \
  -scheme AgentsUsageBar \
  -configuration Release \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
```

## License

TBD — chosen during Phase 6 (MIT or Apache-2.0 candidates).
