package domain

import (
	"reflect"
	"strconv"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/clock"
	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
)

func fp(v float64) *float64 { return &v }

func TestQuotaFraction(t *testing.T) {
	for _, c := range []struct {
		q    Quota
		want float64
	}{
		{Quota{Used: 5, Limit: 10}, 0.5}, {Quota{Used: 15, Limit: 10}, 1}, {Quota{Used: -1, Limit: 10}, 0},
		{Quota{Used: 5, Limit: 0}, 1}, {Quota{Used: 0, Limit: 0}, 0},
	} {
		if got := c.q.Fraction(); got != c.want {
			t.Errorf("%+v: %v", c.q, got)
		}
	}
}

func TestQuotaBands(t *testing.T) {
	if BandFromRemaining(nil) != BandNone {
		t.Error("nil")
	}
	for _, c := range []struct {
		r    float64
		want QuotaBand
	}{
		{0, BandCritical}, {0.19, BandCritical}, {0.20, BandWarning}, {0.49, BandWarning}, {0.50, BandHealthy},
		{0.99, BandHealthy}, {1, BandHealthy}, {-3, BandCritical}, {3, BandHealthy},
	} {
		if got := BandFromRemaining(fp(c.r)); got != c.want {
			t.Errorf("%v: %v", c.r, got)
		}
	}
}

func TestResetCompact(t *testing.T) {
	now := time.Unix(1000, 0)
	if got := ResetPhrase(now, now); got != "Resets now" {
		t.Error(got)
	}
	if got := ResetPhrase(now.Add(-time.Hour), now); got != "Resets now" {
		t.Error(got)
	}
	for _, c := range []struct {
		s    float64
		want string
	}{
		{59, "<1m"}, {60, "1m"}, {59 * 60, "59m"}, {3600, "1h"}, {2*3600 + 50*60, "2h 50m"},
		{86400, "1d"}, {3*86400 + 8*3600, "3d 8h"}, {86400 + 59*60, "1d"},
	} {
		if got := ResetCompact(c.s); got != c.want {
			t.Errorf("%v: %s", c.s, got)
		}
	}
}

func glanceOf(windows ...GlanceWindow) QuotaGlance { return NewQuotaGlance(windows) }

func TestGlanceSelection(t *testing.T) {
	soon, later := time.Unix(100, 0), time.Unix(200, 0)
	g := glanceOf(GlanceWindow{Period: PeriodFiveHours, Utilization: fp(0.694)}, GlanceWindow{Period: PeriodSevenDays, Utilization: fp(0.695)})
	if g.Active.Period != PeriodSevenDays {
		t.Error("higher raw utilization wins, not the rounded display")
	}
	g = glanceOf(GlanceWindow{Period: PeriodFiveHours, Utilization: fp(0.5), ResetsAt: &later}, GlanceWindow{Period: PeriodSevenDays, Utilization: fp(0.5), ResetsAt: &soon})
	if g.Active.Period != PeriodSevenDays {
		t.Error("a tie takes the sooner reset")
	}
	g = NewQuotaGlance(nil)
	if g.HasAnyWindow() || g.Active != nil || g.Percent(PeriodFiveHours) != "—" {
		t.Errorf("%+v", g)
	}
	a, b := "a", "b"
	s := UsageSnapshot{Accounts: []AccountUsage{
		{Name: a, QuotaWindows: []QuotaWindow{{Name: "5h", Utilization: fp(0.2)}, {Name: "7d-sonnet", Utilization: fp(0.99)}}},
		{Name: b, QuotaWindows: []QuotaWindow{{Name: "5h", Utilization: fp(0.3)}, {Name: "7d", Utilization: fp(0.1)}}},
	}}
	g = s.QuotaGlance()
	if *g.FiveHours.AccountName != "b" || *g.SevenDays.Utilization != 0.1 || *g.Active.AccountName != "b" {
		t.Errorf("%+v", g)
	}
	if !(QuotaWindow{Name: "work 7d"}).IsSevenDay() || (QuotaWindow{Name: "7d-opus"}).IsSevenDay() || !(QuotaWindow{Name: "work 5h"}).IsFiveHour() {
		t.Error("window names")
	}
}

