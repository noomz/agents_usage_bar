package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

// Goldens are shared with the Swift tests, so a byte difference fails here too.
const goldenDir = "../../../AgentsUsageBarTests/CLITests/Golden"

func assertGolden(t *testing.T, got, name string) {
	t.Helper()
	want, err := os.ReadFile(filepath.Join(goldenDir, name))
	if err != nil {
		t.Fatal(err)
	}
	if got != string(want) {
		t.Errorf("golden mismatch: %s\n--- got\n%s\n--- want\n%s", name, got, want)
	}
}

// fixtureAsOf is 2026-09-24 05:20:00 UTC.
var fixtureAsOf = time.Unix(1_790_227_200, 0).UTC()

func after(d time.Duration) *time.Time {
	t := fixtureAsOf.Add(d)
	return &t
}

func f64(v float64) *float64 { return &v }
func dec(s string) *decimal.Decimal {
	d := decimal.MustParse(s)
	return &d
}
func intp(n int) *int { return &n }

const (
	hour = time.Hour
	day  = 24 * time.Hour
)

func unitQuota(used, remaining float64) *domain.Quota {
	return &domain.Quota{Used: used, Limit: 1, Remaining: remaining}
}

func window(name string, used float64, reset *time.Time) domain.QuotaWindow {
	return domain.QuotaWindow{Name: name, Utilization: &used, ResetsAt: reset}
}

func timedWindow(name string, used float64, reset *time.Time, seconds float64) domain.QuotaWindow {
	w := window(name, used, reset)
	w.Duration = &seconds
	return w
}

func okReport(id domain.ProviderID, name string, snap domain.UsageSnapshot, hasTokens bool) ProviderReport {
	return ProviderReport{ID: id, DisplayName: name, Status: domain.OK(fixtureAsOf), Snapshot: &snap, HasTokens: hasTokens}
}

func fixtureClaude() ProviderReport {
	p5, p7, w5, w7 := after(4*hour+20*time.Minute), after(31*hour), after(2*hour+50*time.Minute), after(3*day+8*hour)
	return okReport(domain.Claude, "Claude", domain.UsageSnapshot{
		ProviderID: domain.Claude, AsOf: fixtureAsOf, TokensToday: intp(232_400_512), CostTodayUSD: dec("273.86"),
		Quota: unitQuota(0.47, 0.53), Raw: map[string]string{},
		QuotaWindows: []domain.QuotaWindow{
			window("personal 5h", 0.12, p5), window("personal 7d", 0.17, p7),
			window("work 5h", 0.31, w5), window("work 7d", 0.47, w7),
		},
		Accounts: []domain.AccountUsage{
			{Name: "personal", CostTodayUSD: dec("53.63"), Quota: unitQuota(0.17, 0.83), QuotaWindows: []domain.QuotaWindow{window("5h", 0.12, p5), window("7d", 0.17, nil)}},
			{Name: "work", CostTodayUSD: dec("220.23"), Quota: unitQuota(0.47, 0.53), QuotaWindows: []domain.QuotaWindow{window("5h", 0.31, w5), window("7d", 0.47, w7)}},
		},
	}, true)
}

func fixtureCodex() ProviderReport {
	return okReport(domain.Codex, "Codex", domain.UsageSnapshot{
		ProviderID: domain.Codex, AsOf: fixtureAsOf, TokensToday: intp(1_204_331), CostTodayUSD: dec("0.07"),
		Quota: unitQuota(0.69, 0.31), Raw: map[string]string{},
		QuotaWindows: []domain.QuotaWindow{
			timedWindow("primary", 0.69, after(2*hour+50*time.Minute), 5*3600),
			timedWindow("secondary", 0.22, after(5*day), 7*86400),
		},
	}, true)
}

func fixtureOpenRouter() ProviderReport {
	return okReport(domain.OpenRouter, "OpenRouter", domain.UsageSnapshot{
		ProviderID: domain.OpenRouter, AsOf: fixtureAsOf, CostTodayUSD: dec("1.25"), BalanceUSD: dec("9.40"),
		Quota: unitQuota(0.94, 0.06), Raw: map[string]string{},
		PeriodSpendUSD: &domain.PeriodSpend{Day: *dec("1.25"), Week: *dec("8.10"), Month: *dec("31.40")},
	}, false)
}

