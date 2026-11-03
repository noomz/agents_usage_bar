package claude

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/httpclient"
	"github.com/noomz/agents_usage_bar/cli/internal/secret"
)

const (
	usageURL        = "https://api.anthropic.com/api/oauth/usage"
	refreshURL      = "https://platform.claude.com/v1/oauth/token"
	oauthBetaHeader = "oauth-2025-04-20"
	oauthClientID   = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
	userAgent       = "Agents-Usage-Bar/1.0"
)

var errNoCredentials = errors.New("claude: no credentials")

type quotaWindowResponse struct {
	Utilization *float64 `json:"utilization"`
	ResetsAt    *string  `json:"resets_at"`
}

type usageResponse struct {
	FiveHour       *quotaWindowResponse `json:"five_hour"`
	SevenDay       *quotaWindowResponse `json:"seven_day"`
	SevenDaySonnet *quotaWindowResponse `json:"seven_day_sonnet"`
	SevenDayOpus   *quotaWindowResponse `json:"seven_day_opus"`
}

type refreshResponse struct {
	AccessToken  *string  `json:"access_token"`
	RefreshToken *string  `json:"refresh_token"`
	ExpiresIn    *float64 `json:"expires_in"`
}

type refreshBody struct {
	GrantType    string `json:"grant_type"`
	RefreshToken string `json:"refresh_token"`
	ClientID     string `json:"client_id"`
}

// oauthClient is the usage endpoint behind the credential lifecycle.
type oauthClient struct {
	http  httpclient.Client
	creds *credentialLoader
	now   func() time.Time
}

// getUsage loads credentials, refreshes file tokens near expiry, and reads usage. A Keychain
// token is never refreshed: Claude Code owns that item, so refreshing would rotate the token out
// from under it, and this process never writes the Keychain. An environment token has no refresh
// token. A failed refresh leaves the stored file untouched.
func (c *oauthClient) getUsage(ctx context.Context) (*usageResponse, error) {
	credential := c.creds.load()
	if credential == nil {
		return nil, errNoCredentials
	}
	token := credential.token
	if credential.source != sourceKeychain && needsRefresh(token, c.now()) && token.RefreshToken != nil {
		rotated, err := c.refresh(ctx, token)
		if err != nil {
			return nil, err
		}
		token = rotated
		if credential.source == sourceFile {
			if err := c.creds.saveToFile(rotated); err != nil {
				logSaveFailure()
			}
		}
	}
	var usage usageResponse
	headers := map[string]string{"anthropic-beta": oauthBetaHeader, "Accept": "application/json", "User-Agent": userAgent}
	if err := c.http.GetJSON(ctx, usageURL, &token.AccessToken, headers, &usage); err != nil {
		return nil, err
	}
	return &usage, nil
}

func (c *oauthClient) refresh(ctx context.Context, token oauthToken) (oauthToken, error) {
	body := refreshBody{GrantType: "refresh_token", RefreshToken: token.RefreshToken.Reveal(), ClientID: oauthClientID}
	headers := map[string]string{"Accept": "application/json", "User-Agent": userAgent}
	var response refreshResponse
	if err := c.http.PostJSON(ctx, refreshURL, body, nil, headers, &response); err != nil {
		var status domain.HTTPError
		if errors.As(err, &status) && (status.Status == 400 || status.Status == 401) {
			return oauthToken{}, fmt.Errorf("refresh failed: invalid_client (run 'claude logout && claude login')")
		}
		return oauthToken{}, fmt.Errorf("refresh failed: %w", err)
	}
	if response.AccessToken == nil || *response.AccessToken == "" {
		return oauthToken{}, errors.New("refresh failed: no access token in reply")
	}
	rotated := token
	rotated.AccessToken = secret.New(*response.AccessToken)
	if response.RefreshToken != nil {
		wrapped := secret.New(*response.RefreshToken)
		rotated.RefreshToken = &wrapped
	}
	if response.ExpiresIn != nil {
		expires := float64(c.now().UnixMilli()) + *response.ExpiresIn*1000
		rotated.ExpiresAtMs = &expires
	}
	return rotated, nil
}