func TestDisplayedQuota(t *testing.T) {
	account := AccountUsage{Name: "w", Quota: &Quota{Used: 0.68, Limit: 1}, QuotaWindows: []QuotaWindow{{Name: "5h", Utilization: fp(0.24)}, {Name: "7d", Utilization: fp(0.68)}}}
	if got := account.DisplayedQuota().Used; got != 0.24 {
		t.Errorf("child bar uses 5h: %v", got)
	}
	s := UsageSnapshot{Accounts: []AccountUsage{account, {Name: "x", QuotaWindows: []QuotaWindow{{Name: "5h", Utilization: fp(0.3)}}}}}
	if got := s.DisplayedQuota().Used; got != 0.3 {
		t.Errorf("%v", got)
	}
	s = UsageSnapshot{Quota: &Quota{Used: 0.9, Limit: 1}, QuotaWindows: []QuotaWindow{{Name: "5h", Utilization: fp(0.1)}}}
	if got := s.DisplayedQuota().Used; got != 0.1 {
		t.Errorf("%v", got)
	}
	s = UsageSnapshot{Quota: &Quota{Used: 0.9, Limit: 1}}
	if got := s.DisplayedQuota().Used; got != 0.9 {
		t.Errorf("%v", got)
	}
}

func TestQuotaUsageCaption(t *testing.T) {
	tokens := 1
	if _, ok := (UsageSnapshot{TokensToday: &tokens, Quota: &Quota{Limit: 1}}).QuotaUsageCaption(); ok {
		t.Error("tokens suppress the caption")
	}
	if got, _ := (UsageSnapshot{Quota: &Quota{Used: 0.5, Limit: 1}, Raw: map[string]string{"period": "May"}}).QuotaUsageCaption(); got != "50% used · May" {
		t.Error(got)
	}
	if got, _ := (UsageSnapshot{Quota: &Quota{Used: 0.5, Limit: 1}}).QuotaUsageCaption(); got != "50% used" {
		t.Error(got)
	}
}

func TestProviderIDs(t *testing.T) {
	want := []ProviderID{"openrouter", "claude", "codex", "gemini", "grok", "pi-local", "ollama", "ollama-cloud", "lmstudio", "lms-llamacpp", "llamacpp"}
	if !reflect.DeepEqual(AllKnown, want) {
		t.Errorf("%v", AllKnown)
	}
	for id, wantLocal := range map[ProviderID]bool{Ollama: true, LMStudio: true, LlamaCpp: true, LMStudioLlamaCpp: true, "engine.x": true, OllamaCloud: false, PiLocal: false, Claude: false} {
		if id.IsLocalRuntime() != wantLocal {
			t.Errorf("%s", id)
		}
	}
	for id, hint := range map[ProviderID]string{Claude: "Claude", PiLocal: "Local Llama", LMStudioLlamaCpp: "LM Studio llama.cpp", "engine.gpu-box": "Gpu Box", "mystery": "Mystery", "engine.a_b": "A_B"} {
		if id.DisplayHint() != hint {
			t.Errorf("%s: %s", id, id.DisplayHint())
		}
	}
	if _, ok := NamedProvider("nope"); ok {
		t.Error("nope")
	}
	if _, ok := NamedProvider("engine."); ok {
		t.Error("bare engine prefix")
	}
	if id, ok := NamedProvider("engine.x"); !ok || id != "engine.x" {
		t.Error("engine.x")
	}
}

func order(items []ProviderID, preference ...ProviderID) []ProviderID {
	return OrderProviders(items, func(id ProviderID) ProviderID { return id }, preference)
}

func TestProviderOrder(t *testing.T) {
	cases := []struct {
		name              string
		items, pref, want []ProviderID
	}{
		{"unset", []ProviderID{"engine.z", Codex, "engine.a", Claude}, nil, []ProviderID{Claude, Codex, "engine.a", "engine.z"}},
		{"listed first", []ProviderID{Claude, Codex, Grok, "engine.a"}, []ProviderID{Grok, "engine.a"}, []ProviderID{Grok, "engine.a", Claude, Codex}},
		{"stale listed ids are skipped", []ProviderID{Claude}, []ProviderID{"gone", Claude}, []ProviderID{Claude}},
		{"mixed-case engine", []ProviderID{Claude, "engine.GPU"}, []ProviderID{"engine.gpu"}, []ProviderID{"engine.GPU", Claude}},
		{"case-only twins are deterministic", []ProviderID{"engine.gpu", "engine.GPU"}, []ProviderID{"engine.gpu"}, []ProviderID{"engine.GPU", "engine.gpu"}},
	}
	for _, c := range cases {
		if got := order(c.items, c.pref...); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: %v", c.name, got)
		}
	}
}

