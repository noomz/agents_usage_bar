package domain

import (
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
)

// DegradedNote is the raw["note"] value of a snapshot whose usage is temporarily unavailable.
const DegradedNote = "usage-temporarily-unavailable"

// Sentinels in raw["providerStatus"] that classify an outage while still returning a snapshot.
const (
	RawProviderStatus        = "providerStatus"
	StatusSentinelNotRunning = "notRunning"
	StatusSentinelUnauth     = "unauthenticated"
)

// Quota is a used/limit/remaining triple. Accounts with no limit have a nil Quota.
type Quota struct {
	Used, Limit, Remaining float64
}

// UnitQuota is a Quota from a consumed fraction, with limit 1.
func UnitQuota(used float64) Quota {
	return Quota{Used: used, Limit: 1, Remaining: maxF(0, 1-used)}
}

func minF(x, y float64) float64 {
	if y < x {
		return y
	}
	return x
}

func maxF(x, y float64) float64 {
	if y >= x {
		return y
	}
	return x
}

// Fraction is the consumed fraction, clamped to [0, 1]. A zero limit does not divide by zero.
func (q Quota) Fraction() float64 {
	return minF(1, maxF(0, q.Used/maxF(q.Limit, math.SmallestNonzeroFloat64)))
}

// QuotaBand is the remaining-fraction band shared by the bars and the classic renderer.
type QuotaBand int

// The bands.
const (
	BandNone QuotaBand = iota
	BandCritical
	BandWarning
	BandHealthy
)

// BandFromRemaining maps a remaining fraction onto a band. Nil is the no-limit account.
func BandFromRemaining(remaining *float64) QuotaBand {
	if remaining == nil {
		return BandNone
	}
	clamped := minF(maxF(*remaining, 0), 1)
	switch {
	case clamped < 0.20:
		return BandCritical
	case clamped < 0.50:
		return BandWarning
	}
	return BandHealthy
}

// QuotaWindow is a time-bounded quota window. Utilization is a fraction in [0, 1].
type QuotaWindow struct {
	Name        string
	Utilization *float64
	ResetsAt    *time.Time
	// Duration is the window length in seconds when the source reports it.
	Duration *float64
}

// IsFiveHour names Claude's session window, "5h" or "work 5h".
func (w QuotaWindow) IsFiveHour() bool {
	return w.Name == "5h" || strings.HasSuffix(w.Name, " 5h")
}

// IsSevenDay names the canonical weekly window, excluding 7d-sonnet and 7d-opus.
func (w QuotaWindow) IsSevenDay() bool {
	return w.Name == "7d" || strings.HasSuffix(w.Name, " 7d")
}

// AsQuota is utilization as a Quota, nil when utilization is omitted.
func (w QuotaWindow) AsQuota() *Quota {
	if w.Utilization == nil {
		return nil
	}
	q := UnitQuota(*w.Utilization)
	return &q
}

// PeriodSpend is provider-reported spend per provider-defined period.
type PeriodSpend struct {
	Day, Week, Month decimal.Decimal
}

// BillingModel is how an account pays.
type BillingModel string

// The billing models.
const (
	BillingMetered      BillingModel = "metered"
	BillingSubscription BillingModel = "subscription"
	BillingLocal        BillingModel = "local"
)

// AccountUsage is one account's slice of an aggregated provider row.
type AccountUsage struct {
	Name         string
	CostTodayUSD *decimal.Decimal
	TokensToday  *int
	Quota        *Quota
	QuotaWindows []QuotaWindow
}

// DisplayedQuota prefers the 5-hour session window, so the bar matches its reset caption.
func (a AccountUsage) DisplayedQuota() *Quota {
	for _, w := range a.QuotaWindows {
		if w.IsFiveHour() {
			if q := w.AsQuota(); q != nil {
				return q
			}
			break
		}
	}
	return a.Quota
}

// QuotaGlance selects Claude's account window for the account.
func (a AccountUsage) QuotaGlance() QuotaGlance {
	return glanceFromWindows(a.QuotaWindows, &a.Name)
}

