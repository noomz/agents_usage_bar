# Failure, polling, and privacy

Map: [Ollama Cloud usage](../map.md)
Type: grilling
Status: resolved
Blocked by: 02

## Question

Poll cadence for `/api/usage` (reuse 5m default?), 401/404/shape-change handling (degrade cloud part only; stale reuse), cache interaction (see unauthenticated-sticks-via-cache gotcha), and a privacy checklist: no key/sig/pubkey in logs (`os.Logger` privacy), no personal payload in fixtures, `scripts/check-secrets.sh` coverage.

## Answer (2026-09-28)

- **Polling:** shared interval (default 5 min) + on-open refresh, like OpenRouter. `/api/me` once per launch and on credential change, not per poll.
- **Bad explicit key (401):** row shows unauthenticated ("check OLLAMA_API_KEY" / config), **no** fallback to the device key. Must recover on the next poll after the key is fixed — guard against the unauthenticated-sticks-via-cache gotcha (POLL-06 + cache seed) with a test.
- **Device-key 401** (signed out / key rotated): row shows unauthenticated with a hint to run `ollama signin`.
- **Other failures** (5xx, timeout, decode/shape change): degrade to stale with the last snapshot, same as the other providers; never affects the local `ollama` row. All fields optional; unknown keys ignored.
- **Privacy checklist (acceptance criteria):**
  - No key, signature, pubkey, email, name, or ID in logs; `os.Logger` interpolations `.private` by default; only status codes + credential *source* are public.
  - `/api/me` personal fields (`Email`, `Name`, `ID`, `AvatarURL`, …) are not decoded — decode `Plan` only.
  - Test fixtures are synthetic (generated ed25519 key in-test, made-up usage values); no real payloads committed.
  - `scripts/check-secrets.sh` patterns extended for Ollama API key shapes and OpenSSH private-key headers.
