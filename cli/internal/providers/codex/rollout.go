package codex

import (
	"bytes"
	"encoding/json"
	"errors"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

// The rollout types declare fields the fold never reads because a mistyped one must reject the
// whole line, as Swift's Decodable does.

type rolloutEvent struct {
	Timestamp string `json:"timestamp"`
	Type      string `json:"type"`
	Payload   struct {
		Type       string      `json:"type"`
		Info       *tokenInfo  `json:"info"`
		RateLimits *rateLimits `json:"rate_limits"`
	} `json:"payload"`
}

type tokenInfo struct {
	TotalTokenUsage    *tokenUsage `json:"total_token_usage"`
	LastTokenUsage     *tokenUsage `json:"last_token_usage"`
	ModelContextWindow *swiftInt   `json:"model_context_window"`
}

type tokenUsage struct {
	InputTokens, CachedInputTokens, OutputTokens, TotalTokens int
}

// UnmarshalJSON rejects a usage object missing a required count.
func (u *tokenUsage) UnmarshalJSON(data []byte) error {
	var raw struct {
		Input     *swiftInt `json:"input_tokens"`
		Cached    *swiftInt `json:"cached_input_tokens"`
		Output    *swiftInt `json:"output_tokens"`
		Reasoning *swiftInt `json:"reasoning_output_tokens"`
		Total     *swiftInt `json:"total_tokens"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	if raw.Input == nil || raw.Cached == nil || raw.Output == nil || raw.Total == nil {
		return errors.New("token usage missing a required count")
	}
	*u = tokenUsage{int(*raw.Input), int(*raw.Cached), int(*raw.Output), int(*raw.Total)}
	return nil
}

// riseSince is the usage added since an earlier cumulative total of the same session. A total
// that dropped starts the session count again.
func (u tokenUsage) riseSince(earlier tokenUsage) tokenUsage {
	if u.TotalTokens < earlier.TotalTokens {
		return u
	}
	return tokenUsage{
		InputTokens:       max(0, u.InputTokens-earlier.InputTokens),
		CachedInputTokens: max(0, u.CachedInputTokens-earlier.CachedInputTokens),
		OutputTokens:      max(0, u.OutputTokens-earlier.OutputTokens),
		TotalTokens:       u.TotalTokens - earlier.TotalTokens,
	}
}

func (u tokenUsage) plus(other tokenUsage) tokenUsage {
	return tokenUsage{
		InputTokens:       u.InputTokens + other.InputTokens,
		CachedInputTokens: u.CachedInputTokens + other.CachedInputTokens,
		OutputTokens:      u.OutputTokens + other.OutputTokens,
		TotalTokens:       u.TotalTokens + other.TotalTokens,
	}
}

type rateLimits struct {
	LimitID              *string        `json:"limit_id"`
	LimitName            *string        `json:"limit_name"`
	Primary              *rolloutWindow `json:"primary"`
	Secondary            *rolloutWindow `json:"secondary"`
	Credits              *credits       `json:"credits"`
	PlanType             *string        `json:"plan_type"`
	RateLimitReachedType *string        `json:"rate_limit_reached_type"`
}

func (r rateLimits) hasWindows() bool { return r.Primary != nil || r.Secondary != nil }

// isPostLimitNulling is null windows meaning "the cap was hit". CLIProxy also writes null
// windows but keeps limit_id "codex", and those must not inherit an older window.
func (r rateLimits) isPostLimitNulling() bool {
	return !r.hasWindows() && (equal(r.LimitID, "premium") || r.RateLimitReachedType != nil)
}

func (r rateLimits) fillingEmptyWindows(earlier rateLimits) rateLimits {
	filled := r
	filled.Primary = orElse(r.Primary, earlier.Primary)
	filled.Secondary = orElse(r.Secondary, earlier.Secondary)
	filled.Credits = orElse(r.Credits, earlier.Credits)
	filled.LimitID = orElse(r.LimitID, earlier.LimitID)
	filled.LimitName = orElse(r.LimitName, earlier.LimitName)
	filled.PlanType = orElse(r.PlanType, earlier.PlanType)
	filled.RateLimitReachedType = orElse(r.RateLimitReachedType, earlier.RateLimitReachedType)
	return filled
}

func orElse[T any](p, fallback *T) *T {
	if p != nil {
		return p
	}
	return fallback
}

func (r rateLimits) droppingWindowsReset(instant time.Time) rateLimits {
	keep := func(w *rolloutWindow) *rolloutWindow {
		if w == nil {
			return nil
		}
		if reset := w.resetsAt(instant); reset != nil && !reset.After(instant) {
			return nil
		}
		return w
	}
	live := r
	live.Primary, live.Secondary = keep(r.Primary), keep(r.Secondary)
	return live
}

type rolloutWindow struct {
	UsedPercent     float64
	WindowMinutes   int
	ResetsAt        *swiftInt
	ResetsInSeconds *swiftInt
}

// UnmarshalJSON rejects a window missing used_percent or window_minutes.
func (w *rolloutWindow) UnmarshalJSON(data []byte) error {
	var raw struct {
		UsedPercent     *float64  `json:"used_percent"`
		WindowMinutes   *swiftInt `json:"window_minutes"`
		ResetsAt        *swiftInt `json:"resets_at"`
		ResetsInSeconds *swiftInt `json:"resets_in_seconds"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	if raw.UsedPercent == nil || raw.WindowMinutes == nil {
		return errors.New("rate-limit window missing a required field")
	}
	*w = rolloutWindow{*raw.UsedPercent, int(*raw.WindowMinutes), raw.ResetsAt, raw.ResetsInSeconds}
	return nil
}

// resetsAt normalises the current absolute form and the legacy countdown.
func (w rolloutWindow) resetsAt(now time.Time) *time.Time {
	switch {
	case w.ResetsAt != nil:
		t := time.Unix(int64(*w.ResetsAt), 0).UTC()
		return &t
	case w.ResetsInSeconds != nil:
		t := now.Add(time.Duration(*w.ResetsInSeconds) * time.Second)
		return &t
	}
	return nil
}

type credits struct {
	HasCredits *bool   `json:"has_credits"`
	Unlimited  *bool   `json:"unlimited"`
	Balance    *string `json:"balance"`
}

// swiftInt decodes as JSONDecoder decodes Int: 98.0 and 1e3 are integers, 98.5 is an error.
type swiftInt int

func (i *swiftInt) UnmarshalJSON(data []byte) error {
	var n json.Number
	if err := json.Unmarshal(data, &n); err != nil {
		return err
	}
	if v, err := strconv.ParseInt(n.String(), 10, 64); err == nil {
		*i = swiftInt(v)
		return nil
	}
	f, err := n.Float64()
	if err != nil || f != math.Trunc(f) || math.Abs(f) > 1<<53 {
		return errors.New("not an integer")
	}
	*i = swiftInt(f)
	return nil
}

// rolloutFiles lists `*.jsonl` under root/YYYY/MM/DD for each Gregorian day key, with symlinks
// resolved so cache keys are canonical.
func rolloutFiles(root string, dayKeys []string) []string {
	var files []string
	for _, key := range dayKeys {
		dir := filepath.Join(root, strings.ReplaceAll(key, "-", string(filepath.Separator)))
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, entry := range entries {
			name := entry.Name()
			if strings.HasPrefix(name, ".") || filepath.Ext(name) != ".jsonl" {
				continue
			}
			path := filepath.Join(dir, name)
			if real, err := filepath.EvalSymlinks(path); err == nil {
				path = real
			}
			if info, err := os.Stat(path); err != nil || !info.Mode().IsRegular() {
				continue
			}
			files = append(files, path)
		}
	}
	return files
}

func parseTimestamp(s string) (time.Time, bool) {
	t, err := time.Parse(time.RFC3339Nano, s)
	return t, err == nil
}

// rolloutFold is one pass over the rollout files. last is the token_count event with the
// largest timestamp and carries the account's rate-limit windows. days is token usage per day
// key: total_token_usage is cumulative per session, so last alone is one session's total.
type rolloutFold struct {
	last     rolloutEvent
	lastFile string
	days     map[string]tokenUsage
}

// foldRollouts reads every token_count event with info, ok=false when there is none. Each event
// adds its rise in the session's cumulative usage to the day of its timestamp, so a session
// that runs past midnight splits across days. Rate-limit windows are account-level, so the
// latest windows are tracked apart from the latest event: a later event that nulls them after a
// usage-limit hit inherits them, minus any window that has already reset.
func foldRollouts(files []string, dayKey func(time.Time) string) (rolloutFold, bool) {
	var (
		days        = map[string]tokenUsage{}
		best        rolloutEvent
		bestFile    string
		bestTime    time.Time
		found       bool
		lastWindows rateLimits
		windowsTime time.Time
		hasWindows  bool
	)
	for _, file := range files {
		contents, err := os.ReadFile(file)
		if err != nil || !utf8.Valid(contents) {
			continue
		}
		var previous tokenUsage
		for _, line := range bytes.Split(contents, []byte{'\n'}) {
			if !bytes.Contains(line, []byte(`"token_count"`)) {
				continue
			}
			var event rolloutEvent
			if json.Unmarshal(line, &event) != nil {
				continue
			}
			if event.Type != "event_msg" || event.Payload.Type != "token_count" || event.Payload.Info == nil {
				continue
			}
			at, ok := parseTimestamp(event.Timestamp)
			if !ok {
				continue
			}
			if usage := event.Payload.Info.TotalTokenUsage; usage != nil {
				key := dayKey(at)
				days[key] = days[key].plus(usage.riseSince(previous))
				previous = *usage
			}
			if limits := event.Payload.RateLimits; limits != nil && limits.hasWindows() && (!hasWindows || !at.Before(windowsTime)) {
				lastWindows, windowsTime, hasWindows = *limits, at, true
			}
			if !found || at.After(bestTime) {
				best, bestFile, bestTime, found = event, file, at, true
			}
		}
	}
	if !found {
		return rolloutFold{}, false
	}
	if limits := best.Payload.RateLimits; limits != nil && limits.isPostLimitNulling() && hasWindows && !windowsTime.After(bestTime) {
		live := limits.fillingEmptyWindows(lastWindows).droppingWindowsReset(bestTime)
		if live.hasWindows() {
			best.Payload.RateLimits = &live
		}
	}
	return rolloutFold{last: best, lastFile: bestFile, days: days}, true
}

// maxQuota is the max(primary, secondary) quota shared by the rollout and wham/usage paths.
func maxQuota(windows []domain.QuotaWindow) *domain.Quota {
	var worst *float64
	for _, w := range windows {
		if w.Utilization != nil && (worst == nil || *w.Utilization > *worst) {
			worst = w.Utilization
		}
	}
	if worst == nil {
		return nil
	}
	q := domain.UnitQuota(*worst)
	return &q
}
