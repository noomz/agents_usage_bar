# Subscription usage is never spend

Claude (Pro/Max OAuth), Codex (ChatGPT plan), Gemini tiers and Ollama Cloud plans are paid for with a fixed subscription, so quota, not money, is what runs out. Their token-priced `~$` is recorded as **API-equivalent value**: shown in the provider drill-down and the dashboard, but never summed into spend totals, month spend or budgets. Only metered accounts (OpenRouter, Grok credits, Claude/Codex on an API key) produce spend, reported or estimated. Each account's billing model is stored per day at poll time, so a later plan change never rewrites history.

## Considered Options

- Count estimated cost as spend everywhere (the earlier Spend budgets rule): totals and budgets would mean "API-equivalent usage" and overstate the real bill by the subscription users' whole usage.
- Derive billing model from current credentials at read time: no store change, but switching plans would reclassify past days.
- A user-declared per-provider setting: goes stale and cannot express a provider with mixed accounts.
