package grok

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/cache"
	"github.com/noomz/agents_usage_bar/cli/internal/clock"
	"github.com/noomz/agents_usage_bar/cli/internal/config"
	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/paths"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/secret"
)

const fixtures = "../../../../AgentsUsageBarTests/ProvidersGrokTests/Fixtures/"

var testNow = time.Unix(1_787_000_000, 0).UTC()

type getCall struct {
	url, bearer string
	headers     map[string]string
}

// fakeHTTP answers by bearer: a string decodes as the body, an error is returned.
type fakeHTTP struct {
	byBearer map[string]any
	post     any
	gets     []getCall
	postBody any
}

func (f *fakeHTTP) answer(answer any, out any) error {
	switch a := answer.(type) {
	case error:
		return a
	case string:
		if err := json.Unmarshal([]byte(a), out); err != nil {
			return domain.DecodeError{Err: err}
		}
		return nil
	}
	return domain.HTTPError{Status: 599}
}

func (f *fakeHTTP) GetJSON(_ context.Context, rawURL string, bearer *secret.Secret, headers map[string]string, out any) error {
	f.gets = append(f.gets, getCall{rawURL, bearer.Reveal(), headers})
	return f.answer(f.byBearer[bearer.Reveal()], out)
}

func (f *fakeHTTP) PostJSON(_ context.Context, _ string, body any, _ *secret.Secret, _ map[string]string, out any) error {
	f.postBody = body
	return f.answer(f.post, out)
}

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func testEnv(home string, http *fakeHTTP, env map[string]string) provider.Env {
	base, _ := url.Parse("https://cli-chat-proxy.grok.com/v1")
	return provider.Env{
		Config:  config.App{Grok: config.Grok{Enabled: true, APIURL: base}},
		HTTP:    http,
		Cache:   cache.Noop{},
		Clock:   clock.Fixed(testNow),
		DayKeys: domain.NewDayKeyOwner(clock.Fixed(testNow), time.UTC),
		Paths:   paths.For("linux", home, func(string) string { return "" }),
		Getenv:  func(key string) string { return env[key] },
	}
}

func decodeFixture(t *testing.T, name string) billingResponse {
	t.Helper()
	raw, err := os.ReadFile(fixtures + name + ".json")
	if err != nil {
		t.Fatal(err)
	}
	var response billingResponse
	if err := json.Unmarshal(raw, &response); err != nil {
		t.Fatal(err)
	}
	return response
}

func TestDecodeBillingFixtures(t *testing.T) {
	credits := decodeFixture(t, "billing-credits")
	if *credits.creditUsagePercent != 42.5 || *credits.monthlyLimit != 1000 || *credits.includedUsed != 425 ||
		*credits.prepaidBalance != 12.5 || *credits.subscriptionTier != "supergrok" || credits.billingPeriodEnd == nil {
		t.Fatalf("credits %+v", credits)
	}
	nested := decodeFixture(t, "billing-nested-data")
	if *nested.monthlyLimit != 500 || *nested.includedUsed != 400 || *nested.creditUsagePercent != 80 || *nested.subscriptionTier != "supergrok_plus" {
		t.Fatalf("nested %+v", nested)
	}
	weekly := decodeFixture(t, "billing-config-weekly")
	if *weekly.creditUsagePercent != 24 || *weekly.periodLabel != "weekly" || *weekly.productLabel != "GrokBuild" ||
		*weekly.prepaidBalance != 0 || weekly.billingPeriodEnd == nil || *weekly.normalizedPercent() != 0.24 {
		t.Fatalf("weekly %+v", weekly)
	}
	if q := weekly.quota(); q.Used != 24 || q.Limit != 100 {
		t.Fatalf("weekly quota %+v", q)
	}
	zero := decodeFixture(t, "billing-monthly-zero")
	if *zero.monthlyLimit != 0 || *zero.includedUsed != 0 || zero.quota() != nil || zero.billingPeriodEnd == nil {
		t.Fatalf("zero stub %+v", zero)
	}
}

