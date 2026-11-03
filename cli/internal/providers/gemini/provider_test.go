package gemini

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/paths"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/secret"
)

const fixtures = "../../../../AgentsUsageBarTests/ProvidersGeminiTests/Fixtures/"

func fixture(t *testing.T, name string) string {
	t.Helper()
	data, err := os.ReadFile(fixtures + name)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

// fakeHTTP plays a queue per URL. A string decodes into out; an error returns as is.
type fakeHTTP struct {
	mu      sync.Mutex
	queue   map[string][]any
	bearers []string
	forms   [][][2]string
	bodies  []string
}

func (f *fakeHTTP) next(rawURL string, out any) error {
	queue := f.queue[rawURL]
	if len(queue) == 0 {
		return fmt.Errorf("unscripted call to %s", rawURL)
	}
	f.queue[rawURL] = queue[1:]
	switch r := queue[0].(type) {
	case error:
		return r
	case string:
		if err := json.Unmarshal([]byte(r), out); err != nil {
			return domain.DecodeError{Err: err}
		}
	}
	return nil
}

func (f *fakeHTTP) GetJSON(context.Context, string, *secret.Secret, map[string]string, any) error {
	return errors.New("unexpected GET")
}

func (f *fakeHTTP) PostJSON(_ context.Context, rawURL string, body any, bearer *secret.Secret, _ map[string]string, out any) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.bearers = append(f.bearers, bearer.Reveal())
	encoded, _ := json.Marshal(body)
	f.bodies = append(f.bodies, string(encoded))
	return f.next(rawURL, out)
}

func (f *fakeHTTP) PostForm(_ context.Context, rawURL string, fields [][2]string, _ map[string]string, out any) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.forms = append(f.forms, fields)
	return f.next(rawURL, out)
}

var testNow = time.Date(2026, 5, 15, 12, 0, 0, 0, time.UTC)

type creds struct {
	access  string
	expires time.Duration
}

func credsJSON(c creds) string {
	return fmt.Sprintf(`{"access_token":%q,"refresh_token":"file-refresh","expiry_date":%d,"token_type":"Bearer"}`, c.access, testNow.Add(c.expires).UnixMilli())
}

func setup(t *testing.T, c creds, clientEnv bool) (provider.Provider, *fakeHTTP, string) {
	t.Helper()
	root := t.TempDir()
	dir := filepath.Join(root, ".gemini")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "settings.json"), []byte(fixture(t, "gemini-settings-fixture.json")), 0o600); err != nil {
		t.Fatal(err)
	}
	credsPath := filepath.Join(dir, "oauth_creds.json")
	if err := os.WriteFile(credsPath, []byte(credsJSON(c)), 0o600); err != nil {
		t.Fatal(err)
	}
	http := &fakeHTTP{queue: map[string][]any{}}
	p := Build(provider.Env{
		HTTP:         http,
		Paths:        paths.Layout{Home: root},
		TokenRefresh: provider.RefreshAllowed,
		Getenv: func(key string) string {
			if clientEnv && strings.HasPrefix(key, "GEMINI_CLI_CLIENT_") {
				return "test-" + key
			}
			return ""
		},
	})
	if p == nil {
		t.Fatal("Build returned nil")
	}
	return p, http, credsPath
}

const refreshed = `{"access_token":"refreshed-access","expires_in":3599,"scope":"s","token_type":"Bearer"}`

