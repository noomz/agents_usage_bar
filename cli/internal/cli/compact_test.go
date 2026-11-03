package cli

import (
	"strings"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

func TestEmptyLiveSaysNoProviders(t *testing.T) {
	got := lines(compact(UsageReport{AsOf: fixtureAsOf, Source: SourceLive}, ViewUsage, false, nil))
	want := []string{"today $0.00 spent · 0 tok · 05:20", "0 at ≥80% · 0 at 50–79% · 0 unavailable", "no providers enabled"}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("%v", got)
	}
}

func TestShortGeminiModel(t *testing.T) {
	for in, want := range map[string]string{
		"gemini-2.5-pro": "2.5-pro", "gemini-2.5-flash": "2.5-flash", "gemini-2.5-flash-lite": "2.5-lite",
		"custom-model": "custom-model", "gemini-": "gemini-",
	} {
		if got := shortGeminiModel(in); got != want {
			t.Errorf("%s: %s", in, got)
		}
	}
}

func TestAllDisabledSaysNoProviders(t *testing.T) {
	p := fixtureCodex()
	p.Status = domain.Disabled()
	got := lines(compact(UsageReport{AsOf: fixtureAsOf, Source: SourceLive, Providers: []ProviderReport{p}}, ViewUsage, false, nil))
	if got[len(got)-1] != "no providers enabled" {
		t.Errorf("%v", got)
	}
}

func TestClaudeAccountWithNoWindowsIsNoLimit(t *testing.T) {
	p := fixtureClaude()
	p.Snapshot = &domain.UsageSnapshot{ProviderID: domain.Claude, AsOf: fixtureAsOf, TokensToday: intp(0), Raw: map[string]string{},
		Accounts: []domain.AccountUsage{{Name: "solo"}}}
	out := lines(compact(UsageReport{AsOf: fixtureAsOf, Source: SourceLive, Providers: []ProviderReport{p}}, ViewQuota, false, nil))
	row := firstLine(t, out, func(l string) bool { return strings.Contains(l, "solo") })
	if !strings.Contains(row, "no limit") {
		t.Error(row)
	}
}

func TestHeaderCounts(t *testing.T) {
	got := lines(compact(richReport(), ViewUsage, false, nil))
	if got[0] != "today $273.93 spent · 233.6M tok · 05:20" {
		t.Error(got[0])
	}
	if got[1] != "1 at ≥80% · 2 at 50–79% · 2 unavailable" {
		t.Error(got[1])
	}
}

func TestRowsFollowKnownOrder(t *testing.T) {
	text := compact(richReport(), ViewUsage, false, nil)
	last := -1
	for _, name := range []string{"OpenRouter", "Claude", "Codex", "Gemini", "Grok", "local"} {
		i := strings.Index(text, name)
		if i <= last {
			t.Errorf("%s out of order", name)
		}
		last = i
	}
}

func multiCodex(cost *string, accounts ...domain.AccountUsage) ProviderReport {
	p := fixtureCodex()
	snap := domain.UsageSnapshot{ProviderID: domain.Codex, AsOf: fixtureAsOf, TokensToday: intp(18_404), Raw: map[string]string{"source": "codex-accounts"}, Accounts: accounts}
	if cost != nil {
		snap.CostTodayUSD = dec(*cost)
	}
	p.Snapshot = &snap
	return p
}

func codexAccount(name string, primary *float64, reset *time.Time, secondary *float64) domain.AccountUsage {
	a := domain.AccountUsage{Name: name}
	if primary != nil || reset != nil {
		w := domain.QuotaWindow{Name: "primary", Utilization: primary, ResetsAt: reset}
		seconds := 5.0 * 3600
		w.Duration = &seconds
		a.QuotaWindows = append(a.QuotaWindows, w)
	}
	if secondary != nil {
		a.QuotaWindows = append(a.QuotaWindows, timedWindow("secondary", *secondary, after(6*day), 7*86400))
	}
	if primary != nil {
		q := domain.UnitQuota(*primary)
		a.Quota = &q
	}
	return a
}