func TestDecodeBillingShapes(t *testing.T) {
	var onePercent billingResponse
	body := `{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY"},"creditUsagePercent":1.0,"productUsage":[{"product":"GrokBuild","usagePercent":1.0}]}}`
	if err := json.Unmarshal([]byte(body), &onePercent); err != nil {
		t.Fatal(err)
	}
	if *onePercent.normalizedPercent() != 0.01 {
		t.Fatalf("1 on the wire is 1%%: %v", *onePercent.normalizedPercent())
	}

	var unknown billingResponse
	if err := json.Unmarshal([]byte(`{"monthlyLimit":10,"brandNewField":{"x":1}}`), &unknown); err != nil || *unknown.monthlyLimit != 10 {
		t.Fatalf("%v %+v", err, unknown)
	}

	// A wrong-typed field rejects the typed envelope, and the flexible reader still finds the rest.
	var wrongType billingResponse
	if err := json.Unmarshal([]byte(`{"config":{"creditUsagePercent":"7","isUnifiedBillingUser":"yes","subscription_tier":"x"}}`), &wrongType); err != nil {
		t.Fatal(err)
	}
	if *wrongType.creditUsagePercent != 7 || *wrongType.subscriptionTier != "x" {
		t.Fatalf("%+v", wrongType)
	}

	var bad billingResponse
	if json.Unmarshal([]byte(`[1]`), &bad) == nil {
		t.Fatal("a non-object must fail decode")
	}
}

func TestQuota(t *testing.T) {
	f := func(v float64) *float64 { return &v }
	included := billingResponse{creditUsagePercent: f(42.5), monthlyLimit: f(1000), includedUsed: f(425)}
	if q := included.quota(); q.Used != 425 || q.Limit != 1000 || q.Remaining != 575 {
		t.Fatalf("%+v", q)
	}
	percent := billingResponse{creditUsagePercent: f(80)}
	if q := percent.quota(); q.Used != 80 || q.Limit != 100 {
		t.Fatalf("%+v", q)
	}
}

func TestCreditsURL(t *testing.T) {
	cases := map[string]string{
		"https://cli-chat-proxy.grok.com/v1":               defaultCreditsURL,
		"https://cli-chat-proxy.grok.com/v1/":              defaultCreditsURL,
		"https://cli-chat-proxy.grok.com/v1/billing":       defaultCreditsURL,
		"https://proxy.test/v1":                            "https://proxy.test/v1/billing?format=credits",
		"https://proxy.test/v1/billing?format=json&team=a": "https://proxy.test/v1/billing?team=a&format=credits",
	}
	for base, want := range cases {
		parsed, err := url.Parse(base)
		if err != nil {
			t.Fatal(err)
		}
		if got := creditsURL(parsed); got != want {
			t.Errorf("%s: got %s", base, got)
		}
	}
}

func TestLoadCandidates(t *testing.T) {
	session := func(home string) {
		writeFile(t, filepath.Join(home, ".grok", "auth.json"), `{"https://auth.x.ai::c":{"key":"session"}}`)
	}
	pi := func(home string, expires int64) {
		body, _ := json.Marshal(map[string]any{"xai": map[string]any{"type": "oauth", "access": "pi", "refresh": "r", "expires": expires}})
		writeFile(t, filepath.Join(home, ".pi", "agent", "auth.json"), string(body))
	}
	cases := []struct {
		name  string
		setup func(string)
		env   map[string]string
		want  []string
	}{
		{"session wins over env", session, map[string]string{"XAI_API_KEY": "env"}, []string{"session", "env"}},
		{"empty env ignored", session, map[string]string{"XAI_API_KEY": ""}, []string{"session"}},
		{"missing", func(string) {}, nil, nil},
		{"pi after session", func(h string) { session(h); pi(h, 2_000_000_000) }, nil, []string{"session", "pi"}},
		{"expired pi skipped", func(h string) { pi(h, 1) }, nil, nil},
		{"pi expiry in milliseconds", func(h string) { pi(h, 2_000_000_000_000) }, nil, []string{"pi"}},
		{"pi only", func(h string) { pi(h, 2_000_000_000) }, nil, []string{"pi"}},
		{"same key twice", func(h string) { writeFile(t, filepath.Join(h, ".grok", "auth.json"), `{"i":{"key":"same"}}`) }, map[string]string{"XAI_API_KEY": "same"}, []string{"same"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			home := t.TempDir()
			c.setup(home)
			var got []string
			for _, cred := range loadCandidates(testEnv(home, nil, c.env), testNow) {
				got = append(got, cred.token.Reveal())
			}
			if strings.Join(got, ",") != strings.Join(c.want, ",") {
				t.Fatalf("got %v", got)
			}
		})
	}
}

