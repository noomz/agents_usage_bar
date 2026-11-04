package claude

import (
	"context"
	"errors"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/httpclient"
)

const (
	usageURL        = "https://api.anthropic.com/api/oauth/usage"
	oauthBetaHeader = "oauth-2025-04-20"
	userAgent       = "Agents-Usage-Bar/1.0"
)

var (
	errNoCredentials = errors.New("claude: no credentials")
	errTokenExpired  = errors.New("claude: token expired")
)

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

// oauthClient is the usage endpoint. It only reads credentials: an expired token waits for Claude
// Code to refresh it, and the row shows local data until then.
type oauthClient struct {
	http  httpclient.Client
	creds *credentialLoader
	now   func() time.Time
}

func (c *oauthClient) getUsage(ctx context.Context) (*usageResponse, error) {
	now := c.now()
	token := c.creds.load(now)
	if token == nil {
		return nil, errNoCredentials
	}
	if token.expired(now) {
		return nil, errTokenExpired
	}
	var usage usageResponse
	headers := map[string]string{"anthropic-beta": oauthBetaHeader, "Accept": "application/json", "User-Agent": userAgent}
	if err := c.http.GetJSON(ctx, usageURL, &token.AccessToken, headers, &usage); err != nil {
		return nil, err
	}
	return &usage, nil
}
