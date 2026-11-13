// Package codex reports Codex usage from rollout transcripts and wham/usage.
//
// It only reads credentials: Codex manages its own token rotation, so an expired bearer shows
// as no data and nothing is refreshed or written back.
package codex

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/cache"
	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/jsonl"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/resources"
	"github.com/noomz/agents_usage_bar/cli/internal/secret"
)

const usageURL = "https://chatgpt.com/backend-api/wham/usage"

var errNoCredentials = errors.New("no Codex credentials")

// rates is the file-level default price per million tokens. Rollout token_count events carry
// no model id, so the table's per-model rows never apply.
type rates struct {
	Default struct {
		Input  float64 `json:"inputPerMToken"`
		Output float64 `json:"outputPerMToken"`
		Cached float64 `json:"cachedInputPerMToken"`
	} `json:"default"`
}

func loadRates(data []byte) *rates {
	var r rates
	if json.Unmarshal(data, &r) != nil {
		return nil
	}
	return &r
}

// cost keeps every step in Decimal so totals print the same bytes as the app. Reasoning tokens
// are a subset of output tokens and are not billed again.
func (r rates) cost(u tokenUsage) decimal.Decimal {
	perMillion := decimal.FromInt(1_000_000)
	column := func(tokens int, rate float64) decimal.Decimal {
		return decimal.FromInt(int64(tokens)).Mul(decimal.FromFloat64(rate)).Div(perMillion)
	}
	return column(max(0, u.InputTokens-u.CachedInputTokens), r.Default.Input).
		Add(column(u.CachedInputTokens, r.Default.Cached)).
		Add(column(u.OutputTokens, r.Default.Output))
}

type Provider struct {
	env                              provider.Env
	sessionsRoot, authPath, proxyDir string
	rates                            *rates
}

// Build registers Codex when saved credentials, a sessions directory, or a login exists.
func Build(env provider.Env) provider.Provider {
	p := &Provider{
		env:          env,
		sessionsRoot: filepath.Join(env.Paths.Home, ".codex", "sessions"),
		authPath:     filepath.Join(env.Paths.Home, ".codex", "auth.json"),
		proxyDir:     filepath.Join(env.Paths.Home, ".ccs", "cliproxy", "auth"),
		rates:        loadRates(resources.CodexPricing),
	}
	_, statErr := os.Stat(p.sessionsRoot)
	if loadCredentials(p.authPath) == nil && statErr != nil && len(discover(p.proxyDir, p.authPath)) == 0 {
		return nil
	}
	return p
}

func (p *Provider) ID() domain.ProviderID { return domain.Codex }

func (p *Provider) DisplayName() string { return "Codex" }

func (p *Provider) Capabilities() domain.Capabilities {
	return domain.Capabilities{HasQuota: true, HasCost: true, HasTokens: true}
}

// Rollout tokens and cost always win. Two or more logins
// take quota from one wham/usage per login. Otherwise live rollout windows win, a windowless
// rollout overlays wham/usage, and with no rollout wham/usage is the whole row.
func (p *Provider) Fetch(ctx context.Context, now time.Time) (domain.UsageSnapshot, domain.ProviderStatus, error) {
	logins := discover(p.proxyDir, p.authPath)
	rollout, err := p.readRollout(now)
	if err != nil {
		return domain.UsageSnapshot{}, domain.ProviderStatus{}, err
	}

	if len(logins) >= 2 {
		return p.multiLoginSnapshot(ctx, logins, rollout, now), domain.OK(now), nil
	}
	var single *login
	if len(logins) == 1 {
		single = &logins[0]
	}
	if rollout != nil {
		if len(rollout.QuotaWindows) == 0 {
			if overlaid := p.overlay(ctx, *rollout, single, now); overlaid != nil {
				return *overlaid, domain.OK(now), nil
			}
		}
		return *rollout, domain.OK(now), nil
	}

	usage, err := p.fetchUsage(ctx, single)
	if err != nil {
		var status domain.HTTPError
		if errors.Is(err, errNoCredentials) || (errors.As(err, &status) && (status.Status == 401 || status.Status == 403)) {
			return domain.UsageSnapshot{ProviderID: domain.Codex, AsOf: now, Raw: map[string]string{"status": "no-data-yet"}}, domain.Unauthenticated(), nil
		}
		return domain.UsageSnapshot{}, domain.ProviderStatus{}, err
	}
	return usage.snapshot(now), domain.OK(now), nil
}

