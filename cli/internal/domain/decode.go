package domain

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strconv"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
)

// Decoders mirror Swift's synthesized Codable: a missing or mistyped required key fails the
// whole value, and null or a missing optional key is nil. They operate on a generic tree so
// the two Date encodings (ISO 8601 in day files, reference-date seconds in today.json) and
// Decimal's exact number text stay explicit.

// ReferenceDateOffset is seconds from the Unix epoch to Foundation's reference date.
const ReferenceDateOffset = 978307200

// ParseJSON parses into a tree whose numbers keep their exact text.
func ParseJSON(data []byte) (any, error) {
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	var v any
	if err := d.Decode(&v); err != nil {
		return nil, err
	}
	if d.More() {
		return nil, errors.New("trailing data")
	}
	return v, nil
}

type reader struct {
	m   map[string]any
	err error
}

func newReader(v any) *reader {
	m, ok := v.(map[string]any)
	if !ok {
		return &reader{err: errors.New("expected object")}
	}
	return &reader{m: m}
}

func (r *reader) fail(key string) {
	if r.err == nil {
		r.err = fmt.Errorf("key %q missing or mistyped", key)
	}
}

// has returns the value unless it is absent or null.
func (r *reader) has(key string) (any, bool) {
	if r.err != nil {
		return nil, false
	}
	v, ok := r.m[key]
	if !ok || v == nil {
		return nil, false
	}
	return v, true
}

func (r *reader) reqString(key string) string {
	v, ok := r.has(key)
	if !ok {
		r.fail(key)
		return ""
	}
	s, ok := v.(string)
	if !ok {
		r.fail(key)
	}
	return s
}

func (r *reader) optString(key string) *string {
	v, ok := r.has(key)
	if !ok {
		return nil
	}
	s, ok := v.(string)
	if !ok {
		r.fail(key)
		return nil
	}
	return &s
}

func (r *reader) reqBool(key string) bool {
	v, ok := r.has(key)
	if !ok {
		r.fail(key)
		return false
	}
	b, ok := v.(bool)
	if !ok {
		r.fail(key)
	}
	return b
}

func numberInt(v any) (int, bool) {
	n, ok := v.(json.Number)
	if !ok {
		return 0, false
	}
	if i, err := strconv.ParseInt(n.String(), 10, 64); err == nil {
		return int(i), true
	}
	f, err := n.Float64()
	if err != nil || f != math.Trunc(f) || math.Abs(f) > 1<<53 {
		return 0, false
	}
	return int(f), true
}

func (r *reader) reqInt(key string) int {
	v, ok := r.has(key)
	if !ok {
		r.fail(key)
		return 0
	}
	i, ok := numberInt(v)
	if !ok {
		r.fail(key)
	}
	return i
}

func (r *reader) optInt(key string) *int {
	v, ok := r.has(key)
	if !ok {
		return nil
	}
	i, ok := numberInt(v)
	if !ok {
		r.fail(key)
		return nil
	}
	return &i
}

func numberFloat(v any) (float64, bool) {
	n, ok := v.(json.Number)
	if !ok {
		return 0, false
	}
	f, err := n.Float64()
	return f, err == nil
}

func (r *reader) reqDouble(key string) float64 {
	v, ok := r.has(key)
	if !ok {
		r.fail(key)
		return 0
	}
	f, ok := numberFloat(v)
	if !ok {
		r.fail(key)
	}
	return f
}

func (r *reader) optDouble(key string) *float64 {
	v, ok := r.has(key)
	if !ok {
		return nil
	}
	f, ok := numberFloat(v)
	if !ok {
		r.fail(key)
		return nil
	}
	return &f
}

func numberDecimal(v any) (decimal.Decimal, bool) {
	n, ok := v.(json.Number)
	if !ok {
		return decimal.Decimal{}, false
	}
	return decimal.Parse(n.String())
}

