// Package ollamacloud reports Ollama Cloud's monthly included usage. Every fetch re-reads the
// config and device key, so a fixed credential applies on the next poll and key bytes live only
// for the fetch.
package ollamacloud

import (
	"context"
	"errors"
	"strconv"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/config"
	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/httpclient"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/secret"
)

const (
	defaultBaseURL = "https://ollama.com"
	windowName     = "mo"
	noCredential   = "run ollama signin or set OLLAMA_API_KEY"
)

type usageResponse struct {
	Activity *struct {
		Cost *string `json:"cost"`
	} `json:"activity"`
	Limits *struct {
		Monthly *struct {
			Usage *float64 `json:"usage"`
		} `json:"monthly"`
	} `json:"limits"`
}

// meResponse declares only Plan: the response also carries personal fields that are never read.
type meResponse struct {
	Plan *string `json:"Plan"`
}

// credential is an explicit key sent as Bearer, or a device key that signs.
type credential struct {
	apiKey *secret.Secret
	source config.CredentialSource
	device *signer
}

func resolve(cfg config.OllamaCloud, loadDevice func() *signer) *credential {
	if cfg.APIKey != nil {
		source := cfg.APIKeySource
		if source == "" {
			source = config.SourceConfig
		}
		return &credential{apiKey: cfg.APIKey, source: source}
	}
	if device := loadDevice(); device != nil {
		return &credential{device: device}
	}
	return nil
}

func (c *credential) sourceKey() string {
	if c.device != nil {
		return "device"
	}
	return string(c.source)
}

func (c *credential) rejectedHint() string {
	switch {
	case c.device != nil:
		return "run ollama signin"
	case c.source == config.SourceEnv:
		return "check OLLAMA_API_KEY"
	}
	return "check [ollama] api_key"
}

// fingerprint identifies which credential a plan belongs to, not just its source. It stays in
// memory and is never printed.
type fingerprint struct {
	key    secret.Secret
	device string
}

func (c *credential) fingerprint() fingerprint {
	if c.device != nil {
		return fingerprint{device: c.device.publicKeyField}
	}
	return fingerprint{key: *c.apiKey}
}

// Provider polls /api/usage, then /api/me until one call succeeds for the current credential.
type Provider struct {
	http       httpclient.Client
	loadConfig func() config.OllamaCloud
	loadDevice func() *signer
	baseURL    string
	loc        *time.Location

	plan        *string
	planFetched bool
	planOwner   *fingerprint
}

// Build registers the row only when a credential resolves. No credential means no row at all.
func Build(env provider.Env) provider.Provider {
	path := deviceKeyPath(env.Paths.Home)
	loadDevice := func() *signer { return loadSigner(path) }
	if resolve(env.Config.OllamaCloud, loadDevice) == nil {
		return nil
	}
	fileEnv := func(key string) (string, bool) {
		v := env.Getenv(key)
		return v, v != ""
	}
	return newProvider(env.HTTP, func() config.OllamaCloud {
		return config.Load(fileEnv, env.Paths.ConfigFile()).OllamaCloud
	}, loadDevice, time.Local)
}

func newProvider(http httpclient.Client, loadConfig func() config.OllamaCloud, loadDevice func() *signer, loc *time.Location) *Provider {
	return &Provider{
		http: http, loadConfig: loadConfig, loadDevice: loadDevice, baseURL: defaultBaseURL, loc: loc,
	}
}

// ID implements provider.Provider.
func (p *Provider) ID() domain.ProviderID { return domain.OllamaCloud }

// DisplayName implements provider.Provider.
func (p *Provider) DisplayName() string { return "Ollama Cloud" }

// Capabilities implements provider.Provider: quota only, never today's totals.
func (p *Provider) Capabilities() domain.Capabilities { return domain.Capabilities{HasQuota: true} }

func (p *Provider) usage(ctx context.Context, c *credential, now time.Time) (usageResponse, error) {
	var out usageResponse
	rawURL := p.baseURL + "/api/usage"
	if c.device == nil {
		return out, p.http.GetJSON(ctx, rawURL, c.apiKey, nil, &out)
	}
	signed, auth, err := c.device.sign("GET", rawURL, now)
	if err != nil {
		return out, err
	}
	return out, p.http.GetJSON(ctx, signed, nil, map[string]string{"Authorization": auth}, &out)
}