// readRollout returns today's snapshot, nil when no token_count event exists. Like the app it
// advances the transcript cursors, though the fold rereads each whole file.
func (p *Provider) readRollout(now time.Time) (*domain.UsageSnapshot, error) {
	today := p.env.DayKeys.KeyFor(now)
	days := []string{today}
	if yesterday, ok := domain.AddDays(today, -1); ok {
		days = append(days, yesterday)
	}
	files := rolloutFiles(p.sessionsRoot, days)
	if len(files) == 0 {
		return nil, nil
	}
	if err := p.env.Cache.WithCursors(func(c cache.Cursors) { advanceOffsets(c, files) }); err != nil {
		return nil, err
	}
	fold, ok := foldRollouts(files, p.env.DayKeys.WallKey)
	if !ok {
		return nil, nil
	}
	return p.rolloutSnapshot(fold.last, fold.lastFile, fold.days[today], now), nil
}

func advanceOffsets(c cache.Cursors, files []string) {
	prior := c.AllTranscriptOffsets()
	offsets := make([]domain.TranscriptOffset, 0, len(files))
	for _, file := range files {
		key := jsonl.FileURL(file)
		var start uint64
		var modified *time.Time
		if o, ok := prior[key]; ok {
			start, modified = o.ByteOffset, &o.LastModified
		}
		delta, err := jsonl.ReadDelta(file, start, modified)
		if err != nil {
			continue
		}
		offsets = append(offsets, domain.TranscriptOffset{URL: key, ByteOffset: delta.NewOffset, LastModified: delta.LastModified})
	}
	c.SetTranscriptOffsets(offsets)
}

func (p *Provider) rolloutSnapshot(event rolloutEvent, file string, today tokenUsage, now time.Time) *domain.UsageSnapshot {
	snap := domain.UsageSnapshot{
		ProviderID: domain.Codex,
		AsOf:       now,
		Raw:        map[string]string{"source": "rollout", "fileURL": filepath.Base(file)},
	}
	snap.TokensToday = &today.TotalTokens
	if p.rates != nil {
		cost := p.rates.cost(today)
		snap.CostTodayUSD = &cost
	}
	if limits := event.Payload.RateLimits; limits != nil {
		appendWindow := func(name string, w *rolloutWindow) {
			if w == nil {
				return
			}
			fraction := w.UsedPercent / 100
			duration := float64(w.WindowMinutes * 60)
			snap.QuotaWindows = append(snap.QuotaWindows, domain.QuotaWindow{Name: name, Utilization: &fraction, ResetsAt: w.resetsAt(now), Duration: &duration})
		}
		appendWindow("primary", limits.Primary)
		appendWindow("secondary", limits.Secondary)
		snap.Quota = maxQuota(snap.QuotaWindows)
		if limits.Credits != nil && limits.Credits.Balance != nil {
			snap.BalanceUSD = parseBalance(*limits.Credits.Balance)
		}
	}
	return &snap
}

func parseBalance(s string) *decimal.Decimal {
	if d, ok := decimal.Parse(s); ok {
		return &d
	}
	return nil
}

// overlay keeps a windowless rollout's tokens and cost and takes quota from wham/usage. CLIProxy
// sessions write null windows. A failure returns nil, leaving the rollout row.
func (p *Provider) overlay(ctx context.Context, rollout domain.UsageSnapshot, single *login, now time.Time) *domain.UsageSnapshot {
	usage, err := p.fetchUsage(ctx, single)
	if err != nil {
		return nil
	}
	quota := usage.snapshot(now)
	if quota.Quota == nil && len(quota.QuotaWindows) == 0 {
		return nil
	}
	return &domain.UsageSnapshot{
		ProviderID:   domain.Codex,
		AsOf:         now,
		TokensToday:  rollout.TokensToday,
		CostTodayUSD: rollout.CostTodayUSD,
		BalanceUSD:   orElse(quota.BalanceUSD, rollout.BalanceUSD),
		Quota:        quota.Quota,
		Raw:          map[string]string{"source": "rollout+wham-usage", "fileURL": rollout.Raw["fileURL"]},
		QuotaWindows: quota.QuotaWindows,
	}
}

