# Theme selection ux

Map: [aub CLI themes](../map.md)
Type: grilling
Status: resolved
Assignee: lazym0m3nt
Blocked by: —

## Question

Pin the selection behaviour: `--theme` flag parsing, `AUB_THEME`, `aub settings set/get/list cli-theme`, precedence (flag > env > setting > `compact`), unknown-name error text and exit code, how users discover theme names (help text / `aub settings list`), and that the setting read is skipped when flag or env is present.

## Answer

Decided 2026-09-25 (grilling, 14 questions). Precedence stays `--theme` > `AUB_THEME` > `cli-theme` setting > `compact`.

**Flag**
- `--theme NAME` only: space form like `--provider`; no `--theme=NAME`, no short form. Added to `AUBCommand.knownTokens` so the GUI binary routes to the CLI path.
- Accepted on any command and ignored where irrelevant (`--json`, `settings`, `install`), like `--no-color`. The value is **always validated at parse**.
- Unknown name → new `AUBParseError.unknownTheme`: `error: unknown CLI theme 'x'; expected compact|classic` on stderr, exit 2.

**Env**
- `AUB_THEME=""` counts as unset.
- Invalid value → same error prefixed `AUB_THEME:`, exit 2.

**Setting**
- Key `cli-theme` (new `Spec.Kind` in `CLISettings`), default `compact`; bad `set` → `invalid value 'x' for cli-theme; expected compact|classic`.
- `settings get cli-theme` reports the **stored** value only (not env/flag), like every other key.
- Garbage in UserDefaults (hand-edited) → silent fallback to `compact`, per the existing `currentValue` pattern.

**Names**
- Case-insensitive on flag, env and setting; canonical form is lowercase. `settings set cli-theme Classic` stores and echoes `classic`. Errors always list lowercase names. Only `cli-theme` folds case.

**Resolution timing**
- Env and setting are read lazily, only when a text render is about to happen and no higher source won. `--json`, `settings`, `install` never read them, so a bad `AUB_THEME` cannot break JSON scripts, and flag/env skip the UserDefaults read.

**Discovery**
- Help flags block: `--theme NAME    CLI theme: compact (default) | classic`, plus an env line naming `AUB_THEME` and `NO_COLOR`.
- New subcommand `aub themes` (listed in help, in `isSubcommand`):
  - Text: one row per theme — `●` on the active one, name, one-line description, `(default)` on compact — then `active: <name> (from flag|AUB_THEME|setting|default)`. Runs full resolution, so `--theme`/env on this command are honoured and an invalid env errors as above.
  - `--json`: `{"themes":[{"name","description","default"}],"active":"<name>","source":"flag|env|setting|default"}`.
  - Any extra argument (`aub themes classic`) → unexpected-argument error, exit 2. Writing stays `aub settings set cli-theme X`.

**Not done**
- No CLI theme picker in the app's Settings window in v1.
