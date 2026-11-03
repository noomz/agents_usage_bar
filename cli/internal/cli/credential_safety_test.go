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

const (
	claudeTokenRoute = "POST /v1/oauth/token"
	geminiTokenRoute = "POST /token"
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

func tokenServer(t *testing.T, h *harness) *httpscript.Client {
	t.Helper()
	server := httpscript.New()
	reply := `{"access_token":"rotated","refresh_token":"rotated-r","expires_in":3600}`
	server.Script(claudeTokenRoute, httpscript.JSON(reply))
	server.Script(geminiTokenRoute, httpscript.JSON(reply))
	h.Registry = func(env provider.Env) provider.Registry {
		env.HTTP, env.LocalhostHTTP = server, httpscript.Refusing()
		env.Processes = provider.StaticCatalog{}
		return providers.Build(env)
	}
	h.env["GEMINI_CLI_CLIENT_ID"], h.env["GEMINI_CLI_CLIENT_SECRET"] = "id", "secret"
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

func TestNonDarwinNeverSpendsARefreshTokenOrWritesACredential(t *testing.T) {
	for _, goos := range []string{"linux", "freebsd"} {
		for _, args := range [][]string{{}, {"usage", "--live", "--json"}, {"quota", "--live", "--json"}} {
			t.Run(goos+" "+strings.Join(args, " "), func(t *testing.T) {
				h := newHarness(t)
				h.GOOS = goos
				files := seedExpiredLogins(t, h)
				server := tokenServer(t, h)
				if _, errOut, code := h.run(args...); code != 0 || errOut != "" {
					t.Fatalf("code=%d err=%q", code, errOut)
				}
				if n := server.Count(claudeTokenRoute) + server.Count(geminiTokenRoute); n != 0 {
					t.Fatalf("%d refresh calls", n)
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
	tokenServer(t, h)
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

// The control arm: the same setup with the darwin rule does reach the server and rewrite the
// file, so the zero counts above come from the rule and not from a dead fixture.
func TestDarwinKeepsTheAppsRefreshBehavior(t *testing.T) {
	h := newHarness(t)
	h.GOOS = "darwin"
	files := seedExpiredLogins(t, h)
	server := tokenServer(t, h)
	if _, _, code := h.run("usage", "--live", "--json"); code != 0 {
		t.Fatalf("code=%d", code)
	}
	if server.Count(claudeTokenRoute) != 1 || server.Count(geminiTokenRoute) != 1 {
		t.Fatalf("calls %+v", server.Calls())
	}
	if changed := changedFiles(t, files); len(changed) != 1 || changed[0] != ".claude" {
		t.Fatalf("changed %v", changed)
	}
}

func TestRefreshPolicyRule(t *testing.T) {
	var zero provider.RefreshPolicy
	if zero != provider.RefreshForbidden {
		t.Fatal("the zero value must forbid")
	}
	if provider.RefreshPolicyFor("darwin") != provider.RefreshAllowed || provider.RefreshPolicyFor("linux") != provider.RefreshForbidden {
		t.Fatal("rule")
	}
}