func TestGrokHomeOverrideAndFixture(t *testing.T) {
	home := t.TempDir()
	raw, err := os.ReadFile(fixtures + "auth-session.json")
	if err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(home, "alt", "auth.json"), string(raw))
	got := loadCandidates(testEnv(home, nil, map[string]string{"GROK_HOME": filepath.Join(home, "alt")}), testNow)
	if len(got) != 1 || got[0].source != sourceSession || got[0].token.Reveal() != "session-token-fixture" {
		t.Fatalf("%v", got)
	}
}

func TestBuildNeedsACredential(t *testing.T) {
	home := t.TempDir()
	if p := Build(testEnv(home, &fakeHTTP{}, nil)); p != nil {
		t.Fatalf("no credential must not register: %v", p)
	}
	key, team := secret.New("m"), "team"
	env := testEnv(home, &fakeHTTP{}, nil)
	env.Config.Grok.ManagementKey, env.Config.Grok.TeamID = &key, &team
	if p := Build(env); p == nil {
		t.Fatal("a management key registers the row")
	}
	writeFile(t, filepath.Join(home, ".grok", "auth.json"), `{"i":{"key":"k"}}`)
	if p := Build(testEnv(home, &fakeHTTP{}, nil)); p == nil {
		t.Fatal("a session registers the row")
	}
}

const weeklyBody = `{"config":{"creditUsagePercent":5.0,"isUnifiedBillingUser":true,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-11-05T11:08:00Z"}}}`

func TestSession401ThenPiOAuth(t *testing.T) {
	home := t.TempDir()
	writeFile(t, filepath.Join(home, ".grok", "auth.json"), `{"i":{"key":"dead"}}`)
	body, _ := json.Marshal(map[string]any{"xai": map[string]any{"type": "oauth", "access": "good", "expires": 2_000_000_000}})
	writeFile(t, filepath.Join(home, ".pi", "agent", "auth.json"), string(body))
	http := &fakeHTTP{byBearer: map[string]any{"dead": domain.HTTPError{Status: 401}, "good": weeklyBody}}
	p := Build(testEnv(home, http, nil))
	snap, err := p.Fetch(context.Background(), testNow)
	if err != nil {
		t.Fatal(err)
	}
	if len(http.gets) != 2 || http.gets[0].headers["x-grok-client-mode"] != "cli" || http.gets[0].headers["X-XAI-Token-Auth"] != "xai-grok-cli" {
		t.Fatalf("session call headers: %+v", http.gets)
	}
	if _, cli := http.gets[1].headers["x-grok-client-mode"]; cli {
		t.Fatal("Pi OAuth must not send CLI headers")
	}
	if http.gets[0].url != defaultCreditsURL {
		t.Fatal(http.gets[0].url)
	}
	if snap.Raw["period"] != "weekly" || len(snap.QuotaWindows) != 1 || snap.QuotaWindows[0].Name != "billing" || snap.QuotaWindows[0].ResetsAt == nil {
		t.Fatalf("%+v", snap)
	}
	if caption, _ := snap.QuotaUsageCaption(); caption != "5% used · weekly" {
		t.Fatal(caption)
	}
	if p.Status().Kind != domain.StatusOK {
		t.Fatalf("%+v", p.Status())
	}
}

func withSession(t *testing.T, http *fakeHTTP, env map[string]string) (provider.Env, string) {
	t.Helper()
	home := t.TempDir()
	writeFile(t, filepath.Join(home, ".grok", "auth.json"), `{"i":{"key":"k"}}`)
	return testEnv(home, http, env), home
}

func TestFetchFailureModes(t *testing.T) {
	cases := []struct {
		name   string
		answer any
		kind   domain.StatusKind
		note   bool
	}{
		{"unauthorized is muted", domain.HTTPError{Status: 401}, domain.StatusUnauthenticated, false},
		{"forbidden is muted", domain.HTTPError{Status: 403}, domain.StatusUnauthenticated, false},
		{"server error degrades", domain.HTTPError{Status: 503}, domain.StatusError, true},
		{"undecodable degrades", `[1]`, domain.StatusError, true},
		{"network degrades", domain.NetworkError{Code: domain.NetworkTimedOut, Err: errors.New("t")}, domain.StatusError, true},
		{"empty payload degrades", `{}`, domain.StatusError, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			env, _ := withSession(t, &fakeHTTP{byBearer: map[string]any{"k": c.answer}}, nil)
			p := Build(env)
			snap, err := p.Fetch(context.Background(), testNow)
			if err != nil {
				t.Fatalf("must not throw: %v", err)
			}
			if snap.Quota != nil || snap.Raw["status"] != "no-data-yet" || p.Status().Kind != c.kind {
				t.Fatalf("%+v %+v", snap, p.Status())
			}
			if _, tagged := snap.Raw["note"]; tagged != c.note {
				t.Fatalf("note %v", snap.Raw)
			}
		})
	}
}

