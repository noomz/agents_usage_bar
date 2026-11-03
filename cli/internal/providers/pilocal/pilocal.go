// Package pilocal reports today's local-model usage from Pi session JSONL, and owns the session
// reader package grok reuses for xAI spend.
package pilocal

import (
	"context"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/cache"
	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/jsonl"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
)

// AgentDir is $PI_CODING_AGENT_DIR when non-empty, else ~/.pi/agent.
func AgentDir(getenv func(string) string, home string) string {
	if override := getenv("PI_CODING_AGENT_DIR"); override != "" {
		return override
	}
	return defaultAgentDir(home)
}

func defaultAgentDir(home string) string { return filepath.Join(home, ".pi", "agent") }

// SessionDirs are the trees to scan: the default agent directory and any override, collapsed
// when one is a symlink of the other.
func SessionDirs(getenv func(string) string, home string) []string {
	return underAgentDirs(getenv, home, "sessions")
}

// ModelsFiles are the models.json files to read, one per agent directory.
func ModelsFiles(getenv func(string) string, home string) []string {
	return underAgentDirs(getenv, home, "models.json")
}

func underAgentDirs(getenv func(string) string, home, name string) []string {
	candidates := []string{filepath.Join(defaultAgentDir(home), name)}
	if override := getenv("PI_CODING_AGENT_DIR"); override != "" {
		candidates = append(candidates, filepath.Join(override, name))
	}
	seen := map[string]bool{}
	var out []string
	for _, path := range candidates {
		resolved, err := filepath.EvalSymlinks(path)
		if err != nil {
			resolved = filepath.Clean(path)
		}
		if !seen[resolved] {
			seen[resolved] = true
			out = append(out, resolved)
		}
	}
	return out
}

// Acc is a poll's delta.
type Acc struct {
	Tokens    int
	CostUSD   decimal.Decimal
	Providers map[string]bool
	Models    map[string]bool
}

// Delta is one incremental read of the session trees.
type Delta struct {
	Acc   Acc
	Files int
}

// ReadSessions adds every record since today in catalog past the stored cursors, then saves
// the cursors under keyPrefix. The prefix keeps each reader's cursors apart: package grok reads
// the same files as this provider, so sharing a key would hide bytes from one of them. Any
// unreadable file fails the read and advances no cursor.
func ReadSessions(store cache.Cursors, roots []string, catalog Catalog, today time.Time, keyPrefix string) (Delta, error) {
	prior := store.AllTranscriptOffsets()
	var floor *time.Time
	for key, offset := range prior {
		if strings.HasPrefix(key, keyPrefix) && (floor == nil || offset.LastModified.Before(*floor)) {
			modified := offset.LastModified
			floor = &modified
		}
	}
	if floor != nil {
		earlier := floor.Add(-time.Second)
		floor = &earlier
	}
	files := jsonl.ScanRoots(roots, floor)
	delta := Delta{Acc: Acc{CostUSD: decimal.FromInt(0), Providers: map[string]bool{}, Models: map[string]bool{}}, Files: len(files)}
	offsets := make([]domain.TranscriptOffset, 0, len(files))
	for _, path := range files {
		key := keyPrefix + jsonl.FileURL(path)
		var start uint64
		var modified *time.Time
		if offset, ok := prior[key]; ok {
			start, modified = offset.ByteOffset, &offset.LastModified
		}
		read, err := jsonl.ReadDelta(path, start, modified)
		if err != nil {
			return Delta{}, err
		}
		offsets = append(offsets, domain.TranscriptOffset{URL: key, ByteOffset: read.NewOffset, LastModified: read.LastModified})
		for _, line := range read.Lines {
			record, ok := DecodeRecord(line)
			if !ok || record.Timestamp.Before(today) || !catalog[record.Provider] {
				continue
			}
			delta.Acc.Tokens += record.Tokens
			delta.Acc.CostUSD = delta.Acc.CostUSD.Add(record.CostUSD)
			delta.Acc.Providers[record.Provider] = true
			if record.Model != "" {
				delta.Acc.Models[record.Model] = true
			}
		}
	}
	store.SetTranscriptOffsets(offsets)
	return delta, nil
}

// Provider is the Local Llama row.
type Provider struct {
	env provider.Env
}

// Build registers the row whenever it is enabled: Fetch reports a machine with no Pi sessions.
func Build(env provider.Env) provider.Provider {
	return &Provider{env: env}
}

// ID implements provider.Provider.
func (*Provider) ID() domain.ProviderID { return domain.PiLocal }

// DisplayName implements provider.Provider.
func (*Provider) DisplayName() string { return "Local Llama" }

// Capabilities implements provider.Provider.
func (*Provider) Capabilities() domain.Capabilities {
	return domain.Capabilities{HasCost: true, HasTokens: true}
}

// Fetch implements provider.Provider.
func (p *Provider) Fetch(_ context.Context, now time.Time) (domain.UsageSnapshot, domain.ProviderStatus, error) {
	roots := SessionDirs(p.env.Getenv, p.env.Paths.Home)
	catalog := LoadCatalog(ModelsFiles(p.env.Getenv, p.env.Paths.Home))
	if !AnyExists(roots) {
		zeroTokens, zeroCost := 0, decimal.FromInt(0)
		return domain.UsageSnapshot{
			ProviderID: domain.PiLocal, AsOf: now, TokensToday: &zeroTokens, CostTodayUSD: &zeroCost,
			Raw: map[string]string{domain.RawProviderStatus: domain.StatusSentinelUnauth},
		}, domain.Unauthenticated(), nil
	}
	var delta Delta
	var total domain.DailyUsageRecord
	var err error
	p.env.Cache.WithCursors(func(c cache.Cursors) {
		if delta, err = ReadSessions(c, roots, catalog, p.env.DayKeys.StartOfDay(now), ""); err == nil {
			total = c.AccumulateDailyUsage(domain.PiLocal, now, delta.Acc.Tokens, delta.Acc.CostUSD, map[string]int{})
		}
	})
	if err != nil {
		return domain.UsageSnapshot{}, domain.ProviderStatus{}, err
	}
	tokens, cost := total.Tokens, total.CostUSD
	return domain.UsageSnapshot{
		ProviderID: domain.PiLocal, AsOf: now, TokensToday: &tokens, CostTodayUSD: &cost,
		Raw: map[string]string{
			"providers": joinSorted(delta.Acc.Providers),
			"models":    joinSorted(delta.Acc.Models),
			"filesRead": strconv.Itoa(delta.Files),
		},
	}, domain.OK(now), nil
}

// AnyExists reports whether any path exists.
func AnyExists(paths []string) bool {
	for _, path := range paths {
		if _, err := os.Stat(path); err == nil {
			return true
		}
	}
	return false
}

func joinSorted(set map[string]bool) string {
	items := make([]string, 0, len(set))
	for item := range set {
		items = append(items, item)
	}
	sort.Strings(items)
	return strings.Join(items, ",")
}
