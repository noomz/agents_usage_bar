# Map: Ollama Cloud usage

Label: wayfinder:map
Issue: https://github.com/noomz/agents_usage_bar/issues/12

## Destination

A spec, ready to implement, for showing **Ollama Cloud** account usage (plan, session / weekly / monthly usage fraction) in AUB — popover row and `aub` CLI — for `:cloud` models (e.g. `glm-5.3:cloud`). Today the Ollama provider is local-only: it reads `localhost:11434/api/ps` + `/api/tags`, and `:cloud` models never appear there, so cloud use is invisible.

## Notes

- Domain: `AgentsUsageBar/Providers/Ollama/OllamaProvider.swift` (capabilities `hasQuota/hasCost/hasTokens = false`, `isLocal = true`), `UsageSnapshot.quotaWindows`, `QuotaWindow`, threshold engine, CLI renderers.
- Research: [research/01-ollama-cloud-usage-api.md](research/01-ollama-cloud-usage-api.md).
- Key facts (from research, undocumented upstream):
  - `GET https://ollama.com/api/usage` → `limits.{session,weekly,monthly}.usage` as 0–1 fractions; no reset timestamps.
  - `POST https://ollama.com/api/me` → plan name.
  - Auth used by prior art: device-key signature (`~/.ollama/id_ed25519`, created by `ollama signin`), header `Authorization: <b64 pubkey>:<b64 sig>` over `METHOD,request-uri` with `ts` query param. Bearer `OLLAMA_API_KEY` also accepted (ticket 01).
  - Pricing changed 2026-08-31: new plans = monthly credit, reset on subscription day; legacy plans keep 5h session + 7d weekly windows — out of scope (ticket 04: monthly only).
- Standing preferences:
  - Repo is public: no personal account data, plan, key material, pubkeys, or home paths in tickets, fixtures, logs, or commits. Probe payloads get scrubbed before landing anywhere tracked.
  - Private key used only in-process for signing; never logged, cached, copied, or sent.
  - Undocumented endpoints → every field optional; failure degrades the cloud part only, never the local row (GEMINI-04 isolation).
  - GSD deprecated; plan here.

## Decisions so far

<!-- one line per resolved ticket: [title](issues/NN-slug.md): gist -->
- [Usage API research](research/01-ollama-cloud-usage-api.md): `/api/usage` + `/api/me` exist, device-key signed; no reset times in JSON; CodexBar scrapes settings HTML instead; openusage (Swift) uses the API.
- [Live probe](issues/01-live-probe.md): device-key signature **and** Bearer `OLLAMA_API_KEY` both work on `/api/usage` + `/api/me`, same payload; new-pricing account returns `limits.monthly` only; `activity.period` is rolling last-4-weeks (no reset time); local server 404s `/api/usage` but proxies `/api/me` (plan) with no auth.
- [Auth source](issues/02-auth-source.md): `OLLAMA_API_KEY` env > `[ollama] api_key` toml > device-key signing; on when any credential resolves (`[ollama] cloud = false` opts out); plan via cloud `/api/me` with same credential, best-effort.
- [Provider shape](issues/03-provider-shape.md): separate remote row `ollama-cloud` (hasQuota) beside untouched local `ollama`; shown only when a credential resolves; built on main after #9 (b94ce8c).
- [Quota mapping](issues/04-quota-mapping.md): monthly only → one `mo` window; resets via optional `[ollama] billing_day` else `↻ unknown`; percent only, no $; `activity.cost` (own last-4-weeks spend) in tooltip + `--json` only.
- [Surfaces](issues/05-surfaces.md): standard remote quota row in popover + all CLI views; tooltip/`--json` carry plan, own last-4-weeks spend, credential source; default slot after `ollama`.
- [Failure, polling, privacy](issues/06-failure-polling-privacy.md): shared 5-min poll, `/api/me` per launch; explicit-key 401 → unauthenticated, no fallback, must recover next poll; decode `Plan` only from `/api/me`; synthetic fixtures; check-secrets extended.

## Not yet specified

_Empty — all tickets resolved 2026-09-28; ready to write the spec._

## Out of scope

- Scraping `ollama.com/settings` HTML with browser cookies (CodexBar route) — fragile, needs browser cookie access.
- Per-request token/cost estimation by summing `eval_count` from local responses — AUB doesn't proxy traffic.
- Showing cloud usage for local (non-`:cloud`) models.
