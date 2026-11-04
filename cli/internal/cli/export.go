package cli

import (
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/swiftjson"
)

// Export renderers. Spend and API-equivalent value never share a field. backfillChecked, the
// account salt, and budgets are never exported.

const exportSchemaVersion = 1

// CSVTable names one CSV table.
type CSVTable string

const (
	CSVDays     CSVTable = "days"
	CSVAccounts CSVTable = "accounts"
	CSVEvents   CSVTable = "events"
	CSVQuota    CSVTable = "quota"
)

func validCSVTable(s string) bool {
	switch CSVTable(s) {
	case CSVDays, CSVAccounts, CSVEvents, CSVQuota:
		return true
	}
	return false
}

// csvColumns are fixed for schema 1. Columns may be appended; a rename or removal bumps it.
var csvColumns = map[CSVTable][]string{
	CSVDays:     {"date", "provider", "tokens", "costUSD", "valueUSD", "costEstimated", "balanceUSD", "billingModel", "origin", "sealed", "firstSeen", "lastSeen"},
	CSVAccounts: {"date", "provider", "account", "label", "billingModel", "plan"},
	CSVEvents:   {"date", "time", "provider", "kind", "window", "account", "fraction", "notified", "carriedOver"},
	CSVQuota:    {"date", "provider", "account", "window", "peak", "peakResetsAt", "endOfDay"},
}

// exportScope is what one export covers.
type exportScope struct {
	statsRange StatsRange
	provider   *domain.ProviderID
	isEnabled  func(domain.ProviderID) bool
}

func (s exportScope) contains(id *domain.ProviderID) bool {
	if id == nil {
		return s.provider == nil
	}
	return s.provider == nil || *id == *s.provider
}

// exportDay is one range key. A day with no file has a nil zone and every tracked provider as
// a gap. The gap set is the enabled providers seen in range, so a provider never configured is
// not a gap every day. Today is the one unsealed day.
type exportDay struct {
	date     string
	timeZone *string
	sealed   bool
	records  []domain.DayRecord
	events   []domain.UsageEvent
	gaps     []domain.ProviderID
}

func exportDays(days []domain.DayFile, scope exportScope) []exportDay {
	byKey := domain.DaysByKey(days)
	tracked := map[domain.ProviderID]bool{}
	consider := func(id domain.ProviderID) {
		if scope.contains(&id) && (scope.isEnabled == nil || scope.isEnabled(id)) {
			tracked[id] = true
		}
	}
	for _, key := range scope.statsRange.Keys {
		if day := byKey[key]; day != nil {
			for _, r := range day.Records {
				consider(r.Provider)
			}
		}
	}
	if scope.provider != nil {
		consider(*scope.provider)
	}
	out := make([]exportDay, len(scope.statsRange.Keys))
	for i, key := range scope.statsRange.Keys {
		day := exportDay{date: key, sealed: key < scope.statsRange.Today, records: []domain.DayRecord{}, events: []domain.UsageEvent{}, gaps: []domain.ProviderID{}}
		present := map[domain.ProviderID]bool{}
		if file := byKey[key]; file != nil {
			zone := file.TimeZone
			day.timeZone = &zone
			for _, r := range file.Records {
				id := r.Provider
				if scope.contains(&id) {
					day.records = append(day.records, r)
					present[id] = true
				}
			}
			for _, e := range file.Events {
				if scope.contains(e.Provider) {
					day.events = append(day.events, e)
				}
			}
		}
		sort.SliceStable(day.records, func(a, b int) bool { return day.records[a].Provider < day.records[b].Provider })
		for id := range tracked {
			if !present[id] {
				day.gaps = append(day.gaps, id)
			}
		}
		sort.Slice(day.gaps, func(a, b int) bool { return day.gaps[a] < day.gaps[b] })
		out[i] = day
	}
	return out
}

// exportBillingModel is the one model, `mixed` for metered plus subscription, nil otherwise.
func exportBillingModel(r domain.DayRecord) *string {
	models := map[domain.BillingModel]bool{}
	for _, a := range r.Accounts {
		models[a.BillingModel] = true
	}
	switch len(models) {
	case 0:
		return nil
	case 1:
		for m := range models {
			s := string(m)
			return &s
		}
	}
	if len(models) == 2 && models[domain.BillingMetered] && models[domain.BillingSubscription] {
		return strPtr("mixed")
	}
	return nil
}

func optTree[T any](v *T, convert func(T) any) any {
	if v == nil {
		return nil
	}
	return convert(*v)
}

func moneyTree(m domain.Money) any            { return m.String() }
func dateTree(t time.Time) any                { return iso8601(t) }
func stringTree(s string) any                 { return s }
func intTree(n int) any                       { return n }
func providerTreeID(id domain.ProviderID) any { return string(id) }

func recordTree(r domain.DayRecord) map[string]any {
	split := r.CostSplit()
	quota := make(map[string]any, len(r.Quota))
	for name, q := range r.Quota {
		quota[name] = map[string]any{"peak": q.Peak, "peakResetsAt": optTree(q.PeakResetsAt, dateTree), "endOfDay": q.EndOfDay}
	}
	accounts := make([]any, len(r.Accounts))
	for i, a := range r.Accounts {
		accounts[i] = map[string]any{"key": a.Key, "label": a.Label, "billingModel": string(a.BillingModel), "plan": optTree(a.Plan, stringTree)}
	}
	return map[string]any{
		"provider":      string(r.Provider),
		"tokens":        optTree(r.Tokens, intTree),
		"costUSD":       optTree(split.Spend, moneyTree),
		"valueUSD":      optTree(split.Value, moneyTree),
		"costEstimated": r.CostEstimated,
		"balanceUSD":    optTree(r.BalanceUSD, moneyTree),
		"billingModel":  optTree(exportBillingModel(r), stringTree),
		"quota":         quota,
		"accounts":      accounts,
		"origin":        string(r.Origin),
		"firstSeen":     optTree(r.FirstSeen, dateTree),
		"lastSeen":      optTree(r.LastSeen, dateTree),
	}
}