func (r *reader) reqDecimal(key string) decimal.Decimal {
	v, ok := r.has(key)
	if !ok {
		r.fail(key)
		return decimal.Decimal{}
	}
	d, ok := numberDecimal(v)
	if !ok {
		r.fail(key)
	}
	return d
}

func (r *reader) optDecimal(key string) *decimal.Decimal {
	v, ok := r.has(key)
	if !ok {
		return nil
	}
	d, ok := numberDecimal(v)
	if !ok {
		r.fail(key)
		return nil
	}
	return &d
}

func (r *reader) reqArray(key string) []any {
	v, ok := r.has(key)
	if !ok {
		r.fail(key)
		return nil
	}
	a, ok := v.([]any)
	if !ok {
		r.fail(key)
		return nil
	}
	return a
}

func (r *reader) optArray(key string) ([]any, bool) {
	v, ok := r.has(key)
	if !ok {
		return nil, false
	}
	a, ok := v.([]any)
	if !ok {
		r.fail(key)
		return nil, false
	}
	return a, true
}

func (r *reader) optObject(key string) (any, bool) {
	v, ok := r.has(key)
	if !ok {
		return nil, false
	}
	if _, ok := v.(map[string]any); !ok {
		r.fail(key)
		return nil, false
	}
	return v, true
}

func (r *reader) reqStringMap(key string) map[string]string {
	v, ok := r.has(key)
	if !ok {
		r.fail(key)
		return nil
	}
	m, ok := v.(map[string]any)
	if !ok {
		r.fail(key)
		return nil
	}
	out := make(map[string]string, len(m))
	for k, x := range m {
		s, ok := x.(string)
		if !ok {
			r.fail(key)
			return nil
		}
		out[k] = s
	}
	return out
}

// RefDate is Foundation's default Date encoding: seconds since 2001-01-01 as a double.
func RefDate(seconds float64) time.Time {
	whole := math.Floor(seconds)
	nanos := (seconds - whole) * 1e9
	return time.Unix(int64(whole)+ReferenceDateOffset, int64(nanos)).UTC()
}

// RefSeconds is the inverse of RefDate.
func RefSeconds(t time.Time) float64 {
	return float64(t.Unix()-ReferenceDateOffset) + float64(t.Nanosecond())/1e9
}

func (r *reader) reqRefDate(key string) time.Time {
	return RefDate(r.reqDouble(key))
}

func (r *reader) optRefDate(key string) *time.Time {
	f := r.optDouble(key)
	if f == nil {
		return nil
	}
	t := RefDate(*f)
	return &t
}

func parseISO(v any) (time.Time, bool) {
	s, ok := v.(string)
	if !ok {
		return time.Time{}, false
	}
	t, err := time.Parse(time.RFC3339Nano, s)
	return t.UTC(), err == nil
}

func (r *reader) reqISODate(key string) time.Time {
	v, ok := r.has(key)
	if !ok {
		r.fail(key)
		return time.Time{}
	}
	t, ok := parseISO(v)
	if !ok {
		r.fail(key)
	}
	return t
}

func (r *reader) optISODate(key string) *time.Time {
	v, ok := r.has(key)
	if !ok {
		return nil
	}
	t, ok := parseISO(v)
	if !ok {
		r.fail(key)
		return nil
	}
	return &t
}

// --- today.json values ---

func decodeQuota(v any) (Quota, error) {
	r := newReader(v)
	q := Quota{Used: r.reqDouble("used"), Limit: r.reqDouble("limit"), Remaining: r.reqDouble("remaining")}
	return q, r.err
}

func (r *reader) optQuota(key string) *Quota {
	v, ok := r.optObject(key)
	if !ok {
		return nil
	}
	q, err := decodeQuota(v)
	if err != nil {
		r.fail(key)
		return nil
	}
	return &q
}