func TestProviderStateTransitions(t *testing.T) {
	now := time.Unix(5000, 0)
	last := time.Unix(1000, 0)
	msg := "hint"
	seed := ProviderState{ID: Ollama, DisplayName: "Ollama", PlaceholderMessage: &msg}

	running := seed.ApplyingSnapshot(UsageSnapshot{Raw: map[string]string{}}, now)
	if running.Status.Kind != StatusOK || running.PlaceholderMessage != nil || !running.LastSuccess.Equal(now) {
		t.Errorf("%+v", running)
	}
	stopped := seed.ApplyingSnapshot(UsageSnapshot{Raw: map[string]string{RawProviderStatus: StatusSentinelNotRunning}}, now)
	if stopped.Status.Kind != StatusNotRunning || stopped.LastSuccess != nil || stopped.PlaceholderMessage != nil || stopped.Snapshot == nil {
		t.Errorf("%+v", stopped)
	}
	unauth := seed.ApplyingSnapshot(UsageSnapshot{Raw: map[string]string{RawProviderStatus: StatusSentinelUnauth}}, now)
	if unauth.Status.Kind != StatusUnauthenticated || unauth.Snapshot != nil || unauth.PlaceholderMessage == nil {
		t.Errorf("%+v", unauth)
	}
	cold := seed.ApplyingError(HTTPError{Status: 500})
	if cold.Status.Kind != StatusError || cold.PlaceholderMessage == nil {
		t.Errorf("%+v", cold)
	}
	warm := ProviderState{ID: Ollama, LastSuccess: &last, Snapshot: &UsageSnapshot{}}.ApplyingError(HTTPError{Status: 500})
	if warm.Status.Kind != StatusStale || warm.Snapshot == nil || !warm.Status.LastSuccess.Equal(last) {
		t.Errorf("%+v", warm)
	}
}

func TestLocalCaption(t *testing.T) {
	msg := "Set port"
	state := func(raw map[string]string, status ProviderStatus) ProviderState {
		return ProviderState{Snapshot: &UsageSnapshot{Raw: raw}, Status: status}
	}
	ok := OK(time.Unix(0, 0))
	cases := []struct {
		s    ProviderState
		want string
	}{
		{ProviderState{PlaceholderMessage: &msg}, "Set port"},
		{state(map[string]string{"loadingModel": "true"}, ok), "Running — loading model…"},
		{ProviderState{Status: NotRunning()}, "Not running"},
		{state(map[string]string{"modelCount": "0", "installedCount": "0"}, ok), "Idle — no models installed"},
		{state(map[string]string{"modelCount": "0"}, ok), "Idle — 0 models loaded"},
		{state(map[string]string{"modelCount": "1", "modelName": "m"}, ok), "m"},
		{state(map[string]string{"modelCount": "1", "modelName": "m", "vramBytes": "3221225472"}, ok), "m · 3.0 GB VRAM"},
		{state(map[string]string{"modelCount": "3", "modelName": "m"}, ok), "m · +2 more"},
		{state(map[string]string{"modelCount": "1"}, ok), "—"},
	}
	for _, c := range cases {
		if got := c.s.LocalSecondaryCaption(); got != c.want {
			t.Errorf("got %s want %s", got, c.want)
		}
	}
}

func money(s string) *Money {
	m := NewMoney(decimal.MustParse(s))
	return &m
}

func account(model BillingModel, cost *Money) DayAccount {
	return DayAccount{Key: string(model), Label: string(model), BillingModel: model, CostUSD: cost}
}

func text(m *Money) string {
	if m == nil {
		return "nil"
	}
	return m.String()
}