func TestCodexMultiLoginRows(t *testing.T) {
	report := UsageReport{AsOf: fixtureAsOf, Source: SourceLive, Providers: []ProviderReport{
		multiCodex(strPtr("0.07"),
			codexAccount("team", f64(0.80), after(4*hour), f64(0.10)),
			codexAccount("plus", f64(0.20), after(2*hour+50*time.Minute), f64(0.90)),
			codexAccount("guest", nil, nil, nil)),
	}}
	usage := lines(compact(report, ViewUsage, false, nil))
	if usage[1] != "1 at ≥80% · 0 at 50–79% · 1 unavailable" {
		t.Error(usage[1])
	}
	has := func(s string, want ...string) {
		t.Helper()
		for _, w := range want {
			if !strings.Contains(s, w) {
				t.Errorf("%q lacks %q", s, w)
			}
		}
	}
	lacks := func(s string, bad ...string) {
		t.Helper()
		for _, b := range bad {
			if strings.Contains(s, b) {
				t.Errorf("%q has %q", s, b)
			}
		}
	}
	header := firstLine(t, usage, func(l string) bool { return strings.Contains(l, "Codex") })
	has(header, "$0.07 spent")
	lacks(header, "%")
	plus := firstLine(t, usage, func(l string) bool { return strings.Contains(l, "plus") })
	has(plus, "    plus ", "20%", "5h", "↻ 2h 50m")
	lacks(plus, "90%", "spent", "●")
	team := firstLine(t, usage, func(l string) bool { return strings.Contains(l, "team") })
	has(team, "▲   team● ", "80%", "5h", "↻ 4h")
	lacks(team, "spent")
	guest := firstLine(t, usage, func(l string) bool { return strings.Contains(l, "guest") })
	has(guest, "!   guest", "unavailable")
	lacks(guest, "no limit")

	quota := lines(compact(report, ViewQuota, false, nil))
	if quota[0] != "2 at ≥80% · 0 at 50–79% · 1 unavailable" {
		t.Error(quota[0])
	}
	firstLine(t, quota, func(l string) bool {
		return strings.Contains(l, "plus") && strings.Contains(l, "20%") && strings.Contains(l, "5h")
	})
	firstLine(t, quota, func(l string) bool {
		return strings.Contains(l, "90%") && strings.Contains(l, "7d") && !strings.Contains(l, "plus")
	})
	firstLine(t, quota, func(l string) bool { return strings.Contains(l, "team●") && strings.Contains(l, "80%") })
}

func names(ls []line) string {
	out := []string{}
	for _, l := range ls {
		out = append(out, l.name)
	}
	return strings.Join(out, "|")
}

func TestCodexAccountMark(t *testing.T) {
	now := fixtureAsOf
	equal := multiCodex(nil, codexAccount("team", f64(0.40), after(2*hour), nil), codexAccount("plus", f64(0.40), after(hour), nil))
	if got := names(usageLines(equal, now)); !strings.Contains(got, "  plus●") || strings.Contains(got, "team●") {
		t.Errorf("sooner reset wins: %s", got)
	}
	nilReset := multiCodex(nil, codexAccount("plus", f64(0.50), nil, nil), codexAccount("team", f64(0.50), after(hour), nil))
	if got := names(usageLines(nilReset, now)); !strings.Contains(got, "team●") || strings.Contains(got, "plus●") {
		t.Errorf("a nil reset loses: %s", got)
	}
	nobody := multiCodex(nil, codexAccount("plus", nil, nil, f64(0.80)), codexAccount("team", nil, nil, nil))
	got := usageLines(nobody, now)
	if strings.Contains(names(got), "●") {
		t.Errorf("no fraction, no mark: %s", names(got))
	}
	if s := severityLine(got); s != "0 at ≥80% · 0 at 50–79% · 2 unavailable" {
		t.Error(s)
	}
}

func TestCodexOneLoginStaysOneRow(t *testing.T) {
	got := usageLines(fixtureCodex(), fixtureAsOf)
	if len(got) != 1 || got[0].name != "Codex" {
		t.Errorf("%+v", got)
	}
}