// multiLoginSnapshot is one row with a child per login. A failed wham/usage leaves that child
// with no quota and does not cancel the others.
func (p *Provider) multiLoginSnapshot(ctx context.Context, logins []login, rollout *domain.UsageSnapshot, now time.Time) domain.UsageSnapshot {
	responses := make([]*usageResponse, len(logins))
	var wg sync.WaitGroup
	for i := range logins {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if usage, err := p.fetchUsage(ctx, &logins[i]); err == nil {
				responses[i] = &usage
			}
		}()
	}
	wg.Wait()

	planTypes := map[string]string{}
	for i, l := range logins {
		if responses[i] != nil && responses[i].PlanType != nil {
			key := ""
			if l.accountID != nil {
				key = *l.accountID
			}
			planTypes[key] = *responses[i].PlanType
		}
	}
	snap := domain.UsageSnapshot{ProviderID: domain.Codex, AsOf: now, Raw: map[string]string{"source": "codex-accounts"}}
	if rollout != nil {
		snap.TokensToday, snap.CostTodayUSD = rollout.TokensToday, rollout.CostTodayUSD
	}
	var worst *float64
	for _, item := range labeled(logins, planTypes) {
		account := domain.AccountUsage{Name: item.label}
		if response := responses[item.index]; response != nil {
			account.QuotaWindows = response.windows()
			for _, w := range account.QuotaWindows {
				if w.Name == "primary" && w.Utilization != nil {
					account.Quota = w.AsQuota()
					if worst == nil || *w.Utilization > *worst {
						worst = w.Utilization
					}
				}
			}
		}
		snap.Accounts = append(snap.Accounts, account)
	}
	if worst != nil {
		q := domain.UnitQuota(*worst)
		snap.Quota = &q
	}
	return snap
}

// usageResponse is wham/usage. Its shape is deliberately distinct from the rollout's: singular
// rate_limit, primary_window, reset_at, and limit_window_seconds.
type usageResponse struct {
	PlanType  *string `json:"plan_type"`
	RateLimit *struct {
		Primary   *usageWindow `json:"primary_window"`
		Secondary *usageWindow `json:"secondary_window"`
	} `json:"rate_limit"`
	Credits *credits `json:"credits"`
}

type usageWindow struct {
	UsedPercent        *float64  `json:"used_percent"`
	ResetAt            *swiftInt `json:"reset_at"`
	LimitWindowSeconds *swiftInt `json:"limit_window_seconds"`
}

func (w usageWindow) quotaWindow(name string) domain.QuotaWindow {
	out := domain.QuotaWindow{Name: name}
	if w.UsedPercent != nil {
		fraction := *w.UsedPercent / 100
		out.Utilization = &fraction
	}
	if w.ResetAt != nil {
		t := time.Unix(int64(*w.ResetAt), 0).UTC()
		out.ResetsAt = &t
	}
	if w.LimitWindowSeconds != nil {
		duration := float64(*w.LimitWindowSeconds)
		out.Duration = &duration
	}
	return out
}

func (r usageResponse) windows() []domain.QuotaWindow {
	var windows []domain.QuotaWindow
	if r.RateLimit != nil {
		if r.RateLimit.Primary != nil {
			windows = append(windows, r.RateLimit.Primary.quotaWindow("primary"))
		}
		if r.RateLimit.Secondary != nil {
			windows = append(windows, r.RateLimit.Secondary.quotaWindow("secondary"))
		}
	}
	return windows
}

// snapshot has no tokens or cost: wham/usage reports neither.
func (r usageResponse) snapshot(now time.Time) domain.UsageSnapshot {
	windows := r.windows()
	snap := domain.UsageSnapshot{
		ProviderID: domain.Codex, AsOf: now,
		Quota: maxQuota(windows), QuotaWindows: windows,
		Raw: map[string]string{"source": "oauth-wham-usage"},
	}
	if r.Credits != nil && r.Credits.Balance != nil {
		snap.BalanceUSD = parseBalance(*r.Credits.Balance)
	}
	return snap
}

// fetchUsage calls wham/usage for a login, or with auth.json's bearer when there is none.
func (p *Provider) fetchUsage(ctx context.Context, l *login) (usageResponse, error) {
	var token secret.Secret
	var accountID *string
	if l != nil {
		token, accountID = l.token, l.accountID
	} else {
		creds := loadCredentials(p.authPath)
		if creds == nil {
			return usageResponse{}, errNoCredentials
		}
		token, accountID = creds.token, creds.accountID
	}
	headers := map[string]string{"Accept": "application/json", "User-Agent": "Agents-Usage-Bar/1.0"}
	if accountID != nil {
		headers["ChatGPT-Account-Id"] = *accountID
	}
	var response usageResponse
	err := p.env.HTTP.GetJSON(ctx, usageURL, &token, headers, &response)
	return response, err
}
