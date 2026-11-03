package claude

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/secret"
)

func loaderWith(t *testing.T, file *string, keychain []byte, keychainErr error, env map[string]string) *credentialLoader {
	t.Helper()
	path := filepath.Join(t.TempDir(), ".credentials.json")
	if file != nil {
		writeFile(t, path, *file)
	}
	return &credentialLoader{
		path: path,
		keychain: func(service string) ([]byte, error) {
			if service != keychainService {
				t.Errorf("service %q", service)
			}
			return keychain, keychainErr
		},
		getenv: func(key string) string { return env[key] },
	}
}

func TestCredentialLoad(t *testing.T) {
	ref := func(s string) *string { return &s }
	good := `{"claudeAiOauth":{"accessToken":"file-token","refreshToken":"r","expiresAt":1778000000000,"subscriptionType":"claude_max"}}`
	keychain := []byte(`{"claudeAiOauth":{"accessToken":"keychain-token"}}`)
	cases := []struct {
		name        string
		file        *string
		keychain    []byte
		keychainErr error
		env         map[string]string
		wantToken   string
		wantSource  credentialSource
	}{
		{"file wins over keychain and env", &good, keychain, nil, map[string]string{envTokenKey: "e"}, "file-token", sourceFile},
		{"mcpOAuth shape", ref(`{"mcpOAuth":{"accessToken":"mcp-token"}}`), nil, errors.New("none"), nil, "mcp-token", sourceFile},
		{"missing file falls to keychain", nil, keychain, nil, nil, "keychain-token", sourceKeychain},
		{"invalid json falls to keychain", ref(`{broken`), keychain, nil, nil, "keychain-token", sourceKeychain},
		{"missing access token falls to keychain", ref(`{"claudeAiOauth":{"refreshToken":"r"}}`), keychain, nil, nil, "keychain-token", sourceKeychain},
		{"empty access token falls to keychain", ref(`{"claudeAiOauth":{"accessToken":""}}`), keychain, nil, nil, "keychain-token", sourceKeychain},
		{"keychain failure falls to env", nil, nil, errors.New("exit 51"), map[string]string{envTokenKey: "env-token"}, "env-token", sourceEnvironment},
		{"undecodable keychain falls to env", nil, []byte("nope"), nil, map[string]string{envTokenKey: "env-token"}, "env-token", sourceEnvironment},
		{"empty env is nothing", nil, nil, errors.New("none"), map[string]string{envTokenKey: ""}, "", 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := loaderWith(t, c.file, c.keychain, c.keychainErr, c.env).load()
			if c.wantToken == "" {
				if got != nil {
					t.Fatalf("want nil, got source %v", got.source)
				}
				return
			}
			if got == nil || got.token.AccessToken.Reveal() != c.wantToken || got.source != c.wantSource {
				t.Fatalf("got %+v", got)
			}
		})
	}
}

func TestLinuxHasNoKeychainAndMissingFileIsNoCredential(t *testing.T) {
	if provider.KeychainFor("linux") != nil {
		t.Fatal("Linux must have no Keychain reader")
	}
	loader := &credentialLoader{path: filepath.Join(t.TempDir(), "missing.json"), getenv: func(string) string { return "" }}
	if loader.load() != nil {
		t.Fatal("missing file with no Keychain must read as no credential")
	}
}

func TestCredentialFixtures(t *testing.T) {
	for _, name := range []string{"credentials-claudeAiOauth-shape.json", "credentials-mcpOAuth-shape.json"} {
		token := decodeOAuthBlob([]byte(fixture(t, name)))
		if token == nil || token.RefreshToken == nil || token.ExpiresAtMs == nil {
			t.Errorf("%s: %+v", name, token)
		}
	}
}

func TestNeedsRefresh(t *testing.T) {
	ms := func(d time.Duration) *float64 {
		v := float64(testNow.Add(d).UnixMilli())
		return &v
	}
	cases := []struct {
		name    string
		expires *float64
		want    bool
	}{
		{"unknown expiry", nil, true},
		{"beyond buffer", ms(10 * time.Minute), false},
		{"within buffer", ms(4 * time.Minute), true},
		{"expired", ms(-time.Hour), true},
	}
	for _, c := range cases {
		if got := needsRefresh(oauthToken{ExpiresAtMs: c.expires}, testNow); got != c.want {
			t.Errorf("%s: got %v", c.name, got)
		}
	}
}

