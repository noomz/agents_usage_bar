# Map: Popover idle CPU

Label: wayfinder:map
Issue: none yet (open one when the plan is approved)

## Destination

AgentsUsageBar uses about 0% CPU while the popover is closed. While it is open, the relative timestamps, staleness, and reset countdowns still update every second. Each popover open triggers the POLL-03 refresh.

## Evidence (2026-10-14)

- pid 8740, up 6d18h: 264 min of CPU time (2.7% average), 9% at the time of sampling, 514k idle wakeups.
- `sample` 5 s with the popover **closed**: 12% of main-thread samples went to `CA::Transaction::commit` → `NSWindow layoutIfNeeded` → AttributeGraph → `TimelineView<>.UpdateFilter.updateValue` → `ProviderRowView.body` / `RelativeTimestampLabel.body` / `ClaudeQuotaGlanceView.body`.
- `CGWindowList`: popover window 36187 (360×1081, layer 101) reports `onscreen: false` at the same time.
- Peer spindump (`~/Desktop/lag.spindump.txt`, 11:04): main thread idle in `mach_msg` for 1317 of 1444 samples, 0.95 s CPU in 15 s. Steady background cost, not a hang.

## Root cause

`MenuBarExtra(.window)` keeps the popover's SwiftUI tree mounted after it closes. That tree runs 2N independent `TimelineView(.periodic(by: 1))` timers:

- `AgentsUsageBar/UI/ProviderRowView.swift:59` wraps the **whole row** (staleness, `ClaudeQuotaGlanceView(now:)`, `AccountChildRow(now:)`, `resetsText(now:)`, the degraded subtitle).
- `AgentsUsageBar/UI/Components/RelativeTimestampLabel.swift:34` is a second timer inside each row.

Every second, every row is recomputed and the hidden window is laid out and committed. The cost grows with the row count; the Codex per-account rows increased it.

Suspected second bug (verify in T1): `PopoverRootView`'s `.task { await store.refresh(...) }` (POLL-03) runs only when the view mounts. If the tree stays mounted, opening the popover again does not trigger a refresh.

Both reviewers rate this bug as very likely real: MenuBarExtra content runs `onAppear` / `.task` once, on first mount (`AgentsUsageBarApp.swift:7-8`; orchetect/MenuBarExtraAccess exists for this reason). T1 confirms it. If confirmed, POLL-03 is a second, user-visible bug, and the fix and the commit message name it.

## Design (rev 2, after review)

One clock, owned by the popover, ticking only while the popover window is visible on screen.

**Visibility signal: window occlusion (option B).** `onAppear`/`onDisappear` are rejected: they most likely fire once on 14/15, and a pass on the macOS 27 beta host would prove nothing for the 14.0 target.
- A small `WindowAccessor: NSViewRepresentable` hands back the hosting `NSWindow` from `viewDidMoveToWindow`. The panel is reused (same window ID), so one attach is enough.
- `.task(id: window identity)`:
  - read `window.occlusionState.contains(.visible)` once at attach, because the notification can lag `orderFront` by a frame;
  - then iterate `NotificationCenter.default.notifications(named: NSWindow.didChangeOcclusionStateNotification, object: window)` and update `isVisible`.
  - The `.task` cancels the loop automatically; no Combine and no observer tokens (the project bans Combine).
- Bonus: the clock also pauses on screen lock and display sleep.
- `isVisible` starts `true`, because the view mounts on the first open.

**Clock.** Lives in a small child view `ProviderListView(now:)`, which replaces the `ForEach` in `PopoverRootView`. This keeps `TotalsHeaderView`/`FooterView` and the `UserDefaults` sort out of the per-second body work.
- `@State now`, seeded from the injected `\.clockService` (not `Date.now`), matching `FooterView`.
- Tick loop in `.task(id: isVisible)`:
  - `guard isVisible else { return }`
  - then **`now = clock.now()` synchronously first**, so the first frame after reopening is not stale;
  - then loop `ContinuousClock.sleep(until: next, tolerance: .milliseconds(100))` with `next += .seconds(1)`, which avoids drift and lets the OS coalesce wakeups;
  - `do/catch` exits on cancellation.
- No wall-clock second alignment. Labels floor `now - lastSuccess`, so wall-clock phase does not matter.
- Nothing writes `@State` while hidden. Any write to a hidden-but-mounted window still lays out and commits.

**POLL-03 refresh.** A separate `.task(id: isVisible) { if isVisible { await store.refresh(now:) } }`. It is never awaited inside the tick loop: the refresh awaits the whole fan-out (8 s HTTP timeout) and would freeze the clock.
- The mount-only `.task` in `PopoverRootView` is removed.
- Existing coalescing (`AggregateStore.swift:186`: join in-flight, skip if < 5 s since the last tick) makes a fast close → reopen a no-op.

**Views.**
- `ProviderRowView(state:now:)` and `RelativeTimestampLabel(date:now:prefix:isStale:)` take a **required** `now` (no default, so the compiler catches every call site) and lose their `TimelineView`s.
- The unused `clock` env in `ProviderRowView` (`:28`) is deleted. The five previews pass `.now`.
- No test constructs these views; the suites test static helpers, which are unchanged.