func fixtureGemini() ProviderReport {
	r := okReport(domain.Gemini, "Gemini", domain.UsageSnapshot{
		ProviderID: domain.Gemini, AsOf: fixtureAsOf, Quota: unitQuota(0.19, 0.81), Raw: map[string]string{"note": domain.DegradedNote},
		QuotaWindows: []domain.QuotaWindow{window("gemini-2.5-pro", 0.19, after(hour)), window("gemini-2.5-flash", 0.04, after(hour))},
	}, false)
	r.Status = domain.Errored(domain.ProviderError{Kind: domain.ErrHTTP, Message: "HTTP 503"})
	return r
}

func fixtureGrok() ProviderReport {
	return ProviderReport{ID: domain.Grok, DisplayName: "Grok", Status: domain.Unauthenticated()}
}

func fixtureOllama() ProviderReport {
	return ProviderReport{ID: domain.Ollama, DisplayName: "Ollama", Status: domain.NotRunning(), IsLocal: true}
}

// The Swift fixture builds this row through the real Ollama Cloud mapper; these are its values.
func fixtureOllamaCloud() ProviderReport {
	reset := time.Date(2026, 10, 8, 0, 0, 0, 0, time.UTC)
	return okReport(domain.OllamaCloud, "Ollama Cloud", domain.UsageSnapshot{
		ProviderID: domain.OllamaCloud, AsOf: fixtureAsOf, Quota: unitQuota(0.62, 0.38),
		Raw:          map[string]string{"credentialSource": "env", "ownSpendLast4WeeksUSD": "4.5", "plan": "pro"},
		QuotaWindows: []domain.QuotaWindow{window("mo", 0.62, &reset)},
	}, false)
}

func fixtureLMStudioLlamaCpp() ProviderReport {
	return ProviderReport{ID: domain.LMStudioLlamaCpp, DisplayName: "LM Studio llama.cpp", Status: domain.NotRunning(), PlaceholderMessage: strPtr("Start LM Studio's llama.cpp server"), IsLocal: true}
}

func fixtureLlamaCpp() ProviderReport {
	r := okReport(domain.LlamaCpp, "llama.cpp", domain.UsageSnapshot{
		ProviderID: domain.LlamaCpp, AsOf: fixtureAsOf,
		Raw: map[string]string{"modelCount": "1", "modelName": "Qwen3.5-4B", "vramBytes": "3221225472"},
	}, false)
	r.IsLocal = true
	return r
}

func fixtureCustomEngine() ProviderReport {
	return ProviderReport{ID: "engine.gpu-box", DisplayName: "gpu-box", Status: domain.NotRunning(), PlaceholderMessage: strPtr("Set [engine.gpu-box] port or match_path in config.toml"), IsLocal: true}
}

func richReport() UsageReport {
	return UsageReport{AsOf: fixtureAsOf, Source: SourceCached, Providers: []ProviderReport{
		fixtureOpenRouter(), fixtureClaude(), fixtureCodex(), fixtureGemini(), fixtureGrok(),
		fixtureOllama(), fixtureOllamaCloud(), fixtureLMStudioLlamaCpp(), fixtureLlamaCpp(), fixtureCustomEngine(),
	}}
}

func lines(s string) []string { return strings.Split(strings.TrimSuffix(s, "\n"), "\n") }

func firstLine(t *testing.T, all []string, match func(string) bool) string {
	t.Helper()
	for _, l := range all {
		if match(l) {
			return l
		}
	}
	t.Fatalf("no matching line in:\n%s", strings.Join(all, "\n"))
	return ""
}

// syntheticDays ports SyntheticHistory: fake slugs and round numbers. Every day covers each
// billing model. Every 7th Claude day is a gap and every 5th Codex day is backfilled.
func syntheticDays(lastKey string, count int) []domain.DayFile {
	last, err := time.Parse("2006-01-02", lastKey)
	if err != nil {
		panic(err)
	}
	days := make([]domain.DayFile, count)
	for offset := range days {
		date := last.AddDate(0, 0, offset-count+1)
		days[offset] = syntheticDay(date.Format("2006-01-02"), date, offset)
	}
	return days
}

func synthMoney(dollars, quarters int) *domain.Money {
	amount := decimal.FromInt(int64(dollars)).Add(decimal.FromInt(int64(quarters)).Div(decimal.FromInt(4)))
	m := domain.NewMoney(amount)
	return &m
}

