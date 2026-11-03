package cli

import (
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

// View is which text view a theme renders.
type View int

// The views.
const (
	ViewUsage View = iota
	ViewQuota
)

// Base column widths. Their total is the output width when no terminal width is known.
const (
	baseNameWidth = 12
	baseBarWidth  = 10
	minBarWidth   = 5
	maxBarWidth   = 20
	minNameWidth  = 4
)

type severity int

const (
	severityNormal severity = iota
	severityWarning
	severityCritical
)

// severityOf bands on the displayed whole percent, so glyph, colour, and number agree.
func severityOf(fraction float64) severity {
	pct := int(math.Round(fraction * 100))
	switch {
	case pct >= 80:
		return severityCritical
	case pct >= 50:
		return severityWarning
	}
	return severityNormal
}

func (s severity) glyph() string {
	switch s {
	case severityCritical:
		return "▲"
	case severityWarning:
		return "△"
	}
	return " "
}

func (s severity) band() domain.QuotaBand {
	switch s {
	case severityCritical:
		return domain.BandCritical
	case severityWarning:
		return domain.BandWarning
	}
	return domain.BandHealthy
}

// gauge is a bar with a percent, or text in the bar's place. Text is never counted in the
// severity line.
type gauge struct {
	isBar    bool
	fraction float64
	text     string
}

func barGauge(f float64) gauge { return gauge{isBar: true, fraction: f} }
func textGauge(s string) gauge { return gauge{text: s} }

// line is a data row, or a problem row when problem is non-empty.
type line struct {
	name    string
	gauge   gauge
	label   string
	reset   *string
	money   *string
	problem string
}

func problemLine(name, word string) line { return line{name: name, problem: word} }

// renderCompact is the `compact` theme: a two-line header, one line per provider showing its
// most-used window, errors in place, and one `local` line.
func renderCompact(report UsageReport, view View, color bool, width *int, loc *time.Location, order []domain.ProviderID) string {
	visible := make([]ProviderReport, 0, len(report.Providers))
	for _, p := range report.Providers {
		if p.Status.Kind != domain.StatusDisabled {
			visible = append(visible, p)
		}
	}
	providers := domain.OrderProviders(visible, func(p ProviderReport) domain.ProviderID { return p.ID }, order)
	now := report.AsOf

	var lines []line
	var locals []ProviderReport
	for _, p := range providers {
		if p.IsLocal {
			locals = append(locals, p)
			continue
		}
		if view == ViewUsage {
			lines = append(lines, usageLines(p, now)...)
		} else {
			lines = append(lines, quotaLines(p, now)...)
		}
	}
	var local []string
	if view == ViewUsage {
		local = localItems(locals)
	}

	layout := fitLayout(lines, width)
	var out []string
	if view == ViewUsage {
		out = append(out, headerTotals(report, loc))
	}
	out = append(out, severityLine(lines))
	if len(providers) == 0 {
		message := "no providers enabled"
		if report.Source == SourceCached {
			message = "no cached data yet — run aub --live"
		}
		out = append(out, dim(message, color))
	}
	for _, l := range lines {
		out = append(out, layout.render(l, color))
	}
	if len(local) > 0 {
		w := layout.totalWidth()
		if width != nil {
			w = *width
		}
		out = append(out, localLines(local, w)...)
	}
	return strings.Join(out, "\n") + "\n"
}

func headerTotals(report UsageReport, loc *time.Location) string {
	totals := report.Totals()
	return "today " + usd(totals.CostUSD) + " spent · " + siTokens(totals.Tokens) + " tok · " + report.AsOf.In(loc).Format("15:04")
}

func severityLine(lines []line) string {
	critical, warning, unavailable := 0, 0, 0
	for _, l := range lines {
		switch {
		case l.problem != "":
			unavailable++
		case l.gauge.isBar:
			switch severityOf(l.gauge.fraction) {
			case severityCritical:
				critical++
			case severityWarning:
				warning++
			}
		}
	}
	return fmt.Sprintf("%d at ≥80%% · %d at 50–79%% · %d unavailable", critical, warning, unavailable)
}

// siTokens is `232.4M`; below 1000 the plain count. It rounds before picking the unit so
// 999_950 is `1.0M`, not `1000.0K`.
func siTokens(n int) string {
	if n < 1_000 {
		return strconv.Itoa(n)
	}
	for _, unit := range []struct {
		scale float64
		name  string
	}{{1e3, "K"}, {1e6, "M"}} {
		x := math.Round(float64(n)/unit.scale*10) / 10
		if x < 1_000 {
			return fmt.Sprintf("%.1f%s", x, unit.name)
		}
	}
	return fmt.Sprintf("%.1fB", float64(n)/1e9)
}

func strPtr(s string) *string { return &s }

func usageLines(p ProviderReport, now time.Time) []line {
	name := labelFor(p)
	if p.Snapshot == nil {
		return []line{problemLine(name, problemWordOr(p, "unavailable"))}
	}
	snap := *p.Snapshot
	var lines []line
	switch {
	case p.ID == domain.Claude && len(snap.Accounts) > 0:
		// Header row with the combined cost, then one indented row per account.
		lines = []line{{name: name, gauge: textGauge(""), money: spent(snap.CostTodayUSD)}}
		for _, a := range accountsInOrder(snap) {
			g, windowLabel, reset := claudeWindow(a.value.QuotaGlance().Active, now)
			lines = append(lines, line{name: a.name, gauge: g, label: windowLabel, reset: reset, money: spent(a.value.CostTodayUSD)})
		}
	case p.ID == domain.Codex && len(snap.Accounts) >= 2:
		// Header spend only. Each child is its 5-hour primary, not max(primary, secondary).
		lines = []line{{name: name, gauge: textGauge(""), money: spent(snap.CostTodayUSD)}}
		for _, a := range codexAccountsInOrder(snap) {
			lines = append(lines, codexUsageLine(a, p, snap, now))
		}
	default:
		g, windowLabel, reset := worstWindow(p, snap, now)
		lines = []line{{name: name, gauge: g, label: windowLabel, reset: reset, money: money(p, snap)}}
	}
	if word := problemWord(p); word != nil {
		lines = append(lines, problemLine(name, *word))
	}
	return lines
}

func hasUtilization(windows []domain.QuotaWindow) bool {
	for _, w := range windows {
		if w.Utilization != nil {
			return true
		}
	}
	return false
}

// worstWindow is a provider's most-used window as gauge, label, and reset column.
func worstWindow(p ProviderReport, snap domain.UsageSnapshot, now time.Time) (gauge, string, *string) {
	if p.ID == domain.Claude {
		if glance := snap.QuotaGlance(); glance.HasAnyWindow() {
			return claudeWindow(glance.Active, now)
		}
	}
	if p.ID == domain.OpenRouter {
		if snap.Quota == nil {
			return textGauge("no limit"), "", nil
		}
		return barGauge(snap.Quota.Fraction()), "credits", nil
	}
	if p.ID == domain.Grok && snap.Quota == nil && !hasUtilization(snap.QuotaWindows) {
		if snap.CostTodayUSD != nil {
			return textGauge(usd(*snap.CostTodayUSD) + " spent"), "", nil
		}
		if snap.BalanceUSD != nil {
			return textGauge(usd(*snap.BalanceUSD) + " left"), "", nil
		}
	}
	var worst *domain.QuotaWindow
	for i := range snap.QuotaWindows {
		w := &snap.QuotaWindows[i]
		if w.Utilization != nil && (worst == nil || *worst.Utilization < *w.Utilization) {
			worst = w
		}
	}
	if worst != nil {
		return barGauge(*worst.Utilization), windowLabel(*worst, p, snap), resetColumn(worst.ResetsAt, now)
	}
	if q := snap.DisplayedQuota(); q != nil {
		return barGauge(q.Fraction()), "", nil
	}
	return textGauge("no limit"), "", nil
}

func claudeWindow(w *domain.GlanceWindow, now time.Time) (gauge, string, *string) {
	if w == nil || w.Utilization == nil {
		return textGauge("no limit"), "", nil
	}
	return barGauge(*w.Utilization), string(w.Period), resetColumn(w.ResetsAt, now)
}

func resetColumn(date *time.Time, now time.Time) *string {
	text := "↻ unknown"
	if date != nil {
		text = "↻ " + resetCountdown(*date, now)
	}
	return &text
}

// resetCountdown has no `Resets ` prefix: `2h 50m`, `3d 8h`, `<1m`, `now`.
func resetCountdown(until, now time.Time) string {
	interval := until.Sub(now).Seconds()
	if interval <= 0 {
		return "now"
	}
	return domain.ResetCompact(interval)
}

// windowLabel is length-derived (`5h`, `7d`) when known, Grok's billing period, else the name.
func windowLabel(w domain.QuotaWindow, p ProviderReport, snap domain.UsageSnapshot) string {
	if w.Duration != nil && *w.Duration > 0 {
		s := int(*w.Duration)
		if s%86_400 == 0 {
			return strconv.Itoa(s/86_400) + "d"
		}
		if s%3_600 == 0 {
			return strconv.Itoa(s/3_600) + "h"
		}
		return strconv.Itoa(max(1, s/60)) + "m"
	}
	if p.ID == domain.Grok {
		if period := snap.Raw["period"]; period != "" && chars(period) <= 10 {
			return period
		}
	}
	if p.ID == domain.Gemini {
		return shortGeminiModel(w.Name)
	}
	return w.Name
}

// shortGeminiModel turns `gemini-2.5-flash-lite` into `2.5-lite`.
func shortGeminiModel(model string) string {
	s := strings.TrimPrefix(model, "gemini-")
	if strings.HasSuffix(s, "-flash-lite") {
		s = strings.TrimSuffix(s, "-flash-lite") + "-lite"
	}
	if s == "" {
		return model
	}
	return s
}

func money(p ProviderReport, snap domain.UsageSnapshot) *string {
	left := func() *string {
		if snap.BalanceUSD == nil {
			return nil
		}
		return strPtr(usd(*snap.BalanceUSD) + " left")
	}
	switch p.ID {
	case domain.Grok:
		if snap.Quota != nil || hasUtilization(snap.QuotaWindows) {
			if s := spent(snap.CostTodayUSD); s != nil {
				return s
			}
			if l := left(); l != nil {
				return l
			}
			return strPtr("no cost data")
		}
		if snap.CostTodayUSD != nil {
			return left()
		}
		if l := left(); l != nil {
			return l
		}
		return strPtr("no cost data")
	case domain.OpenRouter:
		return left()
	}
	return spent(snap.CostTodayUSD)
}

func spent(cost *decimal.Decimal) *string {
	if cost == nil {
		return nil
	}
	return strPtr(usd(*cost) + " spent")
}

// problemWord names a provider in trouble, nil when healthy.
func problemWord(p ProviderReport) *string {
	degraded := p.Snapshot != nil && p.Snapshot.Raw["note"] == domain.DegradedNote
	switch p.Status.Kind {
	case domain.StatusUnauthenticated:
		return strPtr("unauthenticated")
	case domain.StatusStale:
		return strPtr("stale")
	case domain.StatusError, domain.StatusNotRunning:
		return strPtr("unavailable")
	}
	if degraded || p.Snapshot == nil {
		return strPtr("unavailable")
	}
	return nil
}

func problemWordOr(p ProviderReport, fallback string) string {
	if w := problemWord(p); w != nil {
		return *w
	}
	return fallback
}

type namedAccount struct {
	name  string
	value domain.AccountUsage
}

func sortedAccounts(snap domain.UsageSnapshot, marked *string) []namedAccount {
	accounts := make([]domain.AccountUsage, len(snap.Accounts))
	copy(accounts, snap.Accounts)
	sort.SliceStable(accounts, func(i, j int) bool { return accounts[i].Name < accounts[j].Name })
	out := make([]namedAccount, len(accounts))
	for i, a := range accounts {
		name := "  " + a.Name
		if marked != nil && a.Name == *marked {
			name += "●"
		}
		out[i] = namedAccount{name, a}
	}
	return out
}

// markedCodexAccount is the login with the highest primary, ties going to the sooner reset,
// then the lower name. A login with no primary fraction gets no mark.
func markedCodexAccount(accounts []domain.AccountUsage) *string {
	var best *string
	var bestFraction float64
	var bestReset time.Time
	for _, a := range accounts {
		var primary *domain.QuotaWindow
		for i := range a.QuotaWindows {
			if a.QuotaWindows[i].Name == "primary" {
				primary = &a.QuotaWindows[i]
				break
			}
		}
		if primary == nil || primary.Utilization == nil {
			continue
		}
		reset := time.Date(4001, 1, 1, 0, 0, 0, 0, time.UTC)
		if primary.ResetsAt != nil {
			reset = *primary.ResetsAt
		}
		f := *primary.Utilization
		better := best == nil || f > bestFraction ||
			(f == bestFraction && (reset.Before(bestReset) || (reset.Equal(bestReset) && a.Name < *best)))
		if better {
			name := a.Name
			best, bestFraction, bestReset = &name, f, reset
		}
	}
	return best
}

func codexAccountsInOrder(snap domain.UsageSnapshot) []namedAccount {
	return sortedAccounts(snap, markedCodexAccount(snap.Accounts))
}

// accountsInOrder sorts Claude accounts, with `●` on the active constraint.
func accountsInOrder(snap domain.UsageSnapshot) []namedAccount {
	var active *string
	if w := snap.QuotaGlance().Active; w != nil {
		active = w.AccountName
	}
	return sortedAccounts(snap, active)
}

func codexUsageLine(a namedAccount, p ProviderReport, snap domain.UsageSnapshot, now time.Time) line {
	for _, w := range a.value.QuotaWindows {
		if w.Name != "primary" {
			continue
		}
		if w.Utilization == nil {
			break
		}
		return line{name: a.name, gauge: barGauge(*w.Utilization), label: windowLabel(w, p, snap), reset: resetColumn(w.ResetsAt, now)}
	}
	return problemLine(a.name, "unavailable")
}

func codexQuotaWindows(a domain.AccountUsage) []domain.QuotaWindow {
	var out []domain.QuotaWindow
	for _, name := range []string{"primary", "secondary"} {
		for _, w := range a.QuotaWindows {
			if w.Name == name {
				out = append(out, w)
				break
			}
		}
	}
	return out
}

func windowGauge(w domain.QuotaWindow) gauge {
	if w.Utilization != nil {
		return barGauge(*w.Utilization)
	}
	return textGauge("no limit")
}

func quotaLines(p ProviderReport, now time.Time) []line {
	name := labelFor(p)
	if p.Snapshot == nil {
		return []line{problemLine(name, problemWordOr(p, "unavailable"))}
	}
	snap := *p.Snapshot
	var lines []line
	withProblem := func() []line {
		if word := problemWord(p); word != nil {
			lines = append(lines, problemLine(name, *word))
		}
		return lines
	}
	if p.ID == domain.Codex && len(snap.Accounts) >= 2 {
		lines = []line{{name: name, gauge: textGauge("")}}
		for _, a := range codexAccountsInOrder(snap) {
			windows := codexQuotaWindows(a.value)
			if len(windows) == 0 {
				lines = append(lines, problemLine(a.name, "unavailable"))
				continue
			}
			for i, w := range windows {
				rowName := ""
				if i == 0 {
					rowName = a.name
				}
				lines = append(lines, line{name: rowName, gauge: windowGauge(w), label: windowLabel(w, p, snap), reset: resetColumn(w.ResetsAt, now)})
			}
		}
		return withProblem()
	}
	addRow := func(rowName string, g gauge, label string, reset *string) {
		lines = append(lines, line{name: rowName, gauge: g, label: label, reset: reset})
	}
	firstName := func() string {
		if len(lines) == 0 {
			return name
		}
		return ""
	}
	glance := snap.QuotaGlance()
	switch {
	case p.ID == domain.Claude && len(snap.Accounts) > 0:
		addRow(name, textGauge(""), "", nil)
		for _, a := range accountsInOrder(snap) {
			g := a.value.QuotaGlance()
			windows := nonNilWindows(g.FiveHours, g.SevenDays)
			if len(windows) == 0 {
				addRow(a.name, textGauge("no limit"), "", nil)
				continue
			}
			for i, w := range windows {
				rowGauge, label, reset := claudeWindow(w, now)
				rowName := ""
				if i == 0 {
					rowName = a.name
				}
				addRow(rowName, rowGauge, label, reset)
			}
		}
	case p.ID == domain.Claude && glance.HasAnyWindow():
		for _, w := range nonNilWindows(glance.FiveHours, glance.SevenDays) {
			rowGauge, label, reset := claudeWindow(w, now)
			addRow(firstName(), rowGauge, label, reset)
		}
	case p.ID == domain.OpenRouter:
		rowGauge, label, reset := worstWindow(p, snap, now)
		addRow(name, rowGauge, label, reset)
		if spend := snap.PeriodSpendUSD; spend != nil {
			for _, period := range []struct {
				name   string
				amount decimal.Decimal
			}{{"day", spend.Day}, {"week", spend.Week}, {"month", spend.Month}} {
				addRow("", textGauge(usd(period.amount)+" spent"), period.name, nil)
			}
		}
	case len(snap.QuotaWindows) > 0:
		for _, w := range snap.QuotaWindows {
			addRow(firstName(), windowGauge(w), windowLabel(w, p, snap), resetColumn(w.ResetsAt, now))
		}
	default:
		rowGauge, label, reset := worstWindow(p, snap, now)
		addRow(name, rowGauge, label, reset)
	}
	return withProblem()
}

func nonNilWindows(windows ...*domain.GlanceWindow) []*domain.GlanceWindow {
	var out []*domain.GlanceWindow
	for _, w := range windows {
		if w != nil {
			out = append(out, w)
		}
	}
	return out
}

func localItems(locals []ProviderReport) []string {
	var out []string
	for _, p := range locals {
		if p.PlaceholderMessage != nil && *p.PlaceholderMessage != "" {
			continue
		}
		name := labelFor(p)
		var raw map[string]string
		if p.Snapshot != nil {
			raw = p.Snapshot.Raw
		}
		switch {
		case raw["loadingModel"] == "true":
			out = append(out, "◐ "+name+" loading")
		case p.Status.Kind == domain.StatusNotRunning:
			out = append(out, "○ "+name+" stopped")
		case p.Status.Kind == domain.StatusOK:
			count, _ := strconv.Atoi(raw["modelCount"])
			if count <= 0 {
				out = append(out, "○ "+name+" idle")
				continue
			}
			item := "● " + name
			if model, ok := raw["modelName"]; ok {
				item += " " + model
			}
			if count > 1 {
				item += fmt.Sprintf(" +%d", count-1)
			}
			out = append(out, item)
		default:
			out = append(out, "○ "+name+" unavailable")
		}
	}
	return out
}

func localLines(items []string, width int) []string {
	const prefix = "  local "
	indent := strings.Repeat(" ", len(prefix))
	var lines []string
	current := prefix
	for _, item := range items {
		fresh := current == prefix || current == indent
		candidate := current + "  " + item
		if fresh {
			candidate = current + item
		}
		if !fresh && chars(candidate) > width {
			lines = append(lines, current)
			current = indent + item
		} else {
			current = candidate
		}
	}
	return append(lines, current)
}

var shortLabels = map[domain.ProviderID]string{
	domain.OpenRouter: "OpenRouter", domain.Claude: "Claude", domain.Codex: "Codex", domain.Gemini: "Gemini",
	domain.Grok: "Grok", domain.PiLocal: "Local Llama", domain.Ollama: "Ollama", domain.OllamaCloud: "Ollama Cloud",
	domain.LMStudio: "LM Studio", domain.LlamaCpp: "llama.cpp",
}

func labelFor(p ProviderReport) string {
	if label, ok := shortLabels[p.ID]; ok {
		return label
	}
	return p.DisplayName
}

// layout is the column widths for one render, fitted to the available width.
type layout struct {
	nameWidth, barWidth, labelWidth, resetWidth, moneyWidth int
}

func (l layout) gaugeWidth() int { return l.barWidth + 5 }

func (l layout) totalWidth() int {
	w := 2 + l.nameWidth + 1 + l.barWidth + 5
	if l.labelWidth > 0 {
		w += 1 + l.labelWidth
	}
	if l.resetWidth > 0 {
		w += 1 + l.resetWidth
	}
	if l.moneyWidth > 0 {
		w += 2 + l.moneyWidth
	}
	return w
}

func fitLayout(lines []line, width *int) layout {
	longestName, labels, resets, moneys, texts := 0, 0, 0, 0, 0
	for _, l := range lines {
		longestName = max(longestName, chars(l.name))
		if l.problem != "" {
			continue
		}
		labels = max(labels, chars(l.label))
		if l.reset != nil {
			resets = max(resets, chars(*l.reset))
		}
		if l.money != nil {
			moneys = max(moneys, chars(*l.money))
		}
		if !l.gauge.isBar {
			texts = max(texts, chars(l.gauge.text))
		}
	}
	// Text gauges (`$31.40 spent`) must fit where the bar and percent go.
	barFloor := max(minBarWidth, texts-5)
	result := layout{nameWidth: baseNameWidth, barWidth: max(baseBarWidth, barFloor), labelWidth: labels, resetWidth: resets, moneyWidth: moneys}
	if width == nil {
		return result
	}
	if *width > result.totalWidth() {
		extra := *width - result.totalWidth()
		grow := min(extra, max(0, longestName-result.nameWidth))
		result.nameWidth += grow
		extra -= grow
		result.barWidth = min(maxBarWidth, result.barWidth+extra)
		return result
	}
	for result.totalWidth() > *width && result.barWidth > barFloor {
		result.barWidth--
	}
	for result.totalWidth() > *width && result.nameWidth > minNameWidth {
		result.nameWidth--
	}
	return result
}

func (l layout) render(row line, color bool) string {
	if row.problem != "" {
		return paint("! "+l.fitName(row.name)+" "+row.problem, domain.BandCritical, color)
	}
	var out string
	if row.gauge.isBar {
		sev := severityOf(row.gauge.fraction)
		fill, track := eighthBar(row.gauge.fraction, l.barWidth)
		pct := percent(row.gauge.fraction)
		out = paint(sev.glyph(), sev.band(), color) + " " + l.fitName(row.name) + " " +
			paint(fill, sev.band(), color) + paint(track, domain.BandNone, color) +
			" " + spaces(4-chars(pct)) + pct
	} else {
		// Pad outside the ANSI span so the trailing-space trim below reaches it.
		out = "  " + l.fitName(row.name) + " " + paint(row.gauge.text, domain.BandNone, color) +
			spaces(l.gaugeWidth()-chars(row.gauge.text))
	}
	if l.labelWidth > 0 {
		out += " " + pad(row.label, l.labelWidth)
	}
	if l.resetWidth > 0 {
		reset := ""
		if row.reset != nil {
			reset = *row.reset
		}
		out += " " + pad(reset, l.resetWidth)
	}
	if l.moneyWidth > 0 && row.money != nil {
		out += "  " + spaces(l.moneyWidth-chars(*row.money)) + *row.money
	}
	return trimTrailingSpaces(out)
}

func (l layout) fitName(name string) string {
	if chars(name) <= l.nameWidth {
		return pad(name, l.nameWidth)
	}
	runes := []rune(name)
	return string(runes[:l.nameWidth-1]) + "…"
}