Rejected:
- Pausable custom `TimelineSchedule`: it keeps 2N timers and still needs the same visibility signal.
- Key/resign notifications: a proxy for visibility, not a measure of it.
- `controlActiveState`: unclear whether it updates in an ordered-out panel.
- `appearsActive`: macOS 15+ only.
- `willCloseNotification`: the panel is ordered out, not closed.
- Reusing `WindowActivationObserver`: it is app-global and filtered by title. Only its MainActor-hop pattern carries over.
- Env-injected `now`: an implicit dependency for one hop.
- `NSStatusItem` + `NSPopover` rewrite: too large for the problem.

Out of scope:
- The menu bar label: a static SF Symbol whose tint changes at most once per poll.
- `PollScheduler` cadence.
- The `FooterView` reset text crossing midnight while open: existing, not a regression. Optional follow-up: pass it `now`.
- The silent skip of manual Refresh within 5 s of an open: existing coalescing behaviour.

## Tasks

1. [x] T1 spike, throwaway and not committed. On the installed build, log with os_log across 5 open/close cycles:
   - the occlusion notification and `occlusionState`
   - key/resign
   - `onAppear`/`onDisappear`
   - `.task` start

   Pass criteria:
   - occlusion flips visible ↔ not-visible on every cycle;
   - record whether `.task`/`onAppear` re-fire, which confirms or rules out the POLL-03 bug.

   If occlusion fails on any cycle, stop and re-plan; key/resign is the fallback.
2. [x] T2 `WindowAccessor` and the `isVisible` task in `PopoverRootView`.
3. [x] T3 `ProviderListView(now:)` with the tick loop, plus the POLL-03 visible-edge refresh task; remove the mount-only `.task`.
4. [x] T4 required `now` on `ProviderRowView` and `RelativeTimestampLabel`; delete both `TimelineView`s and the unused `clock`; update the previews and the doc comments that mention TimelineView.
5. [x] T5 build plus the full test plan (`AgentsUsageBar.xctestplan`). No new unit test: the new logic is view wiring with no pure branch worth isolating, so its proof is T6 on the real app.
6. [x] T6 A/B proof on the real app, with the old and new builds measured in the same session, Codex multi-account rows present, and the popover **opened and closed once before** each closed-state measurement (content is built on first open only):
   - Closed for 60 s, measured with `top -l 13 -s 5 -stats pid,cpu,idlew`: mean CPU < 0.3%, and idle wakeups/s at least 10× lower than the old build.
   - Closed, `sample` 5 s: 0 `TimelineView` frames; under 1% of main-thread samples in `CA::Transaction::commit`.
   - Open: "Updated Xs ago" advances each second. Reopen after more than 2 min closed: no stale first frame.
   - Close and reopen 3 times, more than 5 s apart: a refresh fires on each open (log line or `lastSuccess` advances).
   - Close within 1 s of opening during a slow fetch: the closed-state CPU check above still passes, and the refresh still completes.

Dependencies: T1 → T2 → T3 → T6. T4 is independent of T2/T3 (signature changes only) and can be done alongside them. T5 runs after T3 + T4.

## Risks

- `notifications(named:object:)` with a non-Sendable `NSWindow` under Swift 6 strict concurrency may raise diagnostics. Fallback: observe with `object: nil` and filter by window identity inside the loop on MainActor.
- The occlusion notification may arrive a frame after `orderFront`. The initial read at attach, plus a synchronous `now` refresh on the edge, covers it.
- Remaining hidden work: one body evaluation per `AggregateStore` mutation (each poll, default 5 min). Negligible.

## Outcome (2026-10-14)

- T1: on this macOS the popover view is rebuilt on every open (`onAppear`/`onDisappear` fired 11/11 cycles, including after opening Settings). Occlusion reports `visible=false` at attach and flips to `true` about 20 ms later on every open. The POLL-03 mount-only bug did **not** reproduce here, so it is not claimed.
- Not observed: the "kept mounted while hidden" state the old pid 8740 was in, and therefore the occlusion `visible=false` path. The lock-screen test was skipped by the user. The path is covered by design but unverified.
- T5: 1233 tests pass. One source-text assertion updated (`now: ctx.date` → `now: now`).
- T6 (popover closed after opening, same window state as the old process):

| | old pid 8740 | new build |
|---|---|---|
| mean CPU, 65 s `top` | 10.42% | 0.01–0.02% |
| `TimelineView` frames in 5 s `sample` | 19 | 0 |
| main thread busy | 6.6% | 0.0–0.9% |
| main samples in `CA::Transaction::commit` | 7.8% | 0.0–0.4% |

- The idle-wakeup threshold was dropped: the `IDLEW` delta was 0.1/s even on the old build, so it cannot discriminate.
- The A/B is not perfectly matched: the old process was 6 days old, the new one minutes old.