func TestClaudeAccounts(t *testing.T) {
	all := lines(compact(richReport(), ViewUsage, false, nil))
	work := firstLine(t, all, func(l string) bool { return strings.HasPrefix(l, "    work● ") })
	personal := firstLine(t, all, func(l string) bool { return strings.HasPrefix(l, "    personal ") })
	header := firstLine(t, all, func(l string) bool { return strings.HasPrefix(l, "  Claude ") })
	if !strings.HasSuffix(header, "$273.86 spent") || strings.Contains(header, "%") {
		t.Error(header)
	}
	if !strings.Contains(work, "47% 7d") || !strings.Contains(personal, "17% 7d") || !strings.Contains(personal, "↻ unknown") {
		t.Errorf("%s\n%s", work, personal)
	}
}

func TestLocalLine(t *testing.T) {
	text := compact(richReport(), ViewUsage, false, nil)
	if !strings.Contains(text, "  local ○ Ollama stopped  ● llama.cpp Qwen3.5-4B") {
		t.Error(text)
	}
	if strings.Contains(text, "gpu-box") || strings.Contains(text, "LM Studio llama.cpp") {
		t.Error("placeholders must be hidden")
	}
}

func TestEighthBar(t *testing.T) {
	for _, c := range []struct {
		f    float64
		want string
	}{{0.94, "█████████▍"}, {0.69, "██████▉░░░"}, {0.47, "████▊░░░░░"}, {0.17, "█▊░░░░░░░░"}, {0, "░░░░░░░░░░"}, {1, "██████████"}, {1.4, "██████████"}} {
		fill, track := eighthBar(c.f, 10)
		if fill+track != c.want {
			t.Errorf("%v: %s", c.f, fill+track)
		}
	}
}

func TestBlockBar(t *testing.T) {
	for _, c := range []struct {
		f    *float64
		want string
	}{{f64(0), strings.Repeat("░", 20)}, {f64(0.5), strings.Repeat("█", 10) + strings.Repeat("░", 10)}, {f64(1), strings.Repeat("█", 20)}, {nil, strings.Repeat("█", 20)}} {
		if got := blockBar(c.f, 20); got != c.want {
			t.Errorf("%v: %s", c.f, got)
		}
	}
}

func TestSeverityEdges(t *testing.T) {
	for _, c := range []struct {
		f    float64
		want severity
	}{{0.80, severityCritical}, {0.7996, severityCritical}, {0.7949, severityWarning}, {0.50, severityWarning}, {0.4996, severityWarning}, {0.4949, severityNormal}} {
		if got := severityOf(c.f); got != c.want {
			t.Errorf("%v: %v", c.f, got)
		}
	}
}

func TestSITokens(t *testing.T) {
	for n, want := range map[int]string{0: "0", 999: "999", 1_500: "1.5K", 232_400_512: "232.4M", 1_260_000_000: "1.3B", 999_949: "999.9K", 999_950: "1.0M", 999_950_000: "1.0B"} {
		if got := siTokens(n); got != want {
			t.Errorf("%d: %s", n, got)
		}
	}
}

func TestResetColumn(t *testing.T) {
	cases := []struct {
		at   *time.Time
		want string
	}{{after(3*day + 8*hour), "↻ 3d 8h"}, {after(-5 * time.Second), "↻ now"}, {nil, "↻ unknown"}}
	for _, c := range cases {
		if got := *resetColumn(c.at, fixtureAsOf); got != c.want {
			t.Errorf("got %s want %s", got, c.want)
		}
	}
}

func TestStaleKeepsBarAndAddsLine(t *testing.T) {
	p := fixtureCodex()
	p.Status = domain.Stale(fixtureAsOf, domain.ProviderError{Kind: domain.ErrHTTP, Message: "HTTP 500"})
	got := lines(compact(UsageReport{AsOf: fixtureAsOf, Source: SourceCached, Providers: []ProviderReport{p}}, ViewUsage, false, nil))
	if !strings.HasPrefix(got[2], "△ Codex") || !strings.HasPrefix(got[3], "! Codex") || !strings.HasSuffix(got[3], "stale") {
		t.Errorf("%v", got)
	}
}

func TestOllamaCloudLabelledMonthly(t *testing.T) {
	row := firstLine(t, lines(compact(richReport(), ViewUsage, false, nil)), func(l string) bool { return strings.Contains(l, "Ollama Cloud") })
	if !strings.Contains(row, " mo ") || strings.Contains(row, "30d") {
		t.Error(row)
	}
}

