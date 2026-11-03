// Package gemini reports per-model quota from the Code Assist API for OAuth-personal logins.
//
// gemini-cli owns ~/.gemini/oauth_creds.json, so this package never writes it. An expired access
// token is refreshed in memory and the refreshed token dies with the process. Google does not
// rotate the refresh token, and a rotated one in the response is ignored, so the file stays valid.
package gemini

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/secret"
)

const (
	quotaURL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
	tokenURL = "https://oauth2.googleapis.com/token"
	// refreshSkew is how close to expiry a token may be before it is refreshed.
	refreshSkew = 60 * time.Second
)

var headers = map[string]string{"Accept": "application/json", "User-Agent": "Agents-Usage-Bar/1.0"}

// credentials is ~/.gemini/oauth_creds.json. access_token may be absent, because gemini-cli can
// clear it after a failed refresh. expiry_date is epoch milliseconds.
type credentials struct {
	accessToken  *secret.Secret
	refreshToken secret.Secret
	expiry       time.Time
}

// Format redacts: fmt cannot reach Secret's own Format through an unexported field.
func (credentials) Format(f fmt.State, _ rune) { _, _ = f.Write([]byte("<redacted>")) }

// loadCredentials returns nil when the file is absent, malformed, or missing a required field.
func loadCredentials(path string) *credentials {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	// scope, id_token, and token_type are declared so a mistyped one rejects the file, as Swift's
	// Decodable does.
	var raw struct {
		AccessToken  *string  `json:"access_token"`
		RefreshToken *string  `json:"refresh_token"`
		Scope        *string  `json:"scope"`
		IDToken      *string  `json:"id_token"`
		ExpiryDate   *float64 `json:"expiry_date"`
		TokenType    *string  `json:"token_type"`
	}
	if json.Unmarshal(data, &raw) != nil || raw.RefreshToken == nil || raw.ExpiryDate == nil {
		return nil
	}
	creds := &credentials{
		refreshToken: secret.New(*raw.RefreshToken),
		expiry:       time.UnixMilli(0).Add(time.Duration(*raw.ExpiryDate * float64(time.Millisecond))),
	}
	if raw.AccessToken != nil {
		token := secret.New(*raw.AccessToken)
		creds.accessToken = &token
	}
	return creds
}

// isOAuthPersonal is the gate: security.auth.selectedType must be exactly "oauth-personal". There
// is deliberately no fall-through to a flat key.
func isOAuthPersonal(path string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	var top map[string]any
	if json.Unmarshal(data, &top) != nil {
		return false
	}
	security, _ := top["security"].(map[string]any)
	auth, _ := security["auth"].(map[string]any)
	return auth["selectedType"] == "oauth-personal"
}

// oauthKind classifies a failure to obtain a bearer.
type oauthKind int

const (
	oauthNotSignedIn oauthKind = iota
	oauthRefreshFailed
	oauthRefreshDisabled
	oauthRefreshForbidden
	oauthTransport
)

type oauthError struct {
	kind   oauthKind
	status int
	err    error
}

func (e oauthError) Error() string {
	switch e.kind {
	case oauthNotSignedIn:
		return "not signed in to Gemini"
	case oauthRefreshFailed:
		return fmt.Sprintf("Gemini token refresh failed: HTTP %d", e.status)
	case oauthRefreshDisabled:
		return "Gemini token refresh disabled: GEMINI_CLI_CLIENT_ID and GEMINI_CLI_CLIENT_SECRET not set"
	case oauthRefreshForbidden:
		return "Gemini token refresh is left to gemini-cli on this host"
	}
	return "Gemini token refresh transport failure"
}

func (e oauthError) Unwrap() error { return e.err }

// Provider implements provider.Provider.
type Provider struct {
	env                    provider.Env
	credsPath              string
	clientID, clientSecret string
	status                 domain.ProviderStatus
}

// Build registers Gemini when settings select oauth-personal and the credentials file is usable.
func Build(env provider.Env) provider.Provider {
	dir := filepath.Join(env.Paths.Home, ".gemini")
	credsPath := filepath.Join(dir, "oauth_creds.json")
	if !isOAuthPersonal(filepath.Join(dir, "settings.json")) || loadCredentials(credsPath) == nil {
		return nil
	}
	return &Provider{
		env: env, credsPath: credsPath,
		clientID: env.Getenv("GEMINI_CLI_CLIENT_ID"), clientSecret: env.Getenv("GEMINI_CLI_CLIENT_SECRET"),
	}
}

// ID implements provider.Provider.
func (p *Provider) ID() domain.ProviderID { return domain.Gemini }

// DisplayName implements provider.Provider.
func (p *Provider) DisplayName() string { return "Gemini" }

// Capabilities implements provider.Provider.
func (p *Provider) Capabilities() domain.Capabilities { return domain.Capabilities{HasQuota: true} }

// Status implements provider.Provider.
func (p *Provider) Status() domain.ProviderStatus { return p.status }

// bearer returns the file's access token while it is more than refreshSkew from expiry, unless
// it is the token just rejected with 401. Otherwise it refreshes.
func (p *Provider) bearer(ctx context.Context, now time.Time, rejected *secret.Secret) (secret.Secret, error) {
	creds := loadCredentials(p.credsPath)
	if creds == nil {
		return secret.Secret{}, oauthError{kind: oauthNotSignedIn}
	}
	if t := creds.accessToken; t != nil && *t != (secret.Secret{}) && (rejected == nil || *t != *rejected) && creds.expiry.Sub(now) > refreshSkew {
		return *t, nil
	}
	return p.refresh(ctx, creds.refreshToken)
}