func TestBuildGate(t *testing.T) {
	valid := fixture(t, "gemini-oauth-creds-fixture.json")
	cases := []struct {
		name      string
		settings  string
		creds     string
		wantBuilt bool
	}{
		{name: "no ~/.gemini at all, as on Linux"},
		{name: "settings without creds", settings: fixture(t, "gemini-settings-fixture.json")},
		{name: "creds without settings", creds: valid},
		{name: "oauth-personal with creds", settings: fixture(t, "gemini-settings-fixture.json"), creds: valid, wantBuilt: true},
		{name: "other auth", settings: fixture(t, "gemini-settings-other-auth.json"), creds: valid},
		{name: "malformed settings", settings: "{", creds: valid},
		{name: "missing security", settings: `{"other":1}`, creds: valid},
		{name: "missing auth", settings: `{"security":{}}`, creds: valid},
		{name: "non-string type", settings: `{"security":{"auth":{"selectedType":3}}}`, creds: valid},
		{name: "flat keypath does not count", settings: `{"selectedAuthType":"oauth-personal","selectedType":"oauth-personal"}`, creds: valid},
		{name: "wrong case", settings: `{"security":{"auth":{"selectedType":"OAuth-Personal"}}}`, creds: valid},
		{name: "vertex", settings: `{"security":{"auth":{"selectedType":"vertex-ai"}}}`, creds: valid},
		{name: "malformed creds", settings: fixture(t, "gemini-settings-fixture.json"), creds: "{"},
		{name: "creds without refresh token", settings: fixture(t, "gemini-settings-fixture.json"), creds: `{"access_token":"a","expiry_date":1}`},
		{name: "creds without expiry", settings: fixture(t, "gemini-settings-fixture.json"), creds: `{"access_token":"a","refresh_token":"r"}`},
		{name: "creds with mistyped scope", settings: fixture(t, "gemini-settings-fixture.json"), creds: `{"refresh_token":"r","expiry_date":1,"scope":3}`},
		{name: "null access token is usable", settings: fixture(t, "gemini-settings-fixture.json"), creds: `{"access_token":null,"refresh_token":"r","expiry_date":1}`, wantBuilt: true},
		{name: "integer expiry is usable", settings: fixture(t, "gemini-settings-fixture.json"), creds: `{"refresh_token":"r","expiry_date":1778834115287}`, wantBuilt: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			dir := filepath.Join(root, ".gemini")
			if err := os.MkdirAll(dir, 0o755); err != nil {
				t.Fatal(err)
			}
			for name, contents := range map[string]string{"settings.json": tc.settings, "oauth_creds.json": tc.creds} {
				if contents != "" {
					if err := os.WriteFile(filepath.Join(dir, name), []byte(contents), 0o600); err != nil {
						t.Fatal(err)
					}
				}
			}
			p := Build(provider.Env{Paths: paths.Layout{Home: root}, Getenv: func(string) string { return "" }})
			if built := p != nil; built != tc.wantBuilt {
				t.Fatalf("built = %v", built)
			}
		})
	}
}

func TestExpiryIsEpochMilliseconds(t *testing.T) {
	path := filepath.Join(t.TempDir(), "c.json")
	if err := os.WriteFile(path, []byte(fixture(t, "gemini-oauth-creds-fixture.json")), 0o600); err != nil {
		t.Fatal(err)
	}
	c := loadCredentials(path)
	if got := c.expiry.Unix(); got != 1778834115 {
		t.Fatalf("expiry = %d", got)
	}
	if rendered := fmt.Sprintf("%+v %#v %v", c, c, *c); strings.Contains(rendered, "FAKE") {
		t.Fatal("a token leaked through formatting")
	}
}

