package claude

import (
	"encoding/json"
	"errors"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

const (
	stalenessHorizon = 24 * time.Hour
	cleanupHorizon   = 48 * time.Hour
)

// errNoFeedData is a missing or empty feed: the statusline tee is not installed or never fired.
var errNoFeedData = errors.New("claude hook: no feed data")

// hookPayload is the subset of the JSON Claude Code pushes to a statusline command. A field of
// the wrong type rejects the whole payload, as Codable does.
type hookPayload struct {
	SessionID      *string `json:"session_id"`
	TranscriptPath *string `json:"transcript_path"`
	Model          *struct {
		ID          *string `json:"id"`
		DisplayName *string `json:"display_name"`
	} `json:"model"`
	Cost *struct {
		TotalCostUSD *float64 `json:"total_cost_usd"`
	} `json:"cost"`
	RateLimits *struct {
		FiveHour *hookWindow `json:"five_hour"`
		SevenDay *hookWindow `json:"seven_day"`
	} `json:"rate_limits"`
}

type hookWindow struct {
	UsedPercentage *float64 `json:"used_percentage"`
	ResetsAt       *float64 `json:"resets_at"`
}

func (w hookWindow) resetsAtTime() *time.Time {
	if w.ResetsAt == nil {
		return nil
	}
	t := time.UnixMilli(int64(*w.ResetsAt * 1000))
	return &t
}

func (w hookWindow) utilization() *float64 { return fraction(w.UsedPercentage) }

// mergeWindow: a later reset is a new window and replaces the stored one. The same reset keeps
// the higher percentage, because a rate-limited session stops writing and a later session can
// report less for the same window. A payload without the window keeps what is stored.
func mergeWindow(stored, candidate *hookWindow) *hookWindow {
	if candidate == nil {
		return stored
	}
	if stored == nil {
		return candidate
	}
	if stored.ResetsAt != nil && candidate.ResetsAt != nil && *candidate.ResetsAt != *stored.ResetsAt {
		if *candidate.ResetsAt > *stored.ResetsAt {
			return candidate
		}
		return stored
	}
	storedPct, candidatePct := math.Inf(-1), math.Inf(-1)
	if stored.UsedPercentage != nil {
		storedPct = *stored.UsedPercentage
	}
	if candidate.UsedPercentage != nil {
		candidatePct = *candidate.UsedPercentage
	}
	if candidatePct > storedPct {
		return candidate
	}
	return stored
}

// accountFromTranscriptPath: transcript_path names the owning account and beats the directory
// the tee wrote into, whose routing flaps across invocations in shared-settings ccs setups.
func accountFromTranscriptPath(path *string) *string {
	if path == nil {
		return nil
	}
	if _, rest, ok := strings.Cut(*path, "/.ccs/instances/"); ok {
		slug, _, _ := strings.Cut(rest, "/")
		if slug == "" {
			return nil
		}
		return &slug
	}
	if strings.Contains(*path, "/.claude/") {
		name := "default"
		return &name
	}
	return nil
}

type feedEntry struct {
	account string
	path    string
	mtime   time.Time
}

// enumerateFeed reads `<dir>/<session>.json` as account "default" and
// `<dir>/<account>/<session>.json` as that account. It fails only when dir itself cannot be
// listed.
func enumerateFeed(dir string) ([]feedEntry, error) {
	top, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var entries []feedEntry
	for _, item := range top {
		if strings.HasPrefix(item.Name(), ".") {
			continue
		}
		path := filepath.Join(dir, item.Name())
		if item.IsDir() {
			children, err := os.ReadDir(path)
			if err != nil {
				continue
			}
			for _, child := range children {
				if strings.HasPrefix(child.Name(), ".") || filepath.Ext(child.Name()) != ".json" {
					continue
				}
				childPath := filepath.Join(path, child.Name())
				if info, err := os.Stat(childPath); err == nil && info.Mode().IsRegular() {
					entries = append(entries, feedEntry{item.Name(), childPath, info.ModTime()})
				}
			}
			continue
		}
		if filepath.Ext(item.Name()) == ".json" {
			if info, err := os.Stat(path); err == nil && info.Mode().IsRegular() {
				entries = append(entries, feedEntry{"default", path, info.ModTime()})
			}
		}
	}
	return entries, nil
}

// newestCopies keeps one entry per session file. The tee derives the account from
// $CLAUDE_CONFIG_DIR at runtime, so one session can leave copies under several accounts, and
// counting each would multiply its cumulative cost. The newest is the latest payload pushed.
func newestCopies(entries []feedEntry) []feedEntry {
	newest := map[string]feedEntry{}
	for _, entry := range entries {
		name := filepath.Base(entry.path)
		if current, ok := newest[name]; !ok || entry.mtime.After(current.mtime) {
			newest[name] = entry
		}
	}
	out := make([]feedEntry, 0, len(newest))
	for _, entry := range newest {
		out = append(out, entry)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].path < out[j].path })
	return out
}