// UsageSnapshot is one provider's usage as of one poll. Nil means not available.
// QuotaWindows and Accounts distinguish nil (absent) from empty.
type UsageSnapshot struct {
	ProviderID     ProviderID
	AsOf           time.Time
	TokensToday    *int
	CostTodayUSD   *decimal.Decimal
	BalanceUSD     *decimal.Decimal
	Quota          *Quota
	Raw            map[string]string
	QuotaWindows   []QuotaWindow
	Accounts       []AccountUsage
	PeriodSpendUSD *PeriodSpend
}

// DisplayedQuota is the glance-bar quota: the 5-hour window when one exists, else Quota.
func (s UsageSnapshot) DisplayedQuota() *Quota {
	if len(s.Accounts) > 0 {
		var best *float64
		for _, a := range s.Accounts {
			if q := a.DisplayedQuota(); q != nil {
				if best == nil || q.Used > *best {
					used := q.Used
					best = &used
				}
			}
		}
		if best == nil {
			return s.Quota
		}
		q := UnitQuota(*best)
		return &q
	}
	var best *float64
	for _, w := range s.QuotaWindows {
		if w.IsFiveHour() && w.Utilization != nil && (best == nil || *w.Utilization > *best) {
			best = w.Utilization
		}
	}
	if best != nil {
		q := UnitQuota(*best)
		return &q
	}
	return s.Quota
}

// QuotaUsageCaption is the secondary line for a provider with quota but no today totals.
func (s UsageSnapshot) QuotaUsageCaption() (string, bool) {
	if s.TokensToday != nil || s.CostTodayUSD != nil || s.Quota == nil {
		return "", false
	}
	pct := int(math.Round(s.Quota.Fraction() * 100))
	if period := s.Raw["period"]; period != "" {
		return fmt.Sprintf("%d%% used · %s", pct, period), true
	}
	return fmt.Sprintf("%d%% used", pct), true
}

// QuotaGlance is the aggregate Claude glance. Multi-account sources contribute one candidate
// per primary period.
func (s UsageSnapshot) QuotaGlance() QuotaGlance {
	if len(s.Accounts) > 0 {
		var windows []GlanceWindow
		for _, a := range s.Accounts {
			name := a.Name
			windows = append(windows, glanceCandidates(a.QuotaWindows, &name)...)
		}
		return NewQuotaGlance(windows)
	}
	return glanceFromWindows(s.QuotaWindows, nil)
}

// GlancePeriod is a canonical Claude window.
type GlancePeriod string

// The canonical windows.
const (
	PeriodFiveHours GlancePeriod = "5h"
	PeriodSevenDays GlancePeriod = "7d"
)

// GlanceWindow is one candidate for a canonical window.
type GlanceWindow struct {
	Period      GlancePeriod
	Utilization *float64
	ResetsAt    *time.Time
	AccountName *string
}

// QuotaGlance is the presentation choice for Claude's 5-hour and 7-day windows, shared by
// every renderer so they agree on values, the active constraint, and its reset.
type QuotaGlance struct {
	FiveHours, SevenDays, Active *GlanceWindow
}

func glanceCandidates(windows []QuotaWindow, account *string) []GlanceWindow {
	var out []GlanceWindow
	for _, w := range windows {
		switch {
		case w.IsFiveHour():
			out = append(out, GlanceWindow{PeriodFiveHours, w.Utilization, w.ResetsAt, account})
		case w.IsSevenDay():
			out = append(out, GlanceWindow{PeriodSevenDays, w.Utilization, w.ResetsAt, account})
		}
	}
	return out
}

func glanceFromWindows(windows []QuotaWindow, account *string) QuotaGlance {
	return NewQuotaGlance(glanceCandidates(windows, account))
}

// NewQuotaGlance selects the worst window per period, then the active constraint.
func NewQuotaGlance(windows []GlanceWindow) QuotaGlance {
	five := selectGlance(PeriodFiveHours, windows)
	seven := selectGlance(PeriodSevenDays, windows)
	return QuotaGlance{FiveHours: five, SevenDays: seven, Active: activeConstraint(five, seven)}
}