func (r *reader) optWindows(key string) []QuotaWindow {
	items, ok := r.optArray(key)
	if !ok {
		return nil
	}
	out := make([]QuotaWindow, 0, len(items))
	for _, item := range items {
		w := newReader(item)
		out = append(out, QuotaWindow{
			Name:        w.reqString("name"),
			Utilization: w.optDouble("utilization"),
			ResetsAt:    w.optRefDate("resetsAt"),
			Duration:    w.optDouble("duration"),
		})
		if w.err != nil {
			r.fail(key)
			return nil
		}
	}
	return out
}

func decodeSnapshot(v any) (UsageSnapshot, error) {
	r := newReader(v)
	s := UsageSnapshot{
		ProviderID:   ProviderID(r.reqString("providerID")),
		AsOf:         r.reqRefDate("asOf"),
		TokensToday:  r.optInt("tokensToday"),
		CostTodayUSD: r.optDecimal("costTodayUSD"),
		BalanceUSD:   r.optDecimal("balanceUSD"),
		Quota:        r.optQuota("quota"),
		Raw:          r.reqStringMap("raw"),
		QuotaWindows: r.optWindows("quotaWindows"),
	}
	if items, ok := r.optArray("accounts"); ok {
		s.Accounts = make([]AccountUsage, 0, len(items))
		for _, item := range items {
			a := newReader(item)
			s.Accounts = append(s.Accounts, AccountUsage{
				Name:         a.reqString("name"),
				CostTodayUSD: a.optDecimal("costTodayUSD"),
				TokensToday:  a.optInt("tokensToday"),
				Quota:        a.optQuota("quota"),
				QuotaWindows: a.optWindows("quotaWindows"),
			})
			if a.err != nil {
				return s, a.err
			}
		}
	}
	if v, ok := r.optObject("periodSpendUSD"); ok {
		p := newReader(v)
		s.PeriodSpendUSD = &PeriodSpend{Day: p.reqDecimal("day"), Week: p.reqDecimal("week"), Month: p.reqDecimal("month")}
		if p.err != nil {
			return s, p.err
		}
	}
	return s, r.err
}

func decodeProviderError(v any) (ProviderError, error) {
	r := newReader(v)
	kind := r.reqString("kind")
	msg := r.reqString("message")
	if r.err != nil {
		return ProviderError{}, r.err
	}
	if !validProviderErrorKind(kind) {
		return ProviderError{}, fmt.Errorf("unknown error kind %q", kind)
	}
	return ProviderError{ProviderErrorKind(kind), msg}, nil
}

// decodeStatus reads Swift's enum form: {"ok":{"lastSuccess":…}}, {"unauthenticated":{}},
// {"error":{"_0":{…}}}, {"stale":{"lastSuccess":…,"error":{…}}}.
func decodeStatus(v any) (ProviderStatus, error) {
	m, ok := v.(map[string]any)
	if !ok || len(m) != 1 {
		return ProviderStatus{}, errors.New("status must have one case")
	}
	for name, body := range m {
		r := newReader(body)
		switch StatusKind(name) {
		case StatusOK:
			return OK(r.reqRefDate("lastSuccess")), r.err
		case StatusStale:
			last := r.reqRefDate("lastSuccess")
			e, ok := r.has("error")
			if !ok {
				return ProviderStatus{}, errors.New("stale without error")
			}
			pe, err := decodeProviderError(e)
			if err != nil {
				return ProviderStatus{}, err
			}
			return Stale(last, pe), r.err
		case StatusUnauthenticated:
			return Unauthenticated(), r.err
		case StatusNotRunning:
			return NotRunning(), r.err
		case StatusDisabled:
			return Disabled(), r.err
		case StatusError:
			e, ok := r.has("_0")
			if !ok {
				return ProviderStatus{}, errors.New("error without payload")
			}
			pe, err := decodeProviderError(e)
			if err != nil {
				return ProviderStatus{}, err
			}
			return Errored(pe), nil
		}
		return ProviderStatus{}, fmt.Errorf("unknown status %q", name)
	}
	return ProviderStatus{}, errors.New("unreachable")
}

