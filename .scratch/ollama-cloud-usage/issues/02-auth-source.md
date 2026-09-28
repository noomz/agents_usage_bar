# Auth source

Map: [Ollama Cloud usage](../map.md)
Type: grilling
Status: resolved
Blocked by: —

## Question

Device-key signing (zero setup after `ollama signin`; AUB reads a private key) vs Bearer `OLLAMA_API_KEY` from env/config (explicit, documented key type, unconfirmed on `/api/usage`) vs both with a precedence. Covers: OpenSSH ed25519 parsing in Swift (CryptoKit `Curve25519.Signing`), key never leaves process memory, behaviour when signed out / key absent, and opt-in vs on-by-default.

## Answer (2026-09-28)

- **Order:** `OLLAMA_API_KEY` env > `[ollama] api_key` in `config.toml` (same D-03 `env > toml` rule and `Secret` type as OpenRouter/Grok) > device-key signature from `~/.ollama/id_ed25519`. An explicit key always wins.
- **Default:** on whenever any credential resolves; `[ollama] cloud = false` turns it off. No credential → cloud part silently absent (local row unchanged), not an error.
- **Plan:** `POST ollama.com/api/me` with the same credential as `/api/usage`; best-effort — failure hides the plan badge only.
- **Device-key details (defaults, not grilled):** parse the unencrypted OpenSSH container only; encrypted (`cipher != none`), wrong type, or unreadable → treat as "no device credential" and log once at debug with no path contents. Signing per `server/cloud_proxy.go`: `ts` query param, challenge `METHOD,<request-uri>`, header `<pubkey field>:<b64 sig>`. Key bytes held only in memory for the signing call; never logged, cached, or written.
- **Testing:** signer tested against a fixture key generated in-test (never a real key); header format pinned by a golden test.
