# SPEC — Ollama Cloud usage row

Source: wayfinder map `.scratch/ollama-cloud-usage/map.md`, tickets `.scratch/ollama-cloud-usage/issues/01–06`, research `.scratch/ollama-cloud-usage/research/01-ollama-cloud-usage-api.md` (detail lives there; this spec is the contract). Issue #12. Prior spec archived: `docs/specs/aub-cli-themes.md`.

## §G

G1|New remote provider row `ollama-cloud` shows Ollama Cloud monthly included-usage fraction (popover + `aub` CLI), for `:cloud` model users. Local `ollama` row unchanged.

## §C

C1|Endpoints undocumented upstream (`ollama.com/api/usage`, `/api/me`): every field optional, unknown keys ignored, shape change degrades cloud row only.
C2|Credential sources = env var, `config.toml`, existing CLI key file (`~/.ollama/id_ed25519`). No Keychain, no browser cookies, no settings-page HTML scraping.
C3|Repo public: no real keys, signatures, pubkeys, payloads, emails, names, ids, plan of any real account in code, tests, fixtures, logs, commits.
C4|Monthly window only. Legacy 5h session / 7d weekly windows out of scope.
C5|Percent only: no dollar figures, no plan-allowance table, no allowance config.
C6|Archived-spec CLI invariants stay in force for any CLI render change (esp. `docs/specs/aub-cli-themes.md` V5 classic golden, V14 short labels, V31 ordering helper, V37 no regex/`DateFormatter` in render path).
C7|No new entitlements; app stays unsandboxed + `network.client` only.

## §I

I1|Usage API|`GET https://ollama.com/api/usage` → `{activity:{cost:"<decimal str>", models:[], period:{type, starting_at, ending_at}}, limits:{monthly:{usage:<0–1>, models:[]}}}`. 401 body `{"error":"invalid credentials"}`.
I2|Account API|`POST https://ollama.com/api/me` (body `{}`) → PascalCase object; only `Plan` (lowercase slug, open-ended) consumed.
I3|Auth|Bearer: `Authorization: Bearer <OLLAMA_API_KEY>`. Device: add query `ts=<unix s>`; challenge `"<METHOD>,<path>?<query>"`; header `Authorization: <authorized_keys pubkey field>:<base64 raw ed25519 sig>` (Ollama `auth/auth.go` `Sign`, `server/cloud_proxy.go`).
I4|Config|`OLLAMA_API_KEY` env; `config.toml` `[ollama]` keys `api_key`, `cloud` (bool), `billing_day` (1–31) (`Config/AppConfig.swift`, `Config/ConfigStore.swift`).
I5|Domain|`ProviderID.ollamaCloud` = `"ollama-cloud"` (`Domain/ProviderID.swift`, `allKnown`); `QuotaWindow` (`Domain/QuotaWindow.swift`); `ProviderStatus.unauthenticated`.
I6|Provider|new `Providers/OllamaCloud/` (provider actor, response types, signer); registration in `App/ProviderRegistryFactory.swift`.
I7|UI|`UI/ProviderRowView.swift` (standard remote row), `UI/ProviderDashboardURL.swift`, `UI/Welcome/DetectionProbe.swift`.
I8|CLI|`CLI/CompactTextRenderer.swift` short-label table, classic `UsageTextRenderer.swift`, `UsageJSONRenderer.swift`, `provider-order` validation (`CLISettings.swift`).
I9|Hygiene|`scripts/check-secrets.sh` `PATTERNS` (+ ci.yml copy); README Privacy + Configuration sections.

## §V

