package grok

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"
)

// billingResponse is the lenient decode of GET /billing?format=credits. Fields sit at the top
// level or under data, billing, or config, in camelCase or snake_case.
type billingResponse struct {
	creditUsagePercent *float64
	monthlyLimit       *float64
	includedUsed       *float64
	totalUsed          *float64
	prepaidBalance     *float64
	subscriptionTier   *string
	billingPeriodEnd   *time.Time
	currentPeriod      *string
	periodLabel        *string
	productLabel       *string
}

// UnmarshalJSON tries the live typed envelope first. Any field of the wrong type there rejects
// that whole path, as Codable does, and the flexible reader takes over.
func (r *billingResponse) UnmarshalJSON(data []byte) error {
	var top map[string]any
	if err := json.Unmarshal(data, &top); err != nil {
		return err
	}
	if top == nil {
		return errors.New("billing payload is not an object")
	}
	if typed := fromCreditsDocument(top); typed != nil {
		*r = *typed
		return nil
	}
	for _, level := range []map[string]any{top, objectField(top, "data"), objectField(top, "billing"), objectField(top, "config")} {
		if level == nil {
			continue
		}
		if fields := decodeFields(level); fields != nil {
			*r = *fields
			return nil
		}
	}
	*r = billingResponse{}
	return nil
}

func objectField(m map[string]any, key string) map[string]any {
	inner, _ := m[key].(map[string]any)
	return inner
}

func strictNumber(m map[string]any, key string) (*float64, bool) {
	switch v := m[key].(type) {
	case nil:
		return nil, true
	case float64:
		return &v, true
	}
	return nil, false
}

func strictString(m map[string]any, key string) (*string, bool) {
	switch v := m[key].(type) {
	case nil:
		return nil, true
	case string:
		return &v, true
	}
	return nil, false
}

// strictAmount is a number or a `{ "val": N }` box. A box without a number fails.
func strictAmount(m map[string]any, key string) (*float64, bool) {
	switch v := m[key].(type) {
	case nil:
		return nil, true
	case float64:
		return &v, true
	case map[string]any:
		if val, ok := v["val"].(float64); ok {
			return &val, true
		}
	}
	return nil, false
}

func fromCreditsDocument(top map[string]any) *billingResponse {
	cfg, ok := top["config"].(map[string]any)
	if !ok {
		return nil
	}
	docPercent, ok := strictNumber(top, "creditUsagePercent")
	if !ok {
		return nil
	}
	var period map[string]any
	switch v := cfg["currentPeriod"].(type) {
	case nil:
	case map[string]any:
		period = v
	default:
		return nil
	}
	periodType, ok1 := strictString(period, "type")
	_, ok2 := strictString(period, "start")
	periodEnd, ok3 := strictString(period, "end")
	if !ok1 || !ok2 || !ok3 {
		return nil
	}
	rows, ok := strictRows(cfg, "productUsage", false)
	if !ok {
		return nil
	}
	percentField, ok1 := strictNumber(cfg, "creditUsagePercent")
	_, ok2 = strictString(cfg, "billingPeriodStart")
	endField, ok3 := strictString(cfg, "billingPeriodEnd")
	tier, ok4 := strictString(cfg, "subscriptionTier")
	if !ok1 || !ok2 || !ok3 || !ok4 {
		return nil
	}
	if unified, present := cfg["isUnifiedBillingUser"]; present && unified != nil {
		if _, isBool := unified.(bool); !isBool {
			return nil
		}
	}
	amounts := map[string]*float64{}
	for _, key := range []string{"monthlyLimit", "used", "includedUsed", "totalUsed", "prepaidBalance", "onDemandCap", "onDemandUsed"} {
		amount, ok := strictAmount(cfg, key)
		if !ok {
			return nil
		}
		amounts[key] = amount
	}

	product := preferredRow(rows)
	percent := firstNonNil(percentField, docPercent)
	if percent == nil && product != nil {
		percent = product.usagePercent
	}
	end := parseDate(firstNonNil(endField, periodEnd))
	var label *string
	if periodType != nil {
		humanized := humanizePeriod(*periodType)
		label = &humanized
	}
	response := &billingResponse{
		creditUsagePercent: percent,
		monthlyLimit:       amounts["monthlyLimit"],
		includedUsed:       firstNonNil(amounts["used"], amounts["includedUsed"], amounts["totalUsed"]),
		totalUsed:          amounts["totalUsed"],
		prepaidBalance:     amounts["prepaidBalance"],
		subscriptionTier:   tier,
		billingPeriodEnd:   end,
		currentPeriod:      label,
		periodLabel:        label,
	}
	if product != nil {
		response.productLabel = product.product
	}
	if response.creditUsagePercent == nil && response.monthlyLimit == nil && response.includedUsed == nil && response.billingPeriodEnd == nil {
		return nil
	}
	return response
}

func firstNonNil[T any](values ...*T) *T {
	for _, v := range values {
		if v != nil {
			return v
		}
	}
	return nil
}

type productRow struct {
	product      *string
	usagePercent *float64
}

// strictRows reads a product usage array. Any wrong-typed row fails it.
func strictRows(m map[string]any, key string, snake bool) ([]productRow, bool) {
	raw, present := m[key]
	if !present || raw == nil {
		return nil, true
	}
	list, ok := raw.([]any)
	if !ok {
		return nil, false
	}
	rows := make([]productRow, 0, len(list))
	for _, item := range list {
		row, ok := item.(map[string]any)
		if !ok {
			return nil, false
		}
		product, ok1 := strictString(row, "product")
		percent, ok2 := strictNumber(row, "usagePercent")
		if !ok1 || !ok2 {
			return nil, false
		}
		if percent == nil && snake {
			if percent, ok2 = strictNumber(row, "usage_percent"); !ok2 {
				return nil, false
			}
		}
		rows = append(rows, productRow{product, percent})
	}
	return rows, true
}