func TestCostSplit(t *testing.T) {
	cases := []struct {
		name         string
		record       DayRecord
		spend, value string
	}{
		{"metered", DayRecord{CostUSD: money("3"), Accounts: []DayAccount{account(BillingMetered, nil)}}, "3", "nil"},
		{"subscription is value", DayRecord{CostUSD: money("3"), Accounts: []DayAccount{account(BillingSubscription, nil)}}, "nil", "3"},
		{"accounts split mixed", DayRecord{CostUSD: money("5"), Accounts: []DayAccount{account(BillingMetered, money("2")), account(BillingSubscription, money("3"))}}, "2", "3"},
		{"top-up stays", DayRecord{CostUSD: money("10"), Accounts: []DayAccount{account(BillingSubscription, money("4")), account(BillingSubscription, money("1"))}}, "nil", "10"},
		{"mixed without account cost is unknown", DayRecord{CostUSD: money("5"), Accounts: []DayAccount{account(BillingMetered, nil), account(BillingSubscription, nil)}}, "nil", "nil"},
		{"unknown stays unknown", DayRecord{Accounts: []DayAccount{account(BillingMetered, nil)}}, "nil", "nil"},
		{"local has neither", DayRecord{CostUSD: money("5"), Accounts: []DayAccount{account(BillingLocal, nil)}}, "nil", "nil"},
	}
	for _, c := range cases {
		split := c.record.CostSplit()
		if text(split.Spend) != c.spend || text(split.Value) != c.value {
			t.Errorf("%s: spend %s value %s", c.name, text(split.Spend), text(split.Value))
		}
	}
}

func dayOf(key string, records ...DayRecord) DayFile {
	return DayFile{Date: key, TimeZone: "UTC", Records: records}
}

func meteredRecord(id ProviderID, cost string, estimated bool) DayRecord {
	return DayRecord{Provider: id, CostUSD: money(cost), CostEstimated: estimated, Accounts: []DayAccount{account(BillingMetered, nil)}}
}

func TestMonthSpend(t *testing.T) {
	const today = "2026-10-03"
	or := BudgetScope{Provider: OpenRouter}
	days := []DayFile{
		dayOf("2026-09-30", meteredRecord(OpenRouter, "100", false)),
		dayOf("2026-10-01", meteredRecord(OpenRouter, "1.50", false)),
		dayOf("2026-10-02", meteredRecord(OpenRouter, "2", false)),
		dayOf("2026-10-03", meteredRecord(OpenRouter, "0.25", false)),
	}
	got := MonthSpend(days, today, or)
	if got.Amount == nil || got.Amount.String() != "3.75" || got.Incomplete || got.Estimated {
		t.Errorf("%+v", got)
	}
	got = MonthSpend(days[:2], today, or)
	if !got.Incomplete || got.Amount.String() != "1.5" {
		t.Errorf("a gap marks the month incomplete: %+v", got)
	}
	got = MonthSpend([]DayFile{dayOf("2026-10-01", meteredRecord(OpenRouter, "1", true)), dayOf("2026-10-02", meteredRecord(OpenRouter, "1", false)), dayOf("2026-10-03", meteredRecord(OpenRouter, "1", false))}, today, or)
	if !got.Estimated {
		t.Errorf("%+v", got)
	}
	sub := []DayFile{dayOf("2026-10-03", DayRecord{Provider: Claude, CostUSD: money("9"), Accounts: []DayAccount{account(BillingSubscription, nil)}})}
	if got = MonthSpend(sub, today, BudgetScope{Provider: Claude}); got.Amount != nil {
		t.Errorf("value is never spend: %+v", got)
	}
	mixed := []DayFile{days[1], days[2], dayOf("2026-10-03", meteredRecord(OpenRouter, "0.25", false), sub[0].Records[0])}
	total := MonthSpend(mixed, today, BudgetTotal)
	if total.Amount.String() != "3.75" {
		t.Errorf("%+v", total)
	}
}

func TestMoneyRoundsTo6Places(t *testing.T) {
	for in, want := range map[string]string{"1.2345675": "1.234568", "1.2345665": "1.234567", "-1.2345675": "-1.234568", "0.0000005": "0.000001", "0.0000004": "0", "12.10": "12.1"} {
		if got := money(in).String(); got != want {
			t.Errorf("%s: %s", in, got)
		}
	}
}

