package ollamacloud

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/config"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/paths"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/providers/httpscript"
	"github.com/noomz/agents_usage_bar/cli/internal/secret"
)

const (
	usageKey = "GET /api/usage"
	meKey    = "POST /api/me"
	usageOK  = `{"activity":{"cost":"1.23456","models":[],"period":{"type":"last_4_weeks"}},"limits":{"monthly":{"usage":0.25,"models":[]},"weekly":{"usage":0.9}}}`
	meOK     = `{"ID":"00000000-0000-0000-0000-000000000000","Name":"example-user","Email":"user@example.com","Plan":"pro"}`
)

var testNow = time.Unix(1_790_000_000, 0)

func keyed(value string, source config.CredentialSource) config.OllamaCloud {
	s := secret.New(value)
	return config.OllamaCloud{Enabled: true, APIKey: &s, APIKeySource: source}
}

func noDevice() *signer { return nil }

func fixed(cfg config.OllamaCloud) func() config.OllamaCloud {
	return func() config.OllamaCloud { return cfg }
}

func happy() *httpscript.Client {
	return httpscript.New().Script(usageKey, httpscript.JSON(usageOK)).Script(meKey, httpscript.JSON(meOK))
}

func TestMapping(t *testing.T) {
	p := newProvider(happy(), fixed(keyed("fake-env", config.SourceEnv)), noDevice, time.UTC)
	snap, err := p.Fetch(context.Background(), testNow)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"plan": "pro", "ownSpendLast4WeeksUSD": "1.23456", "credentialSource": "env"}
	if !reflect.DeepEqual(snap.Raw, want) {
		t.Errorf("raw %v", snap.Raw)
	}
	if len(snap.QuotaWindows) != 1 {
		t.Fatalf("windows %+v", snap.QuotaWindows)
	}
	w := snap.QuotaWindows[0]
	if w.Name != "mo" || *w.Utilization != 0.25 || w.Duration != nil || w.ResetsAt != nil {
		t.Errorf("window %+v", w)
	}
	if *snap.Quota != (domain.Quota{Used: 0.25, Limit: 1, Remaining: 0.75}) {
		t.Errorf("quota %+v", snap.Quota)
	}
	if snap.CostTodayUSD != nil || snap.TokensToday != nil || p.Status().Kind != domain.StatusOK {
		t.Errorf("snapshot %+v status %+v", snap, p.Status())
	}
}

func TestClampsUtilization(t *testing.T) {
	for _, tc := range []struct{ raw, want float64 }{{1.4, 1}, {-0.2, 0}, {0, 0}, {1, 1}} {
		http := httpscript.New().Script(usageKey, httpscript.JSON(fmt.Sprintf(`{"limits":{"monthly":{"usage":%v}}}`, tc.raw)))
		snap, err := newProvider(http, fixed(keyed("k", config.SourceEnv)), noDevice, time.UTC).Fetch(context.Background(), testNow)
		if err != nil || *snap.QuotaWindows[0].Utilization != tc.want {
			t.Errorf("%v: %+v %v", tc.raw, snap.QuotaWindows, err)
		}
	}
}

func TestMissingMonthlyIsEmptyButOK(t *testing.T) {
	for _, body := range []string{`{}`, `{"limits":{}}`, `{"limits":{"monthly":{}}}`, `{"surprise":[1,2]}`} {
		http := httpscript.New().Script(usageKey, httpscript.JSON(body))
		p := newProvider(http, fixed(keyed("k", config.SourceEnv)), noDevice, time.UTC)
		snap, err := p.Fetch(context.Background(), testNow)
		if err != nil || snap.QuotaWindows != nil || snap.Quota != nil || p.Status().Kind != domain.StatusOK {
			t.Errorf("%s: %+v %v", body, snap, err)
		}
	}
}

func TestCostParsing(t *testing.T) {
	for _, tc := range []struct{ cost, want string }{{"1.23456", "1.23456"}, {"0.00000", "0"}, {"n/a", ""}, {"1.5abc", ""}, {"", ""}} {
		http := httpscript.New().Script(usageKey, httpscript.JSON(fmt.Sprintf(`{"activity":{"cost":%q},"limits":{"monthly":{"usage":0.5}}}`, tc.cost)))
		snap, err := newProvider(http, fixed(keyed("k", config.SourceEnv)), noDevice, time.UTC).Fetch(context.Background(), testNow)
		if err != nil || snap.Raw["ownSpendLast4WeeksUSD"] != tc.want {
			t.Errorf("%q: %v %v", tc.cost, snap.Raw, err)
		}
	}
}

