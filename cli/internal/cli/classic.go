package cli

import (
	"strings"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

const classicBarWidth = 20

func maxDisplayName(report UsageReport) int {
	width := 16
	for _, p := range report.Providers {
		width = max(width, chars(p.DisplayName))
	}
	return width
}

func renderClassicUsage(report UsageReport, color bool) string {
	nameWidth := maxDisplayName(report)
	totals := report.Totals()
	lines := []string{
		pad("Today total", nameWidth) + "  " + pad(tokenCount(totals.Tokens)+" tokens", 22) + "  " + usd(totals.CostUSD),
	}
	if report.hasAnyQuotaOnlyProvider() {
		lines = append(lines, "Total excludes quota-only providers")
	}
	lines = append(lines, strings.Repeat("─", 57))
	for _, p := range report.Providers {
		lines = append(lines, classicUsageBlock(p, nameWidth, color, report.AsOf)...)
	}
	return strings.Join(lines, "\n") + "\n"
}

func renderClassicQuota(report UsageReport, color bool) string {
	nameWidth := maxDisplayName(report)
	var lines []string
	for _, p := range report.Providers {
		lines = append(lines, classicQuotaBlock(p, nameWidth, color, report.AsOf)...)
	}
	return strings.Join(lines, "\n") + "\n"
}

func classicUsageBlock(p ProviderReport, nameWidth int, color bool, now time.Time) []string {
	name := pad(p.DisplayName, nameWidth)
	if p.IsLocal {
		return []string{name + "  " + localCaption(p)}
	}
	indent := pad("", nameWidth)
	var glance *domain.QuotaGlance
	if p.ID == domain.Claude && p.Snapshot != nil {
		g := p.Snapshot.QuotaGlance()
		glance = &g
	}
	hasWindows := glance != nil && glance.HasAnyWindow()

	var barLine string
	if hasWindows {
		barLine = claudeDualBarLine(*glance)
	} else {
		var q *domain.Quota
		if glance != nil && glance.Active != nil && glance.Active.Utilization != nil {
			active := domain.UnitQuota(*glance.Active.Utilization)
			q = &active
		} else if p.Snapshot != nil {
			q = p.Snapshot.DisplayedQuota()
		}
		barLine = quotaBarLine(q, color)
	}
	lines := []string{name + "  " + barLine, indent + "  " + secondaryLine(p)}
	if hasWindows {
		lines = append(lines, claudeUsageLines(*glance, indent, now)...)
	}
	var accounts []domain.AccountUsage
	var windows []domain.QuotaWindow
	if p.Snapshot != nil {
		accounts, windows = p.Snapshot.Accounts, p.Snapshot.QuotaWindows
	}
	switch {
	case p.ID == domain.Codex && len(accounts) >= 2:
		for _, a := range accounts {
			lines = append(lines, codexUsageAccountLines(a, indent, color, now)...)
		}
	case len(accounts) >= 2:
		for _, a := range accounts {
			lines = append(lines, accountLines(a, indent)...)
		}
	case !hasWindows && len(windows) > 0:
		lines = append(lines, windowLines(windows, indent, now)...)
	}
	if isDegraded(p) {
		lines = append(lines, indent+"  usage temporarily unavailable")
	}
	return lines
}

func classicQuotaBlock(p ProviderReport, nameWidth int, color bool, now time.Time) []string {
	indent := pad("", nameWidth)
	var q *domain.Quota
	if p.Snapshot != nil {
		q = p.Snapshot.DisplayedQuota()
	}
	lines := []string{pad(p.DisplayName, nameWidth) + "  " + quotaBarLine(q, color)}
	if p.Snapshot != nil {
		if p.ID == domain.Codex && len(p.Snapshot.Accounts) >= 2 {
			for _, a := range p.Snapshot.Accounts {
				lines = append(lines, codexQuotaAccountLines(a, indent, now)...)
			}
		} else if len(p.Snapshot.QuotaWindows) > 0 {
			lines = append(lines, windowLines(p.Snapshot.QuotaWindows, indent, now)...)
		}
	}
	if isDegraded(p) {
		lines = append(lines, indent+"  usage temporarily unavailable")
	}
	return lines
}

// claudeDualBarLine: `▀` is 5h only, `▄` is 7d only, `█` is both, `░` is neither.
func claudeDualBarLine(g domain.QuotaGlance) string {
	filled := func(w *domain.GlanceWindow, edge float64) bool {
		return w != nil && w.Utilization != nil && *w.Utilization >= edge
	}
	var b strings.Builder
	for cell := 1; cell <= classicBarWidth; cell++ {
		edge := float64(cell) / float64(classicBarWidth)
		five, seven := filled(g.FiveHours, edge), filled(g.SevenDays, edge)
		switch {
		case five && seven:
			b.WriteString("█")
		case five:
			b.WriteString("▀")
		case seven:
			b.WriteString("▄")
		default:
			b.WriteString("░")
		}
	}
	return b.String() + "  5h " + g.Percent(domain.PeriodFiveHours) + " · 7d " + g.Percent(domain.PeriodSevenDays)
}

func quotaBarLine(q *domain.Quota, color bool) string {
	var consumed, remaining *float64
	label := "no limit"
	if q != nil {
		f := q.Fraction()
		r := 1 - f
		consumed, remaining = &f, &r
		label = percent(f)
	}
	return paint(blockBar(consumed, classicBarWidth), domain.BandFromRemaining(remaining), color) + "  " + label
}

func secondaryLine(p ProviderReport) string {
	if p.Snapshot == nil {
		return "— · —"
	}
	if caption, ok := p.Snapshot.QuotaUsageCaption(); ok {
		return caption
	}
	tokens, cost := "—", "—"
	if p.Snapshot.TokensToday != nil {
		tokens = tokenCount(*p.Snapshot.TokensToday) + " tokens"
	}
	if p.Snapshot.CostTodayUSD != nil {
		cost = usd(*p.Snapshot.CostTodayUSD)
	}
	parts := []string{tokens, cost}
	if p.Snapshot.BalanceUSD != nil {
		parts = append(parts, "bal "+usd(*p.Snapshot.BalanceUSD))
	}
	return strings.Join(parts, " · ")
}

func claudeUsageLines(g domain.QuotaGlance, indent string, now time.Time) []string {
	values := "5h " + g.Percent(domain.PeriodFiveHours) + " · 7d " + g.Percent(domain.PeriodSevenDays)
	if g.Active == nil {
		return []string{indent + "  " + values}
	}
	account, reset := "", ""
	if g.Active.AccountName != nil {
		account = *g.Active.AccountName + " "
	}
	if g.Active.ResetsAt != nil {
		reset = "  " + domain.ResetPhrase(*g.Active.ResetsAt, now)
	}
	return []string{
		indent + "  Active: " + account + string(g.Active.Period) + " " + g.Percent(g.Active.Period) + reset,
		indent + "  " + values,
	}
}

func windowLines(windows []domain.QuotaWindow, indent string, now time.Time) []string {
	labelWidth := 0
	for _, w := range windows {
		labelWidth = max(labelWidth, chars(w.Name))
	}
	lines := make([]string, len(windows))
	for i, w := range windows {
		pct, reset := "—", "—"
		if w.Utilization != nil {
			pct = percent(*w.Utilization)
		}
		if w.ResetsAt != nil {
			reset = domain.ResetPhrase(*w.ResetsAt, now)
		}
		lines[i] = indent + "  " + pad(w.Name, labelWidth) + "  " + pad(pct, 4) + "  " + reset
	}
	return lines
}

// codexUsageAccountLines: a missing primary is `unavailable`, not the no-limit bar.
func codexUsageAccountLines(a domain.AccountUsage, indent string, color bool, now time.Time) []string {
	lines := []string{indent + "    " + a.Name}
	for _, w := range a.QuotaWindows {
		if w.Name != "primary" {
			continue
		}
		if w.Utilization == nil {
			break
		}
		q := domain.UnitQuota(*w.Utilization)
		reset := "Resets —"
		if w.ResetsAt != nil {
			reset = domain.ResetPhrase(*w.ResetsAt, now)
		}
		return append(lines, indent+"  "+quotaBarLine(&q, color), indent+"  "+reset)
	}
	return append(lines, indent+"  unavailable")
}

func codexQuotaAccountLines(a domain.AccountUsage, indent string, now time.Time) []string {
	lines := []string{indent + "    " + a.Name}
	if len(a.QuotaWindows) > 0 {
		return append(lines, windowLines(a.QuotaWindows, indent, now)...)
	}
	return append(lines, indent+"  unavailable")
}

func accountLines(a domain.AccountUsage, indent string) []string {
	head := "  " + a.Name
	if a.CostTodayUSD != nil {
		head += " · " + usd(*a.CostTodayUSD)
	}
	return []string{indent + "  " + head, indent + "  " + claudeDualBarLine(a.QuotaGlance())}
}

func isDegraded(p ProviderReport) bool {
	return p.Snapshot != nil && p.Snapshot.Raw["note"] == domain.DegradedNote
}

func localCaption(p ProviderReport) string {
	return domain.ProviderState{
		ID: p.ID, DisplayName: p.DisplayName, PlaceholderMessage: p.PlaceholderMessage, Snapshot: p.Snapshot, Status: p.Status,
	}.LocalSecondaryCaption()
}
