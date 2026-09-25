# Custom themes scope

Map: [aub CLI themes](../map.md)
Type: grilling
Status: resolved
Blocked by: 02

## Question

Are user-defined (custom) CLI themes in scope for this effort?

Options: out of scope; external only via `aub --json | <tool>` / `aub render` stdin; or loadable theme files — only if 02 shows zero cost on the default path. Decide using measured numbers, not intuition.

## Answer

Decided 2026-09-25. **Custom (user-defined) CLI themes are out of scope for this effort.** `aub` ships `compact` and `classic` compiled in; theme choice stays a static switch.

- The supported path for a user's own layout is `aub --json | <their tool>`. It exists today and costs `aub` nothing extra.
- `aub render` (a second aub process consuming the JSON) is not shipped: 02 measured +6 ms / +14 MB, failing the gate. The prototype branch stays as evidence only.
- Loadable theme files (runtime templates) are rejected: unmeasured cost, needs a template language and error UX, and contradicts the static-switch preference.
- The JSON document's gap vs the text renderer (~8 derived fields: `placeholderMessage`, degraded flag, `isLocal`, `quotaGlance`, captions, `hasAnyQuotaOnlyProvider`) is acknowledged but **not** closed here; 03's "`--json` untouched" stands. If external-tool parity with `compact` is wanted later, that is a separate `--json` enrichment effort.
