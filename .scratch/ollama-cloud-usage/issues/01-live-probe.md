# Live probe of usage endpoints

Map: [Ollama Cloud usage](../map.md)
Type: research
Status: resolved
Blocked by: — (needs user OK: sends a device-key signature to ollama.com)

## Question

Against a real signed-in account: what exact JSON do `GET /api/usage` and `POST /api/me` return (legacy vs new plan — session/weekly, monthly, or both; any dollar amounts; any reset/anchor fields)? Does `/api/usage` accept a Bearer `OLLAMA_API_KEY` too, with the same payload? Does the local server (v0.34.x) expose anything (headers on `:cloud` responses, proxy of `/api/usage`)?

Output: field table + a **scrubbed** sample payload (no plan-identifying values, ids, emails) usable as a test fixture.

## Answer (2026-09-28, device-key probe; one new-pricing account)

Probe: throwaway Swift/CryptoKit script (not committed); raw bodies kept outside the repo. Values below are scrubbed.

| Call | Auth | Result |
|---|---|---|
| `GET ollama.com/api/usage` | none | 401 `{"error": …}` |
| `GET ollama.com/api/usage` | device-key signature | 200 JSON (shape below) |
| `POST ollama.com/api/me` (body `{}`) | device-key signature | 200 JSON, PascalCase keys |
| `GET localhost:11434/api/usage` | none | 404 — local server does not proxy usage |
| `POST localhost:11434/api/me` | none | 200 JSON, lowercase keys — local server proxies `/api/me` and signs it itself |
| `GET ollama.com/api/usage` | Bearer `OLLAMA_API_KEY` | 200, identical shape to device-key |
| `POST ollama.com/api/me` | Bearer `OLLAMA_API_KEY` | 200, identical shape to device-key |
| `POST ollama.com/api/chat` (control) | Bearer / none | 200 / 401 |

Signing confirmed working as in Ollama's `server/cloud_proxy.go`: challenge `METHOD,<path>?ts=<unix>`, header `Authorization: <authorized_keys pubkey field>:<base64 raw ed25519 sig>`. CryptoKit `Curve25519.Signing.PrivateKey(rawRepresentation: seed)` works after parsing the unencrypted OpenSSH container.

`/api/usage` shape (new-pricing account → **monthly only**, no `session`/`weekly` keys):

```json
{
  "activity": {
    "cost": "0.00000",
    "models": [],
    "period": { "type": "last_4_weeks", "starting_at": "2026-01-01T00:00:00Z", "ending_at": "2026-01-29T00:00:00.000000000Z" }
  },
  "limits": {
    "monthly": { "usage": 0.25, "models": [] }
  }
}
```

- `limits.monthly.usage`: fraction 0–1 of the monthly credit.
- `activity.cost`: **string** decimal (USD), for the activity period — not the billing month.
- `activity.period`: rolling `last_4_weeks` ending *now* — **not** a billing window; gives no reset time.
- No reset timestamp anywhere → reset stays unknown from JSON (ticket 04).
- Legacy-plan shape (`session`/`weekly`) not observed; still only from third-party reports.

`/api/me` shape (fields only — contains personal data, never fixture real values):
`ID, Name, Email, AvatarURL, Bio, FirstName, LastName, Links[], CreatedAt, Plan` — `Plan` is a lowercase slug; treat as open-ended (pricing page lists free, pro, max, team, enterprise). Local `/api/me` returns the same with lowercase keys (`id, name, email, avatarurl, plan`).

Both auth modes work on both endpoints, same payload. Bad or missing credentials → 401 `{"error":"invalid credentials"}` (`/api/me` 401 comes back with `text/html` content-type despite a JSON body).

Implication: plan can come from **localhost `/api/me` with no key handling at all**; only `/api/usage` needs AUB to sign.

### Addendum: settings page

`GET ollama.com/settings` with a Bearer key → 303 to `/signin`; the web page (with "$X of $Y used" and "Resets in N") needs a browser session cookie. The reset date is therefore not reachable with API credentials.
