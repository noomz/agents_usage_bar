// Package openrouter reports OpenRouter credits, key quota, and today's spend from a baseline.
package openrouter

import (
	"context"
	"errors"
	"math"
	"sync"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/cache"
	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/httpclient"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/secret"
)

type creditsResponse struct {
	Data struct {
		TotalCredits *float64 `json:"total_credits"`
		TotalUsage   *float64 `json:"total_usage"`
	} `json:"data"`
}

type keyResponse struct {
	Data struct {
		Label              *string  `json:"label"`
		Limit              *float64 `json:"limit"`
		LimitReset         *string  `json:"limit_reset"`
		LimitRemaining     *float64 `json:"limit_remaining"`
		IncludeBYOKInLimit *bool    `json:"include_byok_in_limit"`
		Usage              *float64 `json:"usage"`
		UsageDaily         *float64 `json:"usage_daily"`
		UsageWeekly        *float64 `json:"usage_weekly"`
		UsageMonthly       *float64 `json:"usage_monthly"`
		BYOKUsage          *float64 `json:"byok_usage"`
		BYOKUsageDaily     *float64 `json:"byok_usage_daily"`
		BYOKUsageWeekly    *float64 `json:"byok_usage_weekly"`
		BYOKUsageMonthly   *float64 `json:"byok_usage_monthly"`
		IsFreeTier         *bool    `json:"is_free_tier"`
	} `json:"data"`
}

var errMissingField = domain.DecodeError{Err: errors.New("required field missing")}

func (r creditsResponse) validate() error {
	if r.Data.TotalCredits == nil || r.Data.TotalUsage == nil {
		return errMissingField
	}
	return nil
}

func (r keyResponse) validate() error {
	d := r.Data
	if d.Label == nil || d.IncludeBYOKInLimit == nil || d.IsFreeTier == nil {
		return errMissingField
	}
	for _, f := range []*float64{d.Usage, d.UsageDaily, d.UsageWeekly, d.UsageMonthly, d.BYOKUsage, d.BYOKUsageDaily, d.BYOKUsageWeekly, d.BYOKUsageMonthly} {
		if f == nil {
			return errMissingField
		}
	}
	return nil
}

// Provider fetches /credits and /key together.
type Provider struct {
	http       httpclient.Client
	cache      cache.Store
	dayKeys    *domain.DayKeyOwner
	bearer     secret.Secret
	creditsURL string
	keyURL     string
	headers    map[string]string
}

// Build needs an API key. A management key alone only feeds history backfill.
func Build(env provider.Env) provider.Provider {
	cfg := env.Config.OpenRouter
	if cfg.APIKey == nil {
		return nil
	}
	headers := map[string]string{}
	if cfg.HTTPReferer != nil && *cfg.HTTPReferer != "" {
		headers["HTTP-Referer"] = *cfg.HTTPReferer
	}
	if cfg.XTitle != "" {
		headers["X-Title"] = cfg.XTitle
	}
	return &Provider{
		http: env.HTTP, cache: env.Cache, dayKeys: env.DayKeys, bearer: *cfg.APIKey,
		creditsURL: cfg.APIURL.JoinPath("credits").String(),
		keyURL:     cfg.APIURL.JoinPath("key").String(),
		headers:    headers,
	}
}

func (p *Provider) ID() domain.ProviderID { return domain.OpenRouter }

func (p *Provider) DisplayName() string { return "OpenRouter" }

func (p *Provider) Capabilities() domain.Capabilities {
	return domain.Capabilities{HasQuota: true, HasCost: true}
}

func (p *Provider) get(ctx context.Context) (creditsResponse, keyResponse, error) {
	var credits creditsResponse
	var key keyResponse
	var creditsErr, keyErr error
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		if creditsErr = p.http.GetJSON(ctx, p.creditsURL, &p.bearer, p.headers, &credits); creditsErr == nil {
			creditsErr = credits.validate()
		}
	}()
	go func() {
		defer wg.Done()
		if keyErr = p.http.GetJSON(ctx, p.keyURL, &p.bearer, p.headers, &key); keyErr == nil {
			keyErr = key.validate()
		}
	}()
	wg.Wait()
	if creditsErr != nil {
		return credits, key, creditsErr
	}
	return credits, key, keyErr
}

// todayCost is the delta from today's baseline. A cold start, a new day, or a refund is zero.
func (p *Provider) todayCost(now time.Time, usage float64) float64 {
	b := p.cache.Baseline(domain.OpenRouter)
	if b == nil || b.Date != p.dayKeys.KeyFor(now) || usage < b.Value {
		return 0
	}
	return usage - b.Value
}

func (p *Provider) Fetch(ctx context.Context, now time.Time) (domain.UsageSnapshot, domain.ProviderStatus, error) {
	credits, key, err := p.get(ctx)
	if err != nil {
		return domain.UsageSnapshot{}, domain.ProviderStatus{}, err
	}
	totalCredits, totalUsage := *credits.Data.TotalCredits, *credits.Data.TotalUsage
	cost := decimal.FromFloat64(p.todayCost(now, totalUsage))
	p.cache.MaintainBaseline(domain.OpenRouter, now, totalUsage)
	balance := decimal.FromFloat64(totalCredits - totalUsage)

	return domain.UsageSnapshot{
		ProviderID:   domain.OpenRouter,
		AsOf:         now,
		CostTodayUSD: &cost,
		BalanceUSD:   &balance,
		Quota:        quota(key, totalCredits, totalUsage),
		Raw:          map[string]string{},
		PeriodSpendUSD: &domain.PeriodSpend{
			Day:   decimal.FromFloat64(*key.Data.UsageDaily),
			Week:  decimal.FromFloat64(*key.Data.UsageWeekly),
			Month: decimal.FromFloat64(*key.Data.UsageMonthly),
		},
	}, domain.OK(now), nil
}

// quota prefers the key's limit, then positive prepaid credits.
func quota(key keyResponse, totalCredits, totalUsage float64) *domain.Quota {
	if limit := key.Data.Limit; limit != nil {
		used := *key.Data.Usage
		remaining := math.Max(0, *limit-used)
		if key.Data.LimitRemaining != nil {
			remaining = *key.Data.LimitRemaining
		}
		return &domain.Quota{Used: used, Limit: *limit, Remaining: remaining}
	}
	if totalCredits > 0 {
		return &domain.Quota{Used: totalUsage, Limit: totalCredits, Remaining: math.Max(0, totalCredits-totalUsage)}
	}
	return nil
}