func utilOr(p *float64, fallback float64) float64 {
	if p == nil {
		return fallback
	}
	return *p
}

var distantFuture = time.Date(4001, 1, 1, 0, 0, 0, 0, time.UTC)

func resetOrFuture(t *time.Time) time.Time {
	if t == nil {
		return distantFuture
	}
	return *t
}

func selectGlance(period GlancePeriod, windows []GlanceWindow) *GlanceWindow {
	var best *GlanceWindow
	for i := range windows {
		w := &windows[i]
		if w.Period != period {
			continue
		}
		if best == nil {
			best = w
			continue
		}
		left, right := utilOr(best.Utilization, -1), utilOr(w.Utilization, -1)
		if left != right {
			if left < right {
				best = w
			}
			continue
		}
		if resetOrFuture(best.ResetsAt).After(resetOrFuture(w.ResetsAt)) {
			best = w
		}
	}
	return best
}

func activeConstraint(five, seven *GlanceWindow) *GlanceWindow {
	var fu, su *float64
	if five != nil {
		fu = five.Utilization
	}
	if seven != nil {
		su = seven.Utilization
	}
	switch {
	case fu != nil && su != nil:
		if *fu != *su {
			if *fu > *su {
				return five
			}
			return seven
		}
		if !resetOrFuture(five.ResetsAt).After(resetOrFuture(seven.ResetsAt)) {
			return five
		}
		return seven
	case fu != nil:
		return five
	case su != nil:
		return seven
	}
	return nil
}

// HasAnyWindow reports either canonical window.
func (g QuotaGlance) HasAnyWindow() bool { return g.FiveHours != nil || g.SevenDays != nil }

// Window returns the canonical window for a period.
func (g QuotaGlance) Window(p GlancePeriod) *GlanceWindow {
	if p == PeriodFiveHours {
		return g.FiveHours
	}
	return g.SevenDays
}

// Percent is the rounded text for a period, or an em dash.
func (g QuotaGlance) Percent(p GlancePeriod) string {
	w := g.Window(p)
	if w == nil || w.Utilization == nil {
		return "—"
	}
	return strconv.Itoa(int(math.Round(*w.Utilization*100))) + "%"
}

// DailyTotals sums tokens and cost across providers.
type DailyTotals struct {
	Tokens  int
	CostUSD decimal.Decimal
}

// Capabilities is static metadata about what a provider can report.
type Capabilities struct {
	HasQuota, HasCost, HasTokens, IsLocal bool
}

// ProviderErrorKind classifies a fetch failure.
type ProviderErrorKind string

// The kinds.
const (
	ErrAuth            ProviderErrorKind = "auth"
	ErrPaymentRequired ProviderErrorKind = "paymentRequired"
	ErrHTTP            ProviderErrorKind = "http"
	ErrDecode          ProviderErrorKind = "decode"
	ErrNetwork         ProviderErrorKind = "network"
	ErrNotYetFetched   ProviderErrorKind = "notYetFetched"
	ErrUnknown         ProviderErrorKind = "unknown"
)

func validProviderErrorKind(k string) bool {
	switch ProviderErrorKind(k) {
	case ErrAuth, ErrPaymentRequired, ErrHTTP, ErrDecode, ErrNetwork, ErrNotYetFetched, ErrUnknown:
		return true
	}
	return false
}

// ProviderError is a typed fetch error. It can be cached in a status.
type ProviderError struct {
	Kind    ProviderErrorKind
	Message string
}

func (e ProviderError) Error() string { return e.Message }

// HTTPError is a non-2xx response.
type HTTPError struct {
	Status int
}

func (e HTTPError) Error() string { return "HTTP " + strconv.Itoa(e.Status) }

// NetworkErrorCode is the URLError equivalent used by the localhost classifier.
type NetworkErrorCode int

// The codes the classifier distinguishes.
const (
	NetworkOther NetworkErrorCode = iota
	NetworkCannotConnect
	NetworkCannotFindHost
	NetworkConnectionLost
	NetworkTimedOut
)

