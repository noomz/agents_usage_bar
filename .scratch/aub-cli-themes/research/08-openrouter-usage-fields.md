# OpenRouter usage fields (ticket 08)

Fetched 2026-09-25. Primary sources = OpenRouter official docs.

Sources:
- Key endpoint / limits: https://openrouter.ai/docs/api-reference/limits
- Credits: https://openrouter.ai/docs/api-reference/get-credits
- Activity: https://openrouter.ai/docs/api/api-reference/analytics/get-user-activity (also https://openrouter.ai/docs/api-reference/analytics/get-activity via search snippet)
- Management keys: https://openrouter.ai/docs/guides/overview/auth/management-api-keys

## Field table

"aub reads" cites `AgentsUsageBar/Providers/OpenRouter/`; "decoded" = parsed in `OpenRouterResponses.swift` but not surfaced.

| Field | Endpoint | Unit | Window | Reset rule | Key type | aub reads? |
|---|---|---|---|---|---|---|
| `data.usage` | GET /api/v1/key | credits (USD) | all time | never | normal key | yes, `OpenRouterProvider.swift:97` (Quota.used when key limit set) |
| `data.usage_daily` | /key | credits (USD) | current UTC day | UTC midnight | normal | decoded (`OpenRouterResponses.swift:60`), NOT used |
| `data.usage_weekly` | /key | credits (USD) | current UTC week, starts Monday | Mon 00:00 UTC | normal | decoded (`:63`), not used |
| `data.usage_monthly` | /key | credits (USD) | current UTC month | 1st 00:00 UTC | normal | decoded (`:66`), not used |
| `data.byok_usage[_daily/_weekly/_monthly]` | /key | credits (external BYOK spend) | same as above | same | normal | decoded (`:70-73`), not used |
| `data.limit` | /key | credits | per-key ceiling; null = unlimited | see limit_reset | normal | yes, `Provider.swift:95-98` |
| `data.limit_remaining` | /key | credits | same | same | normal | yes, `:99` |
| `data.limit_reset` | /key | string or null ("null if never resets") | — | `daily` = "every day at midnight UTC" (management-keys doc). Other values (weekly/monthly): UNVERIFIED | normal | decoded (`:46`), not used |
| `data.include_byok_in_limit` | /key | bool | — | — | normal | decoded (`:52`), not used |
| `data.is_free_tier` | /key | bool: "whether the user has paid for credits before" | — | — | normal | not read |
| `data.free_model_daily_requests.{used,limit,remaining}` | /key | request count | current UTC day | UTC midnight | normal | no (not decoded) |
| `data.total_credits` | GET /api/v1/credits | credits purchased (USD-equivalent; docs say only "credits") | lifetime | never | **management key** per docs | yes, `Provider.swift:102-106,116` |
| `data.total_usage` | /credits | credits used | lifetime | never | **management key** | yes, `:70-72,84,106,116` (baseline delta gives costToday) |
| `usage` (per row) | GET /api/v1/activity | USD, OpenRouter credits spent | one row per date+model+endpoint, last 30 *completed* UTC days (today excluded) | UTC day; wait ~30 min after boundary | **management key** | no |
| `byok_usage_inference`, `requests`, `prompt_tokens`, `completion_tokens`, `reasoning_tokens` | /activity | USD / counts | same | same | management | no |
| Activity params: `date`, `api_key_hash`, `user_id`, `workspace_id`, `group_by=workspace` | /activity | — | — | — | management | no |

Notes:
- CONFLICT vs code: docs (get-credits page) say `/credits` needs a management key ("403 Only management keys can perform this operation"). aub's code calls it with the user's bearer and has a fallback design; whether a normal key gets 403 in practice is UNVERIFIED (not tested; no key used). Provider currently fails the whole fetch if either call throws (`async let` + `try await`, `Provider.swift:59-61`) — worth checking.
- Docs give no explicit unit for `/key` usage beyond "credits"; OpenRouter credits are 1:1 USD elsewhere in docs (activity says "USD (OpenRouter credits spent)"). Treated as USD.
- `/activity` returns no token-free "today" number: current day excluded, so it cannot give spend today.
- Endpoints `/api/v1/keys` (list/create/update, management key) exist; full schema, allowed `limit_reset` enum: UNVERIFIED (create-key page 404 on fetch).

## What aub could show on the OpenRouter row

1. Spend today: `usage_daily` from /key (normal key, UTC-day exact) — replaces the baseline-delta hack (`Provider.swift:63-84`) that shows 0 on cold launch. Caveat: UTC day, not local midnight; aub is local-midnight. Label accordingly.
2. Spend this week / month: `usage_weekly`, `usage_monthly` (UTC Mon-start / UTC month).
3. All-time spend: `usage`.
4. Key limit bar: `limit`, `limit_remaining`, plus reset caption from `limit_reset` (daily → "resets 00:00 UTC"; other values unverified).
5. Prepaid balance: `total_credits - total_usage` (needs management key per docs).
6. Free-tier: `free_model_daily_requests` used/limit, `is_free_tier` badge.
7. BYOK spend split: `byok_usage_*` (respect `include_byok_in_limit`).
8. Per-model/day breakdown: /activity (management key, yesterday and earlier only) — out of scope for "today".