func TestHappyPath(t *testing.T) {
	body := `{"creditUsagePercent":42.5,"monthlyLimit":1000,"includedUsed":425,"prepaidBalance":12.5,"subscriptionTier":"supergrok"}`
	env, _ := withSession(t, &fakeHTTP{byBearer: map[string]any{"k": body}}, nil)
	p := Build(env)
	snap, err := p.Fetch(context.Background(), testNow)
	if err != nil {
		t.Fatal(err)
	}
	if snap.ProviderID != domain.Grok || snap.TokensToday != nil || snap.CostTodayUSD != nil || snap.Quota.Used != 425 || snap.Quota.Limit != 1000 {
		t.Fatalf("%+v", snap)
	}
	if snap.BalanceUSD.String() != "12.5" || snap.Raw["prepaidBalance"] != "12.5" || snap.Raw["subscriptionTier"] != "supergrok" {
		t.Fatalf("%v %v", snap.BalanceUSD, snap.Raw)
	}
	if caption, _ := snap.QuotaUsageCaption(); caption != "43% used" {
		t.Fatal(caption)
	}
	caps := p.Capabilities()
	if !caps.HasTokens || !caps.HasCost || !caps.HasQuota || caps.IsLocal || p.DisplayName() != "Grok" {
		t.Fatalf("%+v", caps)
	}
}

func managementEnv(t *testing.T, http *fakeHTTP) (provider.Env, string) {
	t.Helper()
	env, home := withSession(t, http, map[string]string{"TZ": "Asia/Bangkok"})
	key, team := secret.New("m"), "team-1"
	env.Config.Grok.ManagementKey, env.Config.Grok.TeamID = &key, &team
	return env, home
}

func TestManagementSources(t *testing.T) {
	balance := `{"total":{"val":"-1250"}}`
	spend := `{"timeSeries":[{"dataPoints":[{"values":[0.10,0.05]}]},{"dataPoints":[{"values":[1.25]}]}]}`

	t.Run("empty cli with spend reports management", func(t *testing.T) {
		http := &fakeHTTP{byBearer: map[string]any{"k": `{}`, "m": balance}, post: spend}
		env, _ := managementEnv(t, http)
		p := Build(env)
		snap, err := p.Fetch(context.Background(), testNow)
		if err != nil {
			t.Fatal(err)
		}
		if snap.Quota != nil || snap.BalanceUSD.String() != "12.5" || snap.Raw["source"] != "management" || p.Status().Kind != domain.StatusOK {
			t.Fatalf("%+v %v", snap, p.Status())
		}
		if snap.CostTodayUSD.Cmp(decimal.MustParse("1.40")) != 0 {
			t.Fatalf("spend %s", snap.CostTodayUSD)
		}
		sent, _ := json.Marshal(http.postBody)
		for _, want := range []string{
			`"analytics_request"`, `"time_range"`, `"start_time":"2026-08-17 00:00:00"`, `"end_time":"2026-08-18 00:00:00"`,
			`"timezone":"Asia/Bangkok"`, `"time_unit":"TIME_UNIT_NONE"`, `"group_by":["description"]`, `"filters":[]`,
		} {
			if !strings.Contains(string(sent), want) {
				t.Errorf("request misses %s: %s", want, sent)
			}
		}
	})

	t.Run("cli quota overlays management spend", func(t *testing.T) {
		http := &fakeHTTP{byBearer: map[string]any{"k": `{"creditUsagePercent":41,"currentPeriod":"weekly"}`, "m": `{"total":{"val":"800"}}`}, post: `{"timeSeries":[{"dataPoints":[{"values":[2]}]}]}`}
		env, _ := managementEnv(t, http)
		snap, err := Build(env).Fetch(context.Background(), testNow)
		if err != nil {
			t.Fatal(err)
		}
		if snap.Raw["period"] != "weekly" || snap.Quota == nil || snap.CostTodayUSD.String() != "2" || snap.BalanceUSD.String() != "8" {
			t.Fatalf("%+v", snap)
		}
	})

	t.Run("unsafe team id fails management only", func(t *testing.T) {
		http := &fakeHTTP{byBearer: map[string]any{"k": weeklyBody}}
		env, _ := managementEnv(t, http)
		bad := "../escape"
		env.Config.Grok.TeamID = &bad
		snap, err := Build(env).Fetch(context.Background(), testNow)
		if err != nil || snap.Raw["source"] != "" || snap.Quota == nil {
			t.Fatalf("%v %+v", err, snap)
		}
	})
}

