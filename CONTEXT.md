# Agents Usage Bar

A macOS menu bar app plus the `aub` command-line tool that show today's AI-agent usage across providers.

## Language

**CLI theme**:
A built-in layout that decides how `aub` prints usage in the terminal (which fields, order, glyphs); `compact` and `classic` are CLI themes.
_Avoid_: theme (unqualified), skin, style, layout mode

**Active CLI theme**:
The CLI theme one `aub` run actually uses, taken from the first source that names one: the command-line flag, the environment, the saved setting, then the default (`compact`).
_Avoid_: current theme, selected theme

**Provider order**:
The sequence in which providers are listed in the `compact` CLI theme and the menu bar popover; the user can pin some providers to the top, the rest follow the default sequence.
_Avoid_: sort order, ranking, priority

**App theme**:
The menu bar app's light, dark or auto appearance.
_Avoid_: theme (unqualified), colour scheme