func TestFetch(t *testing.T) {
	cases := []struct {
		name         string
		creds        creds
		clientEnv    bool
		deleteCreds  bool
		quota        []any
		token        []any
		wantErr      bool
		status       domain.StatusKind
		note         bool
		noData       bool
		bearers      []string
		refreshCalls int
		used         float64
		windows      []string
	}{
		{
			name: "valid file token needs no refresh and no client credentials", creds: creds{"file-access", time.Hour},
			quota:  []any{fixture(t, "gemini-quota-response-fixture.json")},
			status: domain.StatusOK, bearers: []string{"file-access"}, used: 0.15,
			windows: []string{"gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-2.5-pro"},
		},
		{
			name: "multiple buckets keep the lowest remaining per model", creds: creds{"file-access", time.Hour},
			quota:  []any{fixture(t, "gemini-quota-response-multibucket-fixture.json")},
			status: domain.StatusOK, bearers: []string{"file-access"}, used: 0.40, windows: []string{"gemini-2.5-pro"},
		},
		{
			name: "empty response has no quota", creds: creds{"file-access", time.Hour},
			quota:  []any{`{}`},
			status: domain.StatusOK, bearers: []string{"file-access"},
		},
		{
			name: "token inside the skew refreshes in memory", creds: creds{"file-access", 59 * time.Second}, clientEnv: true,
			token: []any{refreshed}, quota: []any{`{"buckets":[{"remainingFraction":0.5,"modelId":"m"}]}`},
			status: domain.StatusOK, bearers: []string{"refreshed-access"}, refreshCalls: 1, used: 0.5, windows: []string{"m"},
		},
		{
			name: "token just past the skew stays", creds: creds{"file-access", 61 * time.Second},
			quota:  []any{`{}`},
			status: domain.StatusOK, bearers: []string{"file-access"},
		},
		{
			name: "empty file token refreshes", creds: creds{"", time.Hour}, clientEnv: true,
			token: []any{refreshed}, quota: []any{`{}`},
			status: domain.StatusOK, bearers: []string{"refreshed-access"}, refreshCalls: 1,
		},
		{
			name: "expired without client credentials throws without touching the network", creds: creds{"file-access", -time.Hour},
			wantErr: true,
		},
		{
			name: "refresh 400 throws", creds: creds{"file-access", -time.Hour}, clientEnv: true,
			token: []any{domain.HTTPError{Status: 400}}, wantErr: true, refreshCalls: 1,
		},
		{
			name: "refresh 401 throws", creds: creds{"file-access", -time.Hour}, clientEnv: true,
			token: []any{domain.HTTPError{Status: 401}}, wantErr: true, refreshCalls: 1,
		},
		{
			name: "refresh transport failure degrades", creds: creds{"file-access", -time.Hour}, clientEnv: true,
			token:  []any{domain.NetworkError{Code: domain.NetworkTimedOut, Err: errors.New("timeout")}},
			status: domain.StatusError, note: true, noData: true, refreshCalls: 1,
		},
		{
			name: "refresh response missing a field degrades", creds: creds{"file-access", -time.Hour}, clientEnv: true,
			token:  []any{`{"token_type":"Bearer"}`},
			status: domain.StatusError, note: true, noData: true, refreshCalls: 1,
		},
		{
			name: "creds gone after registration is muted, not an error", creds: creds{"file-access", time.Hour}, deleteCreds: true,
			status: domain.StatusUnauthenticated, noData: true,
		},
		{
			name: "401 refreshes once even when the file holds the rejected token", creds: creds{"file-access", time.Hour}, clientEnv: true,
			quota: []any{domain.HTTPError{Status: 401}, `{"buckets":[{"remainingFraction":0.75,"modelId":"m"}]}`}, token: []any{refreshed},
			status: domain.StatusOK, bearers: []string{"file-access", "refreshed-access"}, refreshCalls: 1, used: 0.25, windows: []string{"m"},
		},
		{
			name: "second 401 degrades, one retry only", creds: creds{"file-access", time.Hour}, clientEnv: true,
			quota: []any{domain.HTTPError{Status: 401}, domain.HTTPError{Status: 401}}, token: []any{refreshed},
			status: domain.StatusError, note: true, noData: true, bearers: []string{"file-access", "refreshed-access"}, refreshCalls: 1,
		},
		{
			name: "401 with refresh failing throws", creds: creds{"file-access", time.Hour}, clientEnv: true,
			quota: []any{domain.HTTPError{Status: 401}}, token: []any{domain.HTTPError{Status: 400}},
			wantErr: true, bearers: []string{"file-access"}, refreshCalls: 1,
		},
		{
			name: "401 without client credentials throws", creds: creds{"file-access", time.Hour},
			quota:   []any{domain.HTTPError{Status: 401}},
			wantErr: true, bearers: []string{"file-access"},
		},
		{
			name: "5xx never throws", creds: creds{"file-access", time.Hour},
			quota:  []any{domain.HTTPError{Status: 503}},
			status: domain.StatusError, note: true, noData: true, bearers: []string{"file-access"},
		},
		{
			name: "403 is not retried", creds: creds{"file-access", time.Hour},
			quota:  []any{domain.HTTPError{Status: 403}},
			status: domain.StatusError, note: true, noData: true, bearers: []string{"file-access"},
		},
		{
			name: "malformed quota degrades", creds: creds{"file-access", time.Hour},
			quota:  []any{`{"buckets":[{"remainingFraction":"x"}]}`},
			status: domain.StatusError, note: true, noData: true, bearers: []string{"file-access"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			p, http, credsPath := setup(t, tc.creds, tc.clientEnv)
			http.queue[quotaURL] = tc.quota
			http.queue[tokenURL] = tc.token
			if tc.deleteCreds {
				if err := os.Remove(credsPath); err != nil {
					t.Fatal(err)
				}
			}
			var before []byte
			if !tc.deleteCreds {
				before, _ = os.ReadFile(credsPath)
			}
			snap, err := p.Fetch(context.Background(), testNow)
			if !tc.deleteCreds {
				after, _ := os.ReadFile(credsPath)
				if string(before) != string(after) {
					t.Fatal("oauth_creds.json changed")
				}
			}
			if fmt.Sprint(http.bearers) != fmt.Sprint(tc.bearers) {
				t.Fatalf("bearers = %d calls, want %d", len(http.bearers), len(tc.bearers))
			}
			if len(http.forms) != tc.refreshCalls {
				t.Fatalf("refresh calls = %d, want %d", len(http.forms), tc.refreshCalls)
			}
			if tc.wantErr {
				if err == nil {
					t.Fatal("expected error")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if p.Status().Kind != tc.status {
				t.Fatalf("status = %v", p.Status().Kind)
			}
			if tc.note != (snap.Raw["note"] == domain.DegradedNote) {
				t.Fatalf("raw = %v", snap.Raw)
			}
			if snap.TokensToday != nil || snap.CostTodayUSD != nil {
				t.Fatal("Gemini reports neither tokens nor cost")
			}
			if tc.noData {
				if snap.Raw["status"] != "no-data-yet" || snap.Quota != nil || snap.QuotaWindows != nil {
					t.Fatalf("not muted: %+v", snap)
				}
				return
			}
			if snap.Raw["source"] != "v1internal" {
				t.Fatalf("raw = %v", snap.Raw)
			}
			names := []string{}
			for _, w := range snap.QuotaWindows {
				names = append(names, w.Name)
			}
			if fmt.Sprint(names) != fmt.Sprint(append([]string{}, tc.windows...)) {
				t.Fatalf("windows = %v", names)
			}
			if tc.windows == nil {
				if snap.Quota != nil || snap.QuotaWindows != nil {
					t.Fatalf("unexpected quota: %+v", snap)
				}
				return
			}
			if math.Abs(snap.Quota.Fraction()-tc.used) > 1e-9 {
				t.Fatalf("quota = %v", snap.Quota.Fraction())
			}
		})
	}
}

func TestRefreshFormAndQuotaBody(t *testing.T) {
	p, http, _ := setup(t, creds{"", time.Hour}, true)
	http.queue[tokenURL] = []any{refreshed}
	http.queue[quotaURL] = []any{`{}`}
	if _, err := p.Fetch(context.Background(), testNow); err != nil {
		t.Fatal(err)
	}
	want := [][2]string{
		{"client_id", "test-GEMINI_CLI_CLIENT_ID"},
		{"client_secret", "test-GEMINI_CLI_CLIENT_SECRET"},
		{"refresh_token", "file-refresh"},
		{"grant_type", "refresh_token"},
	}
	if fmt.Sprint(http.forms[0]) != fmt.Sprint(want) {
		t.Fatal("wrong refresh form")
	}
	if http.bodies[0] != `{"project":""}` {
		t.Fatalf("quota body = %s", http.bodies[0])
	}
}

func TestClientCredentialsNeedBothVariables(t *testing.T) {
	for _, env := range []map[string]string{
		{},
		{"GEMINI_CLI_CLIENT_ID": "x"},
		{"GEMINI_CLI_CLIENT_SECRET": "x"},
		{"GEMINI_CLI_CLIENT_ID": "x", "GEMINI_CLI_CLIENT_SECRET": ""},
		{"GEMINI_CLI_CLIENT_ID": "", "GEMINI_CLI_CLIENT_SECRET": "x"},
	} {
		p := &Provider{clientID: env["GEMINI_CLI_CLIENT_ID"], clientSecret: env["GEMINI_CLI_CLIENT_SECRET"]}
		_, err := p.refresh(context.Background(), secret.New("r"))
		var oauth oauthError
		if !errors.As(err, &oauth) || oauth.kind != oauthRefreshDisabled {
			t.Fatalf("env %v: err = %v", env, err)
		}
	}
}

func TestResetTime(t *testing.T) {
	cases := []struct {
		reset string
		unix  int64
		ok    bool
	}{
		{"2026-05-16T00:00:00Z", 1778889600, true},
		{"2026-05-16T00:00:00.500Z", 1778889600, true},
		{"not a date", 0, false},
	}
	for _, tc := range cases {
		reset, fraction, model := tc.reset, 0.5, "m"
		w := foldBuckets([]quotaBucket{{RemainingFraction: &fraction, ResetTime: &reset, ModelID: &model}})
		if tc.ok != (w[0].ResetsAt != nil) || (tc.ok && w[0].ResetsAt.Unix() != tc.unix) {
			t.Fatalf("%s: %v", tc.reset, w[0].ResetsAt)
		}
	}
}
