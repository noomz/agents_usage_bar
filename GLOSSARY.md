# Agents Usage Bar

A macOS menu bar app that shows today's AI agent usage per provider and keeps a short daily history of it.

## Usage history

**Day record**:
One provider's usage for one local calendar day: totals, quota peaks and end-of-day values, and the accounts seen that day.
_Avoid_: Daily snapshot, history row

**Day key**:
The local calendar date a day record belongs to. It only moves forward: if the clock or time zone takes the date back, usage stays on the newest day key, and a date that is skipped becomes a gap.
_Avoid_: Today's date, bucket

**Sealed**:
A day record that no longer changes from polling, because a poll on a later local day has happened.
_Avoid_: Closed, finalized

**Observed**:
A day record built from the app's own polls during that day.
_Avoid_: Live, real

**Backfilled**:
A day record rebuilt later from data the provider keeps (transcripts, history APIs), not from polls on that day.
_Avoid_: Imported, reconstructed

**Gap**:
A day with no day record for a provider, meaning its usage is unknown. Never shown or counted as zero.
_Avoid_: Empty day, zero day

**Usage event**:
A dated moment worth marking in history: a quota band crossed, a budget crossed, a pace warning, a quota reset, or sign-in lost or regained. Recorded whether or not the user was notified.
_Avoid_: Alert, notification, marker, threshold event

**Estimated cost**:
A cost worked out from token counts and a price table rather than reported by the provider.
_Avoid_: Approximate cost, computed cost

**Billing model**:
How an account is paid for: metered (charged per use, so money is what runs out), subscription (a fixed plan, so quota is what runs out) or local (nothing runs out).
_Avoid_: Plan, tier, pricing

**Account**:
One sign-in a provider is used through, such as a ccs instance for Claude or a ChatGPT login for Codex. A provider may have several.
_Avoid_: Login, profile, user

**Account key**:
The name history uses to recognise the same account on every day. It never changes, never shows an email and does not reveal the provider's own account identifier.
_Avoid_: Account id, account name

**Account label**:
The readable name shown for an account, such as a ccs instance name or a plan name. It can change from day to day; history never stores an email as a label.
_Avoid_: Account name, display name

**Spend**:
Money actually charged for usage on a metered account, reported or estimated. Subscription usage is never spend.
_Avoid_: Cost (when meaning money charged), bill

**API-equivalent value**:
What a subscription account's usage would have cost at metered prices. Shows value for money; never counted as spend or toward a budget.
_Avoid_: Subscription cost, virtual spend

**Budget**:
An optional monthly spending cap in US dollars, set for one provider or for all providers together.
_Avoid_: Limit, quota, goal

**Month spend**:
The spend so far in the current local calendar month, summed from day records. Incomplete when any day in the month is a gap or has unknown cost.
_Avoid_: Monthly usage, billing total

**Dashboard**:
The window that shows the retained usage history as charts, opened from the menu bar, the CLI, a hotkey or a notification.
_Avoid_: Stats window, history view, report