### Credentials (ticket 02)
V1|Resolution order: `OLLAMA_API_KEY` env (non-empty) > `[ollama] api_key` toml > device key file. First hit wins; env/toml key held as `Secret`. Same `env > toml` rule as OpenRouter/Grok (D-03).
V2|Row registered iff a credential resolves AND `[ollama] cloud` ≠ `false`. No credential → no row (not placeholder, not error).
V3|Device key: parse unencrypted OpenSSH container only (`openssh-key-v1`, cipher `none`, one key, type `ssh-ed25519`, check ints equal); seed = first 32 bytes of private field → `Curve25519.Signing.PrivateKey`. Any mismatch/unreadable → "no device credential" (V2), one debug log line with no path content or bytes.
V4|Key bytes + signatures live in memory for the fetch only: never logged, cached, persisted, or put in snapshot/raw/tooltip. `OllamaDeviceSigner` and `Secret` redact `description` and have empty mirrors (`dump` never prints key material).
V5|Explicit key (env/toml) 401/403 → status `.error(ProviderError(kind: .auth))` (store convention: `.unauthenticated` = placeholder only), message `check OLLAMA_API_KEY` / `check [ollama] api_key`; no fallback to device key. Device-key 401 → same kind, message `run ollama signin`. No credential at fetch time → same kind, `run ollama signin or set OLLAMA_API_KEY`.
V6|After credential fix (edited toml key, new `ollama signin` key, server recovery), row leaves auth error on next poll — no restart, no stuck state via cache seed / POLL-06 skip (V25). Tests required: server recovery + changed credential.

### Mapping (ticket 04)
V7|`limits.monthly.usage` → one `QuotaWindow(name: "mo", utilization: clamp 0…1, resetsAt: V8, duration: nil)` (V24). Missing `limits.monthly` or `usage` → no window, row shows `no limit`-style empty state, status not error. Other `limits.*` keys ignored.
V8|`resetsAt`: `billing_day` N set → next local midnight on day N strictly after `now`, N clamped to last day of month when month shorter; `Calendar(identifier: .gregorian)` + current time zone (Buddhist-calendar gotcha). Unset/invalid → `nil` → `↻ unknown`. Invalid (∉1…31) logged once, treated as unset.
V9|`hasQuota: true`, `hasCost: false`, `hasTokens: false`, `isLocal: false`. Never contributes to today cost/token totals or rollups.
V10|`activity.cost` parsed as `Decimal` from string; exposed only as tooltip text + `--json` raw; never cost column/totals. Unparseable → omitted.
V11|Window feeds existing threshold engine (default 80 % crossing notification) like any quota window.

### Surfaces (ticket 05)
V12|Display name `Ollama Cloud`; compact short label `Ollama Cloud`; dashboard URL `https://ollama.com/settings`.
V13|`tooltipLabel` lines, each only when known: plan (capitalised `Plan`), `your last 4 weeks: $X`, `via OLLAMA_API_KEY` | `via config` | `via ollama signin`.
V14|`--json` raw keys: `plan`, `ownSpendLast4WeeksUSD` (decimal string), `credentialSource` (`env`|`config`|`device`). No other `/api/me` field anywhere.
V15|`allKnown` places `ollama-cloud` immediately after `ollama`; `provider-order` accepts it; compact/classic/quota/single-provider views render it through existing remote-row paths (no new render branches).
V16|Welcome detection probe: detected iff V2 holds, incl. `[ollama] cloud = false` → not detected (else Welcome seeds `providerEnabled = true` and re-enables row); detected badge names credential source (`DetectionProbe.detail`).

