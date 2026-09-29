# Provider shape

Map: [Ollama Cloud usage](../map.md)
Type: grilling
Status: resolved
Blocked by: —

## Question

Extend `OllamaProvider` into a hybrid (local status + cloud quota, `hasQuota: true`) or add a separate `ollama-cloud` provider id/row? Effects on capabilities, `isLocal` branching in `ProviderRowView`, rollups, provider-order setting, welcome/detection probe, and config (enable toggle).

## Answer (2026-09-28)

- **Separate row:** new remote provider id `ollama-cloud` (`isLocal: false`, `hasQuota: true`), alongside the untouched local `ollama` row. Local-vs-remote rendering is keyed by `ProviderID.isLocalRuntime` (fixed id set), so a remote id gets the existing quota bar, 80% threshold notification, provider-order, CLI compact/classic/quota views and `--json` without new branches.
- **Visibility:** row registered only when a credential resolves (ticket 02) and not disabled via `[ollama] cloud = false`; absent otherwise (not an error row).
- **Base:** implementation builds on `main` after #9 (compact theme) — branch fast-forwarded to `main` @ b94ce8c on 2026-09-28.
- Follow-ons for the spec: add `ollama-cloud` to `ProviderID` (+ `allKnown` order, provider-order validation), display name "Ollama Cloud", dashboard URL `https://ollama.com/settings`, welcome/detection probe line.
