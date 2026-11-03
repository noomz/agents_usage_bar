package cli

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/cache"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
)

type fakeProvider struct {
	id     domain.ProviderID
	caps   domain.Capabilities
	snap   domain.UsageSnapshot
	err    error
	status domain.ProviderStatus
}

func (f *fakeProvider) ID() domain.ProviderID             { return f.id }
func (f *fakeProvider) DisplayName() string               { return string(f.id) }
func (f *fakeProvider) Capabilities() domain.Capabilities { return f.caps }
func (f *fakeProvider) Status() domain.ProviderStatus     { return f.status }
func (f *fakeProvider) Fetch(context.Context, time.Time) (domain.UsageSnapshot, error) {
	return f.snap, f.err
}

type memCache struct {
	cache.Noop
	stored map[domain.ProviderID]domain.ProviderState
}

func (m memCache) LoadAll() map[domain.ProviderID]domain.ProviderState { return m.stored }

func snapshotOf(id domain.ProviderID, tokens int) domain.UsageSnapshot {
	return domain.UsageSnapshot{ProviderID: id, AsOf: fixtureAsOf, TokensToday: &tokens, CostTodayUSD: dec("1"), Raw: map[string]string{}}
}

func TestLiveFetchTotals(t *testing.T) {
	p := &fakeProvider{id: domain.Claude, caps: domain.Capabilities{HasTokens: true}, snap: snapshotOf(domain.Claude, 5), status: domain.OK(fixtureAsOf)}
	report := Session{Providers: []provider.Provider{p}, Cache: cache.Noop{}}.Fetch(context.Background(), ProviderFilter{}, false, fixtureAsOf)
	if report.Source != SourceLive || len(report.Providers) != 1 || report.Totals().Tokens != 5 {
		t.Errorf("%+v", report)
	}
}

func TestCachedPathReadsStoreAndSkipsProviders(t *testing.T) {
	snap := snapshotOf(domain.Codex, 9)
	last := fixtureAsOf
	store := memCache{stored: map[domain.ProviderID]domain.ProviderState{
		domain.Codex:  {ID: domain.Codex, DisplayName: "Codex", Snapshot: &snap, Status: domain.OK(last), LastSuccess: &last},
		domain.Claude: {ID: domain.Claude, DisplayName: "Claude", Status: domain.Unauthenticated()},
	}}
	exploding := &fakeProvider{id: domain.Codex, err: errors.New("must not run")}
	report := Session{Providers: []provider.Provider{exploding}, Cache: store}.Fetch(context.Background(), filterAll, true, fixtureAsOf)
	if report.Source != SourceCached || len(report.Providers) != 2 {
		t.Fatalf("%+v", report)
	}
	if report.Providers[0].ID != domain.Claude || *report.Providers[1].Snapshot.TokensToday != 9 {
		t.Errorf("sorted by id: %+v", report.Providers)
	}
}

func TestFilterOne(t *testing.T) {
	claude := &fakeProvider{id: domain.Claude, snap: snapshotOf(domain.Claude, 1)}
	grok := &fakeProvider{id: domain.Grok, snap: snapshotOf(domain.Grok, 1)}
	report := Session{Providers: []provider.Provider{claude, grok}, Cache: cache.Noop{}}.Fetch(context.Background(), one(domain.Grok), false, fixtureAsOf)
	if len(report.Providers) != 1 || report.Providers[0].ID != domain.Grok {
		t.Errorf("%+v", report.Providers)
	}
}

func TestFetchErrorKeepsCacheAndHidesText(t *testing.T) {
	prior := domain.UsageSnapshot{ProviderID: domain.Gemini, AsOf: fixtureAsOf, Quota: &domain.Quota{Used: 0.4, Limit: 1, Remaining: 0.6}, Raw: map[string]string{"note": domain.DegradedNote}}
	last := fixtureAsOf
	store := memCache{stored: map[domain.ProviderID]domain.ProviderState{
		domain.Gemini: {ID: domain.Gemini, DisplayName: "Gemini", Snapshot: &prior, Status: domain.OK(last), LastSuccess: &last},
	}}
	p := &fakeProvider{id: domain.Gemini, err: errors.New("secret detail")}
	row := Session{Providers: []provider.Provider{p}, Cache: store}.Fetch(context.Background(), filterAll, false, fixtureAsOf).Providers[0]
	if row.ErrorDescription != nil || row.Snapshot == nil || row.Snapshot.Quota.Used != 0.4 || row.Status.Kind != domain.StatusStale {
		t.Errorf("%+v", row)
	}
}

func TestFetchErrorWithoutCacheIsErrorRow(t *testing.T) {
	p := &fakeProvider{id: domain.Gemini, err: domain.HTTPError{Status: 500}}
	row := Session{Providers: []provider.Provider{p}, Cache: cache.Noop{}}.Fetch(context.Background(), filterAll, false, fixtureAsOf).Providers[0]
	if row.Status.Kind != domain.StatusError || row.Snapshot != nil || row.Status.Err.Message != "HTTP 500" {
		t.Errorf("%+v", row)
	}
}

func TestEnabledFilter(t *testing.T) {
	p := &fakeProvider{id: domain.Claude, snap: snapshotOf(domain.Claude, 1)}
	report := Session{Providers: []provider.Provider{p}, Cache: cache.Noop{}, IsEnabled: func(domain.ProviderID) bool { return false }}.Fetch(context.Background(), ProviderFilter{}, false, fixtureAsOf)
	if len(report.Providers) != 0 {
		t.Errorf("%+v", report.Providers)
	}
}

func TestPlaceholdersPreferCachedSnapshotAndSortByKnownOrder(t *testing.T) {
	snap := snapshotOf(domain.Codex, 2)
	store := memCache{stored: map[domain.ProviderID]domain.ProviderState{domain.Codex: {ID: domain.Codex, DisplayName: "Codex", Snapshot: &snap, Status: domain.OK(fixtureAsOf)}}}
	session := Session{
		Providers: []provider.Provider{&fakeProvider{id: domain.Ollama, snap: snapshotOf(domain.Ollama, 0), status: domain.NotRunning(), caps: domain.Capabilities{IsLocal: true}}},
		Placeholders: []provider.PlaceholderSeed{
			{ProviderID: domain.Codex, DisplayName: "Codex", Status: domain.Unauthenticated()},
			{ProviderID: domain.Claude, DisplayName: "Claude", Status: domain.Unauthenticated()},
			{ProviderID: domain.Ollama, DisplayName: "Ollama", Status: domain.NotRunning()},
		},
		Cache: store,
	}
	rows := session.Fetch(context.Background(), filterAll, false, fixtureAsOf).Providers
	if len(rows) != 3 || rows[0].ID != domain.Claude || rows[1].ID != domain.Codex || rows[2].ID != domain.Ollama {
		t.Fatalf("%+v", rows)
	}
	if rows[0].Snapshot != nil || rows[0].Status.Kind != domain.StatusUnauthenticated {
		t.Errorf("placeholder: %+v", rows[0])
	}
	if rows[1].Snapshot == nil {
		t.Error("a cached snapshot wins over the placeholder")
	}
}