### Polling + failure (ticket 06)
V17|`/api/usage` on shared poll interval + on-open refresh. `/api/me` after a successful usage call (never after a rejected one) until one 2xx per credential (2xx without `Plan` counts). Credential identity = fingerprint (`Secret` equality or device `publicKeyField`, never revealed); any change — other source, other key, other account — drops cached plan and re-fetches; plan stored only if fingerprint unchanged across the awaits. Failure → plan omitted, retried next poll; usage unaffected.
V18|5xx / timeout / decode failure → stale with last snapshot (degraded note), same as other remote providers; local `ollama` row never affected. `URLSession` shared instance, 8 s timeout.
V19|Only `Plan` decoded from `/api/me` (Codable struct has one optional field); personal fields never decoded.
V20|Logs: status codes + credential source public; everything else `privacy: .private`; no header values ever.
V21|Tests use synthetic data only: ed25519 key generated in-test and serialised to OpenSSH format by test helper; made-up usage values. Signer header format pinned by golden test per V23.
V22|`check-secrets.sh` + ci.yml share one length-gated `PATTERNS`: provider key prefixes, `BEGIN OPENSSH PRIVATE KEY`, literal `Authorization: Bearer <20+ chars>`, `OLLAMA_API_KEY` assigned a 24+ char literal. Scans `*.swift/plist/yml/json/md` under `AgentsUsageBar/ AgentsUsageBarTests/ .github/ .scratch/ docs/` + `README.md`. Patterns never derived from a real key.
V23|CryptoKit Ed25519 signatures randomized → never golden full header/signature. Golden pins deterministic parts (fixed key + fixed `ts`): pubkey field, challenge string, signed URL; signature part checked by `publicKey.isValidSignature` over challenge + format `<pubkey field>:<base64 64-byte sig>`.
V24|Ollama Cloud window has no `duration` (API reports none; calendar months not fixed-length). Compact `windowLabel` derives label from duration first, so non-nil duration would print `30d`; row must print `mo`. Test on compact render.
V25|Provider re-reads `[ollama]` config (`api_key`, `billing_day`) + device key every fetch and resolves credential fresh; key bytes held for that fetch only. `[ollama] cloud` read at launch only (decides row existence; per-fetch reload ignores it, since enforcing it would override a Settings "on" preference); Settings → Providers toggle applies live.
V26|`URLSessionHTTPClient` persists nothing: `urlCache = nil`, `httpCookieStorage = nil`, `httpShouldSetCookies = false`, `urlCredentialStorage = nil`. Pinned by `makeConfiguration` test.

## §T

id|status|task|cites
T1|x|Domain + config: `ProviderID.ollamaCloud` in `allKnown` after `ollama`; `[ollama] api_key`/`cloud`/`billing_day` + `OLLAMA_API_KEY` in AppConfig/ConfigStore; provider-order accepts id; config tests|V1,V2,V8,V15,I4,I5,I8
T2|x|Device-key signer: OpenSSH ed25519 parser, challenge builder, header; test helper generating synthetic OpenSSH key; golden header test; malformed/encrypted key tests|V3,V4,V21,V23,I3,I6
T3|x|Credential resolver (env > toml > device) + `OllamaCloudProvider` (usage fetch, `/api/me` per launch, mapping, billing-day reset, tooltip/raw, status on 401/5xx/decode), response types; registration in `ProviderRegistryFactory` gated by V2; provider tests incl. recovery-after-fix|V1,V2,V5,V6,V7,V8,V9,V10,V11,V13,V14,V17,V18,V19,V20,I1,I2,I6
T4|x|Surfaces: dashboard URL, detection probe, compact short label, classic/compact/quota/json golden updates for new row (classic change limited to added row), popover row check|V12,V13,V14,V15,V16,V24,C6,I7,I8
T5|x|Hygiene + docs: check-secrets patterns (script + ci.yml), log privacy audit, README Privacy (ollama.com traffic, device-key read) + Configuration (`[ollama]` keys)|V20,V22,C3,C7,I9
T6|x|Live verification on dev machine: build, run app + `aub` with env key, config key, device key; screenshot/row check; no real values in PR text|V1,V5,V12,V13,C3

## §B

id|date|cause|fix
B1|2026-09-28|V21 assumed deterministic Ed25519 signing ("exact header" golden); CryptoKit `Curve25519.Signing` randomizes signatures — same message signs differently, both verify|V23
B2|2026-09-28|V7 gave window `duration: 30 d`; `CompactTextRenderer.windowLabel` prefers duration → row label `30d`, not `mo`, misleading for billing-day monthly reset|V24
B3|2026-09-28|Review of branch: V5 said status `unauthenticated` (store uses `.error(.auth)`); credential resolved once at launch so toml fix / re-signin needed restart despite "next poll" copy; default shared URLCache wrote authenticated responses to disk; Welcome probe ignored `cloud = false`; `/api/me` re-POSTed every tick when `Plan` absent|V5,V6,V16,V17,V25,V26
B4|2026-09-28|Second review of PR #17: plan cache keyed on credential *source*, so another valid key/account in same source kept old plan; `Secret` had no empty mirror (`dump` printed API key); cookies/credential storage still on; `cloud = false` runtime semantics unstated|V4,V17,V22,V25,V26
