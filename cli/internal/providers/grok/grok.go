// Package grok is the Grok row: SuperGrok quota from the CLI billing proxy, prepaid balance and
// API spend from the xAI Management API, and today's xai spend from Pi session JSONL.
package grok

import (
	"context"
	"errors"
	"net/url"
	"strings"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/cache"
	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/providers/pilocal"
	"github.com/noomz/agents_usage_bar/cli/internal/swiftjson"
)

const (
	defaultCreditsURL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
	defaultProxyBase  = "https://cli-chat-proxy.grok.com/v1"
	offsetPrefix      = "grok:"
)

var xaiCatalog = pilocal.Catalog{"xai": true}

// Provider is the Grok row.
type Provider struct {
	env        provider.Env
	management *managementClient
	status     domain.ProviderStatus
}

// Build registers the row when a bearer or a management key exists.
func Build(env provider.Env) provider.Provider {
	var management *managementClient
	if key, team := env.Config.Grok.ManagementKey, env.Config.Grok.TeamID; key != nil && team != nil {
		management = &managementClient{env: env, baseURL: defaultManagementURL, bearer: *key, teamID: *team}
	}
	if len(loadCandidates(env, env.Clock.Now())) == 0 && management == nil {
		return nil
	}
	return &Provider{
		env: env, management: management,
		status: domain.Errored(domain.ProviderError{Kind: domain.ErrNotYetFetched, Message: "not yet fetched"}),
	}
}

// ID implements provider.Provider.
func (*Provider) ID() domain.ProviderID { return domain.Grok }

// DisplayName implements provider.Provider.
func (*Provider) DisplayName() string { return "Grok" }

// Capabilities implements provider.Provider.
func (*Provider) Capabilities() domain.Capabilities {
	return domain.Capabilities{HasQuota: true, HasCost: true, HasTokens: true}
}

// Status implements provider.Provider.
func (p *Provider) Status() domain.ProviderStatus { return p.status }

// creditsURL accepts the proxy base or a full billing URL, and always pins format=credits: bare
// /billing returns a monthly {val:0} stub that reads as "no limit".
func creditsURL(base *url.URL) string {
	if base == nil || strings.Trim(base.String(), "/") == defaultProxyBase {
		return defaultCreditsURL
	}
	u := *base
	if !strings.Contains(u.Path, "/billing") {
		u = *u.JoinPath("billing")
	}
	var query []string
	for _, part := range strings.Split(u.RawQuery, "&") {
		if part != "" && part != "format" && !strings.HasPrefix(part, "format=") {
			query = append(query, part)
		}
	}
	u.RawQuery = strings.Join(append(query, "format=credits"), "&")
	return u.String()
}

func (p *Provider) fetchCredits(ctx context.Context, now time.Time) (*billingResponse, error) {
	candidates := loadCandidates(p.env, now)
	if len(candidates) == 0 {
		return nil, errNoCredentials
	}
	var lastUnauthorized error
	for _, cred := range candidates {
		response, err := p.getCredits(ctx, cred)
		if err == nil {
			return response, nil
		}
		if !isAuthError(err) {
			return nil, err
		}
		lastUnauthorized = err
	}
	return nil, lastUnauthorized
}

func (p *Provider) getCredits(ctx context.Context, cred credential) (*billingResponse, error) {
	headers := map[string]string{"Accept": "application/json"}
	if cred.source == sourceSession {
		headers["X-XAI-Token-Auth"] = "xai-grok-cli"
		headers["x-grok-client-mode"] = "cli"
	}
	var response billingResponse
	if err := p.env.HTTP.GetJSON(ctx, creditsURL(p.env.Config.Grok.APIURL), &cred.token, headers, &response); err != nil {
		return nil, mapBillingError(err)
	}
	return &response, nil
}

func mapBillingError(err error) error {
	var httpErr domain.HTTPError
	if errors.As(err, &httpErr) {
		if httpErr.Status == 401 || httpErr.Status == 403 {
			return unauthorized(httpErr.Status)
		}
		return endpointFailed(httpErr.Status)
	}
	var decodeErr domain.DecodeError
	if errors.As(err, &decodeErr) {
		return errDecodeFailed
	}
	return err
}

type jsonlLoad struct {
	contributed bool
	tokens      int
	costUSD     decimal.Decimal
}

func (p *Provider) loadJSONL(now time.Time) jsonlLoad {
	roots := pilocal.SessionDirs(p.env.Getenv, p.env.Paths.Home)
	var delta pilocal.Delta
	var total domain.DailyUsageRecord
	var err error
	p.env.Cache.WithCursors(func(c cache.Cursors) {
		if delta, err = pilocal.ReadSessions(c, roots, xaiCatalog, p.env.DayKeys.StartOfDay(now), offsetPrefix); err == nil {
			total = c.AccumulateDailyUsage(domain.Grok, now, delta.Acc.Tokens, delta.Acc.CostUSD, map[string]int{})
		}
	})
	if err != nil {
		return jsonlLoad{}
	}
	if len(delta.Acc.Providers) == 0 && total.Tokens <= 0 && total.CostUSD.Sign() <= 0 {
		return jsonlLoad{}
	}
	return jsonlLoad{contributed: true, tokens: total.Tokens, costUSD: total.CostUSD}
}