func TestBillingDaySetsReset(t *testing.T) {
	cfg := keyed("k", config.SourceEnv)
	day := 15
	cfg.BillingDay = &day
	snap, err := newProvider(happy(), fixed(cfg), noDevice, time.UTC).Fetch(context.Background(), testNow)
	if err != nil || snap.QuotaWindows[0].ResetsAt == nil {
		t.Errorf("%+v %v", snap.QuotaWindows, err)
	}
}

func TestAPIKeyTransport(t *testing.T) {
	http := happy()
	if _, err := newProvider(http, fixed(keyed("fake-env", config.SourceEnv)), noDevice, time.UTC).Fetch(context.Background(), testNow); err != nil {
		t.Fatal(err)
	}
	calls := http.Calls()
	if len(calls) != 2 || calls[0].Method != "GET" || calls[0].URL != "https://ollama.com/api/usage" || calls[1].Method != "POST" || calls[1].URL != "https://ollama.com/api/me" {
		t.Fatalf("calls %+v", calls)
	}
	for _, c := range calls {
		if c.Bearer != "fake-env" || c.Headers != nil {
			t.Errorf("call %+v", c)
		}
	}
}

func TestDeviceSignsBothEndpoints(t *testing.T) {
	http := happy()
	s := fixedSigner(t)
	snap, err := newProvider(http, fixed(config.OllamaCloud{}), func() *signer { return s }, time.UTC).Fetch(context.Background(), testNow)
	if err != nil {
		t.Fatal(err)
	}
	public := ed25519.NewKeyFromSeed(fixedSeed).Public().(ed25519.PublicKey)
	want := []struct{ url, challenge string }{
		{"https://ollama.com/api/usage?ts=1790000000", "GET,/api/usage?ts=1790000000"},
		{"https://ollama.com/api/me?ts=1790000000", "POST,/api/me?ts=1790000000"},
	}
	calls := http.Calls()
	for i, w := range want {
		if calls[i].URL != w.url || calls[i].Bearer != "" {
			t.Errorf("call %+v", calls[i])
		}
		field, sig, _ := strings.Cut(calls[i].Headers["Authorization"], ":")
		raw, _ := base64.StdEncoding.DecodeString(sig)
		if field != fixedPublicKeyField || !ed25519.Verify(public, []byte(w.challenge), raw) {
			t.Errorf("%s: bad signature", w.url)
		}
	}
	if snap.Raw["credentialSource"] != "device" {
		t.Errorf("raw %v", snap.Raw)
	}
}

func TestFailures(t *testing.T) {
	s := fixedSigner(t)
	for _, tc := range []struct {
		name   string
		cfg    config.OllamaCloud
		device *signer
		reply  httpscript.Reply
		kind   domain.ProviderErrorKind
		msg    string
	}{
		{"env 401", keyed("k", config.SourceEnv), nil, httpscript.Status(401), domain.ErrAuth, "check OLLAMA_API_KEY"},
		{"env 403", keyed("k", config.SourceEnv), nil, httpscript.Status(403), domain.ErrAuth, "check OLLAMA_API_KEY"},
		{"config 401", keyed("k", config.SourceConfig), nil, httpscript.Status(401), domain.ErrAuth, "check [ollama] api_key"},
		{"config 403", keyed("k", config.SourceConfig), nil, httpscript.Status(403), domain.ErrAuth, "check [ollama] api_key"},
		{"device 401", config.OllamaCloud{}, s, httpscript.Status(401), domain.ErrAuth, "run ollama signin"},
		{"explicit key never falls back to the device", keyed("k", config.SourceEnv), s, httpscript.Status(401), domain.ErrAuth, "check OLLAMA_API_KEY"},
		{"502", keyed("k", config.SourceEnv), nil, httpscript.Status(502), domain.ErrHTTP, "HTTP 502"},
		{"not json", keyed("k", config.SourceEnv), nil, httpscript.JSON("not json"), domain.ErrDecode, ""},
		{"mistyped usage", keyed("k", config.SourceEnv), nil, httpscript.JSON(`{"limits":{"monthly":{"usage":"x"}}}`), domain.ErrDecode, ""},
		{"transport", keyed("k", config.SourceEnv), nil, httpscript.Fail(domain.NetworkError{Code: domain.NetworkTimedOut, Err: errors.New("x")}), domain.ErrNetwork, ""},
	} {
		http := httpscript.New().Script(usageKey, tc.reply).Script(meKey, httpscript.JSON(meOK))
		p := newProvider(http, fixed(tc.cfg), func() *signer { return tc.device }, time.UTC)
		_, err := p.Fetch(context.Background(), testNow)
		pe := domain.ProviderErrorFrom(err)
		if err == nil || pe.Kind != tc.kind || (tc.msg != "" && pe.Message != tc.msg) {
			t.Errorf("%s: %v", tc.name, err)
		}
		if s := p.Status(); s.Kind != domain.StatusError || s.Err.Kind != tc.kind {
			t.Errorf("%s: status %+v", tc.name, s)
		}
		if http.Count(meKey) != 0 {
			t.Errorf("%s: /api/me after a failed usage call", tc.name)
		}
	}
}

