# SPEC — Claude dual-limit glance

## §G

G1|Show Claude 5h and 7d quota pressure at a glance without two full-size bars.

## §C

C1|Design only until build invoked.
C2|Popover stays 360pt wide.
C3|One visual quota bar per provider.
C4|Percent means consumed quota.
C5|QuotaBand colors keep current remaining-quota thresholds.
C6|Text always carries period and percent; color and lane position never stand alone.
C7|No JSON schema change.
C8|7d-sonnet and 7d-opus stay secondary details; they do not add lanes to the primary bar.

## §I

I1|macOS popover|Claude quota glance in ProviderRowView.
I2|CLI usage|Human output from aub usage.
I3|CLI quota|Detailed per-window output from aub quota and aub limits.
I4|JSON CLI|Existing quotaWindows output unchanged.
I5|Shared presentation|Pure quota-window selection consumed by UI and CLI.

## §V

V1|When Claude 5h and 7d utilization exist, UI renders one 10pt rounded composite bar: 5h top lane, 7d bottom lane, 1pt separator.
V2|UI always renders compact text in fixed order: 5h <percent> · 7d <percent>.
V3|Each lane fills to its own consumed fraction and receives its own QuotaBand color.
V4|Higher raw utilization is active constraint; its label is emphasized and its reset is shown.
V5|When displayed rounded percentages tie, neither label is emphasized. Exact raw tie uses sooner reset and caption says Next reset.
V6|When only one utilization exists, UI renders one full-height conventional bar and shows the absent window as —.
V7|When neither utilization exists, current no-limit or unavailable fallback remains.
V8|UI accessibility value names both periods, both percentages or unavailable states, active constraint, and applicable reset.
V9|Multi-account Claude uses one aggregate provider bar. Account child rows show account name, cost, 5h text, and 7d text without child bars.
V10|Aggregate active constraint identifies account and period with highest primary-window utilization; raw tie uses sooner reset.
V11|aub usage renders one conventional bar for active constraint, then prints active period plus both 5h and 7d values as text.
V12|aub usage does not use half-block dual-progress glyph encoding.
V13|aub quota and aub limits keep one detailed line per quota window.
V14|UI and CLI derive active constraint, displayed values, and reset selection from one pure shared module.
V15|Non-Claude providers retain current quota presentation unless they explicitly provide canonical 5h and 7d windows.

## §T

id|status|task|cites
T1|x|Add shared QuotaGlance presentation value and selection logic|V4,V5,V6,V7,V10,V14,V15,I5
T2|x|Render composite Claude bar and compact labels in popover|V1,V2,V3,V4,V5,V6,V7,V8,I1
T3|.|Replace Claude account child bars with compact dual-window text|V9,V10,I1
T4|.|Update aub usage human renderer; retain detailed quota renderer|V11,V12,V13,I2,I3
T5|.|Verify JSON output remains compatible|V13,I4
T6|.|Add regression tests for opposing bands, both healthy, both critical, equal, near-equal, missing windows, and multi-account selection|V1,V2,V3,V4,V5,V6,V7,V8,V9,V10,V11,V12,V13,V14,V15

## §B

id|date|cause|fix
