package grok

import (
	"context"
	"math"
	"os"
	"strings"
	"time"
	"unicode"

	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/secret"
)

const defaultManagementURL = "https://management-api.x.ai"

type managementSnapshot struct {
	remainingUSD *decimal.Decimal
	costTodayUSD *decimal.Decimal
}

type managementClient struct {
	env     provider.Env
	baseURL string
	bearer  secret.Secret
	teamID  string
}

// isSafeTeamID: the team id is a path segment.
func isSafeTeamID(raw string) bool {
	if raw == "" {
		return false
	}
	for _, c := range raw {
		if c != '-' && !unicode.IsLetter(c) && !unicode.IsDigit(c) {
			return false
		}
	}
	return true
}

func (m *managementClient) fetch(ctx context.Context, now time.Time) (*managementSnapshot, error) {
	if !isSafeTeamID(m.teamID) {
		return nil, errNoCredentials
	}
	remaining, err := m.balance(ctx)
	if err != nil {
		return nil, err
	}
	spend, err := m.todaySpend(ctx, now)
	if err != nil {
		return nil, err
	}
	return &managementSnapshot{remainingUSD: remaining, costTodayUSD: &spend}, nil
}

func (m *managementClient) teamURL(leaf string) string {
	return strings.TrimRight(m.baseURL, "/") + "/v1/billing/teams/" + m.teamID + "/" + leaf
}

func (m *managementClient) balance(ctx context.Context) (*decimal.Decimal, error) {
	var response prepaidBalanceResponse
	if err := m.env.HTTP.GetJSON(ctx, m.teamURL("prepaid/balance"), &m.bearer, map[string]string{}, &response); err != nil {
		return nil, mapBillingError(err)
	}
	return response.remainingUSD(), nil
}

func (m *managementClient) todaySpend(ctx context.Context, now time.Time) (decimal.Decimal, error) {
	start := m.env.DayKeys.StartOfDay(now)
	request := analyticsRequest{}
	request.Analytics.TimeRange.Start = start.Format(stampLayout)
	request.Analytics.TimeRange.End = start.AddDate(0, 0, 1).Format(stampLayout)
	request.Analytics.TimeRange.Timezone = zoneIdentifier(m.env.Getenv)
	request.Analytics.TimeUnit = "TIME_UNIT_NONE"
	request.Analytics.Values = []analyticsValue{{"usd", "AGGREGATION_SUM"}}
	request.Analytics.GroupBy = []string{"description"}
	request.Analytics.Filters = []string{}
	var response analyticsResponse
	if err := m.env.HTTP.PostJSON(ctx, m.teamURL("usage"), request, &m.bearer, map[string]string{}, &response); err != nil {
		return decimal.Decimal{}, mapBillingError(err)
	}
	return response.totalUSD(), nil
}

const stampLayout = "2006-01-02 15:04:05"

// zoneIdentifier is the IANA name Foundation's TimeZone.current gives. Go's time.Local is named
// "Local", which the API would reject.
func zoneIdentifier(getenv func(string) string) string {
	if tz := strings.TrimPrefix(getenv("TZ"), ":"); tz != "" {
		return tz
	}
	if target, err := os.Readlink("/etc/localtime"); err == nil {
		if _, name, ok := strings.Cut(target, "zoneinfo/"); ok && name != "" {
			return name
		}
	}
	return "UTC"
}

type prepaidBalanceResponse struct {
	Total *struct {
		Val *string `json:"val"`
	} `json:"total"`
}

func (r prepaidBalanceResponse) remainingUSD() *decimal.Decimal {
	if r.Total == nil || r.Total.Val == nil {
		return nil
	}
	cents, ok := decimal.Parse(*r.Total.Val)
	if !ok {
		return nil
	}
	if cents.Sign() < 0 {
		cents = cents.Mul(decimal.FromInt(-1))
	}
	usd := cents.Div(decimal.FromInt(100))
	return &usd
}

type analyticsValue struct {
	Name        string `json:"name"`
	Aggregation string `json:"aggregation"`
}

// analyticsRequest uses the snake_case keys the shared HTTP client's encoder sends in Swift.
type analyticsRequest struct {
	Analytics struct {
		TimeRange struct {
			Start    string `json:"start_time"`
			End      string `json:"end_time"`
			Timezone string `json:"timezone"`
		} `json:"time_range"`
		TimeUnit string           `json:"time_unit"`
		Values   []analyticsValue `json:"values"`
		GroupBy  []string         `json:"group_by"`
		Filters  []string         `json:"filters"`
	} `json:"analytics_request"`
}

type analyticsSeries struct {
	DataPoints      []analyticsPoint `json:"dataPoints"`
	DataPointsSnake []analyticsPoint `json:"data_points"`
}

type analyticsPoint struct {
	Values []float64 `json:"values"`
}

// analyticsResponse takes both spellings: Swift decodes this reply with convertFromSnakeCase,
// which accepts timeSeries and time_series alike.
type analyticsResponse struct {
	TimeSeries      []analyticsSeries `json:"timeSeries"`
	TimeSeriesSnake []analyticsSeries `json:"time_series"`
}

func (r analyticsResponse) totalUSD() decimal.Decimal {
	sum := decimal.FromInt(0)
	for _, series := range append(r.TimeSeries, r.TimeSeriesSnake...) {
		for _, point := range append(series.DataPoints, series.DataPointsSnake...) {
			for _, value := range point.Values {
				if !math.IsNaN(value) && !math.IsInf(value, 0) {
					sum = sum.Add(decimal.FromFloat64(value))
				}
			}
		}
	}
	return sum
}
