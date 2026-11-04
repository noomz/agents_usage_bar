package openrouter

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/cache"
	"github.com/noomz/agents_usage_bar/cli/internal/clock"
	"github.com/noomz/agents_usage_bar/cli/internal/config"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/providers/httpscript"
	"github.com/noomz/agents_usage_bar/cli/internal/secret"
)

const (
	creditsKey = "GET /api/v1/credits"
	keyKey     = "GET /api/v1/key"
)

var now = time.Date(2026, 5, 11, 14, 0, 0, 0, time.UTC)

func fixture(t *testing.T, name string) httpscript.Reply {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("../../../../AgentsUsageBarTests/ProvidersOpenRouterTests/Fixtures", name))
	if err != nil {
		t.Fatal(err)
	}
	return httpscript.JSON(string(data))
}

func creditsJSON(credits, usage string) httpscript.Reply {
	return httpscript.JSON(fmt.Sprintf(`{"data":{"total_credits":%s,"total_usage":%s}}`, credits, usage))
}

func build(t *testing.T, http *httpscript.Client) (provider.Provider, cache.Store) {
	t.Helper()
	dayKeys := domain.NewDayKeyOwner(clock.Fixed(now), time.UTC)
	store := cache.NewFile(filepath.Join(t.TempDir(), "today.json"), dayKeys)
	return buildWith(http, store, dayKeys), store
}

func buildWith(http *httpscript.Client, store cache.Store, dayKeys *domain.DayKeyOwner) provider.Provider {
	key := secret.New("fake-openrouter-key")
	env := provider.Env{Config: config.Defaults(), HTTP: http, Cache: store, DayKeys: dayKeys}
	env.Config.OpenRouter.APIKey = &key
	return Build(env)
}

func TestSnapshot(t *testing.T) {
	limited, unlimited := fixture(t, "key.with_limit.json"), fixture(t, "key.no_limit.json")
	// Runtime values: Go evaluates constant expressions exactly, and the provider subtracts doubles.
	limit, used, credit, spent := 10.0, 8.20, 100.50, 25.30
	noRemaining := httpscript.JSON(strings.Replace(limited.Body, `"limit_remaining": 1.80`, `"limit_remaining": null`, 1))
	for _, tc := range []struct {
		name    string
		credits httpscript.Reply
		key     httpscript.Reply
		balance string
		quota   *domain.Quota
	}{
		{"key limit", fixture(t, "credits.success.json"), limited, "75.2", &domain.Quota{Used: 8.20, Limit: 10, Remaining: 1.80}},
		{"remaining falls back to limit minus usage", fixture(t, "credits.success.json"), noRemaining, "75.2", &domain.Quota{Used: 8.20, Limit: 10, Remaining: limit - used}},
		{"no limit uses prepaid credits", fixture(t, "credits.success.json"), unlimited, "75.2", &domain.Quota{Used: 25.30, Limit: 100.50, Remaining: credit - spent}},
		{"no limit, overspent credits clamp", creditsJSON("5", "7"), unlimited, "-2", &domain.Quota{Used: 7, Limit: 5, Remaining: 0}},
		{"no limit, no credits", creditsJSON("0", "0"), unlimited, "0", nil},
	} {
		http := httpscript.New().Script(creditsKey, tc.credits).Script(keyKey, tc.key)
		p, _ := build(t, http)
		snap, status, err := p.Fetch(context.Background(), now)
		if err != nil {
			t.Errorf("%s: %v", tc.name, err)
			continue
		}
		if got := snap.BalanceUSD.String(); got != tc.balance {
			t.Errorf("%s: balance %s", tc.name, got)
		}
		if !reflect.DeepEqual(snap.Quota, tc.quota) {
			t.Errorf("%s: quota %+v", tc.name, snap.Quota)
		}
		if snap.TokensToday != nil || snap.Raw == nil || snap.ProviderID != domain.OpenRouter || !snap.AsOf.Equal(now) {
			t.Errorf("%s: snapshot %+v", tc.name, snap)
		}
		if status.Kind != domain.StatusOK {
			t.Errorf("%s: status %+v", tc.name, status)
		}
	}
}

func TestPeriodSpendPrintsSwiftBytes(t *testing.T) {
	http := httpscript.New().Script(creditsKey, fixture(t, "credits.success.json")).Script(keyKey, fixture(t, "key.with_limit.json"))
	p, _ := build(t, http)
	snap, _, err := p.Fetch(context.Background(), now)
	if err != nil {
		t.Fatal(err)
	}
	s := snap.PeriodSpendUSD
	if s.Day.String() != "1.1" || s.Week.String() != "5.3" || s.Month.String() != "8.2" {
		t.Errorf("%s %s %s", s.Day, s.Week, s.Month)
	}
}