func preferredRow(rows []productRow) *productRow {
	for i := range rows {
		if rows[i].product != nil && strings.Contains(strings.ToLower(*rows[i].product), "grok") {
			return &rows[i]
		}
	}
	if len(rows) > 0 {
		return &rows[0]
	}
	return nil
}

func decodeFields(c map[string]any) *billingResponse {
	label, periodEnd := decodePeriod(c)
	var productLabel *string
	var productPercent *float64
	for _, key := range []string{"productUsage", "product_usage"} {
		rows, ok := strictRows(c, key, true)
		if !ok || len(rows) == 0 {
			continue
		}
		row := preferredRow(rows)
		productLabel, productPercent = row.product, row.usagePercent
		break
	}
	r := &billingResponse{
		creditUsagePercent: firstNonNil(flexibleDouble(c, "creditUsagePercent", "credit_usage_percent"), productPercent),
		monthlyLimit:       flexibleDouble(c, "monthlyLimit", "monthly_limit"),
		includedUsed:       flexibleDouble(c, "includedUsed", "included_used", "used"),
		totalUsed:          flexibleDouble(c, "totalUsed", "total_used"),
		prepaidBalance:     flexibleDouble(c, "prepaidBalance", "prepaid_balance"),
		subscriptionTier:   flexibleString(c, "subscriptionTier", "subscription_tier"),
		billingPeriodEnd:   firstNonNil(flexibleDate(c, "billingPeriodEnd", "billing_period_end"), periodEnd),
		currentPeriod:      label,
		periodLabel:        label,
		productLabel:       productLabel,
	}
	if r.creditUsagePercent == nil && r.monthlyLimit == nil && r.includedUsed == nil && r.totalUsed == nil &&
		r.prepaidBalance == nil && r.subscriptionTier == nil && r.billingPeriodEnd == nil {
		return nil
	}
	return r
}

func decodePeriod(c map[string]any) (*string, *time.Time) {
	if s := flexibleString(c, "currentPeriod", "current_period"); s != nil {
		humanized := humanizePeriod(*s)
		return &humanized, nil
	}
	for _, key := range []string{"currentPeriod", "current_period"} {
		nested, ok := c[key].(map[string]any)
		if !ok {
			continue
		}
		var label *string
		if kind, ok := nested["type"].(string); ok {
			humanized := humanizePeriod(kind)
			label = &humanized
		}
		var end *time.Time
		if s, ok := nested["end"].(string); ok {
			end = parseDate(&s)
		}
		return label, end
	}
	return nil, nil
}

func flexibleDouble(c map[string]any, keys ...string) *float64 {
	for _, key := range keys {
		switch v := c[key].(type) {
		case float64:
			return &v
		case string:
			if parsed, err := strconv.ParseFloat(v, 64); err == nil {
				return &parsed
			}
		case map[string]any:
			if val, ok := v["val"].(float64); ok {
				return &val
			}
		}
	}
	return nil
}

func flexibleString(c map[string]any, keys ...string) *string {
	for _, key := range keys {
		if v, ok := c[key].(string); ok && v != "" {
			return &v
		}
	}
	return nil
}

func flexibleDate(c map[string]any, keys ...string) *time.Time {
	for _, key := range keys {
		switch v := c[key].(type) {
		case string:
			if d := parseDate(&v); d != nil {
				return d
			}
		case float64:
			seconds := v
			if seconds > 1_000_000_000_000 {
				seconds /= 1000
			}
			d := time.UnixMilli(int64(seconds * 1000))
			return &d
		}
	}
	return nil
}

func parseDate(raw *string) *time.Time {
	if raw == nil {
		return nil
	}
	t, err := time.Parse(time.RFC3339Nano, *raw)
	if err != nil {
		return nil
	}
	return &t
}

func humanizePeriod(raw string) string {
	upper := strings.ToUpper(raw)
	for _, period := range []string{"WEEKLY", "MONTHLY", "DAILY", "HOURLY"} {
		if strings.Contains(upper, period) {
			return strings.ToLower(period)
		}
	}
	return raw
}

// normalizedPercent is 0...1. creditUsagePercent is a percentage point: 1 means 1% used, so a
// value at or below 1 is not a fraction.
func (r billingResponse) normalizedPercent() *float64 {
	if r.creditUsagePercent == nil {
		return nil
	}
	value := math.Min(1, math.Max(0, *r.creditUsagePercent/100))
	return &value
}

func (r billingResponse) isEmpty() bool {
	return r.quota() == nil && r.normalizedPercent() == nil && r.billingPeriodEnd == nil
}

type billingError struct {
	kind   string
	status int
}

func (e billingError) Error() string { return fmt.Sprintf("grok billing: %s %d", e.kind, e.status) }

var (
	errNoCredentials = billingError{kind: "no credentials"}
	errEmptyPayload  = billingError{kind: "empty payload"}
	errDecodeFailed  = billingError{kind: "decode failed"}
)

func unauthorized(status int) billingError { return billingError{"unauthorized", status} }

func endpointFailed(status int) billingError { return billingError{"endpoint failed", status} }

func isAuthError(err error) bool {
	var be billingError
	return errors.As(err, &be) && (be.kind == "unauthorized" || be == errNoCredentials)
}