// NetworkError is a transport failure.
type NetworkError struct {
	Code NetworkErrorCode
	Err  error
}

func (e NetworkError) Error() string { return e.Err.Error() }

// Unwrap exposes the transport error.
func (e NetworkError) Unwrap() error { return e.Err }

// DecodeError is a response that did not match its schema.
type DecodeError struct {
	Err error
}

func (e DecodeError) Error() string { return e.Err.Error() }

// Unwrap exposes the decoder error.
func (e DecodeError) Unwrap() error { return e.Err }

// ProviderErrorFrom converts any error, preserving as much detail as possible.
func ProviderErrorFrom(err error) ProviderError {
	var pe ProviderError
	if errors.As(err, &pe) {
		return pe
	}
	var he HTTPError
	if errors.As(err, &he) {
		switch he.Status {
		case 401, 403:
			return ProviderError{ErrAuth, he.Error()}
		case 402:
			return ProviderError{ErrPaymentRequired, "HTTP 402"}
		}
		return ProviderError{ErrHTTP, he.Error()}
	}
	var ne NetworkError
	if errors.As(err, &ne) {
		return ProviderError{ErrNetwork, err.Error()}
	}
	var de DecodeError
	if errors.As(err, &de) {
		return ProviderError{ErrDecode, err.Error()}
	}
	return ProviderError{ErrUnknown, err.Error()}
}

// StatusKind names a ProviderStatus case.
type StatusKind string

// The status cases. The text is the status name in `aub usage --json`.
const (
	StatusOK              StatusKind = "ok"
	StatusStale           StatusKind = "stale"
	StatusUnauthenticated StatusKind = "unauthenticated"
	StatusNotRunning      StatusKind = "notRunning"
	StatusDisabled        StatusKind = "disabled"
	StatusError           StatusKind = "error"
)

// ProviderStatus is a provider's operational status. LastSuccess applies to ok and stale;
// Err applies to stale and error.
type ProviderStatus struct {
	Kind        StatusKind
	LastSuccess time.Time
	Err         ProviderError
}

// OK is the status after a good fetch.
func OK(lastSuccess time.Time) ProviderStatus {
	return ProviderStatus{Kind: StatusOK, LastSuccess: lastSuccess}
}

// Unauthenticated is the unconfigured-provider status.
func Unauthenticated() ProviderStatus { return ProviderStatus{Kind: StatusUnauthenticated} }

// NotRunning is the muted localhost status: nothing is listening.
func NotRunning() ProviderStatus { return ProviderStatus{Kind: StatusNotRunning} }

// Disabled is the user-disabled status.
func Disabled() ProviderStatus { return ProviderStatus{Kind: StatusDisabled} }

// Errored is a failure with no prior success.
func Errored(err ProviderError) ProviderStatus {
	return ProviderStatus{Kind: StatusError, Err: err}
}

// Stale is a failure after a prior success.
func Stale(lastSuccess time.Time, err ProviderError) ProviderStatus {
	return ProviderStatus{Kind: StatusStale, LastSuccess: lastSuccess, Err: err}
}

// ClassifyLocalhost maps a localhost probe failure: connection refused, unknown host, a lost
// connection, and timeouts mean the runtime is not running.
func ClassifyLocalhost(err error, lastSuccess *time.Time) ProviderStatus {
	var ne NetworkError
	if errors.As(err, &ne) {
		switch ne.Code {
		case NetworkCannotConnect, NetworkCannotFindHost, NetworkConnectionLost, NetworkTimedOut:
			return NotRunning()
		}
	}
	pe := ProviderErrorFrom(err)
	if lastSuccess != nil {
		return Stale(*lastSuccess, pe)
	}
	return Errored(pe)
}

// ProviderState is one provider's persisted row.
type ProviderState struct {
	ID                 ProviderID
	DisplayName        string
	PlaceholderMessage *string
	Snapshot           *UsageSnapshot
	Status             ProviderStatus
	LastSuccess        *time.Time
}