func (p *Provider) refresh(ctx context.Context, refreshToken secret.Secret) (secret.Secret, error) {
	if p.clientID == "" || p.clientSecret == "" {
		return secret.Secret{}, oauthError{kind: oauthRefreshDisabled}
	}
	if p.env.TokenRefresh != provider.RefreshAllowed {
		return secret.Secret{}, oauthError{kind: oauthRefreshForbidden}
	}
	var response struct {
		AccessToken *string `json:"access_token"`
		ExpiresIn   *int    `json:"expires_in"`
	}
	err := p.env.HTTP.PostForm(ctx, tokenURL, [][2]string{
		{"client_id", p.clientID},
		{"client_secret", p.clientSecret},
		{"refresh_token", refreshToken.Reveal()},
		{"grant_type", "refresh_token"},
	}, headers, &response)
	var status domain.HTTPError
	switch {
	case errors.As(err, &status):
		return secret.Secret{}, oauthError{kind: oauthRefreshFailed, status: status.Status}
	case err != nil:
		return secret.Secret{}, oauthError{kind: oauthTransport, err: err}
	case response.AccessToken == nil || response.ExpiresIn == nil:
		return secret.Secret{}, oauthError{kind: oauthTransport, err: domain.DecodeError{Err: errors.New("token response missing a required field")}}
	}
	return secret.New(*response.AccessToken), nil
}

func isRefreshFailure(err error) bool {
	var oauth oauthError
	return errors.As(err, &oauth) && (oauth.kind == oauthRefreshFailed || oauth.kind == oauthRefreshDisabled || oauth.kind == oauthRefreshForbidden)
}

// quotaBucket is one entry of retrieveUserQuota, whose keys are camelCase on the wire.
type quotaBucket struct {
	RemainingFraction *float64 `json:"remainingFraction"`
	ResetTime         *string  `json:"resetTime"`
	ModelID           *string  `json:"modelId"`
	TokenType         *string  `json:"tokenType"`
	RemainingAmount   *string  `json:"remainingAmount"`
}

type quotaResponse struct {
	Buckets []quotaBucket `json:"buckets"`
}

func (p *Provider) fetchQuota(ctx context.Context, bearer secret.Secret) (quotaResponse, error) {
	var response quotaResponse
	err := p.env.HTTP.PostJSON(ctx, quotaURL, map[string]string{"project": ""}, &bearer, headers, &response)
	return response, err
}

// Fetch implements provider.Provider. No credentials is a muted row. A refresh that cannot
// happen is an error. Any other failure is a degraded row, so a flaky v1internal never reports
// as a provider error to the session.
func (p *Provider) Fetch(ctx context.Context, now time.Time) (domain.UsageSnapshot, error) {
	bearer, err := p.bearer(ctx, now, nil)
	if err != nil {
		var oauth oauthError
		if errors.As(err, &oauth) && oauth.kind == oauthNotSignedIn {
			p.status = domain.Unauthenticated()
			return p.muted(now, false), nil
		}
		if isRefreshFailure(err) {
			return domain.UsageSnapshot{}, err
		}
		return p.degraded(now, err), nil
	}

	quota, err := p.fetchQuota(ctx, bearer)
	var status domain.HTTPError
	if errors.As(err, &status) && status.Status == 401 {
		var retried secret.Secret
		retried, err = p.bearer(ctx, now, &bearer)
		if isRefreshFailure(err) {
			return domain.UsageSnapshot{}, err
		}
		if err == nil {
			quota, err = p.fetchQuota(ctx, retried)
		}
	}
	if err != nil {
		return p.degraded(now, err), nil
	}

	windows := foldBuckets(quota.Buckets)
	snap := domain.UsageSnapshot{ProviderID: domain.Gemini, AsOf: now, Raw: map[string]string{"source": "v1internal"}}
	if len(windows) > 0 {
		snap.QuotaWindows = windows
		worst := *windows[0].Utilization
		for _, w := range windows {
			worst = max(worst, *w.Utilization)
		}
		q := domain.UnitQuota(worst)
		snap.Quota = &q
	}
	p.status = domain.OK(now)
	return snap, nil
}

// foldBuckets keeps the lowest remaining fraction per model, sorted by model.
func foldBuckets(buckets []quotaBucket) []domain.QuotaWindow {
	lowest := map[string]quotaBucket{}
	for _, b := range buckets {
		if b.ModelID == nil || b.RemainingFraction == nil {
			continue
		}
		if existing, ok := lowest[*b.ModelID]; ok && *existing.RemainingFraction <= *b.RemainingFraction {
			continue
		}
		lowest[*b.ModelID] = b
	}
	windows := make([]domain.QuotaWindow, 0, len(lowest))
	for model, b := range lowest {
		utilization := 1 - *b.RemainingFraction
		w := domain.QuotaWindow{Name: model, Utilization: &utilization}
		if b.ResetTime != nil {
			if reset, err := time.Parse(time.RFC3339Nano, *b.ResetTime); err == nil {
				w.ResetsAt = &reset
			}
		}
		windows = append(windows, w)
	}
	sort.Slice(windows, func(i, j int) bool { return windows[i].Name < windows[j].Name })
	return windows
}

func (p *Provider) degraded(now time.Time, err error) domain.UsageSnapshot {
	p.status = domain.Errored(domain.ProviderErrorFrom(err))
	return p.muted(now, true)
}

func (p *Provider) muted(now time.Time, tagged bool) domain.UsageSnapshot {
	raw := map[string]string{"status": "no-data-yet"}
	if tagged {
		raw["note"] = domain.DegradedNote
	}
	return domain.UsageSnapshot{ProviderID: domain.Gemini, AsOf: now, Raw: raw}
}
