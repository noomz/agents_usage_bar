package cli

import (
	"fmt"
	"math"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

const (
	defaultStatsDays = 14
	maxTrendCells    = 30
)

// StatsRange is the day keys `aub stats` covers. Today is the open day.
type StatsRange struct {
	Keys  []string
	Today string
}

func (r StatsRange) isTodayOpen() bool { return r.Keys[len(r.Keys)-1] == r.Today }

// bucketSize is days per trend character: 1 up to 30 days, else the smallest bucket that fits.
func (r StatsRange) bucketSize() int {
	return max(1, (len(r.Keys)+maxTrendCells-1)/maxTrendCells)
}

func minKey(a, b string) string {
	if b < a {
		return b
	}
	return a
}

func addedOr(key string, days int, fallback string) string {
	if out, ok := domain.AddDays(key, days); ok {
		return out
	}
	return fallback
}

// ResolveRange applies the flags to today. An --until later than today ends at today. With
// oldest, no --days and no --since start at it instead of 14 days back, because export covers
// every retained day by default.
func ResolveRange(today string, days *int, since, until, oldest *string) (StatsRange, *ParseError) {
	var first, last string
	switch {
	case since != nil && until != nil:
		if days != nil {
			return StatsRange{}, unexpectedArgument("--days")
		}
		first, last = *since, minKey(*until, today)
	case since != nil:
		first, last = *since, today
		if days != nil {
			last = minKey(addedOr(*since, *days-1, today), today)
		}
	default:
		last = today
		if until != nil {
			last = minKey(*until, today)
		}
		if days == nil && oldest != nil {
			first = minKey(*oldest, last)
		} else {
			n := defaultStatsDays
			if days != nil {
				n = *days
			}
			first = addedOr(last, -(n - 1), last)
		}
	}
	if first > last {
		return StatsRange{}, emptyRange(first, last)
	}
	keys := []string{first}
	for {
		next, ok := domain.AddDays(keys[len(keys)-1], 1)
		if !ok || next > last {
			break
		}
		keys = append(keys, next)
	}
	return StatsRange{Keys: keys, Today: today}, nil
}

var dayKeyShape = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)

// IsDayKey is true for a real yyyy-MM-dd date.
func IsDayKey(text string) bool {
	if !dayKeyShape.MatchString(text) {
		return false
	}
	t, err := time.Parse("2006-01-02", text)
	return err == nil && t.Year() >= 1
}

type statsKind int

const (
	kindMetered statsKind = iota
	kindSubscription
	kindMixed
	kindLocal
)

// providerStats is one provider's history over a range.
type providerStats struct {
	id      domain.ProviderID
	kind    statsKind
	records []*domain.DayRecord
	plans   []string
}

func newProviderStats(id domain.ProviderID, records []*domain.DayRecord) providerStats {
	metered, subscription, anyAccount, allLocal := false, false, false, true
	planSet := map[string]bool{}
	for _, r := range records {
		if r == nil {
			continue
		}
		for _, a := range r.Accounts {
			anyAccount = true
			switch a.BillingModel {
			case domain.BillingMetered:
				metered = true
				allLocal = false
			case domain.BillingSubscription:
				subscription = true
				allLocal = false
				if a.Plan != nil {
					planSet[*a.Plan] = true
				}
			}
		}
	}
	kind := kindMetered
	switch {
	case id.IsLocalRuntime() || (anyAccount && allLocal):
		kind = kindLocal
	case metered && subscription:
		kind = kindMixed
	case subscription:
		kind = kindSubscription
	}
	plans := domain.SortedKeys(planSet)
	return providerStats{id, kind, records, plans}
}

func (p providerStats) seenDays() int {
	n := 0
	for _, r := range p.records {
		if r != nil {
			n++
		}
	}
	return n
}

func (p providerStats) hasSpend() bool { return p.kind == kindMetered || p.kind == kindMixed }
func (p providerStats) spend() domain.SpendTotal {
	return domain.SumRecords(p.records, domain.SpendColumn)
}
func (p providerStats) value() domain.SpendTotal {
	return domain.SumRecords(p.records, domain.ValueColumn)
}

func (p providerStats) tokens() *int {
	total, known := 0, false
	for _, r := range p.records {
		if r != nil && r.Tokens != nil {
			total += *r.Tokens
			known = true
		}
	}
	if !known {
		return nil
	}
	return &total
}