func readPayload(path string) (hookPayload, bool) {
	var payload hookPayload
	data, err := os.ReadFile(path)
	if err != nil || json.Unmarshal(data, &payload) != nil {
		return hookPayload{}, false
	}
	return payload, true
}

// hookFeed reads captured statusline payloads: no network, no transcripts, no secrets.
type hookFeed struct {
	dir     string
	dayKeys *domain.DayKeyOwner
}

// cleanup bounds the feed, whose tee writes whatever source is selected. Best effort.
func cleanup(entries []feedEntry, now time.Time) {
	for _, entry := range entries {
		if now.Sub(entry.mtime) > cleanupHorizon {
			_ = os.Remove(entry.path)
		}
	}
}

func (h *hookFeed) prune(now time.Time) {
	if entries, err := enumerateFeed(h.dir); err == nil {
		cleanup(entries, now)
	}
}

// sessionAccounts maps each session still in the feed to its account, attributed as fetch does.
// A non-nil since keeps sessions whose newest copy is at or after it.
func (h *hookFeed) sessionAccounts(since *time.Time) map[string]string {
	accounts := map[string]string{}
	entries, err := enumerateFeed(h.dir)
	if err != nil {
		return accounts
	}
	for _, entry := range newestCopies(entries) {
		if since != nil && entry.mtime.Before(*since) {
			continue
		}
		payload, ok := readPayload(entry.path)
		if !ok {
			continue
		}
		session := strings.TrimSuffix(filepath.Base(entry.path), filepath.Ext(entry.path))
		if payload.SessionID != nil {
			session = *payload.SessionID
		}
		if owner := accountFromTranscriptPath(payload.TranscriptPath); owner != nil {
			accounts[session] = *owner
		} else {
			accounts[session] = entry.account
		}
	}
	return accounts
}

type accountAggregate struct {
	cost     decimal.Decimal
	sawCost  bool
	fiveHour *hookWindow
	sevenDay *hookWindow
}

