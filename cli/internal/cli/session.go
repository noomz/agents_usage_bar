package cli

import (
	"context"
	"sort"
	"sync"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/cache"
	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
)

// ReportSource says where a report's data came from.
type ReportSource string

// The sources.
const (
	SourceLive   ReportSource = "live"
	SourceCached ReportSource = "cached"
)

// UsageReport is what every usage renderer draws.
type UsageReport struct {
	AsOf      time.Time
	Source    ReportSource
	Providers []ProviderReport
}

// ProviderReport is one row of a report.
type ProviderReport struct {
	ID                 domain.ProviderID
	DisplayName        string
	Status             domain.ProviderStatus
	Snapshot           *domain.UsageSnapshot
	PlaceholderMessage *string
	ErrorDescription   *string
	IsLocal            bool
	HasTokens          bool
}

func reportFromState(s domain.ProviderState, isLocal bool) ProviderReport {
	return ProviderReport{
		ID: s.ID, DisplayName: s.DisplayName, Status: s.Status, Snapshot: s.Snapshot,
		PlaceholderMessage: s.PlaceholderMessage, IsLocal: isLocal, HasTokens: s.ID.ContributesToTodayTotal(),
	}
}

func reportFromSeed(seed provider.PlaceholderSeed) ProviderReport {
	return ProviderReport{
		ID: seed.ProviderID, DisplayName: seed.DisplayName, Status: seed.Status,
		PlaceholderMessage: seed.PlaceholderMessage, IsLocal: seed.ProviderID.IsLocalRuntime(),
		HasTokens: seed.ProviderID.ContributesToTodayTotal(),
	}
}

// Totals sums token-reporting rows.
func (r UsageReport) Totals() domain.DailyTotals {
	tokens := 0
	cost := decimal.Decimal{}
	for _, p := range r.Providers {
		if !p.HasTokens || p.Snapshot == nil {
			continue
		}
		if p.Snapshot.TokensToday != nil {
			tokens += *p.Snapshot.TokensToday
		}
		if p.Snapshot.CostTodayUSD != nil {
			cost = cost.Add(*p.Snapshot.CostTodayUSD)
		}
	}
	return domain.DailyTotals{Tokens: tokens, CostUSD: cost}
}

func (r UsageReport) hasAnyQuotaOnlyProvider() bool {
	for _, p := range r.Providers {
		if !p.HasTokens && !p.IsLocal {
			return true
		}
	}
	return false
}

// Session is a one-shot fetch. It never writes provider rows and never notifies.
type Session struct {
	Providers    []provider.Provider
	Placeholders []provider.PlaceholderSeed
	Cache        cache.Store
	IsEnabled    func(domain.ProviderID) bool
}

// Fetch builds a report: the cache as-is when cached, otherwise every wanted provider fetched
// concurrently, with placeholder rows for the rest.
func (s Session) Fetch(ctx context.Context, filter ProviderFilter, cached bool, now time.Time) UsageReport {
	cachedStates := s.Cache.LoadAll()
	var reports []ProviderReport
	source := SourceLive

	if cached {
		source = SourceCached
		states := make([]domain.ProviderState, 0, len(cachedStates))
		for _, st := range cachedStates {
			states = append(states, st)
		}
		sort.Slice(states, func(i, j int) bool { return states[i].ID < states[j].ID })
		for _, st := range states {
			reports = append(reports, reportFromState(st, st.ID.IsLocalRuntime()))
		}
	} else {
		reports = s.fetchLive(ctx, filter, cachedStates, now)
	}

	wanted := make([]ProviderReport, 0, len(reports))
	for _, r := range reports {
		if s.wants(r.ID, filter) {
			wanted = append(wanted, r)
		}
	}
	return UsageReport{AsOf: now, Source: source, Providers: wanted}
}

func (s Session) fetchLive(ctx context.Context, filter ProviderFilter, cachedStates map[domain.ProviderID]domain.ProviderState, now time.Time) []ProviderReport {
	selected := make([]provider.Provider, 0, len(s.Providers))
	seen := map[domain.ProviderID]bool{}
	for _, p := range s.Providers {
		if s.wants(p.ID(), filter) {
			selected = append(selected, p)
			seen[p.ID()] = true
		}
	}
	reports := make([]ProviderReport, len(selected))
	var wg sync.WaitGroup
	for i, p := range selected {
		wg.Add(1)
		go func() {
			defer wg.Done()
			var previous *domain.ProviderState
			if st, ok := cachedStates[p.ID()]; ok {
				previous = &st
			}
			reports[i] = fetchOne(ctx, p, now, previous)
		}()
	}
	wg.Wait()

	for _, seed := range s.Placeholders {
		if !s.wants(seed.ProviderID, filter) || seen[seed.ProviderID] {
			continue
		}
		if st, ok := cachedStates[seed.ProviderID]; ok && st.Snapshot != nil {
			reports = append(reports, reportFromState(st, st.ID.IsLocalRuntime()))
		} else {
			reports = append(reports, reportFromSeed(seed))
		}
	}
	order := func(id domain.ProviderID) int {
		for i, known := range domain.AllKnown {
			if known == id {
				return i
			}
		}
		return len(domain.AllKnown)
	}
	sort.SliceStable(reports, func(i, j int) bool { return order(reports[i].ID) < order(reports[j].ID) })
	return reports
}

func (s Session) wants(id domain.ProviderID, filter ProviderFilter) bool {
	switch filter.Kind {
	case FilterAll:
		return true
	case FilterOne:
		return id == filter.ID
	}
	return s.IsEnabled == nil || s.IsEnabled(id)
}

// fetchOne keeps the last snapshot on failure and never surfaces error text.
func fetchOne(ctx context.Context, p provider.Provider, now time.Time, previous *domain.ProviderState) ProviderReport {
	caps := p.Capabilities()
	snapshot, status, err := p.Fetch(ctx, now)
	if err == nil {
		return ProviderReport{
			ID: p.ID(), DisplayName: p.DisplayName(), Status: status, Snapshot: &snapshot,
			IsLocal: caps.IsLocal, HasTokens: caps.HasTokens,
		}
	}
	if previous != nil {
		return reportFromState(previous.ApplyingError(err), caps.IsLocal)
	}
	return ProviderReport{
		ID: p.ID(), DisplayName: p.DisplayName(), Status: domain.Errored(domain.ProviderErrorFrom(err)),
		IsLocal: caps.IsLocal, HasTokens: caps.HasTokens,
	}
}