func rotated() oauthToken {
	refresh := secret.New("new-refresh")
	expires := 1234567890000.0
	sub := "claude_max"
	return oauthToken{AccessToken: secret.New("new-access"), RefreshToken: &refresh, ExpiresAtMs: &expires, SubscriptionType: &sub}
}

func TestSaveWritesEnvelopeAndMode(t *testing.T) {
	loader := &credentialLoader{path: filepath.Join(t.TempDir(), ".credentials.json")}
	if err := loader.saveToFile(rotated()); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(loader.path)
	if err != nil {
		t.Fatal(err)
	}
	token := decodeOAuthBlob(data)
	if token == nil || token.AccessToken.Reveal() != "new-access" || token.RefreshToken.Reveal() != "new-refresh" ||
		*token.ExpiresAtMs != 1234567890000.0 || *token.SubscriptionType != "claude_max" {
		t.Fatalf("round trip: %s", data)
	}
	info, _ := os.Stat(loader.path)
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("new file mode %v", info.Mode().Perm())
	}
}

// Swift drops these fields. On Linux the file is Claude Code's only login, so losing `scopes` or
// mcpOAuth would break the login this write exists to preserve.
func TestSavePreservesFieldsClaudeCodeOwns(t *testing.T) {
	original := `{"claudeAiOauth":{"accessToken":"old","refreshToken":"old-r","expiresAt":1,"scopes":["user:inference","user:profile"],"rateLimitTier":"default_max"},"mcpOAuth":{"server|abc":{"accessToken":"keep-me"}},"future":{"x":1}}`
	loader := loaderWith(t, &original, nil, nil, nil)
	if err := os.Chmod(loader.path, 0o640); err != nil {
		t.Fatal(err)
	}
	if err := loader.saveToFile(rotated()); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(loader.path)
	var got struct {
		Oauth struct {
			Access string   `json:"accessToken"`
			Scopes []string `json:"scopes"`
			Tier   string   `json:"rateLimitTier"`
		} `json:"claudeAiOauth"`
		MCP    map[string]map[string]string `json:"mcpOAuth"`
		Future map[string]int               `json:"future"`
	}
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("%v: %s", err, data)
	}
	if got.Oauth.Access != "new-access" || len(got.Oauth.Scopes) != 2 || got.Oauth.Tier != "default_max" ||
		got.MCP["server|abc"]["accessToken"] != "keep-me" || got.Future["x"] != 1 {
		t.Fatalf("lost a field: %s", data)
	}
	info, _ := os.Stat(loader.path)
	if info.Mode().Perm() != 0o640 {
		t.Fatalf("mode changed to %v", info.Mode().Perm())
	}
}

func TestSaveFollowsSymlinkedFile(t *testing.T) {
	dir := t.TempDir()
	real := filepath.Join(dir, "dotfiles", "credentials.json")
	writeFile(t, real, `{"claudeAiOauth":{"accessToken":"old"}}`)
	link := filepath.Join(dir, ".credentials.json")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	loader := &credentialLoader{path: link}
	if err := loader.saveToFile(rotated()); err != nil {
		t.Fatal(err)
	}
	if info, _ := os.Lstat(link); info.Mode()&os.ModeSymlink == 0 {
		t.Fatal("the symlink was replaced, so the real file keeps a revoked refresh token")
	}
	data, _ := os.ReadFile(real)
	if !strings.Contains(string(data), "new-refresh") {
		t.Fatalf("real file not updated: %s", data)
	}
}

func oauthFor(t *testing.T, file *string, keychain []byte, env map[string]string, http *scriptedHTTP) *oauthClient {
	t.Helper()
	keychainErr := error(nil)
	if keychain == nil {
		keychainErr = errors.New("none")
	}
	return &oauthClient{http: http, creds: loaderWith(t, file, keychain, keychainErr, env), now: func() time.Time { return testNow }}
}