type peakValue struct {
	fraction float64
	window   string
}

// recordPeak is a record's highest window peak; ties go to the first window name.
func recordPeak(r domain.DayRecord) *peakValue {
	var best *peakValue
	for _, name := range domain.SortedKeys(r.Quota) {
		peak := r.Quota[name].Peak
		if best == nil || best.fraction < peak {
			best = &peakValue{peak, name}
		}
	}
	return best
}

func (p providerStats) peak() *peakValue {
	var best *peakValue
	for _, r := range p.records {
		if r == nil {
			continue
		}
		if v := recordPeak(*r); v != nil && (best == nil || best.fraction < v.fraction) {
			best = v
		}
	}
	return best
}

type trendKind int

const (
	trendValue trendKind = iota
	trendPresent
	trendGap
	trendNoValue
	trendIncomplete
)

type trendCell struct {
	kind  trendKind
	value float64
}

// trend is one cell per bucket, oldest first, with the newest bucket ending at the last key.
// Metered rows plot spend, subscription and mixed rows the day's highest peak, local rows
// presence. A recorded day without that value is noValue, never a gap.
func (p providerStats) trend(bucketSize int) []trendCell {
	type day struct {
		recorded, known bool
		value           float64
	}
	daily := make([]day, len(p.records))
	for i, r := range p.records {
		if r == nil {
			continue
		}
		daily[i].recorded = true
		switch p.kind {
		case kindMetered:
			if spend := r.CostSplit().Spend; spend != nil {
				daily[i].known, daily[i].value = true, spend.Amount.Float64()
			}
		case kindSubscription, kindMixed:
			if v := recordPeak(*r); v != nil {
				daily[i].known, daily[i].value = true, v.fraction
			}
		case kindLocal:
			daily[i].known, daily[i].value = true, 1
		}
	}
	var buckets [][]day
	for end := len(daily); end > 0; {
		start := max(0, end-bucketSize)
		buckets = append([][]day{daily[start:end]}, buckets...)
		end = start
	}
	cells := make([]trendCell, len(buckets))
	for i, bucket := range buckets {
		recorded, known := 0, 0
		sum, top := 0.0, math.Inf(-1)
		for _, d := range bucket {
			if d.recorded {
				recorded++
			}
			if d.known {
				known++
				sum += d.value
				top = math.Max(top, d.value)
			}
		}
		switch {
		case recorded == 0:
			cells[i] = trendCell{kind: trendGap}
		case p.kind == kindLocal:
			cells[i] = trendCell{kind: trendPresent}
		case known == 0 && recorded == len(bucket):
			cells[i] = trendCell{kind: trendNoValue}
		case known < len(bucket):
			cells[i] = trendCell{kind: trendIncomplete}
		case p.kind == kindMetered:
			cells[i] = trendCell{kind: trendValue, value: sum}
		default:
			cells[i] = trendCell{kind: trendValue, value: top}
		}
	}
	return cells
}

// collectStats is every provider with a record in range, in provider-order. Local runtimes
// appear only when includeLocal.
func collectStats(days []domain.DayFile, r StatsRange, includeLocal bool, only *domain.ProviderID, order []domain.ProviderID) []providerStats {
	byKey := domain.DaysByKey(days)
	ids := map[domain.ProviderID]bool{}
	for _, key := range r.Keys {
		if day := byKey[key]; day != nil {
			for _, rec := range day.Records {
				ids[rec.Provider] = true
			}
		}
	}
	var stats []providerStats
	for id := range ids {
		if only != nil && id != *only {
			continue
		}
		records := make([]*domain.DayRecord, len(r.Keys))
		for i, key := range r.Keys {
			records[i] = byKey[key].RecordFor(id)
		}
		p := newProviderStats(id, records)
		if includeLocal || only != nil || p.kind != kindLocal {
			stats = append(stats, p)
		}
	}
	sort.Slice(stats, func(i, j int) bool { return stats[i].id < stats[j].id })
	return domain.OrderProviders(stats, func(p providerStats) domain.ProviderID { return p.id }, order)
}

const noHistoryText = "No history yet. The app records from first launch; backfill runs in the background"

// segment is a run of text in one style. A band of -1 means no band.
type segmentStyle int

const (
	stylePlain segmentStyle = iota
	styleDim
	styleBand
)

type segment struct {
	text  string
	style segmentStyle
	band  domain.QuotaBand
}

