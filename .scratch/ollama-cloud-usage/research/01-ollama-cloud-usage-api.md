# Ollama Cloud usage API — research

Map: [Ollama Cloud usage](../map.md)
Source: deep-research workflow run wf_9745fa66-54e, 2026-09-28 (25 claims checked, 0 refuted).

## Summary

A third-party app can read Ollama Cloud usage from an undocumented endpoint, GET https://ollama.com/api/usage. Ollama's own settings page reportedly uses the same endpoint. It returns limits.{session,weekly,monthly}.usage as fractions from 0 to 1, but no reset timestamps. The plan name (free/pro/max) comes from POST https://ollama.com/api/me. The openusage Swift menu bar app, merged on 2026-09-05 and 2026-09-23, calls both endpoints. It signs each request with the device ed25519 key at ~/.ollama/id_ed25519, which `ollama signin` links to the account. The header is `Authorization: <b64 pubkey>:<b64 sig>`, and the signature covers `<METHOD>,<request-uri>` with a `ts` query parameter. This matches Ollama's own auth.Sign and cloud_proxy code. The documented OLLAMA_API_KEY Bearer key is meant for inference on ollama.com/api and /v1. Some third-party tools reportedly also use it on /api/usage, but that was not confirmed. The docs name no usage or quota API, only the web page ollama.com/settings/usage. Since the Aug 31, 2026 pricing change, the plans are Free ($0, starter credits, 1 concurrent request), Pro ($20/mo, $60 credits, 3 concurrent), Max ($100/mo, $300 credits, 10 concurrent), Team ($500/mo, $1,000 shared credits, early access) and Enterprise (custom pricing). Usage is metered in tokens at per-model rates and resets monthly: on the subscription day for paid plans, on the signup date for Free. Credits do not roll over. Subscribers on the older plans keep their 5-hour session and 7-day weekly windows. CodexBar takes a different route: it scrapes the ollama.com/settings HTML using browser session cookies (wos-session), which also gives it reset times from `data-time` attributes. In API-key mode CodexBar gets no quota data.

## Findings

- **[high, 3-0 (merged from claims 0, 16)]** An undocumented endpoint, GET https://ollama.com/api/usage, returns account usage meters: limits.session (5h), limits.weekly (7d) and limits.monthly, plus recent activity spend. openusage says this is the endpoint Ollama's own settings page reads, but that was not checked independently.
  - Evidence: Two merged openusage PRs (2026-09-05, 2026-09-23) call it, and OllamaUsageClient.swift sets usagePath=/api/usage. The PR was tested against a live Pro account. Verifiers point to other projects using it too: ai-usagebar, opencode-quota, oh-my-pi, quota-axi, 9router.
  - Sources: https://github.com/robinebers/openusage/pull/1270, https://github.com/robinebers/openusage/pull/1173
- **[high, 3-0 / 2-1 (merged from claims 2, 18)]** limits.*.usage is a fraction of the plan allowance (0.349 means 34.9%), not a percentage. The response has no reset timestamp and no window start, so an accurate reset countdown can't be built from the API alone. Every field should be parsed as optional.
  - Evidence: The OllamaUsageMapper.swift doc comment and sample payload show this. ai-usagebar and opencode-quota independently say there are no reset timestamps in the payload. Reset times appear only in the settings HTML.
  - Sources: https://github.com/robinebers/openusage/pull/1270, https://github.com/robinebers/openusage/pull/1173
- **[high, 3-0 (claims 1, 16)]** POST https://ollama.com/api/me returns the plan name (free/pro/max). openusage treats this call as best-effort: if it fails, the meters still show.
  - Evidence: The openusage client code has a test fixture {Plan:free} that maps to the label Free.
  - Sources: https://github.com/robinebers/openusage/pull/1270, https://github.com/robinebers/openusage/pull/1173
