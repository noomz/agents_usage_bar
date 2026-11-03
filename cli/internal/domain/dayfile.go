package domain

import (
	"fmt"
	"sort"
	"strconv"
	"sync"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/clock"
	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
)

// CurrentDayFileSchema is the only day-file schema this build reads.
const CurrentDayFileSchema = 1

// ProviderQuotaWindow is the window name a provider's single quota is filed under.
const ProviderQuotaWindow = "quota"

// DayFile is one `history/<day key>.json`.
type DayFile struct {
	SchemaVersion   int
	Date            string
	TimeZone        string
	Records         []DayRecord
	Events          []UsageEvent
	BackfillChecked []ProviderID
}

// RecordOrigin says whether a record came from polls that day or was rebuilt later.
type RecordOrigin string

// The origins.
const (
	OriginObserved   RecordOrigin = "observed"
	OriginBackfilled RecordOrigin = "backfilled"
)

// DayRecord is one provider's usage for one day key. Nil is unknown, never zero.
type DayRecord struct {
	Provider      ProviderID
	TimeZone      *string
	Tokens        *int
	CostUSD       *Money
	CostEstimated bool
	BalanceUSD    *Money
	Quota         map[string]QuotaDay
	Accounts      []DayAccount
	Origin        RecordOrigin
	FirstSeen     *time.Time
	LastSeen      *time.Time
}

// QuotaDay is one window's peak with the reset at that peak, and its last fraction.
type QuotaDay struct {
	Peak         float64
	PeakResetsAt *time.Time
	EndOfDay     float64
}

// DayAccount is one account seen on a day.
type DayAccount struct {
	Key                 string
	Label               string
	BillingModel        BillingModel
	Plan                *string
	BillingModelAssumed bool
	CostUSD             *Money
	Tokens              *int
	Quota               map[string]QuotaDay
}

// UsageEventKind names a usage event.
type UsageEventKind string

// The kinds.
const (
	EventBand80        UsageEventKind = "band80"
	EventBand95        UsageEventKind = "band95"
	EventBand100       UsageEventKind = "band100"
	EventPace          UsageEventKind = "pace"
	EventReset         UsageEventKind = "reset"
	EventAuthLost      UsageEventKind = "authLost"
	EventAuthRecovered UsageEventKind = "authRecovered"
	EventBudgetWarning UsageEventKind = "budgetWarning"
	EventBudgetLimit   UsageEventKind = "budgetLimit"
)

// EventLabels maps each kind to its text in `aub stats`.
var EventLabels = map[UsageEventKind]string{
	EventBand80: "80%", EventBand95: "95%", EventBand100: "100%", EventPace: "pace", EventReset: "reset",
	EventAuthLost: "auth lost", EventAuthRecovered: "auth back", EventBudgetWarning: "budget", EventBudgetLimit: "budget 100%",
}

// UsageEvent is a notable moment on a day. Provider is nil for the total budget.
type UsageEvent struct {
	Time        time.Time
	Provider    *ProviderID
	Kind        UsageEventKind
	Window      *string
	Account     *string
	Fraction    float64
	Notified    bool
	CarriedOver bool
}

// Money is a USD amount rounded to micro-dollars on creation, so no binary expansion reaches
// a day file, an export, or a view.
type Money struct {
	Amount decimal.Decimal
}

// NewMoney rounds half away from zero to 6 places.
func NewMoney(amount decimal.Decimal) Money {
	return Money{Amount: amount.RoundPlain(6)}
}

// String is the on-disk and export form.
func (m Money) String() string { return m.Amount.String() }

// DayCostSplit separates spend (metered) from API-equivalent value (subscription). They are
// never added together.
type DayCostSplit struct {
	HasMetered      bool
	Spend           *Money
	HasSubscription bool
	Value           *Money
	Estimated       bool
}