type cell struct {
	segments []segment
	right    bool
}

func plainCell(text string) cell { return cell{segments: []segment{{text: text}}} }
func rightCell(text string) cell { return cell{segments: []segment{{text: text}}, right: true} }
func dimCell(text string) cell {
	return cell{segments: []segment{{text: text, style: styleDim}}}
}
func dimRight(text string) cell {
	return cell{segments: []segment{{text: text, style: styleDim}}, right: true}
}

func (c cell) width() int {
	w := 0
	for _, s := range c.segments {
		w += chars(s.text)
	}
	return w
}

func (c cell) painted(color bool) string {
	var b strings.Builder
	for _, s := range c.segments {
		switch s.style {
		case stylePlain:
			b.WriteString(s.text)
		case styleDim:
			b.WriteString(dim(s.text, color && s.text != ""))
		case styleBand:
			b.WriteString(paint(s.text, s.band, color))
		}
	}
	return b.String()
}

// table is columns two spaces apart, padded outside the ANSI spans, trailing space trimmed.
func table(rows [][]cell, color bool) []string {
	columns := 0
	for _, row := range rows {
		columns = max(columns, len(row))
	}
	widths := make([]int, columns)
	for _, row := range rows {
		for i, c := range row {
			widths[i] = max(widths[i], c.width())
		}
	}
	out := make([]string, len(rows))
	for r, row := range rows {
		var b strings.Builder
		for i, c := range row {
			fill := spaces(widths[i] - c.width())
			if i > 0 {
				b.WriteString("  ")
			}
			if c.right {
				b.WriteString(fill + c.painted(color))
			} else {
				b.WriteString(c.painted(color) + fill)
			}
		}
		out[r] = trimTrailingSpaces(b.String())
	}
	return out
}

// legend lists only the markers seen while rendering.
type legend struct {
	estimated, gap, noValue, incomplete bool
}

func (l legend) line(color bool) []string {
	var entries []string
	if l.estimated {
		entries = append(entries, "~ estimated")
	}
	if l.gap {
		entries = append(entries, "· gap")
	}
	if l.noValue {
		entries = append(entries, "? no value")
	}
	if l.incomplete {
		entries = append(entries, "! incomplete")
	}
	if len(entries) == 0 {
		return nil
	}
	return []string{dim(strings.Join(entries, "  "), color)}
}

func statsHeader(r StatsRange, bucketed bool) string {
	text := fmt.Sprintf("%s – %s · %d days", r.Keys[0], r.Keys[len(r.Keys)-1], len(r.Keys))
	if r.isTodayOpen() {
		text += " (today open)"
	}
	if bucketed && r.bucketSize() > 1 {
		text += fmt.Sprintf(" · trend 1 char = %d days", r.bucketSize())
	}
	return text
}

func statsName(id domain.ProviderID) string {
	if label, ok := shortLabels[id]; ok {
		return label
	}
	return id.DisplayHint()
}

// amountText: `~` before an estimated amount, `!` after an incomplete one, `?!` when nothing
// is known. Unknown is never shown as zero.
func amountText(total domain.SpendTotal, l *legend) string {
	if total.Amount == nil {
		l.incomplete = true
		return "?!"
	}
	text := usd(*total.Amount)
	if total.Estimated {
		l.estimated = true
		text = "~" + text
	}
	if total.Incomplete {
		l.incomplete = true
		text += "!"
	}
	return text
}

// spendCell: spend for metered rows, the plan dimmed for subscription rows, metered spend plus
// `+plan` for mixed rows. Value never shows here.
func spendCell(p providerStats, l *legend) cell {
	plans := "subscription"
	if len(p.plans) > 0 {
		plans = strings.Join(p.plans, "/")
	}
	switch p.kind {
	case kindSubscription:
		return dimCell(plans)
	case kindMixed:
		return cell{segments: []segment{{text: amountText(p.spend(), l)}, {text: " +" + plans, style: styleDim}}}
	}
	return plainCell(amountText(p.spend(), l))
}

func totalRow(metered []providerStats, l *legend) []cell {
	if len(metered) == 0 {
		return []cell{plainCell("total"), {segments: []segment{{text: usd(decimal.Decimal{})}, {text: " no metered accounts", style: styleDim}}}}
	}
	var sum domain.SpendTotal
	for _, p := range metered {
		sum.Add(p.spend())
	}
	return []cell{plainCell("total"), plainCell(amountText(sum, l))}
}