func TestOAuthLifecycle(t *testing.T) {
	future := float64(testNow.Add(time.Hour).UnixMilli())
	past := float64(testNow.Add(-time.Hour).UnixMilli())
	body := func(expires float64) string {
		data, _ := json.Marshal(map[string]any{"claudeAiOauth": map[string]any{"accessToken": "old-a", "refreshToken": "old-r", "expiresAt": expires, "subscriptionType": "claude_max", "scopes": []string{"user:inference"}}})
		return string(data)
	}
	usage := fixture(t, "oauth-usage-success.json")
	refresh := fixture(t, "oauth-refresh-success.json")

	t.Run("no credentials", func(t *testing.T) {
		http := &scriptedHTTP{}
		if _, err := oauthFor(t, nil, nil, nil, http).getUsage(t.Context()); !errors.Is(err, errNoCredentials) {
			t.Fatal(err)
		}
		if len(http.calls) != 0 {
			t.Fatal("no request without a credential")
		}
	})

	t.Run("fresh token skips refresh and sends the headers", func(t *testing.T) {
		file := body(future)
		http := &scriptedHTTP{gets: []any{usage}}
		c := oauthFor(t, &file, nil, nil, http)
		got, err := c.getUsage(t.Context())
		if err != nil {
			t.Fatal(err)
		}
		if *got.FiveHour.Utilization != 67.5 || len(http.calls) != 1 {
			t.Fatalf("%+v %+v", got, http.calls)
		}
		call := http.calls[0]
		if call.url != usageURL || call.bearer != "old-a" || call.headers["anthropic-beta"] != oauthBetaHeader || call.headers["User-Agent"] != userAgent {
			t.Fatalf("%+v", call)
		}
		if after, _ := os.ReadFile(c.creds.path); string(after) != file {
			t.Fatal("a fresh token must not rewrite the file")
		}
	})

	t.Run("expired file token rotates and persists before use", func(t *testing.T) {
		file := body(past)
		http := &scriptedHTTP{posts: []any{refresh}, gets: []any{usage}}
		c := oauthFor(t, &file, nil, nil, http)
		if _, err := c.getUsage(t.Context()); err != nil {
			t.Fatal(err)
		}
		if len(http.calls) != 2 || http.calls[0].method != "POST" || http.calls[1].method != "GET" || http.calls[0].url != refreshURL {
			t.Fatalf("%+v", http.calls)
		}
		sent := http.calls[0].body.(refreshBody)
		if sent.GrantType != "refresh_token" || sent.RefreshToken != "old-r" || sent.ClientID != oauthClientID {
			t.Fatalf("%+v", sent)
		}
		wire, _ := json.Marshal(sent)
		for _, key := range []string{`"grant_type"`, `"refresh_token"`, `"client_id"`} {
			if !strings.Contains(string(wire), key) {
				t.Fatalf("wire %s", wire)
			}
		}
		saved, _ := os.ReadFile(c.creds.path)
		token := decodeOAuthBlob(saved)
		var reply refreshResponse
		_ = json.Unmarshal([]byte(refresh), &reply)
		if token.AccessToken.Reveal() != *reply.AccessToken || http.calls[1].bearer != *reply.AccessToken {
			t.Fatal("the rotated access token must be saved and used")
		}
		if token.RefreshToken.Reveal() != *reply.RefreshToken || *token.SubscriptionType != "claude_max" {
			t.Fatalf("saved %s", saved)
		}
		if !strings.Contains(string(saved), "user:inference") {
			t.Fatalf("scopes lost: %s", saved)
		}
		if *token.ExpiresAtMs <= float64(testNow.UnixMilli()) {
			t.Fatal("expiry not advanced")
		}
	})

	t.Run("a reply with no new refresh token keeps the old one", func(t *testing.T) {
		file := body(past)
		http := &scriptedHTTP{posts: []any{`{"access_token":"a2","expires_in":3600}`}, gets: []any{usage}}
		c := oauthFor(t, &file, nil, nil, http)
		if _, err := c.getUsage(t.Context()); err != nil {
			t.Fatal(err)
		}
		saved, _ := os.ReadFile(c.creds.path)
		if decodeOAuthBlob(saved).RefreshToken.Reveal() != "old-r" {
			t.Fatalf("%s", saved)
		}
	})

	failures := []struct {
		name, want string
		answer     any
	}{
		{"invalid client hint", "invalid_client", domain.HTTPError{Status: 400}},
		{"401 hint", "invalid_client", domain.HTTPError{Status: 401}},
		{"server error", "refresh failed", domain.HTTPError{Status: 500}},
		{"network", "refresh failed", domain.NetworkError{Code: domain.NetworkTimedOut, Err: errors.New("t")}},
		{"reply without a token must not be saved", "no access token", `{"expires_in":3600}`},
		{"empty token must not be saved", "no access token", `{"access_token":""}`},
	}
	for _, f := range failures {
		t.Run("failed refresh leaves the file untouched: "+f.name, func(t *testing.T) {
			file := body(past)
			http := &scriptedHTTP{posts: []any{f.answer}}
			c := oauthFor(t, &file, nil, nil, http)
			_, err := c.getUsage(t.Context())
			if err == nil || !strings.Contains(err.Error(), f.want) {
				t.Fatalf("err %v", err)
			}
			if after, _ := os.ReadFile(c.creds.path); string(after) != file {
				t.Fatalf("file changed: %s", after)
			}
			if len(http.calls) != 1 {
				t.Fatalf("must not call usage with a dead token: %+v", http.calls)
			}
		})
	}

	t.Run("keychain token never refreshes and never writes", func(t *testing.T) {
		keychain := []byte(body(past))
		http := &scriptedHTTP{gets: []any{usage}}
		c := oauthFor(t, nil, keychain, nil, http)
		if _, err := c.getUsage(t.Context()); err != nil {
			t.Fatal(err)
		}
		if len(http.calls) != 1 || http.calls[0].method != "GET" {
			t.Fatalf("%+v", http.calls)
		}
		if _, err := os.Stat(c.creds.path); !os.IsNotExist(err) {
			t.Fatal("a Keychain token must never create the file")
		}
	})

	t.Run("env token skips refresh", func(t *testing.T) {
		http := &scriptedHTTP{gets: []any{usage}}
		c := oauthFor(t, nil, nil, map[string]string{envTokenKey: "e"}, http)
		if _, err := c.getUsage(t.Context()); err != nil {
			t.Fatal(err)
		}
		if len(http.calls) != 1 || http.calls[0].bearer != "e" {
			t.Fatalf("%+v", http.calls)
		}
	})

	t.Run("usage endpoint status surfaces", func(t *testing.T) {
		file := body(future)
		for _, status := range []int{429, 500} {
			http := &scriptedHTTP{gets: []any{domain.HTTPError{Status: status}}}
			var got domain.HTTPError
			_, err := oauthFor(t, &file, nil, nil, http).getUsage(t.Context())
			if !errors.As(err, &got) || got.Status != status {
				t.Fatalf("%v", err)
			}
		}
	})
}

func TestResponseDecoding(t *testing.T) {
	var full, partial usageResponse
	if err := json.Unmarshal([]byte(fixture(t, "oauth-usage-success.json")), &full); err != nil {
		t.Fatal(err)
	}
	if full.FiveHour == nil || full.SevenDay == nil || full.FiveHour.ResetsAt == nil || parseResets(full.FiveHour.ResetsAt) == nil {
		t.Fatalf("%+v", full)
	}
	if err := json.Unmarshal([]byte(fixture(t, "oauth-usage-partial.json")), &partial); err != nil {
		t.Fatal(err)
	}
	if partial.FiveHour == nil || partial.SevenDay != nil {
		t.Fatalf("%+v", partial)
	}
	stamp := "2026-05-13T20:00:00.000+00:00"
	if got := parseResets(&stamp); got == nil || !got.Equal(time.Date(2026, 5, 13, 20, 0, 0, 0, time.UTC)) {
		t.Fatalf("%v", got)
	}
}

func TestTokenFormatsRedacted(t *testing.T) {
	if text := fmt.Sprintf("%v %+v", rotated(), rotated()); strings.Contains(text, "new-access") || strings.Contains(text, "new-refresh") {
		t.Fatal(text)
	}
}