func TestBaselineDelta(t *testing.T) {
	yesterday := now.Add(-24 * time.Hour)
	for _, tc := range []struct {
		name     string
		seedAt   *time.Time
		seed     float64
		usage    string
		cost     string
		baseline float64
	}{
		{"cold launch records the baseline", nil, 0, "25.3", "0", 25.3},
		{"second poll is the delta", &now, 25, "26", "1", 25},
		{"negative delta resets", &now, 25, "20", "0", 20},
		{"new day resets", &yesterday, 50, "55", "0", 55},
	} {
		http := httpscript.New().Script(creditsKey, creditsJSON("100", tc.usage)).Script(keyKey, fixture(t, "key.no_limit.json"))
		p, store := build(t, http)
		if tc.seedAt != nil {
			store.MaintainBaseline(domain.OpenRouter, *tc.seedAt, tc.seed)
		}
		snap, _, err := p.Fetch(context.Background(), now)
		if err != nil {
			t.Errorf("%s: %v", tc.name, err)
			continue
		}
		if got := snap.CostTodayUSD.String(); got != tc.cost {
			t.Errorf("%s: cost %s", tc.name, got)
		}
		b, _ := store.Baseline(domain.OpenRouter)
		if b == nil || b.Value != tc.baseline || b.Date != "2026-05-11" {
			t.Errorf("%s: baseline %+v", tc.name, b)
		}
	}
}

func TestFailures(t *testing.T) {
	credits, key := fixture(t, "credits.success.json"), fixture(t, "key.with_limit.json")
	dropped := func(field string) httpscript.Reply {
		var kept []string
		for _, line := range strings.Split(key.Body, "\n") {
			if !strings.Contains(line, `"`+field+`"`) {
				kept = append(kept, line)
			}
		}
		return httpscript.JSON(strings.Join(kept, "\n"))
	}
	for _, tc := range []struct {
		name         string
		credits, key httpscript.Reply
		kind         domain.ProviderErrorKind
	}{
		{"credits 401", httpscript.Status(401), key, domain.ErrAuth},
		{"key 500", credits, httpscript.Status(500), domain.ErrHTTP},
		{"credits 402", httpscript.Status(402), key, domain.ErrPaymentRequired},
		{"error payload", fixture(t, "credits.unauthorized.json"), key, domain.ErrDecode},
		{"key field required", credits, dropped("usage_monthly"), domain.ErrDecode},
		{"byok field required", credits, dropped("byok_usage_daily"), domain.ErrDecode},
		{"tier required", credits, dropped("is_free_tier"), domain.ErrDecode},
		{"mistyped credits", httpscript.JSON(`{"data":{"total_credits":"1","total_usage":2}}`), key, domain.ErrDecode},
		{"transport", httpscript.Fail(domain.NetworkError{Code: domain.NetworkTimedOut, Err: errors.New("x")}), key, domain.ErrNetwork},
	} {
		http := httpscript.New().Script(creditsKey, tc.credits).Script(keyKey, tc.key)
		p, store := build(t, http)
		_, _, err := p.Fetch(context.Background(), now)
		if err == nil {
			t.Errorf("%s: no error", tc.name)
			continue
		}
		if pe := domain.ProviderErrorFrom(err); pe.Kind != tc.kind {
			t.Errorf("%s: %+v", tc.name, pe)
		}
		if b, _ := store.Baseline(domain.OpenRouter); b != nil {
			t.Errorf("%s: a failed fetch wrote a baseline", tc.name)
		}
	}
}

func TestBuildNeedsAKey(t *testing.T) {
	management := secret.New("fake-management")
	env := provider.Env{Config: config.Defaults()}
	env.Config.OpenRouter.ManagementKey = &management
	if p := Build(env); p != nil {
		t.Errorf("built %v", p)
	}
}

