# Provider order setting

Map: [aub CLI themes](../map.md)
Type: grilling
Status: resolved
Assignee: lazym0m3nt
Blocked by: —

## Question

Define the user-set provider order that the `compact` CLI theme and the menu-bar popover both honour (decided in [Compact theme edge cases](05-compact-theme-edge-cases.md) Q16; widens the destination to one popover change).

Pin: setting key (`provider-order`?) and value format (comma list of provider ids), how unlisted and unknown ids are treated (append in known order / warn), whether Claude accounts can be ordered, how `aub settings set/get` validates it, where the popover reads it (today it sorts alphabetically by displayName: `UI/PopoverRootView.swift:46-48`, while the Settings and Welcome tabs use `ProviderID.allKnown`), whether the Settings UI gets a reorder control or stays CLI-only in v1, and that `classic` output is unaffected.

## Answer

Decided 2026-09-25 (grilling, 8 questions).

**Setting**
- UserDefaults key `provider-order` (new `CLISettings` kind), value a comma list of `ProviderID.rawValue` ids, `engine.<slug>` included.
- `set` rejects, exit 2: an id not in `ProviderID.allKnown` and not a configured `engine.*`, or a duplicate. Error lists the valid ids. Case-insensitive, stored and echoed lowercase (as `cli-theme`).
- `set provider-order ""` removes the key (reset). `get` shows the stored list, or the full `allKnown` list as the default when unset. No new `unset` command.
- CLI-only writer in v1: no reorder control in the Settings window.

**Ordering rule** (one shared helper, used by compact and the popover)
- Listed ids first, in the given order.
- Then unlisted providers in `allKnown` order, then custom `engine.*` alphabetical by slug (replaces today's unstable `Int.max` tie).
- Ids that no longer exist (e.g. engine removed from `config.toml`) are skipped silently at read time.
- Claude accounts are not orderable: they stay alphabetical inside the Claude row, `●` on the active one (per [Compact theme edge cases](05-compact-theme-edge-cases.md)).

**Surfaces**
- Honoured by the `compact` CLI theme and the menu-bar popover only.
- Popover drops its alphabetical-by-`displayName` sort (`UI/PopoverRootView.swift:46-48`) and uses the shared rule; when unset that is `allKnown` order, so existing users see OpenRouter move first, Claude second. A changed setting shows on the next popover open.
- Unaffected: `classic` (byte-identical), `--json` array order, Settings Providers tab, Welcome — all keep `allKnown` via their existing code.
