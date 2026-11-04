package claude

import (
	"context"
	"os"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/cache"
	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/jsonl"
)

type usageSource interface {
	getUsage(ctx context.Context) (*usageResponse, error)
}

// sessionReads reconstructs usage from transcripts and reads quota from the OAuth endpoint. The
// oauth field is nil when no credential resolved at build.
type sessionReads struct {
	roots   func() []string
	pricing pricing
	oauth   usageSource
	cache   cache.Store
	dayKeys *domain.DayKeyOwner
}

// fetch returns the snapshot and today's tokens per session. Sessions are nil when nothing was
// read. An OAuth failure of any kind degrades to local data; a transcript or cursor-lock failure
// fails the fetch and advances no cursor.
func (s *sessionReads) fetch(ctx context.Context, now time.Time) (domain.UsageSnapshot, domain.ProviderStatus, map[string]int, error) {
	roots := s.roots()
	if s.oauth == nil && !anyExists(roots) {
		zeroTokens, zeroCost := 0, decimal.FromInt(0)
		return domain.UsageSnapshot{
			ProviderID: domain.Claude, AsOf: now, TokensToday: &zeroTokens, CostTodayUSD: &zeroCost,
			Raw: map[string]string{domain.RawProviderStatus: domain.StatusSentinelUnauth},
		}, domain.Unauthenticated(), nil, nil
	}
	var total domain.DailyUsageRecord
	var readErr error
	err := s.cache.WithCursors(func(c cache.Cursors) { total, readErr = s.readDelta(c, roots, now) })
	if err == nil {
		err = readErr
	}
	if err != nil {
		return domain.UsageSnapshot{}, domain.ProviderStatus{}, nil, err
	}

	var usage *usageResponse
	if s.oauth != nil {
		if response, err := s.oauth.getUsage(ctx); err == nil {
			usage = response
		}
	}

	totalTokens, totalCost := total.Tokens, total.CostUSD
	snapshot := domain.UsageSnapshot{ProviderID: domain.Claude, AsOf: now, TokensToday: &totalTokens, CostTodayUSD: &totalCost, Raw: map[string]string{}}
	if usage != nil {
		snapshot.QuotaWindows, snapshot.Quota = usageQuota(usage)
	}
	return snapshot, domain.OK(now), total.SessionTokens, nil
}

// readDelta counts the transcript bytes past the stored cursors and adds them to today's total.
func (s *sessionReads) readDelta(c cache.Cursors, roots []string, now time.Time) (domain.DailyUsageRecord, error) {
	today := s.dayKeys.StartOfDay(now)
	prior := c.AllTranscriptOffsets()
	var floor *time.Time
	for _, offset := range prior {
		if floor == nil || offset.LastModified.Before(*floor) {
			modified := offset.LastModified
			floor = &modified
		}
	}
	if floor != nil {
		earlier := floor.Add(-time.Second)
		floor = &earlier
	}

	seen := map[string]bool{}
	tokens, cost := 0, decimal.FromInt(0)
	sessions := map[string]int{}
	seenFiles := map[string]bool{}
	var offsets []domain.TranscriptOffset
	for _, path := range jsonl.ScanRoots(roots, floor) {
		// ccs instance roots are symlinks into a root already in the list.
		if seenFiles[path] {
			continue
		}
		seenFiles[path] = true
		key := jsonl.FileURL(path)
		var start uint64
		var modified *time.Time
		if offset, ok := prior[key]; ok {
			start, modified = offset.ByteOffset, &offset.LastModified
		}
		read, err := jsonl.ReadDelta(path, start, modified)
		if err != nil {
			return domain.DailyUsageRecord{}, err
		}
		offsets = append(offsets, domain.TranscriptOffset{URL: key, ByteOffset: read.NewOffset, LastModified: read.LastModified})
		for _, line := range read.Lines {
			record, ok := decodeTranscript(line)
			if !ok || record.timestamp.Before(today) {
				continue
			}
			if record.requestID != nil {
				if seen[*record.requestID] {
					continue
				}
				seen[*record.requestID] = true
			}
			tokens += record.totalTokens()
			sessions[sessionID(path)] += record.totalTokens()
			cost = cost.Add(s.pricing.cost(record))
		}
	}
	// Offsets first: a crash between the two writes under-counts a delta rather than re-counting it.
	c.SetTranscriptOffsets(offsets)
	return c.AccumulateDailyUsage(domain.Claude, now, tokens, cost, sessions), nil
}

// usageQuota lists the windows reported. The primary quota is the larger of 5h and 7d, leaving
// the per-model windows out of the main bar.
func usageQuota(usage *usageResponse) ([]domain.QuotaWindow, *domain.Quota) {
	var windows []domain.QuotaWindow
	for _, w := range []struct {
		name     string
		response *quotaWindowResponse
	}{
		{"5h", usage.FiveHour}, {"7d", usage.SevenDay}, {"7d-sonnet", usage.SevenDaySonnet}, {"7d-opus", usage.SevenDayOpus},
	} {
		if w.response != nil {
			windows = append(windows, domain.QuotaWindow{Name: w.name, Utilization: fraction(w.response.Utilization), ResetsAt: parseResets(w.response.ResetsAt)})
		}
	}
	var primary *float64
	for _, w := range []*quotaWindowResponse{usage.FiveHour, usage.SevenDay} {
		if w != nil && w.Utilization != nil && (primary == nil || *w.Utilization > *primary) {
			primary = w.Utilization
		}
	}
	if primary == nil {
		return windows, nil
	}
	quota := domain.UnitQuota(*primary / 100)
	return windows, &quota
}

func fraction(percent *float64) *float64 {
	if percent == nil {
		return nil
	}
	value := *percent / 100
	return &value
}

func parseResets(raw *string) *time.Time {
	if raw == nil {
		return nil
	}
	t, err := time.Parse(time.RFC3339Nano, *raw)
	if err != nil {
		return nil
	}
	return &t
}

func anyExists(paths []string) bool {
	for _, path := range paths {
		if _, err := os.Stat(path); err == nil {
			return true
		}
	}
	return false
}