func TestRequestShape(t *testing.T) {
	http := httpscript.New().Script("GET /custom/credits", creditsJSON("1", "0")).Script("GET /custom/key", fixture(t, "key.no_limit.json"))
	key, referer := secret.New("fake-openrouter-key"), "https://example.invalid"
	dayKeys := domain.NewDayKeyOwner(clock.Fixed(now), time.UTC)
	env := provider.Env{Config: config.Defaults(), HTTP: http, Cache: cache.Noop{}, DayKeys: dayKeys}
	env.Config.OpenRouter.APIKey = &key
	env.Config.OpenRouter.HTTPReferer = &referer
	u, err := url.Parse("https://proxy.invalid/custom/")
	if err != nil {
		t.Fatal(err)
	}
	env.Config.OpenRouter.APIURL = u
	p := Build(env)
	if _, _, err := p.Fetch(context.Background(), now); err != nil {
		t.Fatal(err)
	}
	urls := map[string]bool{}
	for _, call := range http.Calls() {
		urls[call.URL] = true
		if call.Bearer != "fake-openrouter-key" {
			t.Errorf("bearer on %s", call.URL)
		}
		if call.Headers["HTTP-Referer"] != referer || call.Headers["X-Title"] != "Agents Usage Bar" {
			t.Errorf("headers %v", call.Headers)
		}
	}
	if !urls["https://proxy.invalid/custom/credits"] || !urls["https://proxy.invalid/custom/key"] {
		t.Errorf("urls %v", urls)
	}
}

func TestIdentity(t *testing.T) {
	p, _ := build(t, httpscript.New())
	if p.ID() != domain.OpenRouter || p.DisplayName() != "OpenRouter" {
		t.Errorf("%v %v", p.ID(), p.DisplayName())
	}
	if want := (domain.Capabilities{HasQuota: true, HasCost: true}); p.Capabilities() != want {
		t.Errorf("caps %+v", p.Capabilities())
	}
}

func costsOverRuns(t *testing.T, store cache.Store, dayKeys *domain.DayKeyOwner) []string {
	t.Helper()
	var costs []string
	for i, usage := range []string{"10", "11", "12"} {
		http := httpscript.New().Script(creditsKey, creditsJSON("100", usage)).Script(keyKey, fixture(t, "key.no_limit.json"))
		snap, status, err := buildWith(http, store, dayKeys).Fetch(context.Background(), now)
		if err != nil || status.Kind != domain.StatusOK {
			t.Fatalf("run %d: %v %+v", i, err, status)
		}
		if snap.CostTodayUSD == nil {
			costs = append(costs, "nil")
		} else {
			costs = append(costs, snap.CostTodayUSD.String())
		}
	}
	return costs
}

func TestCostAcrossStoreStates(t *testing.T) {
	const newer = `{"schemaVersion":4,"baselines":[]}`
	const truncated = `{"schemaVersion":3,"provi`
	for _, tc := range []struct {
		name, seed string
		want       []string
		kept       bool
	}{
		{"missing", "", []string{"0", "1", "2"}, false},
		{"newer schema reports no cost and keeps the file", newer, []string{"nil", "nil", "nil"}, true},
		{"corrupt reports no cost once and then heals", truncated, []string{"nil", "1", "2"}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "today.json")
			if tc.seed != "" {
				if err := os.WriteFile(path, []byte(tc.seed), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			dayKeys := domain.NewDayKeyOwner(clock.Fixed(now), time.UTC)
			got := costsOverRuns(t, cache.NewFile(path, dayKeys), dayKeys)
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("costs %v, want %v", got, tc.want)
			}
			if data, _ := os.ReadFile(path); tc.kept && string(data) != tc.seed {
				t.Errorf("file changed: %s", data)
			}
		})
	}
}

// unstoredBaseline reads like a healthy store but cannot keep what it is given.
type unstoredBaseline struct {
	cache.Noop
	record *domain.BaselineRecord
}

func (s unstoredBaseline) Baseline(domain.ProviderID) (*domain.BaselineRecord, bool) {
	return s.record, true
}

func (unstoredBaseline) MaintainBaseline(domain.ProviderID, time.Time, float64) error {
	return errors.New("not stored")
}

func TestCostWhenTheBaselineCannotBeStored(t *testing.T) {
	dayKeys := domain.NewDayKeyOwner(clock.Fixed(now), time.UTC)
	if got := costsOverRuns(t, unstoredBaseline{}, dayKeys); !reflect.DeepEqual(got, []string{"nil", "nil", "nil"}) {
		t.Errorf("no baseline: %v", got)
	}
	today := &domain.BaselineRecord{Value: 9, Date: dayKeys.KeyFor(now)}
	if got := costsOverRuns(t, unstoredBaseline{record: today}, dayKeys); !reflect.DeepEqual(got, []string{"1", "2", "3"}) {
		t.Errorf("today's baseline still measures: %v", got)
	}
}