func TestNoCredentialAtFetch(t *testing.T) {
	http := httpscript.New()
	p := newProvider(http, fixed(config.OllamaCloud{}), noDevice, time.UTC)
	_, err := p.Fetch(context.Background(), testNow)
	if pe := domain.ProviderErrorFrom(err); pe.Kind != domain.ErrAuth || pe.Message != noCredential {
		t.Errorf("%v", err)
	}
	if len(http.Calls()) != 0 {
		t.Errorf("calls %+v", http.Calls())
	}
}

func fetchTwice(t *testing.T, p *Provider) (domain.UsageSnapshot, domain.UsageSnapshot) {
	t.Helper()
	first, err := p.Fetch(context.Background(), testNow)
	if err != nil {
		t.Fatal(err)
	}
	second, err := p.Fetch(context.Background(), testNow)
	if err != nil {
		t.Fatal(err)
	}
	return first, second
}

func TestPlanLifetime(t *testing.T) {
	cfg := keyed("k", config.SourceEnv)
	t.Run("fetched once", func(t *testing.T) {
		http := happy()
		_, second := fetchTwice(t, newProvider(http, fixed(cfg), noDevice, time.UTC))
		if http.Count(usageKey) != 2 || http.Count(meKey) != 1 || second.Raw["plan"] != "pro" {
			t.Errorf("%d %d %v", http.Count(usageKey), http.Count(meKey), second.Raw)
		}
	})
	t.Run("failure omitted then retried", func(t *testing.T) {
		http := httpscript.New().Script(usageKey, httpscript.JSON(usageOK)).Script(meKey, httpscript.Status(500), httpscript.JSON(meOK))
		first, second := fetchTwice(t, newProvider(http, fixed(cfg), noDevice, time.UTC))
		if _, has := first.Raw["plan"]; has || *first.QuotaWindows[0].Utilization != 0.25 {
			t.Errorf("first %+v", first)
		}
		if second.Raw["plan"] != "pro" || http.Count(meKey) != 2 {
			t.Errorf("second %v", second.Raw)
		}
	})
	t.Run("2xx without Plan is not posted again", func(t *testing.T) {
		http := httpscript.New().Script(usageKey, httpscript.JSON(usageOK)).Script(meKey, httpscript.JSON(`{"Email":"user@example.com"}`))
		_, second := fetchTwice(t, newProvider(http, fixed(cfg), noDevice, time.UTC))
		if _, has := second.Raw["plan"]; has || http.Count(meKey) != 1 {
			t.Errorf("%v %d", second.Raw, http.Count(meKey))
		}
	})
	t.Run("empty Plan is absent", func(t *testing.T) {
		http := httpscript.New().Script(usageKey, httpscript.JSON(usageOK)).Script(meKey, httpscript.JSON(`{"Plan":""}`))
		first, _ := fetchTwice(t, newProvider(http, fixed(cfg), noDevice, time.UTC))
		if _, has := first.Raw["plan"]; has {
			t.Errorf("%v", first.Raw)
		}
	})
	t.Run("personal fields never surface", func(t *testing.T) {
		snap, _ := fetchTwice(t, newProvider(happy(), fixed(cfg), noDevice, time.UTC))
		surfaced := fmt.Sprint(snap.Raw)
		for _, secret := range []string{"example-user", "user@example.com", "00000000-0000"} {
			if strings.Contains(surfaced, secret) {
				t.Errorf("%s surfaced", secret)
			}
		}
	})
}