func TestDayKeyOwner(t *testing.T) {
	bangkok := time.FixedZone("ICT", 7*3600)
	at := time.Date(2026, 10, 21, 18, 0, 0, 0, time.UTC)
	owner := NewDayKeyOwner(clock.Fixed(at), bangkok)
	if got := owner.Today(); got != "2026-10-22" {
		t.Errorf("local date: %s", got)
	}
	owner.AdvanceNewest("2026-10-25")
	if got := owner.Today(); got != "2026-10-25" {
		t.Errorf("never goes back: %s", got)
	}
	owner.AdvanceNewest("2026-10-01")
	if got := owner.Today(); got != "2026-10-25" {
		t.Errorf("a lower key is ignored: %s", got)
	}
	for _, c := range []struct {
		key  string
		days int
		want string
	}{{"2026-03-01", -1, "2026-02-28"}, {"2024-02-28", 1, "2024-02-29"}, {"2026-12-31", 1, "2027-01-01"}} {
		if got, ok := AddDays(c.key, c.days); !ok || got != c.want {
			t.Errorf("%v: %s", c, got)
		}
	}
	if _, ok := AddDays("nope", 1); ok {
		t.Error("nope")
	}
}

const fullDay = `{
  "schemaVersion": 1, "date": "2026-10-22", "timeZone": "Asia/Bangkok",
  "records": [
    {"provider": "claude", "tokens": 120000, "costUSD": "12.1", "costEstimated": true,
     "quota": {"5h": {"peak": 0.92, "peakResetsAt": "2026-10-22T01:02:03Z", "endOfDay": 0.4}},
     "accounts": [{"key": "work", "label": "work", "billingModel": "subscription", "plan": "max", "billingModelAssumed": false, "costUSD": "5", "quota": {}}],
     "origin": "observed", "firstSeen": "2026-10-22T00:00:00Z", "lastSeen": "2026-10-22T01:00:00Z"},
    {"provider": "ollama", "costEstimated": false, "quota": {}, "accounts": [], "origin": "observed"}
  ],
  "events": [
    {"time": "2026-10-22T00:30:00Z", "provider": "claude", "kind": "band80", "window": "5h", "account": "work", "fraction": 0.81, "notified": true, "carriedOver": false},
    {"time": "2026-10-22T00:40:00Z", "kind": "budgetLimit", "fraction": 1.0, "notified": false, "carriedOver": false}
  ],
  "backfillChecked": ["codex"]
}`

func TestDecodeDayFile(t *testing.T) {
	r := DecodeDayFile([]byte(fullDay))
	if r.File == nil {
		t.Fatal("unreadable")
	}
	d := r.File
	if d.Records[0].CostUSD.String() != "12.1" || d.Records[1].Tokens != nil || d.Records[1].CostUSD != nil {
		t.Errorf("%+v", d.Records)
	}
	if !d.Records[0].Quota["5h"].PeakResetsAt.Equal(time.Date(2026, 10, 22, 1, 2, 3, 0, time.UTC)) {
		t.Error("iso date")
	}
	if d.Events[1].Provider != nil || d.Events[1].Kind != EventBudgetLimit || d.BackfillChecked[0] != Codex {
		t.Errorf("%+v", d.Events)
	}
	for _, v := range []int{0, 2, 99} {
		got := DecodeDayFile([]byte(`{"schemaVersion":` + strconv.Itoa(v) + `}`))
		if got.UnsupportedSchema == nil || *got.UnsupportedSchema != v {
			t.Errorf("schema %d: %+v", v, got)
		}
	}
	for _, bad := range []string{
		"", "not json", "[]", `{"schemaVersion":"1"}`, `{"date":"2026-10-22"}`,
		`{"schemaVersion":1,"date":"2026-10-22","timeZone":"UTC","records":[]}`,
		`{"schemaVersion":1,"date":"2026-10-22","timeZone":"UTC","records":[{"provider":"x"}],"events":[],"backfillChecked":[]}`,
		`{"schemaVersion":1,"date":"2026-10-22","timeZone":"UTC","records":[],"events":[{"time":"nope","kind":"reset","fraction":1,"notified":true,"carriedOver":false}],"backfillChecked":[]}`,
		`{"schemaVersion":1,"date":"2026-10-22","timeZone":"UTC","records":[],"events":[{"time":"2026-10-22T00:00:00Z","kind":"nope","fraction":1,"notified":true,"carriedOver":false}],"backfillChecked":[]}`,
		`{"schemaVersion":1,"date":"2026-10-22","timeZone":"UTC","records":[{"provider":"x","costEstimated":false,"quota":{},"accounts":[],"origin":"observed","costUSD":3}],"events":[],"backfillChecked":[]}`,
	} {
		got := DecodeDayFile([]byte(bad))
		if got.File != nil || got.UnsupportedSchema != nil {
			t.Errorf("%q should be unreadable", bad)
		}
	}
}