func syntheticDay(key string, start time.Time, index int) domain.DayFile {
	peaks := []float64{0.25, 0.5, 0.85, 0.96, 1.0}
	firstSeen, lastSeen, resetsAt := start.Add(9*hour), start.Add(18*hour), start.Add(14*hour)
	var records []domain.DayRecord
	var events []domain.UsageEvent

	records = append(records, domain.DayRecord{
		Provider: domain.OpenRouter, Tokens: intp(10_000 * (index%5 + 1)), CostUSD: synthMoney(index%4, 2), BalanceUSD: synthMoney(20-index%10, 0),
		Quota:    map[string]domain.QuotaDay{},
		Accounts: []domain.DayAccount{{Key: "default", Label: "default", BillingModel: domain.BillingMetered, Quota: map[string]domain.QuotaDay{}}},
		Origin:   domain.OriginObserved, FirstSeen: &firstSeen, LastSeen: &lastSeen,
	})

	if index%7 != 6 {
		peak := peaks[index%len(peaks)]
		five := domain.QuotaDay{Peak: peak, PeakResetsAt: &resetsAt, EndOfDay: peak / 2}
		seven := domain.QuotaDay{Peak: 0.1 * float64(index%8+1), EndOfDay: 0.1 * float64(index%8+1)}
		records = append(records, domain.DayRecord{
			Provider: domain.Claude, Tokens: intp(100_000 * (index%3 + 1)), CostUSD: synthMoney(5*(index%3+1), 0), CostEstimated: true,
			Quota: map[string]domain.QuotaDay{"5h": five, "7d": seven},
			Accounts: []domain.DayAccount{
				{Key: "work-demo", Label: "work-demo", BillingModel: domain.BillingSubscription, Plan: strPtr("max"), CostUSD: synthMoney(4*(index%3+1), 0), Quota: map[string]domain.QuotaDay{"5h": five}},
				{Key: "default", Label: "default", BillingModel: domain.BillingSubscription, Plan: strPtr("pro"), CostUSD: synthMoney(index%3+1, 0), Quota: map[string]domain.QuotaDay{"5h": {Peak: 0.25, EndOfDay: 0.25}}},
			},
			Origin: domain.OriginObserved, FirstSeen: &firstSeen, LastSeen: &lastSeen,
		})
		if peak >= 0.8 {
			claude := domain.Claude
			events = append(events, domain.UsageEvent{Time: start.Add(12 * hour), Provider: &claude, Kind: domain.EventBand80, Window: strPtr("5h"), Fraction: peak, Notified: true})
		}
	}

	backfilled := index%5 == 4
	codex := domain.DayRecord{
		Provider: domain.Codex, Tokens: intp(50_000 * (index%4 + 1)), CostUSD: synthMoney(index%4+1, 0), CostEstimated: true,
		Quota: map[string]domain.QuotaDay{},
		Accounts: []domain.DayAccount{
			{Key: "a1b2c3d4e5f6", Label: "acct-a1b2", BillingModel: domain.BillingMetered, BillingModelAssumed: backfilled, Quota: map[string]domain.QuotaDay{}},
			{Key: "f6e5d4c3b2a1", Label: "plus", BillingModel: domain.BillingSubscription, Plan: strPtr("plus"), BillingModelAssumed: backfilled, Quota: map[string]domain.QuotaDay{}},
		},
		Origin: domain.OriginObserved, FirstSeen: &firstSeen, LastSeen: &lastSeen,
	}
	if backfilled {
		codex.Origin, codex.FirstSeen, codex.LastSeen = domain.OriginBackfilled, nil, nil
	} else {
		codex.Quota["5h"] = domain.QuotaDay{Peak: 0.5, EndOfDay: 0.25}
	}
	records = append(records, codex)

	records = append(records, domain.DayRecord{
		Provider: domain.Ollama, Quota: map[string]domain.QuotaDay{},
		Accounts: []domain.DayAccount{{Key: "default", Label: "default", BillingModel: domain.BillingLocal, Quota: map[string]domain.QuotaDay{}}},
		Origin:   domain.OriginObserved, FirstSeen: &firstSeen, LastSeen: &lastSeen,
	})
	domainSortRecords(records)
	return domain.DayFile{SchemaVersion: 1, Date: key, TimeZone: "UTC", Records: records, Events: events}
}

func domainSortRecords(records []domain.DayRecord) {
	for i := 1; i < len(records); i++ {
		for j := i; j > 0 && records[j].Provider < records[j-1].Provider; j-- {
			records[j], records[j-1] = records[j-1], records[j]
		}
	}
}