func TestChangedCredentialAppliesNextPoll(t *testing.T) {
	t.Run("fixed key recovers and re-reads billing day", func(t *testing.T) {
		cfg := keyed("fake-bad", config.SourceConfig)
		http := httpscript.New().Script(usageKey, httpscript.Status(401), httpscript.JSON(usageOK)).Script(meKey, httpscript.JSON(meOK))
		p := newProvider(http, func() config.OllamaCloud { return cfg }, noDevice, time.UTC)
		if _, err := p.Fetch(context.Background(), testNow); err == nil {
			t.Fatal("expected a rejection")
		}
		day := 3
		cfg = keyed("fake-good", config.SourceConfig)
		cfg.BillingDay = &day
		snap, err := p.Fetch(context.Background(), testNow)
		if err != nil {
			t.Fatal(err)
		}
		var bearers []string
		for _, c := range http.Calls() {
			if c.Path == "/api/usage" {
				bearers = append(bearers, c.Bearer)
			}
		}
		if !reflect.DeepEqual(bearers, []string{"fake-bad", "fake-good"}) || p.Status().Kind != domain.StatusOK {
			t.Errorf("%v %+v", bearers, p.Status())
		}
		if snap.QuotaWindows[0].ResetsAt == nil || snap.Raw["plan"] != "pro" {
			t.Errorf("%+v", snap)
		}
	})
	t.Run("source change fetches the plan again", func(t *testing.T) {
		cfg := keyed("fake-env", config.SourceEnv)
		s := fixedSigner(t)
		http := happy()
		p := newProvider(http, func() config.OllamaCloud { return cfg }, func() *signer { return s }, time.UTC)
		fetchTwice(t, p)
		if http.Count(meKey) != 1 {
			t.Fatalf("%d", http.Count(meKey))
		}
		cfg = config.OllamaCloud{}
		snap, err := p.Fetch(context.Background(), testNow)
		if err != nil || http.Count(meKey) != 2 || snap.Raw["credentialSource"] != "device" {
			t.Errorf("%v %d %v", err, http.Count(meKey), snap.Raw)
		}
	})
	t.Run("key swap in the same source fetches the plan again", func(t *testing.T) {
		cfg := keyed("fake-a", config.SourceConfig)
		http := httpscript.New().Script(usageKey, httpscript.JSON(usageOK)).Script(meKey, httpscript.JSON(meOK), httpscript.JSON(`{"Plan":"max"}`))
		p := newProvider(http, func() config.OllamaCloud { return cfg }, noDevice, time.UTC)
		fetchTwice(t, p)
		cfg = keyed("fake-b", config.SourceConfig)
		snap, err := p.Fetch(context.Background(), testNow)
		if err != nil || snap.Raw["plan"] != "max" {
			t.Errorf("%v %v", err, snap.Raw)
		}
	})
}

func TestNextReset(t *testing.T) {
	bangkok, err := time.LoadLocation("Asia/Bangkok")
	if err != nil {
		t.Fatal(err)
	}
	newYork, err := time.LoadLocation("America/New_York")
	if err != nil {
		t.Fatal(err)
	}
	at := func(loc *time.Location, y int, m time.Month, d, h int) time.Time {
		return time.Date(y, m, d, h, 0, 0, 0, loc)
	}
	for _, tc := range []struct {
		name string
		day  int
		now  time.Time
		want time.Time
	}{
		{"later this month", 15, at(bangkok, 2026, 9, 10, 9), at(bangkok, 2026, 9, 15, 0)},
		{"rolls to next month", 15, at(bangkok, 2026, 9, 28, 13), at(bangkok, 2026, 10, 15, 0)},
		{"exactly at the reset is next month", 15, at(bangkok, 2026, 9, 15, 0), at(bangkok, 2026, 10, 15, 0)},
		{"clamps to February", 31, at(bangkok, 2027, 2, 10, 0), at(bangkok, 2027, 2, 28, 0)},
		{"after the clamp, next month's full day", 31, at(bangkok, 2027, 2, 28, 1), at(bangkok, 2027, 3, 31, 0)},
		{"leap year", 30, at(bangkok, 2028, 2, 1, 0), at(bangkok, 2028, 2, 29, 0)},
		{"year rollover", 5, at(bangkok, 2026, 12, 20, 0), at(bangkok, 2027, 1, 5, 0)},
		{"local midnight after DST ends", 5, at(newYork, 2026, 10, 20, 0), at(newYork, 2026, 11, 5, 0)},
		{"local midnight after DST starts", 15, at(newYork, 2027, 3, 1, 0), at(newYork, 2027, 3, 15, 0)},
	} {
		day := tc.day
		got := nextReset(&day, tc.now, tc.now.Location())
		if got == nil || !got.Equal(tc.want) {
			t.Errorf("%s: %v want %v", tc.name, got, tc.want)
		}
	}
	for _, day := range []int{0, 32, -1} {
		if got := nextReset(&day, testNow, bangkok); got != nil {
			t.Errorf("day %d: %v", day, got)
		}
	}
	if got := nextReset(nil, testNow, bangkok); got != nil {
		t.Errorf("unset: %v", got)
	}
}