// CostSplit computes spend and value. Per-account costs split a mixed record. Without them, a
// single-model record's cost belongs to that model; a mixed record cannot be split, so both
// are unknown rather than guessed.
func (r DayRecord) CostSplit() DayCostSplit {
	var metered, subscription []DayAccount
	for _, a := range r.Accounts {
		switch a.BillingModel {
		case BillingMetered:
			metered = append(metered, a)
		case BillingSubscription:
			subscription = append(subscription, a)
		}
	}
	return DayCostSplit{
		HasMetered:      len(metered) > 0,
		Spend:           r.share(metered, subscription),
		HasSubscription: len(subscription) > 0,
		Value:           r.share(subscription, metered),
		Estimated:       r.CostEstimated,
	}
}

func (r DayRecord) share(group, others []DayAccount) *Money {
	if len(group) == 0 {
		return nil
	}
	sum := decimal.Decimal{}
	known := 0
	for _, a := range group {
		if a.CostUSD != nil {
			sum = sum.Add(a.CostUSD.Amount)
			known++
		}
	}
	if known != len(group) {
		if len(others) == 0 {
			return r.CostUSD
		}
		return nil
	}
	total := NewMoney(sum)
	// One billing model: a backfill top-up no account owns stays in the total.
	if len(others) == 0 && r.CostUSD != nil && r.CostUSD.Amount.Cmp(total.Amount) > 0 {
		return r.CostUSD
	}
	return &total
}

// SpendTotal is a summed amount: the known part, whether any of it is estimated, and whether
// any counted day is a gap or unknown. Amount is nil when nothing is known.
type SpendTotal struct {
	Amount     *decimal.Decimal
	Estimated  bool
	Incomplete bool
}

// Add folds another total in.
func (t *SpendTotal) Add(o SpendTotal) {
	if o.Amount != nil {
		sum := *o.Amount
		if t.Amount != nil {
			sum = t.Amount.Add(*o.Amount)
		}
		t.Amount = &sum
	}
	t.Estimated = t.Estimated || o.Estimated
	t.Incomplete = t.Incomplete || o.Incomplete
}

// CostColumn picks one amount of a split: spend or value.
type CostColumn struct {
	Amount  func(DayCostSplit) *Money
	Applies func(DayCostSplit) bool
}

// The two columns of a cost split.
var (
	SpendColumn = CostColumn{
		Amount:  func(s DayCostSplit) *Money { return s.Spend },
		Applies: func(s DayCostSplit) bool { return s.HasMetered },
	}
	ValueColumn = CostColumn{
		Amount:  func(s DayCostSplit) *Money { return s.Value },
		Applies: func(s DayCostSplit) bool { return s.HasSubscription },
	}
)

// SumRecords sums a column over days, one record per day and nil for a gap. Days where the
// column does not apply add nothing; a gap or an unknown amount marks the total incomplete.
func SumRecords(records []*DayRecord, column CostColumn) SpendTotal {
	var result SpendTotal
	for _, r := range records {
		if r == nil {
			result.Incomplete = true
			continue
		}
		split := r.CostSplit()
		if !column.Applies(split) {
			continue
		}
		money := column.Amount(split)
		if money == nil {
			result.Incomplete = true
			continue
		}
		amount := money.Amount
		result.Add(SpendTotal{Amount: &amount, Estimated: split.Estimated})
	}
	return result
}

// BudgetScope is what one budget caps: one provider, or all together when Provider is empty.
type BudgetScope struct {
	Provider ProviderID
}

// BudgetProviders are the cost-reporting providers a budget can name.
var BudgetProviders = []ProviderID{Claude, Codex, OpenRouter}

// BudgetTotal caps the sum of BudgetProviders.
var BudgetTotal = BudgetScope{}

// AllBudgetScopes lists scopes with the total first.
func AllBudgetScopes() []BudgetScope {
	scopes := []BudgetScope{BudgetTotal}
	for _, id := range BudgetProviders {
		scopes = append(scopes, BudgetScope{Provider: id})
	}
	return scopes
}

// Name is `total` or the provider id.
func (s BudgetScope) Name() string {
	if s.Provider == "" {
		return "total"
	}
	return string(s.Provider)
}