// DecodeProviderState reads one state from today.json.
func DecodeProviderState(v any) (ProviderState, error) {
	r := newReader(v)
	s := ProviderState{
		ID:                 ProviderID(r.reqString("id")),
		DisplayName:        r.reqString("displayName"),
		PlaceholderMessage: r.optString("placeholderMessage"),
		LastSuccess:        r.optRefDate("lastSuccess"),
	}
	if r.err != nil {
		return s, r.err
	}
	st, ok := r.has("status")
	if !ok {
		return s, errors.New("state without status")
	}
	status, err := decodeStatus(st)
	if err != nil {
		return s, err
	}
	s.Status = status
	if sv, ok := r.has("snapshot"); ok {
		snap, err := decodeSnapshot(sv)
		if err != nil {
			return s, err
		}
		s.Snapshot = &snap
	}
	return s, nil
}

// DecodeBaseline reads one baseline from today.json.
func DecodeBaseline(v any) (BaselineRecord, error) {
	r := newReader(v)
	b := BaselineRecord{
		Value: r.reqDouble("value"), Date: r.reqString("date"), LastValue: r.reqDouble("lastValue"),
		LastUpdated: r.reqRefDate("lastUpdated"),
	}
	return b, r.err
}

// DecodeTranscriptOffset reads one cursor from today.json.
func DecodeTranscriptOffset(v any) (TranscriptOffset, error) {
	r := newReader(v)
	o := TranscriptOffset{URL: r.reqString("url"), LastModified: r.reqRefDate("lastModified")}
	offset := r.reqInt("byteOffset")
	if offset < 0 {
		return o, errors.New("negative byte offset")
	}
	o.ByteOffset = uint64(offset)
	return o, r.err
}

// DecodeDailyUsage reads one running total from today.json. SessionTokens is absent in caches
// written before it existed.
func DecodeDailyUsage(v any) (DailyUsageRecord, error) {
	r := newReader(v)
	d := DailyUsageRecord{Date: r.reqString("date"), Tokens: r.reqInt("tokens"), CostUSD: r.reqDecimal("costUSD"), SessionTokens: map[string]int{}}
	if sv, ok := r.optObject("sessionTokens"); ok {
		for k, x := range sv.(map[string]any) {
			n, ok := numberInt(x)
			if !ok {
				return d, errors.New("session tokens must be integers")
			}
			d.SessionTokens[k] = n
		}
	}
	return d, r.err
}

// --- day files ---

func decodeQuotaDays(r *reader, key string) map[string]QuotaDay {
	v, ok := r.has(key)
	if !ok {
		r.fail(key)
		return nil
	}
	m, ok := v.(map[string]any)
	if !ok {
		r.fail(key)
		return nil
	}
	out := make(map[string]QuotaDay, len(m))
	for name, item := range m {
		d := newReader(item)
		out[name] = QuotaDay{Peak: d.reqDouble("peak"), PeakResetsAt: d.optISODate("peakResetsAt"), EndOfDay: d.reqDouble("endOfDay")}
		if d.err != nil {
			r.fail(key)
			return nil
		}
	}
	return out
}

func (r *reader) optMoney(key string) *Money {
	v, ok := r.has(key)
	if !ok {
		return nil
	}
	s, ok := v.(string)
	if !ok {
		r.fail(key)
		return nil
	}
	d, ok := decimal.Parse(s)
	if !ok {
		r.fail(key)
		return nil
	}
	m := NewMoney(d)
	return &m
}

func validBilling(s string) bool {
	return s == string(BillingMetered) || s == string(BillingSubscription) || s == string(BillingLocal)
}

