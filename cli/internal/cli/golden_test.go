package cli

import (
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

func compact(r UsageReport, view View, color bool, width *int) string {
	return renderCompact(r, view, color, width, time.UTC, nil)
}

func TestClassicAndJSONGoldens(t *testing.T) {
	r := richReport()
	cases := []struct {
		name string
		got  string
	}{
		{"classic-usage.txt", renderClassicUsage(r, false)},
		{"classic-usage-color.txt", renderClassicUsage(r, true)},
		{"classic-quota.txt", renderClassicQuota(r, false)},
		{"classic-quota-color.txt", renderClassicQuota(r, true)},
		{"json-usage.json", renderUsageJSON(r)},
		{"json-quota.json", renderQuotaJSON(r)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { assertGolden(t, c.got, c.name) })
	}
}

func TestCompactGoldens(t *testing.T) {
	r := richReport()
	single := UsageReport{AsOf: fixtureAsOf, Source: SourceCached, Providers: []ProviderReport{fixtureClaude()}}
	empty := UsageReport{AsOf: fixtureAsOf, Source: SourceCached}
	cases := []struct {
		name string
		got  string
	}{
		{"compact-usage.txt", compact(r, ViewUsage, false, nil)},
		{"compact-usage-color.txt", compact(r, ViewUsage, true, nil)},
		{"compact-usage-60.txt", compact(r, ViewUsage, false, intp(60))},
		{"compact-usage-110.txt", compact(r, ViewUsage, false, intp(110))},
		{"compact-quota.txt", compact(r, ViewQuota, false, nil)},
		{"compact-single-claude.txt", compact(single, ViewUsage, false, nil)},
		{"compact-empty-cached.txt", compact(empty, ViewUsage, false, nil)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { assertGolden(t, c.got, c.name) })
	}
}

const statsToday = "2026-03-14"

func statsRangeOf(t *testing.T, days *int, since, until *string) StatsRange {
	t.Helper()
	r, err := ResolveRange(statsToday, days, since, until, nil)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func summary(t *testing.T, r StatsRange, includeLocal, color bool) string {
	t.Helper()
	return renderStatsSummary(syntheticDays(statsToday, 90), r, includeLocal, nil, domain.BudgetConfig{}, nil, color)
}

func TestStatsGoldens(t *testing.T) {
	history := syntheticDays(statsToday, 90)
	r14 := statsRangeOf(t, nil, nil, nil)
	r7 := statsRangeOf(t, intp(7), nil, nil)
	cases := []struct {
		name string
		got  string
	}{
		{"stats-summary.txt", summary(t, r14, false, false)},
		{"stats-summary-color.txt", summary(t, r14, false, true)},
		{"stats-summary-all.txt", summary(t, r14, true, false)},
		{"stats-summary-90.txt", summary(t, statsRangeOf(t, intp(90), nil, nil), false, false)},
		{"stats-claude.txt", renderStatsProvider(history, domain.Claude, r14, false)},
		{"stats-codex.txt", renderStatsProvider(history, domain.Codex, r7, false)},
		{"stats-openrouter.txt", renderStatsProvider(history, domain.OpenRouter, r7, false)},
		{"stats-ollama.txt", renderStatsProvider(history, domain.Ollama, r7, false)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { assertGolden(t, c.got, c.name) })
	}
}

func TestExportGoldens(t *testing.T) {
	history := syntheticDays(statsToday, 7)
	scope := exportScope{statsRange: statsRangeOf(t, intp(3), nil, nil)}
	exportedAt := time.Unix(1_773_500_000, 0)
	cases := []struct {
		name string
		got  string
	}{
		{"export.json", renderExportJSON(history, scope, exportedAt)},
		{"export-days.csv", renderExportCSV(history, scope, CSVDays)},
		{"export-accounts.csv", renderExportCSV(history, scope, CSVAccounts)},
		{"export-events.csv", renderExportCSV(history, scope, CSVEvents)},
		{"export-quota.csv", renderExportCSV(history, scope, CSVQuota)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { assertGolden(t, c.got, c.name) })
	}
}
