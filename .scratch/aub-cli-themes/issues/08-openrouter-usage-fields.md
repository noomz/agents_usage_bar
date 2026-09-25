# OpenRouter usage fields

Map: [aub CLI themes](../map.md)
Type: research
Status: resolved
Blocked by: —

## Question

What per-key and per-account usage figures does the OpenRouter API expose that `aub` could show on the OpenRouter row — spend today / this week / this month / all-time, credits total and remaining, key limit and limit remaining, and any reset cadence for a key limit?

Cover `GET /api/v1/auth/key` (`data.usage`, `usage_daily`, `usage_weekly`, `usage_monthly`, `limit`, `limit_remaining`, `limit_reset`, `is_free_tier`) and `GET /api/v1/credits` (`total_credits`, `total_usage`), plus any activity/analytics endpoint that returns per-day spend. For each field: exact name, unit (USD), what window it covers and when it resets (UTC midnight? rolling?), and whether it needs a management key vs a normal key. Compare against what `AgentsUsageBar/Providers/OpenRouter/OpenRouterProvider.swift` already reads. Output: a table, with the primary-source URLs.

## Answer

`GET /api/v1/key` (normal key) already gives everything windowed: `usage` (all-time), `usage_daily` (UTC day), `usage_weekly` (UTC week, Mon start), `usage_monthly`, `byok_usage_*`, `limit`, `limit_remaining`, `limit_reset` (`daily` = midnight UTC; other values UNVERIFIED), `is_free_tier`, `free_model_daily_requests`. All in USD credits.
`GET /api/v1/credits` (`total_credits`, `total_usage`) is documented as **management-key only** — aub calls it with a normal key (possible 403; unverified in practice).
`GET /api/v1/activity` (management key) gives per-day/model USD + tokens, but only the last 30 *completed* UTC days — no "today".
aub currently uses `usage`, `limit`, `limit_remaining`, `total_credits`, `total_usage`; it decodes but ignores `usage_daily/weekly/monthly`, `limit_reset`, byok fields.
Opportunity: use `usage_daily` for spend-today (drops baseline-delta, works on cold launch; UTC-day caveat), show week/month, and a limit-reset caption.
Full table + sources: [research/08-openrouter-usage-fields.md](../research/08-openrouter-usage-fields.md)