func decodeDayAccount(v any) (DayAccount, error) {
	r := newReader(v)
	a := DayAccount{
		Key:                 r.reqString("key"),
		Label:               r.reqString("label"),
		BillingModel:        BillingModel(r.reqString("billingModel")),
		Plan:                r.optString("plan"),
		BillingModelAssumed: r.reqBool("billingModelAssumed"),
		CostUSD:             r.optMoney("costUSD"),
		Tokens:              r.optInt("tokens"),
	}
	a.Quota = decodeQuotaDays(r, "quota")
	if r.err == nil && !validBilling(string(a.BillingModel)) {
		return a, fmt.Errorf("unknown billing model %q", a.BillingModel)
	}
	return a, r.err
}

func decodeDayRecord(v any) (DayRecord, error) {
	r := newReader(v)
	rec := DayRecord{
		Provider:      ProviderID(r.reqString("provider")),
		TimeZone:      r.optString("timeZone"),
		Tokens:        r.optInt("tokens"),
		CostUSD:       r.optMoney("costUSD"),
		CostEstimated: r.reqBool("costEstimated"),
		BalanceUSD:    r.optMoney("balanceUSD"),
		Origin:        RecordOrigin(r.reqString("origin")),
		FirstSeen:     r.optISODate("firstSeen"),
		LastSeen:      r.optISODate("lastSeen"),
	}
	rec.Quota = decodeQuotaDays(r, "quota")
	for _, item := range r.reqArray("accounts") {
		a, err := decodeDayAccount(item)
		if err != nil {
			return rec, err
		}
		rec.Accounts = append(rec.Accounts, a)
	}
	if r.err == nil && rec.Origin != OriginObserved && rec.Origin != OriginBackfilled {
		return rec, fmt.Errorf("unknown origin %q", rec.Origin)
	}
	return rec, r.err
}

func decodeUsageEvent(v any) (UsageEvent, error) {
	r := newReader(v)
	e := UsageEvent{
		Time:        r.reqISODate("time"),
		Kind:        UsageEventKind(r.reqString("kind")),
		Window:      r.optString("window"),
		Account:     r.optString("account"),
		Fraction:    r.reqDouble("fraction"),
		Notified:    r.reqBool("notified"),
		CarriedOver: r.reqBool("carriedOver"),
	}
	if p := r.optString("provider"); p != nil {
		id := ProviderID(*p)
		e.Provider = &id
	}
	if _, known := EventLabels[e.Kind]; r.err == nil && !known {
		return e, fmt.Errorf("unknown event kind %q", e.Kind)
	}
	return e, r.err
}

// DayFileResult is the outcome of reading a day file's bytes.
type DayFileResult struct {
	File *DayFile
	// UnsupportedSchema is set for a schemaVersion this build cannot read.
	UnsupportedSchema *int
}

// DecodeDayFile reads a day file. Malformed JSON or a bad field gives an empty result.
func DecodeDayFile(data []byte) DayFileResult {
	tree, err := ParseJSON(data)
	if err != nil {
		return DayFileResult{}
	}
	r := newReader(tree)
	version := r.reqInt("schemaVersion")
	if r.err != nil {
		return DayFileResult{}
	}
	if version != CurrentDayFileSchema {
		return DayFileResult{UnsupportedSchema: &version}
	}
	day := DayFile{SchemaVersion: version, Date: r.reqString("date"), TimeZone: r.reqString("timeZone")}
	for _, item := range r.reqArray("records") {
		rec, err := decodeDayRecord(item)
		if err != nil {
			return DayFileResult{}
		}
		day.Records = append(day.Records, rec)
	}
	for _, item := range r.reqArray("events") {
		ev, err := decodeUsageEvent(item)
		if err != nil {
			return DayFileResult{}
		}
		day.Events = append(day.Events, ev)
	}
	for _, item := range r.reqArray("backfillChecked") {
		s, ok := item.(string)
		if !ok {
			return DayFileResult{}
		}
		day.BackfillChecked = append(day.BackfillChecked, ProviderID(s))
	}
	if r.err != nil {
		return DayFileResult{}
	}
	return DayFileResult{File: &day}
}