- **[high, 3-0 (claims 1, 17)]** The usage and me endpoints are called with the local device key (~/.ollama/id_ed25519), the same key `ollama signin` uses. The header is `Authorization: <base64 pubkey>:<base64 signature>`. The signature covers `<METHOD>,<request-uri>`, and the URI carries a `ts=<unix seconds>` parameter so the header can't be replayed. A Swift app can do this with CryptoKit Curve25519.Signing, after parsing the OpenSSH private key.
  - Evidence: The verifier read Ollama's own source. auth.Sign returns '%s:%s' (the pubkey and the signature). signCloudProxyRequest adds ts and signs 'METHOD,RequestURI' when the host is ollama.com.
  - Sources: https://github.com/robinebers/openusage/pull/1173, https://github.com/robinebers/openusage/pull/1270, https://github.com/ollama/ollama (auth/auth.go, server/cloud_proxy.go, api/client.go)
- **[high, 3-0 (claims 3, 4, 11)]** The documented auth for direct cloud access is an OLLAMA_API_KEY, created at ollama.com/settings/keys and sent as `Authorization: Bearer`. On /v1/messages, `x-api-key` alone is not supported. The docs cover this key for inference (/api/chat, /v1). No local server is needed. /api/tags works without auth.
  - Evidence: The doc text matches word for word. A live probe returned 401 for an unauthenticated /api/chat and 200 for an unauthenticated /api/tags.
  - Sources: https://github.com/ollama/ollama/blob/main/docs/api/authentication.mdx, https://docs.ollama.com/cloud
- **[high, 3-0 (claims 9, 10, 12)]** The official docs name no usage, quota or account API. The only ollama.com endpoints the cloud docs list are /api/chat and /api/tags. For usage, users are sent to the web page ollama.com/settings/usage. docs.ollama.com/api/usage covers only per-response token fields such as eval_count, not account quota. Open feature requests ask for an official usage API.
  - Evidence: The docs pages were fetched on 2026-09-28. Verifiers cite the open requests ollama/ollama #12532, #15132, #15663 and #18653.
  - Sources: https://docs.ollama.com/cloud, https://ollama.com/pricing
- **[medium, 3-0 (claim 5, scope limited)]** The local server at localhost:11434 needs no auth. After `ollama signin`, it signs :cloud model requests for the user, so an app can run cloud inference through localhost without holding a key. None of the confirmed sources show the local server exposing account usage or quota.
  - Evidence: The primary doc confirms the proxy behaviour. The research found no evidence either way on whether usage appears in /api/ps, /api/tags, response headers or ~/.ollama/logs. The response fields prompt_eval_count/eval_count are documented per-response metrics and could be summed locally as an estimate.
  - Sources: https://github.com/ollama/ollama/blob/main/docs/api/authentication.mdx
- **[high, 3-0 (merged from claims 6, 13, 14, 23)]** Current plans (fetched 2026-09-28): Free $0 with starter credits and 1 concurrent request. Pro $20/mo or $200/yr with $60/mo credits and 3 concurrent. Max $100/mo with $300/mo credits and 10 concurrent. Team $500/mo (early access) with $1,000/mo credits shared across the team and 10 concurrent. Enterprise custom.
  - Evidence: The live pricing page and the /cloud page (which redirects to pricing) agree. ollamatps.com matches them and was last verified 2026-09-25.
  - Sources: https://ollama.com/pricing, https://ollama.com/cloud, https://ollamatps.com/limits/
- **[high, 3-0 / 2-1 (merged from claims 7, 8, 9, 15, 24)]** On the new pricing, included usage is a monthly dollar credit metered in tokens at per-model rates. It resets on the subscription day for paid plans (annual plans too) and on the signup date for Free. Credits do not roll over. Paid plans get an email at 90%, which the user can turn off. The new plans have no 5-hour or weekly limits.
  - Evidence: The pricing FAQ text matches word for word. The blog says there are 'no 5-hour or weekly limits' on the new pricing.
  - Sources: https://ollama.com/pricing, https://ollama.com/cloud, https://ollamatps.com/limits/, Ollama blog 'transparent pricing' (2026-08-31)