func eventTree(e domain.UsageEvent) map[string]any {
	return map[string]any{
		"time":        iso8601(e.Time),
		"provider":    optTree(e.Provider, providerTreeID),
		"kind":        string(e.Kind),
		"window":      optTree(e.Window, stringTree),
		"account":     optTree(e.Account, stringTree),
		"fraction":    e.Fraction,
		"notified":    e.Notified,
		"carriedOver": e.CarriedOver,
	}
}

func renderExportJSON(days []domain.DayFile, scope exportScope, exportedAt time.Time) string {
	rows := exportDays(days, scope)
	dayTrees := make([]any, len(rows))
	for i, day := range rows {
		records := make([]any, len(day.records))
		for j, r := range day.records {
			records[j] = recordTree(r)
		}
		events := make([]any, len(day.events))
		for j, e := range day.events {
			events[j] = eventTree(e)
		}
		gaps := make([]any, len(day.gaps))
		for j, g := range day.gaps {
			gaps[j] = string(g)
		}
		dayTrees[i] = map[string]any{
			"date": day.date, "timeZone": optTree(day.timeZone, stringTree), "sealed": day.sealed,
			"records": records, "events": events, "gaps": gaps,
		}
	}
	keys := scope.statsRange.Keys
	doc := map[string]any{
		"schemaVersion": exportSchemaVersion,
		"exportedAt":    iso8601(exportedAt),
		"range":         map[string]any{"from": keys[0], "to": keys[len(keys)-1]},
		"days":          dayTrees,
	}
	return swiftjson.Encode(doc, prettyJSON) + "\n"
}

func cellInt(v *int) string {
	if v == nil {
		return ""
	}
	return strconv.Itoa(*v)
}
func cellText(v *string) string {
	if v == nil {
		return ""
	}
	return *v
}
func cellMoney(v *domain.Money) string {
	if v == nil {
		return ""
	}
	return v.String()
}
func cellDate(v *time.Time) string {
	if v == nil {
		return ""
	}
	return iso8601(*v)
}
func cellDouble(v float64) string { return swiftjson.DoubleDescription(v) }
func cellBool(v bool) string      { return strconv.FormatBool(v) }
func cellProvider(v *domain.ProviderID) string {
	if v == nil {
		return ""
	}
	return string(*v)
}

// csvEscape is RFC 4180 quoting for a field holding a comma, quote, or line break.
func csvEscape(field string) string {
	if !strings.ContainsAny(field, ",\"\n\r\v\f\u0085  ") {
		return field
	}
	return `"` + strings.ReplaceAll(field, `"`, `""`) + `"`
}

// renderExportCSV: a gap is a missing row, an unknown value an empty cell, money a plain number.
func renderExportCSV(days []domain.DayFile, scope exportScope, table CSVTable) string {
	rows := [][]string{csvColumns[table]}
	for _, day := range exportDays(days, scope) {
		switch table {
		case CSVDays:
			for _, r := range day.records {
				split := r.CostSplit()
				rows = append(rows, []string{day.date, string(r.Provider), cellInt(r.Tokens), cellMoney(split.Spend), cellMoney(split.Value),
					cellBool(r.CostEstimated), cellMoney(r.BalanceUSD), cellText(exportBillingModel(r)), string(r.Origin),
					cellBool(day.sealed), cellDate(r.FirstSeen), cellDate(r.LastSeen)})
			}
		case CSVAccounts:
			for _, r := range day.records {
				for _, a := range r.Accounts {
					rows = append(rows, []string{day.date, string(r.Provider), a.Key, a.Label, string(a.BillingModel), cellText(a.Plan)})
				}
			}
		case CSVEvents:
			for _, e := range day.events {
				rows = append(rows, []string{day.date, iso8601(e.Time), cellProvider(e.Provider), string(e.Kind), cellText(e.Window),
					cellText(e.Account), cellDouble(e.Fraction), cellBool(e.Notified), cellBool(e.CarriedOver)})
			}
		case CSVQuota:
			for _, r := range day.records {
				rows = append(rows, quotaRows(day.date, r)...)
			}
		}
	}
	lines := make([]string, len(rows))
	for i, row := range rows {
		cells := make([]string, len(row))
		for j, field := range row {
			cells[j] = csvEscape(field)
		}
		lines[i] = strings.Join(cells, ",")
	}
	return strings.Join(lines, "\n") + "\n"
}

// quotaRows: record windows have no account; account windows name the account key.
func quotaRows(date string, r domain.DayRecord) [][]string {
	var rows [][]string
	add := func(account string, windows map[string]domain.QuotaDay) {
		for _, name := range domain.SortedKeys(windows) {
			q := windows[name]
			rows = append(rows, []string{date, string(r.Provider), account, name, cellDouble(q.Peak), cellDate(q.PeakResetsAt), cellDouble(q.EndOfDay)})
		}
	}
	add("", r.Quota)
	for _, a := range r.Accounts {
		add(a.Key, a.Quota)
	}
	return rows
}
