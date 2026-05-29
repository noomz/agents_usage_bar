# Gemini provider setup

Agents Usage Bar reads Gemini OAuth-personal credentials from
`~/.gemini/oauth_creds.json` (written by the official gemini-cli when you
run `gemini login`). For the on-disk access token to be **refreshed
automatically** when it expires, the app also needs the gemini-cli's own
OAuth2 client credentials.

These are the values published by gemini-cli for installed-app flows.
Per RFC 6749 §2.1 they are public — they identify the gemini-cli
application, not the user — but recent GitHub Secret Scanning rules
flag them as Google OAuth secrets regardless of how they are used, so
Agents Usage Bar deliberately keeps them **out of source**. You inject
them at runtime via environment variables.

## What happens without them

| State | Behavior |
| --- | --- |
| `~/.gemini/oauth_creds.json` access token still valid | Gemini row shows live data. |
| Access token within 60s of expiry, env vars set | App refreshes silently. |
| Access token expired, env vars **not** set | App throws `.refreshDisabled`; row renders the same degraded UX as `.refreshFailed` ("Gemini usage temporarily unavailable" subtitle, dim row, other providers unaffected). |
| `~/.gemini/oauth_creds.json` missing | Row shows "No data yet" (`.notSignedIn`); run `gemini login`. |

In other words: the app degrades gracefully if you skip this setup. You
just lose in-app token refresh — running `gemini login` again restores
service until the next token expiry.

## How to set the credentials

### 1. Find the values

Both values live in gemini-cli's source at
[`packages/cli/src/code_assist/oauth2.ts`](https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/code_assist/oauth2.ts).
Open that file and copy the `OAUTH_CLIENT_ID` and `OAUTH_CLIENT_SECRET`
string literals. Re-check if Gemini auth ever breaks wholesale; Google
rotates them rarely but not never.

### 2. Export them in your shell

Add the two exports to your shell profile (`~/.zshrc`, `~/.bashrc`, or
`~/.config/fish/config.fish`). The app reads `ProcessInfo.environment`
at composition time, so the exports must be present in the shell that
launches Agents Usage Bar.

```sh
export GEMINI_CLI_CLIENT_ID='paste-OAUTH_CLIENT_ID-value-here'
export GEMINI_CLI_CLIENT_SECRET='paste-OAUTH_CLIENT_SECRET-value-here'
```

When you launch the app from Finder (rather than from a terminal), macOS
does **not** inherit your shell exports. Two options:

1. Launch the app from a terminal: `open /Applications/AgentsUsageBar.app`
   after sourcing the same profile.
2. Set the values via `launchctl setenv` so they apply to GUI launches:
   ```sh
   launchctl setenv GEMINI_CLI_CLIENT_ID 'paste-OAUTH_CLIENT_ID-value-here'
   launchctl setenv GEMINI_CLI_CLIENT_SECRET 'paste-OAUTH_CLIENT_SECRET-value-here'
   ```
   These survive until reboot. Add them to a Launch Agent if you want them persistent.

### 3. Restart Agents Usage Bar

Quit (popover footer → Quit) and relaunch so the new environment is
picked up. The first refresh after relaunch will use the new credentials
the next time the on-disk token is within 60 seconds of expiry.

## Verifying

- Open the popover. The Gemini row should show today's per-model
  remaining-fraction and a tier label (Free / Legacy / Paid).
- Force a refresh path: wait for the on-disk token's `expiry_date` to
  pass, then watch the row stay green instead of dropping into the
  dimmed "usage temporarily unavailable" state.
- App logs (Console.app, subsystem `app.agents-usage-bar`, category
  `gemini-oauth`) print `oauth2/token refresh OK` on success and
  `oauth2/token refresh skipped — GEMINI_CLI_CLIENT_ID / GEMINI_CLI_CLIENT_SECRET not set`
  when the env vars are missing.

## Why not bundle the values?

GitHub Secret Scanning blocks any push that contains an
`*.apps.googleusercontent.com` client ID or `GOCSPX-` client secret
regardless of source context. Storing the literals in this repo would
require either disabling push-protection or marking each commit as a
false positive — both encourage similar shortcuts elsewhere in the
codebase. Reading them from the environment keeps the repo clean and
makes each contributor opt in.