func TestProviderOrderSetting(t *testing.T) {
	text := renderCompact(richReport(), ViewUsage, false, nil, time.UTC, []domain.ProviderID{domain.Codex, domain.Grok, domain.Claude})
	var got []string
	for _, l := range lines(text)[2:] {
		got = append(got, strings.TrimSpace(string([]rune(l)[2:14])))
	}
	want := []string{"Codex", "Grok", "Claude", "personal", "work●", "OpenRouter"}
	if strings.Join(got[:6], ",") != strings.Join(want, ",") {
		t.Errorf("%v", got)
	}
}

func TestGrokManagementSpendIsNotNoLimit(t *testing.T) {
	p := fixtureGrok()
	p.Status = domain.OK(fixtureAsOf)
	p.Snapshot = &domain.UsageSnapshot{ProviderID: domain.Grok, AsOf: fixtureAsOf, CostTodayUSD: dec("1.25"), BalanceUSD: dec("12.50"), Raw: map[string]string{"source": "management"}}
	text := compact(UsageReport{AsOf: fixtureAsOf, Source: SourceLive, Providers: []ProviderReport{p}}, ViewUsage, false, nil)
	if strings.Contains(text, "no limit") || !strings.Contains(text, "spent") || strings.Contains(text, "no cost data") {
		t.Error(text)
	}
}

func TestTextGaugeHasNoTrailingSpaces(t *testing.T) {
	noLimit := fixtureCodex()
	noLimit.Snapshot = &domain.UsageSnapshot{ProviderID: domain.Codex, AsOf: fixtureAsOf, TokensToday: intp(0), Raw: map[string]string{}}
	report := UsageReport{AsOf: fixtureAsOf, Source: SourceCached, Providers: []ProviderReport{fixtureOpenRouter(), noLimit}}
	for _, color := range []bool{false, true} {
		for _, l := range lines(compact(report, ViewUsage, color, nil)) {
			if strings.HasSuffix(l, " ") || strings.HasSuffix(l, " "+ansiReset) {
				t.Errorf("trailing space: %q", l)
			}
		}
	}
}

func TestLocaleStyles(t *testing.T) {
	amount := *dec("1234.5")
	negative := *dec("-3.5")
	cases := []struct{ locale, pos, neg, tokens string }{
		{"en_US", "$1,234.50", "-$3.50", "1,204,331"},
		{"en_US.UTF-8", "$1,234.50", "-$3.50", "1,204,331"},
		{"en", "$1,234.50", "-$3.50", "1,204,331"},
		{"C", "$1,234.50", "-$3.50", "1,204,331"},
		{"en_TH", "US$1,234.50", "-US$3.50", "1,204,331"},
		{"en_GB", "US$1,234.50", "-US$3.50", "1,204,331"},
		{"en_CA", "US$1,234.50", "-US$3.50", "1,204,331"},
		{"en_AU", "USD\u00a01,234.50", "-USD\u00a03.50", "1,204,331"},
		{"th_TH", "US$1,234.50", "-US$3.50", "1,204,331"},
		{"ko_KR", "US$1,234.50", "-US$3.50", "1,204,331"},
		{"zh_CN", "US$1,234.50", "-US$3.50", "1,204,331"},
		{"ja_JP", "$1,234.50", "-$3.50", "1,204,331"},
		{"de_DE", "1.234,50\u00a0$", "-3,50\u00a0$", "1.204.331"},
		{"fr_FR", "1\u202f234,50\u00a0$US", "-3,50\u00a0$US", "1\u202f204\u202f331"},
		{"ru_RU", "1\u00a0234,50\u00a0$", "-3,50\u00a0$", "1\u00a0204\u00a0331"},
	}
	defer func() { activeStyle = styleUS }()
	for _, c := range cases {
		activeStyle = StyleForLocale(c.locale)
		if usd(amount) != c.pos || usd(negative) != c.neg || tokenCount(1_204_331) != c.tokens {
			t.Errorf("%s: %q %q %q", c.locale, usd(amount), usd(negative), tokenCount(1_204_331))
		}
	}
}