func TestResolve(t *testing.T) {
	loaded := false
	c := resolve(keyed("k", config.SourceConfig), func() *signer { loaded = true; return nil })
	if c == nil || c.sourceKey() != "config" || loaded {
		t.Errorf("%v loaded=%v", c, loaded)
	}
	s := fixedSigner(t)
	if c := resolve(config.OllamaCloud{}, func() *signer { return s }); c == nil || c.sourceKey() != "device" {
		t.Errorf("%v", c)
	}
	if c := resolve(config.OllamaCloud{}, noDevice); c != nil {
		t.Errorf("%v", c)
	}
}

func buildEnv(t *testing.T, home string, getenv map[string]string) provider.Env {
	t.Helper()
	layout := paths.For("linux", home, func(string) string { return "" })
	return provider.Env{
		Config: config.Defaults(), HTTP: httpscript.New(), Paths: layout,
		Getenv: func(k string) string { return getenv[k] },
	}
}

func TestBuild(t *testing.T) {
	empty := buildEnv(t, t.TempDir(), nil)
	if p := Build(empty); p != nil {
		t.Errorf("no credential built %v", p)
	}

	keyedEnv := buildEnv(t, t.TempDir(), map[string]string{"OLLAMA_API_KEY": "fake-env"})
	keyedEnv.Config.OllamaCloud = keyed("fake-env", config.SourceEnv)
	if p := Build(keyedEnv); p == nil || p.ID() != domain.OllamaCloud || p.DisplayName() != "Ollama Cloud" {
		t.Errorf("keyed: %v", p)
	}

	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, ".ollama"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(deviceKeyPath(home), []byte(encodeKey(fixedSeed, keyOptions{})), 0o600); err != nil {
		t.Fatal(err)
	}
	http := httpscript.New().Script(usageKey, httpscript.JSON(usageOK)).Script(meKey, httpscript.JSON(meOK))
	deviceEnv := buildEnv(t, home, nil)
	deviceEnv.HTTP = http
	p := Build(deviceEnv)
	if p == nil {
		t.Fatal("device key did not register")
	}
	snap, err := p.Fetch(context.Background(), testNow)
	if err != nil || snap.Raw["credentialSource"] != "device" {
		t.Errorf("%v %v", err, snap.Raw)
	}
	if want := (domain.Capabilities{HasQuota: true}); p.Capabilities() != want {
		t.Errorf("caps %+v", p.Capabilities())
	}
}

func TestBuildReadsConfigFilePerFetch(t *testing.T) {
	home := t.TempDir()
	env := buildEnv(t, home, nil)
	env.Config.OllamaCloud = keyed("fake-toml", config.SourceConfig)
	http := httpscript.New().Script(usageKey, httpscript.JSON(usageOK)).Script(meKey, httpscript.JSON(meOK))
	env.HTTP = http
	if err := os.MkdirAll(env.Paths.ConfigDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(env.Paths.ConfigFile(), []byte("[ollama]\napi_key = \"fake-toml\"\nbilling_day = 7\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	snap, err := Build(env).Fetch(context.Background(), testNow)
	if err != nil {
		t.Fatal(err)
	}
	if snap.Raw["credentialSource"] != "config" || snap.QuotaWindows[0].ResetsAt == nil || http.Calls()[0].Bearer != "fake-toml" {
		t.Errorf("%+v", snap)
	}
}
