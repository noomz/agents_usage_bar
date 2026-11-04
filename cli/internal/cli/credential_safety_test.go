package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/providers"
	"github.com/noomz/agents_usage_bar/cli/internal/providers/httpscript"
)

type credentialFile struct {
	path    string
	content string
	mtime   time.Time
}

// seedExpiredLogins writes every credential file a provider reads, each holding a refresh token
// and an expired access token.
func seedExpiredLogins(t *testing.T, h *harness) []credentialFile {
	t.Helper()
	expiredMs := strconv.FormatInt(h.Clock.Now().Add(-time.Hour).UnixMilli(), 10)
	seeds := map[string]string{
		".claude/.credentials.json": `{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":` + expiredMs + `}}`,
		".gemini/oauth_creds.json":  `{"access_token":"a","refresh_token":"r","expiry_date":` + expiredMs + `}`,
		".gemini/settings.json":     `{"security":{"auth":{"selectedType":"oauth-personal"}}}`,
		".codex/auth.json":          `{"tokens":{"access_token":"a","refresh_token":"r","account_id":"x"}}`,
		".grok/auth.json":           `{"issuer":{"key":"k","refresh_token":"r"}}`,
		".pi/agent/auth.json":       `{"xai":{"type":"oauth","access":"a","refresh":"r","expires":` + expiredMs + `}}`,
	}
	stamp := time.Date(2020, 1, 2, 3, 4, 5, 0, time.UTC)
	files := make([]credentialFile, 0, len(seeds))
	for rel, content := range seeds {
		path := filepath.Join(h.Layout.Home, rel)
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(path, stamp, stamp); err != nil {
			t.Fatal(err)
		}
		files = append(files, credentialFile{path, content, stamp})
	}
	return files
}

func recordingServer(t *testing.T, h *harness) *httpscript.Client {
	t.Helper()
	server := httpscript.New()
	h.Registry = func(env provider.Env) provider.Registry {
		env.HTTP, env.LocalhostHTTP = server, httpscript.Refusing()
		env.Processes = provider.StaticCatalog{}
		return providers.Build(env)
	}
	return server
}

func changedFiles(t *testing.T, files []credentialFile) []string {
	t.Helper()
	var changed []string
	for _, f := range files {
		data, err := os.ReadFile(f.path)
		if err != nil {
			t.Fatal(err)
		}
		info, err := os.Stat(f.path)
		if err != nil {
			t.Fatal(err)
		}
		if string(data) != f.content || !info.ModTime().Equal(f.mtime) {
			changed = append(changed, filepath.Base(filepath.Dir(f.path)))
		}
	}
	return changed
}

func TestNoOSEverSpendsARefreshTokenOrWritesACredential(t *testing.T) {
	t.Cleanup(func() { activeStyle = styleUS })
	for _, goos := range []string{"darwin", "linux", "freebsd"} {
		for _, args := range [][]string{{}, {"usage", "--live", "--json"}, {"quota", "--live", "--json"}} {
			t.Run(goos+" "+strings.Join(args, " "), func(t *testing.T) {
				h := newHarness(t)
				h.GOOS = goos
				files := seedExpiredLogins(t, h)
				server := recordingServer(t, h)
				if _, _, code := h.run(args...); code != 0 {
					t.Fatalf("code=%d", code)
				}
				for _, call := range server.Calls() {
					if strings.Contains(call.Path, "token") {
						t.Fatalf("refresh call: %s %s", call.Method, call.Path)
					}
				}
				if changed := changedFiles(t, files); len(changed) != 0 {
					t.Fatalf("changed %v", changed)
				}
			})
		}
	}
}

func TestDegradedClaudeRowKeepsLocalTokens(t *testing.T) {
	h := newHarness(t)
	seedExpiredLogins(t, h)
	recordingServer(t, h)
	out, _, code := h.run("usage", "claude", "--live", "--json")
	if code != 0 {
		t.Fatalf("code=%d", code)
	}
	var report struct {
		Providers []struct {
			Status      string `json:"status"`
			TokensToday *int   `json:"tokensToday"`
			Quota       any    `json:"quota"`
		} `json:"providers"`
	}
	if err := json.Unmarshal([]byte(out), &report); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if len(report.Providers) != 1 || report.Providers[0].TokensToday == nil || report.Providers[0].Quota != nil {
		t.Fatalf("%s", out)
	}
	if report.Providers[0].Status == "unauthenticated" || report.Providers[0].Status == "error" {
		t.Fatalf("%s", out)
	}
}

func TestUnusableStoreSurvivesEveryLiveCommandAndStillReports(t *testing.T) {
	t.Cleanup(func() { activeStyle = styleUS })
	for _, tc := range []struct {
		name, body string
		corrupt    bool
	}{
		{"newer schema", `{"schemaVersion":4,"providers":[],"baselines":[],"transcripts":{},"dailyUsage":[],"futureSection":{"a":1}}`, false},
		{"truncated", `{"schemaVersion":3,"providers":[],"base`, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body := tc.body
			h := newHarness(t)
			recordingServer(t, h)
			store := h.Layout.CacheFile()
			transcript := filepath.Join(h.Layout.Home, ".claude", "projects", "p", "s.jsonl")
			stamp := h.Clock.Now().UTC().Format(time.RFC3339)
			line := `{"type":"assistant","timestamp":"` + stamp + `","message":{"model":"m","role":"assistant","usage":{"input_tokens":25}}}` + "\n"
			for path, content := range map[string]string{store: body, transcript: line} {
				if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			old := time.Date(2020, 1, 2, 3, 4, 5, 0, time.UTC)
			if err := os.Chtimes(store, old, old); err != nil {
				t.Fatal(err)
			}
			files := []credentialFile{{store, body, old}}
			for _, args := range [][]string{{}, {"usage", "--live"}, {"quota", "--live"}} {
				if _, _, code := h.run(args...); code != 0 {
					t.Fatalf("%v: code=%d", args, code)
				}
				if changed := changedFiles(t, files); !tc.corrupt && len(changed) != 0 {
					t.Fatalf("%v changed the store", args)
				}
			}
			out, _, code := h.run("usage", "claude", "--live", "--json")
			if code != 0 || !strings.Contains(out, `"tokensToday" : 25`) {
				t.Fatalf("code=%d: %s", code, out)
			}
			if tc.corrupt {
				if aside, err := os.ReadFile(store + ".corrupt"); err != nil || string(aside) != body {
					t.Fatalf("original bytes lost: %v", err)
				}
				return
			}
			if changed := changedFiles(t, files); len(changed) != 0 {
				t.Fatal("--json changed the store")
			}
		})
	}
}
