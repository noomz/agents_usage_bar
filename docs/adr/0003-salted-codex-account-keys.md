# Codex account keys are salted hashes

Usage history must recognise the same account on every day, and exports must be safe to share. For Claude the **account key** is the ccs instance slug (or `default`): the user chose it and it is already stable. For Codex the key is a short hash of the login's `account_id` with a random per-install salt kept in `history/.account-salt` (0600). The same login keeps the same key for as long as the salt exists, and neither the day files nor exports reveal the OpenAI workspace identifier. If the salt is lost, a new one is made and old Codex series show up as different accounts; we accept that rather than keep a second copy of the salt elsewhere. The salt is never exported, and `aub` only reads stored keys.

## Considered Options

- Display label as key: the label is picked to be unique among the logins present now, so it shifts when a login is added or removed (one account becomes two series), and it can be an email.
- Raw `account_id` as key: stable, but every export carries a real workspace identifier.
- Unsalted hash: anyone who knows the `account_id` can recompute it, so it is still linkable.
- `account_id → codex-N` mapping table: readable keys, but the raw ids stay on disk and losing the table splits series the same way.
- Salt in UserDefaults: survives deleting `history/`, but a defaults reset splits series and `history/` stops being self-contained.