func TestIsSafeTeamID(t *testing.T) {
	for raw, want := range map[string]bool{"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee": true, "": false, "../escape": false, "a/b": false} {
		if isSafeTeamID(raw) != want {
			t.Errorf("%q", raw)
		}
	}
}

func assistantLine(provider string, tokens int, cost string) string {
	return `{"type":"message","timestamp":"` + testNow.Format(time.RFC3339) + `","message":{"role":"assistant","provider":"` + provider + `","model":"m","usage":{"totalTokens":` + strconv.Itoa(tokens) + `,"cost":{"total":` + cost + `}}}}` + "\n"
}

func TestPiJSONL(t *testing.T) {
	session := assistantLine("xai", 1000, "1.25") + assistantLine("openrouter", 500, "9.99") + assistantLine("DRM-SWAP", 33482, "0")
	http := &fakeHTTP{byBearer: map[string]any{"k": `{}`, "m": `{"total":{"val":"0"}}`}, post: `{}`}
	env, home := managementEnv(t, http)
	writeFile(t, filepath.Join(home, ".pi", "agent", "sessions", "s.jsonl"), session)
	snap, err := Build(env).Fetch(context.Background(), testNow)
	if err != nil {
		t.Fatal(err)
	}
	if *snap.TokensToday != 1000 || snap.CostTodayUSD.Cmp(decimal.MustParse("1.25")) != 0 || !snap.BalanceUSD.IsZero() ||
		!strings.Contains(snap.Raw["source"], "pi-jsonl") || snap.Quota != nil {
		t.Fatalf("%+v", snap)
	}
}

type recordingStore struct {
	cache.Noop
	offsets map[string]domain.TranscriptOffset
}

func (s *recordingStore) WithCursors(body func(cache.Cursors))                     { body(s) }
func (s *recordingStore) AllTranscriptOffsets() map[string]domain.TranscriptOffset { return s.offsets }
func (s *recordingStore) SetTranscriptOffsets(o []domain.TranscriptOffset) {
	for _, offset := range o {
		s.offsets[offset.URL] = offset
	}
}

func TestOffsetKeyLeavesPiLocalCursorAlone(t *testing.T) {
	env, home := withSession(t, &fakeHTTP{byBearer: map[string]any{"k": weeklyBody}}, nil)
	path := filepath.Join(home, ".pi", "agent", "sessions", "s.jsonl")
	writeFile(t, path, assistantLine("xai", 10, "0.01"))
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	piKey := "file://" + resolved
	store := &recordingStore{offsets: map[string]domain.TranscriptOffset{piKey: {URL: piKey, ByteOffset: 42, LastModified: testNow}}}
	env.Cache = store
	if _, err := Build(env).Fetch(context.Background(), testNow); err != nil {
		t.Fatal(err)
	}
	if store.offsets[piKey].ByteOffset != 42 {
		t.Fatalf("pi cursor moved: %+v", store.offsets[piKey])
	}
	grokKey := "grok:" + piKey
	if got, ok := store.offsets[grokKey]; !ok || got.ByteOffset == 42 {
		t.Fatalf("grok cursor: %+v", store.offsets)
	}
}

func TestCredentialStructsFormatRedacted(t *testing.T) {
	cred := credential{token: secret.New("fixture-value")}
	client := managementClient{bearer: secret.New("fixture-value")}
	if text := fmt.Sprintf("%v %+v %#v %v %+v %#v", cred, cred, &cred, client, client, &client); strings.Contains(text, "fixture-value") {
		t.Fatal(text)
	}
}