func totalCell(total domain.SpendTotal, isValue bool, l *legend) cell {
	total.Estimated = total.Estimated || isValue
	text := amountText(total, l)
	if isValue {
		return dimRight(text)
	}
	return rightCell(text)
}

// peakCell is `92% 5h`, coloured by the severity bands.
func peakCell(peak *peakValue) cell {
	if peak == nil {
		return plainCell("")
	}
	window := ""
	if peak.window != domain.ProviderQuotaWindow {
		window = " " + peak.window
	}
	return cell{segments: []segment{{text: percent(peak.fraction) + window, style: styleBand, band: severityOf(peak.fraction).band()}}}
}

var sparks = []string{"▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"}

// trendCellText: `$` then spend scaled to the row's highest bucket, `%` then the quota peak on
// an absolute scale, or presence for a local row. `·` is a gap, `!` a bucket holding one.
func trendText(p providerStats, bucketSize int, l *legend) cell {
	cells := p.trend(bucketSize)
	top := 0.0
	for _, c := range cells {
		if c.kind == trendValue {
			top = math.Max(top, c.value)
		}
	}
	mark := "%"
	switch p.kind {
	case kindMetered:
		mark = "$"
	case kindLocal:
		mark = " "
	}
	segments := []segment{{text: mark, style: styleDim}}
	for _, c := range cells {
		switch c.kind {
		case trendValue:
			level := c.value
			if p.kind == kindMetered {
				level = 0
				if top > 0 {
					level = c.value / top
				}
			}
			index := 0
			if level > 0 {
				index = min(len(sparks)-1, int(math.Ceil(level*float64(len(sparks))))-1)
			}
			segments = append(segments, segment{text: sparks[index]})
		case trendPresent:
			segments = append(segments, segment{text: "█"})
		case trendGap:
			l.gap = true
			segments = append(segments, segment{text: "·", style: styleDim})
		case trendNoValue:
			l.noValue = true
			segments = append(segments, segment{text: "?", style: styleDim})
		case trendIncomplete:
			l.incomplete = true
			segments = append(segments, segment{text: "!"})
		}
	}
	return cell{segments: segments}
}

func eventLabel(e domain.UsageEvent) string {
	label := domain.EventLabels[e.Kind]
	if e.Window != nil {
		return label + " " + *e.Window
	}
	return label
}

var monthNames = []string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

func monthLabel(key string) string {
	t, err := time.Parse("2006-01-02", key)
	if err != nil {
		return key
	}
	return monthNames[t.Month()-1]
}

func budgetLines(budgets domain.BudgetConfig, monthDays []domain.DayFile, today string, l *legend) []string {
	month := monthLabel(today)
	var out []string
	for _, scope := range domain.AllBudgetScopes() {
		cap, ok := budgets.Caps[scope]
		if !ok {
			continue
		}
		prefix := ""
		if scope.Provider != "" {
			prefix = statsName(scope.Provider) + " "
		}
		spend := domain.MonthSpend(monthDays, today, scope)
		out = append(out, prefix+month+" spend "+amountText(spend, l)+" / "+usd(cap.Amount)+" budget")
	}
	return out
}

func renderStatsSummary(days []domain.DayFile, r StatsRange, includeLocal bool, order []domain.ProviderID, budgets domain.BudgetConfig, monthDays []domain.DayFile, color bool) string {
	providers := collectStats(days, r, includeLocal, nil, order)
	out := []string{statsHeader(r, true)}
	if len(providers) == 0 {
		out = append(out, "No history in this range.")
		return strings.Join(out, "\n") + "\n"
	}
	var l legend
	rows := [][]cell{{dimCell("provider"), dimCell("spend"), dimRight("tokens"), dimCell("peak"), dimRight("days"), dimCell("trend")}}
	var metered []providerStats
	for _, p := range providers {
		if p.hasSpend() {
			metered = append(metered, p)
		}
		dayCount := rightCell(fmt.Sprintf("%d/%d", p.seenDays(), len(r.Keys)))
		trend := trendText(p, r.bucketSize(), &l)
		if p.kind == kindLocal {
			rows = append(rows, []cell{plainCell(statsName(p.id)), dimCell(fmt.Sprintf("used %d/%d days", p.seenDays(), len(r.Keys))), plainCell(""), plainCell(""), dayCount, trend})
			continue
		}
		rows = append(rows, []cell{plainCell(statsName(p.id)), spendCell(p, &l), rightCell(optSITokens(p.tokens())), peakCell(p.peak()), dayCount, trend})
	}
	rows = append(rows, totalRow(metered, &l))
	out = append(out, table(rows, color)...)
	out = append(out, budgetLines(budgets, monthDays, r.Today, &l)...)
	out = append(out, l.line(color)...)
	return strings.Join(out, "\n") + "\n"
}