// fetch merges today's feed. Cost sums cumulative session cost over files modified today, so a
// session spanning midnight counts wholly today, because the statusline reports nothing finer.
// Tokens stay nil: the statusline has no totals. Quota windows are per account, prefixed with the
// account name once two accounts exist, and the primary quota is the worst across them.
func (h *hookFeed) fetch(now time.Time) (domain.UsageSnapshot, error) {
	all, err := enumerateFeed(h.dir)
	if err != nil {
		return domain.UsageSnapshot{}, errNoFeedData
	}
	entries := newestCopies(all)
	if len(entries) == 0 {
		return domain.UsageSnapshot{}, errNoFeedData
	}
	defer cleanup(all, now)

	newest := entries[0].mtime
	for _, entry := range entries {
		if entry.mtime.After(newest) {
			newest = entry.mtime
		}
	}
	if now.Sub(newest) > stalenessHorizon {
		zero := decimal.FromInt(0)
		return domain.UsageSnapshot{ProviderID: domain.Claude, AsOf: now, CostTodayUSD: &zero, Raw: map[string]string{}}, nil
	}

	today := h.dayKeys.StartOfDay(now)
	accounts := map[string]*accountAggregate{}
	for _, entry := range entries {
		payload, ok := readPayload(entry.path)
		if !ok {
			continue
		}
		name := entry.account
		if owner := accountFromTranscriptPath(payload.TranscriptPath); owner != nil {
			name = *owner
		}
		aggregate := accounts[name]
		if aggregate == nil {
			aggregate = &accountAggregate{cost: decimal.FromInt(0)}
			accounts[name] = aggregate
		}
		if !entry.mtime.Before(today) && payload.Cost != nil && payload.Cost.TotalCostUSD != nil {
			aggregate.cost = aggregate.cost.Add(decimalFromUSD(*payload.Cost.TotalCostUSD))
			aggregate.sawCost = true
		}
		if limits := payload.RateLimits; limits != nil {
			aggregate.fiveHour = mergeWindow(aggregate.fiveHour, limits.FiveHour)
			aggregate.sevenDay = mergeWindow(aggregate.sevenDay, limits.SevenDay)
		}
	}
	return assembleSnapshot(accounts, now), nil
}

// decimalFromUSD rounds through a 6-digit string, so summing many sessions has no binary drift.
func decimalFromUSD(usd float64) decimal.Decimal {
	if d, ok := decimal.Parse(strconv.FormatFloat(usd, 'f', 6, 64)); ok {
		return d
	}
	return decimal.FromFloat64(usd)
}

func assembleSnapshot(accounts map[string]*accountAggregate, now time.Time) domain.UsageSnapshot {
	names := make([]string, 0, len(accounts))
	for name := range accounts {
		names = append(names, name)
	}
	sort.Slice(names, func(i, j int) bool {
		if (names[i] == "default") != (names[j] == "default") {
			return names[i] == "default"
		}
		return names[i] < names[j]
	})
	prefixed := len(names) >= 2

	snapshot := domain.UsageSnapshot{ProviderID: domain.Claude, AsOf: now, Raw: map[string]string{}}
	total := decimal.FromInt(0)
	sawCost := false
	var worst *float64
	for _, name := range names {
		aggregate := accounts[name]
		var windows []domain.QuotaWindow
		var accountMax *float64
		for _, w := range []struct {
			label  string
			window *hookWindow
		}{{"5h", aggregate.fiveHour}, {"7d", aggregate.sevenDay}} {
			if w.window == nil {
				continue
			}
			windows = append(windows, domain.QuotaWindow{Name: w.label, Utilization: w.window.utilization(), ResetsAt: w.window.resetsAtTime()})
			displayName := w.label
			if prefixed {
				displayName = name + " " + w.label
			}
			snapshot.QuotaWindows = append(snapshot.QuotaWindows, domain.QuotaWindow{Name: displayName, Utilization: w.window.utilization(), ResetsAt: w.window.resetsAtTime()})
			if pct := w.window.UsedPercentage; pct != nil && (accountMax == nil || *pct > *accountMax) {
				accountMax = pct
			}
		}
		usage := domain.AccountUsage{Name: name, QuotaWindows: windows}
		if aggregate.sawCost {
			total = total.Add(aggregate.cost)
			sawCost = true
			cost := aggregate.cost
			usage.CostTodayUSD = &cost
			snapshot.Raw["cost."+name] = cost.String()
		}
		if accountMax != nil {
			quota := domain.UnitQuota(*accountMax / 100)
			usage.Quota = &quota
			snapshot.Raw["quota."+name] = strconv.Itoa(int(math.Round(*accountMax))) + "%"
			if worst == nil || *accountMax > *worst {
				worst = accountMax
			}
		}
		snapshot.Accounts = append(snapshot.Accounts, usage)
	}
	if sawCost {
		snapshot.CostTodayUSD = &total
	}
	if worst != nil {
		quota := domain.UnitQuota(*worst / 100)
		snapshot.Quota = &quota
	}
	return snapshot
}