// ApplyingError keeps the prior snapshot and marks it stale, or errored with no prior success.
func (s ProviderState) ApplyingError(err error) ProviderState {
	pe := ProviderErrorFrom(err)
	next := s
	if s.LastSuccess != nil {
		next.Status = Stale(*s.LastSuccess, pe)
		next.PlaceholderMessage = nil
	} else {
		next.Status = Errored(pe)
	}
	return next
}

// LocalSecondaryCaption is the secondary line for local runtime rows.
func (s ProviderState) LocalSecondaryCaption() string {
	if s.PlaceholderMessage != nil && *s.PlaceholderMessage != "" {
		return *s.PlaceholderMessage
	}
	var raw map[string]string
	if s.Snapshot != nil {
		raw = s.Snapshot.Raw
	}
	if raw["loadingModel"] == "true" {
		return "Running — loading model…"
	}
	if s.Status.Kind == StatusNotRunning {
		return "Not running"
	}
	count := atoiOr(raw["modelCount"], 0)
	installed := atoiOr(raw["installedCount"], -1)
	name, hasName := raw["modelName"]
	vram := atoiOr(raw["vramBytes"], 0)
	suffix := ""
	if vram > 0 {
		suffix = fmt.Sprintf(" · %.1f GB VRAM", float64(vram)/1_073_741_824.0)
	}
	switch {
	case count == 0:
		if installed == 0 {
			return "Idle — no models installed"
		}
		return "Idle — 0 models loaded"
	case count == 1 && hasName:
		return name + suffix
	case count > 1 && hasName:
		return fmt.Sprintf("%s · +%d more", name, count-1)
	}
	return "—"
}

func atoiOr(s string, fallback int) int {
	n, err := strconv.Atoi(s)
	if err != nil {
		return fallback
	}
	return n
}

// ResetPhrase is `Resets 2h 50m`, or `Resets now` once the instant has passed.
func ResetPhrase(until, now time.Time) string {
	interval := until.Sub(now).Seconds()
	if interval <= 0 {
		return "Resets now"
	}
	return "Resets " + ResetCompact(interval)
}

// ResetCompact is two most-significant units: `<1m`, `12m`, `2h 50m`, `3d 8h`.
func ResetCompact(seconds float64) string {
	t := maxF(0, seconds)
	if t < 60 {
		return "<1m"
	}
	total := int(t / 60)
	days := total / (24 * 60)
	hours := (total / 60) % 24
	minutes := total % 60
	if days >= 1 {
		if hours == 0 {
			return strconv.Itoa(days) + "d"
		}
		return fmt.Sprintf("%dd %dh", days, hours)
	}
	if total/60 >= 1 {
		if minutes == 0 {
			return strconv.Itoa(total/60) + "h"
		}
		return fmt.Sprintf("%dh %dm", total/60, minutes)
	}
	return strconv.Itoa(total) + "m"
}

// RefreshIntervals lists valid interval strings. `manual` is user-triggered only.
var RefreshIntervals = []string{"manual", "1m", "2m", "5m", "15m", "30m"}

// DefaultRefreshInterval is the default polling interval.
const DefaultRefreshInterval = "5m"

// ValidRefreshInterval reports a canonical interval string.
func ValidRefreshInterval(s string) bool {
	for _, v := range RefreshIntervals {
		if v == s {
			return true
		}
	}
	return false
}

// TranscriptOffset is a per-file resume cursor for incremental JSONL reads. ByteOffset is the
// position after the last fully parsed newline.
type TranscriptOffset struct {
	URL          string
	ByteOffset   uint64
	LastModified time.Time
}

// BaselineRecord is a cumulative metric's baseline for one day key.
type BaselineRecord struct {
	Value       float64
	Date        string
	LastValue   float64
	LastUpdated time.Time
}

// DailyUsageRecord is a running token and cost total for one day key.
type DailyUsageRecord struct {
	Date          string
	Tokens        int
	CostUSD       decimal.Decimal
	SessionTokens map[string]int
}