- **[medium, derived from verifier evidence]** Subscribers on the legacy plans (before 2026-08-31, not yet switched) keep a session limit that resets every 5 hours and a weekly limit that resets every 7 days. An app has to handle both models. /api/usage may return session/weekly, monthly, or both.
  - Evidence: This comes from verifier notes on the pricing FAQ and blog, the openusage monthly-meter fix and CodexBar's legacy parsing. It was not a standalone confirmed claim.
  - Sources: https://ollama.com/pricing, https://github.com/robinebers/openusage/pull/1270, https://github.com/steipete/CodexBar/blob/main/docs/ollama.md
- **[high, 3-0 (merged from claims 19, 20, 21, 22)]** CodexBar (steipete) gets Ollama quota by scraping the ollama.com/settings HTML with browser session cookies. It accepts the WorkOS `wos-session` cookie and legacy NextAuth cookie names, and treats a redirect to /signin as an expired session. From the page it parses the plan badge, the monthly '$X of $Y used' figure, the legacy session/hourly/weekly percentages, and the reset times in `data-time` attributes. In API-key mode it only probes /api/web_search and reads /api/tags, so it gets no quota.
  - Evidence: The CodexBar doc (committed 2026-09-24) and its code (OllamaUsageFetcher.swift using SweetCookieKit, OllamaUsageParser.swift) were checked with gh.
  - Sources: https://github.com/steipete/CodexBar/blob/main/docs/ollama.md

## Caveats

1. /api/usage and /api/me are undocumented and were reverse-engineered by third parties. Their shape, auth and existence could change without notice. That the settings page uses /api/usage is openusage's statement, not something verified against ollama.com traffic. 2. Whether /api/usage accepts an OLLAMA_API_KEY Bearer token as well as the device-key signature was not confirmed. Verifier notes cite oh-my-pi, quota-axi and opencode-quota as using a Bearer key, but none of the confirmed claims establish it. 3. Pricing changed on 2026-08-31, so the plan and limit facts are only a few weeks old and could change again. Legacy subscribers still use the 5h and 7d windows, so a tracker has to handle both. 4. No confirmed claims answer research question (2): whether the local server (v0.34.x) exposes cloud usage through /api/ps, /api/tags, headers or ~/.ollama/logs. The only lead is the documented per-response eval counts, which could be summed into a local estimate. 5. The research did not cover ccusage or ClaudeBar support for Ollama. 6. Reading ~/.ollama/id_ed25519 needs the unsandboxed app this project already ships. The key is a sensitive credential and should be used only for signing, never logged or sent anywhere.

## Open questions

- Does GET https://ollama.com/api/usage accept an OLLAMA_API_KEY Bearer token, or only the device-key signature? And does it return the same payload either way?
- Does the local Ollama server (localhost:11434, v0.34.x) expose any cloud usage or quota data, through /api/ps, response headers or logs? Or could it proxy /api/usage?
- Is there a JSON source for reset timestamps (or the subscription anchor date), so a real countdown can be shown without scraping the settings HTML?
- What exact /api/usage shape do legacy-plan accounts get compared with new-plan accounts: session and weekly only, monthly only, or both? Does it include dollar amounts ($X of $Y) as well as fractions?

## Sources

- https://github.com/ollama/ollama/issues/16448 (forum)
- https://github.com/ollama/ollama/issues/15132 (forum)
- https://github.com/can1357/oh-my-pi/issues/11739 (forum)
- https://github.com/diegosouzapw/OmniRoute/pull/14167 (forum)
- https://github.com/steipete/CodexBar/blob/main/docs/ollama.md (secondary)
- https://github.com/ollama/ollama/issues/18653 (forum)
- https://github.com/robinebers/openusage/pull/1270 (primary)
- https://github.com/ollama/ollama/issues/15663 (forum)
- https://github.com/ollama/ollama/blob/main/docs/api/authentication.mdx (primary)
- https://ollama.com/pricing (primary)
- https://docs.ollama.com/cloud (primary)
- https://ollamatps.com/limits/ (secondary)
- https://ollama.com/cloud (primary)
- https://dev.to/amareswer/ollama-cloud-free-vs-pro-usage-limits-pricing-what-you-actually-get-2026-3ieo (blog)
- https://ollamatps.com/pricing/ (secondary)
- https://github.com/robinebers/openusage/pull/1173 (primary)
