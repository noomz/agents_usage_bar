# The day key only moves forward

Usage history files each day under a local calendar date (the **day key**). When the wall-clock date goes backward, for example after flying west over the date line, an NTP correction or a manual clock change, polls keep writing to the newest day key and a sealed day is never reopened. A date skipped forward becomes a gap. If the wall clock is more than 1 day behind the newest key, it is treated as a clock error: history writes pause and the app logs it, but the popover keeps showing live numbers. Time zones never move the date back by more than 1 day, so a larger difference can only be a wrong clock. The newest key is read from the newest day file, and one shared owner gives the key to every "today" consumer (history, the daily accumulator, the OpenRouter baseline, notification state), so they never disagree.

## Considered Options

- Follow the wall clock and reopen the earlier day: breaks "sealed" (a sealed day no longer changes from polling) and mixes two stretches of time into one record.
- Key every day in a fixed home time zone: no backward dates, but "today" stops matching the user's local day while they travel.
- Forward-only with no clock-error limit: a clock set back a month would put a month of usage on one day.
- Store the newest key in UserDefaults: a second source of truth that can drift from the day files.
