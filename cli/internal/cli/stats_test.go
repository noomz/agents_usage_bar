package cli

import (
	"strings"
	"testing"

	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

func TestBudgetFooter(t *testing.T) {
	history := syntheticDays(statsToday, 90)
	r := statsRangeOf(t, nil, nil, nil)
	budgets := domain.BudgetConfig{Caps: map[domain.BudgetScope]domain.Money{
		domain.BudgetTotal: *synthMoney(50, 0), {Provider: domain.OpenRouter}: *synthMoney(20, 0),
	}}
	out := lines(renderStatsSummary(history, r, false, nil, budgets, history, false))
	var l legend
	total := amountText(domain.MonthSpend(history, statsToday, domain.BudgetTotal), &l)
	totalLine, providerLine := -1, -1
	for i, line := range out {
		if line == "Mar spend "+total+" / $50.00 budget" {
			totalLine = i
		}
		if strings.HasPrefix(line, "OpenRouter Mar spend ") && strings.HasSuffix(line, " / $20.00 budget") {
			providerLine = i
		}
	}
	if totalLine < 0 || providerLine < totalLine {
		t.Errorf("total %d provider %d:\n%s", totalLine, providerLine, strings.Join(out, "\n"))
	}
	if strings.Contains(summary(t, r, false, false), "budget") {
		t.Error("no caps, no footer")
	}
}

func TestSummaryHeader(t *testing.T) {
	if got := lines(summary(t, statsRangeOf(t, nil, nil, nil), false, false))[0]; got != "2026-03-01 – 2026-03-14 · 14 days (today open)" {
		t.Error(got)
	}
	until := "2026-03-10"
	if got := lines(summary(t, statsRangeOf(t, nil, nil, &until), false, false))[0]; got != "2026-02-25 – 2026-03-10 · 14 days" {
		t.Error(got)
	}
}

func TestTotalIsMeteredSpendOnly(t *testing.T) {
	r := statsRangeOf(t, nil, nil, nil)
	sum := decimal.Decimal{}
	for _, d := range syntheticDays(statsToday, 90) {
		if d.Date < r.Keys[0] {
			continue
		}
		for _, rec := range d.Records {
			if rec.Provider == domain.OpenRouter {
				sum = sum.Add(rec.CostUSD.Amount)
			}
		}
	}
	total := firstLine(t, lines(summary(t, r, false, false)), func(l string) bool { return strings.HasPrefix(l, "total") })
	if !strings.HasSuffix(total, usd(sum)+"!") || strings.Contains(total, "~") {
		t.Error(total)
	}
}

func TestSpendCells(t *testing.T) {
	all := lines(summary(t, statsRangeOf(t, nil, nil, nil), false, false))
	claude := firstLine(t, all, func(l string) bool { return strings.HasPrefix(l, "Claude") })
	if !strings.Contains(claude, "max/pro") || strings.Contains(claude, "$") {
		t.Error(claude)
	}
	codex := firstLine(t, all, func(l string) bool { return strings.HasPrefix(l, "Codex") })
	if !strings.Contains(codex, "?! +plus") {
		t.Error(codex)
	}
}

func TestLocalHiddenUnlessAll(t *testing.T) {
	r := statsRangeOf(t, nil, nil, nil)
	if strings.Contains(summary(t, r, false, false), "Ollama") {
		t.Error("local row without all")
	}
	if !strings.Contains(summary(t, r, true, false), "used 14/14 days") {
		t.Error("no presence row")
	}
}

func TestGapsAndLegend(t *testing.T) {
	r := statsRangeOf(t, nil, nil, nil)
	all := lines(summary(t, r, false, false))
	if !strings.Contains(firstLine(t, all, func(l string) bool { return strings.HasPrefix(l, "Claude") }), "·") {
		t.Error("claude gap")
	}
	codex := firstLine(t, all, func(l string) bool { return strings.HasPrefix(l, "Codex") })
	if !strings.Contains(codex, "?") || strings.Contains(codex, "·") {
		t.Error(codex)
	}
	if got := all[len(all)-1]; got != "· gap  ? no value  ! incomplete" {
		t.Error(got)
	}
	history := syntheticDays(statsToday, 90)
	if !strings.HasSuffix(renderStatsProvider(history, domain.Claude, r, false), "~ estimated  · gap  ! incomplete\n") {
		t.Error("claude legend")
	}
	or := renderStatsProvider(history, domain.OpenRouter, statsRangeOf(t, intp(3), nil, nil), false)
	if strings.Contains(or, "estimated") || strings.Contains(or, "gap") {
		t.Error(or)
	}
}

func TestNoValueVersusGap(t *testing.T) {
	metered := []domain.DayAccount{{Key: "default", Label: "default", BillingModel: domain.BillingMetered}}
	subscription := []domain.DayAccount{{Key: "demo", Label: "demo", BillingModel: domain.BillingSubscription, Plan: strPtr("pro")}}
	record := func(accounts []domain.DayAccount, cost *int, peak *float64, origin domain.RecordOrigin) *domain.DayRecord {
		r := &domain.DayRecord{Provider: "demo", Accounts: accounts, Origin: origin, Quota: map[string]domain.QuotaDay{}}
		if cost != nil {
			r.CostUSD = synthMoney(*cost, 0)
		}
		if peak != nil {
			r.Quota["5h"] = domain.QuotaDay{Peak: *peak, EndOfDay: *peak}
		}
		return r
	}
	spend := newProviderStats("demo", []*domain.DayRecord{record(metered, intp(2), nil, domain.OriginObserved), record(metered, nil, nil, domain.OriginObserved), nil})
	if spend.kind != kindMetered {
		t.Error("kind")
	}
	assertCells := func(got []trendCell, want ...trendCell) {
		t.Helper()
		if len(got) != len(want) {
			t.Fatalf("%v", got)
		}
		for i := range got {
			if got[i] != want[i] {
				t.Errorf("%d: %+v want %+v", i, got[i], want[i])
			}
		}
	}
	assertCells(spend.trend(1), trendCell{trendValue, 2}, trendCell{kind: trendNoValue}, trendCell{kind: trendGap})
	assertCells(spend.trend(3), trendCell{kind: trendIncomplete})

	backfilled := record(subscription, nil, nil, domain.OriginBackfilled)
	peaks := newProviderStats("demo", []*domain.DayRecord{record(subscription, nil, f64(0.5), domain.OriginObserved), backfilled, backfilled, backfilled, nil})
	if peaks.kind != kindSubscription || peaks.seenDays() != 4 {
		t.Error("peaks")
	}
	assertCells(peaks.trend(1), trendCell{trendValue, 0.5}, trendCell{kind: trendNoValue}, trendCell{kind: trendNoValue}, trendCell{kind: trendNoValue}, trendCell{kind: trendGap})
	assertCells(peaks.trend(2), trendCell{trendValue, 0.5}, trendCell{kind: trendNoValue}, trendCell{kind: trendIncomplete})
	if got := (legend{noValue: true}).line(false); len(got) != 1 || got[0] != "? no value" {
		t.Errorf("%v", got)
	}
}

func TestBucketsBeyondThirtyDays(t *testing.T) {
	text := lines(summary(t, statsRangeOf(t, intp(90), nil, nil), false, false))
	if !strings.HasSuffix(text[0], "· trend 1 char = 3 days") {
		t.Error(text[0])
	}
	claude := firstLine(t, text, func(l string) bool { return strings.HasPrefix(l, "Claude") })
	parts := strings.Split(claude, "%")
	trend := parts[len(parts)-1]
	if chars(trend) != 30 || !strings.Contains(trend, "!") {
		t.Errorf("%q", trend)
	}
}

func TestDrillMarkers(t *testing.T) {
	history := syntheticDays(statsToday, 90)
	codex := renderStatsProvider(history, domain.Codex, statsRangeOf(t, intp(7), nil, nil), false)
	if !strings.Contains(codex, "backfilled") {
		t.Error(codex)
	}
	firstLine(t, lines(codex), func(l string) bool { return strings.HasPrefix(l, statsToday) && strings.HasSuffix(l, "open") })
	if !strings.Contains(renderStatsProvider(history, domain.Claude, statsRangeOf(t, nil, nil, nil), false), "80% 5h") {
		t.Error("peak cell")
	}
}

func TestColourDropsCleanly(t *testing.T) {
	r := statsRangeOf(t, nil, nil, nil)
	if strings.Contains(summary(t, r, false, false), "\x1b") || !strings.Contains(summary(t, r, false, true), "\x1b") {
		t.Error("ansi")
	}
}

func TestRangeFlags(t *testing.T) {
	sp := func(s string) *string { return &s }
	keys := func(days *int, since, until *string) string {
		return strings.Join(statsRangeOf(t, days, since, until).Keys, ",")
	}
	if len(statsRangeOf(t, nil, nil, nil).Keys) != 14 {
		t.Error("default 14")
	}
	cases := []struct{ got, want string }{
		{keys(intp(3), nil, nil), "2026-03-12,2026-03-13,2026-03-14"},
		{keys(nil, sp("2026-02-27"), sp("2026-03-02")), "2026-02-27,2026-02-28,2026-03-01,2026-03-02"},
		{keys(intp(2), sp("2026-03-01"), nil), "2026-03-01,2026-03-02"},
		{keys(nil, sp("2026-03-13"), sp("2026-04-01")), "2026-03-13,2026-03-14"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("got %s want %s", c.got, c.want)
		}
	}
	if _, err := ResolveRange(statsToday, nil, sp("2026-03-05"), sp("2026-03-01"), nil); err == nil || err.Error() != "empty range: 2026-03-05 is after 2026-03-01" {
		t.Errorf("%v", err)
	}
	if _, err := ResolveRange(statsToday, intp(3), sp("2026-03-01"), sp("2026-03-05"), nil); err == nil || err.Error() != "unexpected argument '--days'. Try `aub help`." {
		t.Errorf("%v", err)
	}
	if statsRangeOf(t, intp(30), nil, nil).bucketSize() != 1 || statsRangeOf(t, intp(31), nil, nil).bucketSize() != 2 {
		t.Error("bucket size")
	}
	for key, want := range map[string]bool{"2026-02-30": false, "2024-02-29": true, "2026-13-01": false, "20261001": false, "2026-1-01": false} {
		if IsDayKey(key) != want {
			t.Errorf("IsDayKey(%s)", key)
		}
	}
}