func optSITokens(n *int) string {
	if n == nil {
		return ""
	}
	return siTokens(*n)
}

func renderStatsProvider(days []domain.DayFile, id domain.ProviderID, r StatsRange, color bool) string {
	only := id
	found := collectStats(days, r, true, &only, nil)
	if len(found) == 0 {
		return statsHeader(r, false) + "\nNo " + statsName(id) + " history in this range.\n"
	}
	p := found[0]
	byKey := domain.DaysByKey(days)
	var l legend
	head := statsName(id) + " · " + statsHeader(r, false)
	if p.kind == kindLocal {
		head += fmt.Sprintf(" · used %d/%d days", p.seenDays(), len(r.Keys))
	}
	out := []string{head}

	type moneyColumn struct {
		title   string
		column  domain.CostColumn
		isValue bool
	}
	var columns []moneyColumn
	spendCol := moneyColumn{"spend", domain.SpendColumn, false}
	valueCol := moneyColumn{"value", domain.ValueColumn, true}
	switch p.kind {
	case kindMetered:
		columns = []moneyColumn{spendCol}
	case kindSubscription:
		columns = []moneyColumn{valueCol}
	case kindMixed:
		columns = []moneyColumn{spendCol, valueCol}
	}

	header := []cell{dimCell("date")}
	if p.kind == kindLocal {
		header = append(header, dimCell("used"))
	} else {
		for _, c := range columns {
			header = append(header, dimRight(c.title))
		}
		header = append(header, dimRight("tokens"), dimCell("peak"), dimCell("events"), dimCell("markers"))
	}
	rows := [][]cell{header}

	for i, key := range r.Keys {
		record := p.records[i]
		if record == nil {
			l.gap = true
			rows = append(rows, []cell{plainCell(key), dimCell("·")})
			continue
		}
		if p.kind == kindLocal {
			rows = append(rows, []cell{plainCell(key), plainCell("used")})
			continue
		}
		split := record.CostSplit()
		var markers []string
		cells := []cell{plainCell(key)}
		for _, c := range columns {
			if !c.column.Applies(split) {
				cells = append(cells, rightCell(""))
				continue
			}
			amount := c.column.Amount(split)
			if amount == nil {
				cells = append(cells, rightCell("?"))
				if !containsStr(markers, "!") {
					markers = append(markers, "!")
				}
				l.incomplete = true
				continue
			}
			estimated := c.isValue || split.Estimated
			text := usd(amount.Amount)
			if estimated {
				l.estimated = true
				text = "~" + text
			}
			if c.isValue {
				cells = append(cells, dimRight(text))
			} else {
				cells = append(cells, rightCell(text))
			}
		}
		if record.Origin == domain.OriginBackfilled {
			markers = append(markers, "backfilled")
		}
		if key == r.Today {
			markers = append(markers, "open")
		}
		var events []string
		if day := byKey[key]; day != nil {
			for _, e := range day.Events {
				if e.Provider != nil && *e.Provider == id {
					events = append(events, eventLabel(e))
				}
			}
		}
		cells = append(cells, rightCell(optSITokens(record.Tokens)), peakCell(recordPeak(*record)),
			plainCell(strings.Join(events, ", ")), plainCell(strings.Join(markers, " ")))
		rows = append(rows, cells)
	}
	if p.kind != kindLocal {
		total := []cell{plainCell("total")}
		for _, c := range columns {
			amount := p.spend()
			if c.isValue {
				amount = p.value()
			}
			total = append(total, totalCell(amount, c.isValue, &l))
		}
		total = append(total, rightCell(optSITokens(p.tokens())))
		rows = append(rows, total)
	}
	out = append(out, table(rows, color)...)
	out = append(out, l.line(color)...)
	return strings.Join(out, "\n") + "\n"
}

func containsStr(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}