// TomlKey is the `[budgets]` key.
func (s BudgetScope) TomlKey() string { return s.Name() + "_usd" }

// BudgetConfig is monthly USD caps per scope.
type BudgetConfig struct {
	Caps map[BudgetScope]Money
}

// MonthSpend is spend for a scope in the calendar month of today, the open day included.
// Month keys come from day-key text, never a calendar.
func MonthSpend(days []DayFile, today string, scope BudgetScope) SpendTotal {
	byKey := daysByKey(days)
	prefix := today[:8]
	lastDay, err := strconv.Atoi(today[len(today)-2:])
	if err != nil {
		lastDay = 1
	}
	records := func(id ProviderID) []*DayRecord {
		out := make([]*DayRecord, 0, lastDay)
		for d := 1; d <= lastDay; d++ {
			out = append(out, byKey[prefix+fmt.Sprintf("%02d", d)].RecordFor(id))
		}
		return out
	}
	if scope.Provider != "" {
		return SumRecords(records(scope.Provider), SpendColumn)
	}
	var total SpendTotal
	for _, id := range BudgetProviders {
		rs := records(id)
		metered := false
		for _, r := range rs {
			if r != nil && r.CostSplit().HasMetered {
				metered = true
				break
			}
		}
		if metered {
			total.Add(SumRecords(rs, SpendColumn))
		}
	}
	return total
}

// DaysByKey indexes day files; the first file for a key wins.
func DaysByKey(days []DayFile) map[string]*DayFile { return daysByKey(days) }

func daysByKey(days []DayFile) map[string]*DayFile {
	byKey := make(map[string]*DayFile, len(days))
	for i := range days {
		if _, seen := byKey[days[i].Date]; !seen {
			byKey[days[i].Date] = &days[i]
		}
	}
	return byKey
}

// RecordFor is the first record for a provider, nil when there is none. A nil day has none.
func (d *DayFile) RecordFor(id ProviderID) *DayRecord {
	if d == nil {
		return nil
	}
	for i := range d.Records {
		if d.Records[i].Provider == id {
			return &d.Records[i]
		}
	}
	return nil
}

// SortedKeys returns map keys in byte order.
func SortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// DayKeyOwner is the one owner of the day key: `yyyy-MM-dd` from a Gregorian calendar in the
// local zone, whatever calendar the locale uses. It never decreases: it is the later of the
// wall clock and the newest key seen. Before 1582-10-15 Foundation's Gregorian calendar is
// Julian and this one is proleptic Gregorian; history has no such days.
type DayKeyOwner struct {
	clock  clock.Clock
	loc    *time.Location
	mu     sync.Mutex
	newest string
}

// NewDayKeyOwner builds an owner on a clock and zone.
func NewDayKeyOwner(c clock.Clock, loc *time.Location) *DayKeyOwner {
	return &DayKeyOwner{clock: c, loc: loc}
}

// Today is the day key for the clock's current time.
func (o *DayKeyOwner) Today() string { return o.KeyFor(o.clock.Now()) }

// KeyFor is the key at an instant, held at the newest key when the wall clock is behind it.
func (o *DayKeyOwner) KeyFor(t time.Time) string {
	wall := t.In(o.loc).Format("2006-01-02")
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.newest > wall {
		return o.newest
	}
	return wall
}

// StartOfDay is the first instant of the day key at t, in the owner's zone.
func (o *DayKeyOwner) StartOfDay(t time.Time) time.Time {
	start, err := time.ParseInLocation("2006-01-02", o.KeyFor(t), o.loc)
	if err != nil {
		return t
	}
	return start
}

// AdvanceNewest raises the newest key; a lower key is ignored.
func (o *DayKeyOwner) AdvanceNewest(key string) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.newest < key {
		o.newest = key
	}
}

// AddDays is the key `days` calendar days after key, ok=false when key is not a date.
func AddDays(key string, days int) (string, bool) {
	t, err := time.Parse("2006-01-02", key)
	if err != nil {
		return "", false
	}
	return t.AddDate(0, 0, days).Format("2006-01-02"), true
}