func (p *Provider) fetchPlan(ctx context.Context, c *credential, now time.Time) (*string, error) {
	var out meResponse
	rawURL := p.baseURL + "/api/me"
	var err error
	if c.device == nil {
		err = p.http.PostJSON(ctx, rawURL, struct{}{}, c.apiKey, nil, &out)
	} else {
		signed, auth, signErr := c.device.sign("POST", rawURL, now)
		if signErr != nil {
			return nil, signErr
		}
		err = p.http.PostJSON(ctx, signed, struct{}{}, nil, map[string]string{"Authorization": auth}, &out)
	}
	if err != nil {
		return nil, err
	}
	if out.Plan != nil && *out.Plan == "" {
		return nil, nil
	}
	return out.Plan, nil
}

// Fetch implements provider.Provider. A rejected credential fails with a fix-it hint and never
// falls back to another credential or sends a second request.
func (p *Provider) Fetch(ctx context.Context, now time.Time) (domain.UsageSnapshot, domain.ProviderStatus, error) {
	cfg := p.loadConfig()
	c := resolve(cfg, p.loadDevice)
	if c == nil {
		return domain.UsageSnapshot{}, domain.ProviderStatus{}, domain.ProviderError{Kind: domain.ErrAuth, Message: noCredential}
	}
	owner := c.fingerprint()
	if p.planOwner == nil || *p.planOwner != owner {
		p.plan, p.planFetched, p.planOwner = nil, false, &owner
	}
	usage, err := p.usage(ctx, c, now)
	if err != nil {
		return domain.UsageSnapshot{}, domain.ProviderStatus{}, classify(err, c)
	}
	if !p.planFetched {
		if plan, err := p.fetchPlan(ctx, c, now); err == nil {
			p.plan, p.planFetched = plan, true
		}
	}
	return snapshot(usage, p.plan, c, cfg.BillingDay, now, p.loc), domain.OK(now), nil
}

func classify(err error, c *credential) domain.ProviderError {
	var he domain.HTTPError
	if errors.As(err, &he) && (he.Status == 401 || he.Status == 403) {
		return domain.ProviderError{Kind: domain.ErrAuth, Message: c.rejectedHint()}
	}
	return domain.ProviderErrorFrom(err)
}

// ownSpend needs the whole string to be a number, so garbage is omitted rather than misread.
func ownSpend(cost string) *decimal.Decimal {
	if _, err := strconv.ParseFloat(cost, 64); err != nil {
		return nil
	}
	d, ok := decimal.Parse(cost)
	if !ok {
		return nil
	}
	return &d
}

func snapshot(usage usageResponse, plan *string, c *credential, billingDay *int, now time.Time, loc *time.Location) domain.UsageSnapshot {
	raw := map[string]string{"credentialSource": c.sourceKey()}
	if plan != nil {
		raw["plan"] = *plan
	}
	if usage.Activity != nil && usage.Activity.Cost != nil {
		if spend := ownSpend(*usage.Activity.Cost); spend != nil {
			raw["ownSpendLast4WeeksUSD"] = spend.String()
		}
	}
	snap := domain.UsageSnapshot{ProviderID: domain.OllamaCloud, AsOf: now, Raw: raw}
	if usage.Limits != nil && usage.Limits.Monthly != nil && usage.Limits.Monthly.Usage != nil {
		fraction := min(max(*usage.Limits.Monthly.Usage, 0), 1)
		// No Duration: calendar months are not fixed-length, and the compact view would label a
		// duration `30d` instead of `mo`.
		window := domain.QuotaWindow{Name: windowName, Utilization: &fraction, ResetsAt: nextReset(billingDay, now, loc)}
		snap.Quota = window.AsQuota()
		snap.QuotaWindows = []domain.QuotaWindow{window}
	}
	return snap
}

// nextReset is the next local midnight on the billing day strictly after now. The day clamps to
// the month's last day.
func nextReset(billingDay *int, now time.Time, loc *time.Location) *time.Time {
	if billingDay == nil || *billingDay < 1 || *billingDay > 31 {
		return nil
	}
	local := now.In(loc)
	year, month := local.Year(), local.Month()
	for offset := range time.Month(2) {
		last := time.Date(year, month+offset+1, 0, 0, 0, 0, 0, loc).Day()
		candidate := time.Date(year, month+offset, min(*billingDay, last), 0, 0, 0, 0, loc)
		if candidate.After(now) {
			return &candidate
		}
	}
	return nil
}