func decodeState(t *testing.T, s string) (ProviderState, error) {
	t.Helper()
	tree, err := ParseJSON([]byte(s))
	if err != nil {
		t.Fatal(err)
	}
	return DecodeProviderState(tree)
}

func TestDecodeStatusForms(t *testing.T) {
	cases := []struct {
		status string
		want   StatusKind
		msg    string
	}{
		{`{"ok":{"lastSuccess":100.5}}`, StatusOK, ""},
		{`{"unauthenticated":{}}`, StatusUnauthenticated, ""},
		{`{"notRunning":{}}`, StatusNotRunning, ""},
		{`{"disabled":{}}`, StatusDisabled, ""},
		{`{"error":{"_0":{"kind":"http","message":"HTTP 500"}}}`, StatusError, "HTTP 500"},
		{`{"stale":{"lastSuccess":1,"error":{"kind":"auth","message":"HTTP 401"}}}`, StatusStale, "HTTP 401"},
	}
	for _, c := range cases {
		st, err := decodeState(t, `{"id":"x","displayName":"X","status":`+c.status+`}`)
		if err != nil || st.Status.Kind != c.want || st.Status.Err.Message != c.msg {
			t.Errorf("%s: %+v %v", c.status, st.Status, err)
		}
	}
	for _, bad := range []string{`{"nope":{}}`, `{}`, `{"error":{"_0":{"kind":"nope","message":"m"}}}`} {
		if _, err := decodeState(t, `{"id":"x","displayName":"X","status":`+bad+`}`); err == nil {
			t.Errorf("%s should fail", bad)
		}
	}
}

func TestDecodeSnapshotKeepsExactDecimalAndDates(t *testing.T) {
	st, err := decodeState(t, `{"id":"claude","displayName":"Claude","status":{"unauthenticated":{}},"lastSuccess":0,
	 "snapshot":{"providerID":"claude","asOf":100,"raw":{},"tokensToday":5,"costTodayUSD":273.86034999999999,"quotaWindows":[{"name":"5h","utilization":0.5,"resetsAt":200.25,"duration":18000}],
	 "accounts":[{"name":"a","costTodayUSD":1.5,"tokensToday":3}],"periodSpendUSD":{"day":1,"week":2,"month":3}}}`)
	if err != nil {
		t.Fatal(err)
	}
	s := st.Snapshot
	if s.CostTodayUSD.String() != "273.86034999999999" || *s.Accounts[0].TokensToday != 3 || s.PeriodSpendUSD.Month.String() != "3" {
		t.Errorf("%+v", s)
	}
	want := time.Date(2001, 1, 1, 0, 3, 20, 250_000_000, time.UTC)
	if !s.QuotaWindows[0].ResetsAt.Equal(want) || *s.QuotaWindows[0].Duration != 18000 {
		t.Errorf("%v", s.QuotaWindows[0].ResetsAt)
	}
	if !st.LastSuccess.Equal(time.Date(2001, 1, 1, 0, 0, 0, 0, time.UTC)) {
		t.Error("reference date")
	}
	if _, err := decodeState(t, `{"id":"x","displayName":"X","status":{"disabled":{}},"snapshot":{"asOf":1,"raw":{}}}`); err == nil {
		t.Error("a snapshot without providerID fails")
	}
}

func TestRefDateRoundTrip(t *testing.T) {
	for _, s := range []float64{0, 1.5, 815000000.25, -1.5} {
		if got := RefSeconds(RefDate(s)); got != s {
			t.Errorf("%v: %v", s, got)
		}
	}
}