// Fetch implements provider.Provider. CLI billing, management, and JSONL fail independently; an
// outage of all three mutes the row rather than failing it, and no snapshot carries over
// between fetches because one process fetches once.
func (p *Provider) Fetch(ctx context.Context, now time.Time) (domain.UsageSnapshot, error) {
	billing, cliErr := p.fetchCredits(ctx, now)
	cliHard := cliErr != nil && !isAuthError(cliErr)
	if cliErr == nil && billing.isEmpty() {
		billing, cliErr = nil, errEmptyPayload
	}
	var mgmt *managementSnapshot
	var mgmtErr error
	if p.management != nil {
		mgmt, mgmtErr = p.management.fetch(ctx, now)
	}
	jsonl := p.loadJSONL(now)

	if billing != nil || mgmt != nil || jsonl.contributed {
		p.status = domain.OK(now)
		return p.snapshot(billing, mgmt, jsonl, now), nil
	}
	if cliHard {
		p.status = domain.Errored(domain.ProviderErrorFrom(cliErr))
		return mutedSnapshot(now, true), nil
	}
	reason := cliErr
	if mgmtErr != nil {
		reason = mgmtErr
	}
	if reason == nil {
		reason = errEmptyPayload
	}
	if isAuthError(reason) {
		p.status = domain.Unauthenticated()
		return mutedSnapshot(now, false), nil
	}
	p.status = domain.Errored(domain.ProviderErrorFrom(reason))
	return mutedSnapshot(now, true), nil
}

func mutedSnapshot(now time.Time, tagged bool) domain.UsageSnapshot {
	raw := map[string]string{"status": "no-data-yet"}
	if tagged {
		raw["note"] = domain.DegradedNote
	}
	return domain.UsageSnapshot{ProviderID: domain.Grok, AsOf: now, Raw: raw}
}

func (p *Provider) snapshot(billing *billingResponse, mgmt *managementSnapshot, jsonl jsonlLoad, now time.Time) domain.UsageSnapshot {
	snap := domain.UsageSnapshot{ProviderID: domain.Grok, AsOf: now, Raw: map[string]string{}}
	var sources []string
	if mgmt != nil {
		sources = append(sources, "management")
	}
	if jsonl.contributed {
		sources = append(sources, "pi-jsonl")
	}
	if len(sources) > 0 {
		snap.Raw["source"] = strings.Join(sources, ",")
	}
	var cliBalance *decimal.Decimal
	if billing != nil {
		snap.Quota = billing.quota()
		putRaw(snap.Raw, "subscriptionTier", billing.subscriptionTier)
		putRaw(snap.Raw, "period", firstNonNil(billing.periodLabel, billing.currentPeriod))
		putRaw(snap.Raw, "product", billing.productLabel)
		if prepaid := billing.prepaidBalance; prepaid != nil {
			snap.Raw["prepaidBalance"] = swiftjson.DoubleDescription(*prepaid)
			if *prepaid > 0 {
				balance := decimal.FromFloat64(*prepaid)
				cliBalance = &balance
			}
		}
		if percent := billing.normalizedPercent(); percent != nil {
			snap.QuotaWindows = []domain.QuotaWindow{{Name: "billing", Utilization: percent, ResetsAt: billing.billingPeriodEnd}}
		}
	}
	if mgmt != nil && mgmt.remainingUSD != nil {
		snap.BalanceUSD = mgmt.remainingUSD
	} else {
		snap.BalanceUSD = cliBalance
	}
	if jsonl.contributed {
		tokens, cost := jsonl.tokens, jsonl.costUSD
		snap.TokensToday, snap.CostTodayUSD = &tokens, &cost
	} else if mgmt != nil {
		snap.CostTodayUSD = mgmt.costTodayUSD
	}
	return snap
}

func putRaw(raw map[string]string, key string, value *string) {
	if value != nil {
		raw[key] = *value
	}
}

// quota prefers included-used over the monthly limit, else reads percent on a 100 scale.
func (r billingResponse) quota() *domain.Quota {
	if r.monthlyLimit != nil && *r.monthlyLimit > 0 {
		limit := *r.monthlyLimit
		used := 0.0
		switch percent := r.normalizedPercent(); {
		case r.includedUsed != nil:
			used = *r.includedUsed
		case r.totalUsed != nil:
			used = *r.totalUsed
		case percent != nil:
			used = *percent * limit
		}
		return &domain.Quota{Used: used, Limit: limit, Remaining: max(0, limit-used)}
	}
	if percent := r.normalizedPercent(); percent != nil {
		return &domain.Quota{Used: *percent * 100, Limit: 100, Remaining: max(0, 100-*percent*100)}
	}
	return nil
}
