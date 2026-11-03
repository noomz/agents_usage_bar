package claude

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
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
	}{
		{"file wins over keychain and env", &good, keychain, nil, map[string]string{envTokenKey: "e"}, "file-token"},
		{"mcpOAuth shape", ref(`{"mcpOAuth":{"accessToken":"mcp-token"}}`), nil, errors.New("none"), nil, "mcp-token"},
		{"missing file falls to keychain", nil, keychain, nil, nil, "keychain-token"},
		{"invalid json falls to keychain", ref(`{broken`), keychain, nil, nil, "keychain-token"},
		{"missing access token falls to keychain", ref(`{"claudeAiOauth":{"refreshToken":"r"}}`), keychain, nil, nil, "keychain-token"},
		{"empty access token falls to keychain", ref(`{"claudeAiOauth":{"accessToken":""}}`), keychain, nil, nil, "keychain-token"},
		{"keychain failure falls to env", nil, nil, errors.New("exit 51"), map[string]string{envTokenKey: "env-token"}, "env-token"},
		{"undecodable keychain falls to env", nil, []byte("nope"), nil, map[string]string{envTokenKey: "env-token"}, "env-token"},
		{"empty env is nothing", nil, nil, errors.New("none"), map[string]string{envTokenKey: ""}, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := loaderWith(t, c.file, c.keychain, c.keychainErr, c.env).load()
			if c.wantToken == "" {
				if got != nil {
					t.Fatal("want no credential")
				}
				return
			}
			if got == nil || got.AccessToken.Reveal() != c.wantToken {
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
		if token == nil || token.ExpiresAtMs == nil {
			t.Errorf("%s: %+v", name, token)
		}
	}
}

func TestTokenExpiry(t *testing.T) {
	ms := func(d time.Duration) *float64 {
		v := float64(testNow.Add(d).UnixMilli())
		return &v
	}
	cases := []struct {
		name    string
		expires *float64
		want    bool
	}{
		{"unknown expiry", nil, false},
		{"a minute left", ms(time.Minute), false},
		{"exactly now", ms(0), true},
		{"expired", ms(-time.Hour), true},
	}
	for _, c := range cases {
		if got := (oauthToken{ExpiresAtMs: c.expires}).expired(testNow); got != c.want {
			t.Errorf("%s: got %v", c.name, got)
		}
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

	t.Run("no credentials", func(t *testing.T) {
		http := &scriptedHTTP{}
		if _, err := oauthFor(t, nil, nil, nil, http).getUsage(t.Context()); !errors.Is(err, errNoCredentials) {
			t.Fatal(err)
		}
		if len(http.calls) != 0 {
			t.Fatal("no request without a credential")
		}
	})

	t.Run("fresh token sends the headers", func(t *testing.T) {
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

	t.Run("expired file token makes no request", func(t *testing.T) {
		file := body(past)
		http := &scriptedHTTP{}
		if _, err := oauthFor(t, &file, nil, nil, http).getUsage(t.Context()); !errors.Is(err, errTokenExpired) {
			t.Fatalf("err %v", err)
		}
		if len(http.calls) != 0 {
			t.Fatalf("%+v", http.calls)
		}
	})

	t.Run("expired keychain token makes no request and writes nothing", func(t *testing.T) {
		http := &scriptedHTTP{}
		c := oauthFor(t, nil, []byte(body(past)), nil, http)
		if _, err := c.getUsage(t.Context()); !errors.Is(err, errTokenExpired) {
			t.Fatalf("err %v", err)
		}
		if len(http.calls) != 0 {
			t.Fatalf("%+v", http.calls)
		}
		if _, err := os.Stat(c.creds.path); !os.IsNotExist(err) {
			t.Fatal("a Keychain token must never create the file")
		}
	})

	t.Run("a token with a minute left still reads usage", func(t *testing.T) {
		file := body(float64(testNow.Add(time.Minute).UnixMilli()))
		http := &scriptedHTTP{gets: []any{usage}}
		if _, err := oauthFor(t, &file, nil, nil, http).getUsage(t.Context()); err != nil {
			t.Fatal(err)
		}
		if len(http.calls) != 1 || http.calls[0].method != "GET" {
			t.Fatalf("%+v", http.calls)
		}
	})

	t.Run("a token with no stated expiry still reads usage", func(t *testing.T) {
		file := `{"claudeAiOauth":{"accessToken":"a","refreshToken":"r"}}`
		http := &scriptedHTTP{gets: []any{usage}}
		if _, err := oauthFor(t, &file, nil, nil, http).getUsage(t.Context()); err != nil {
			t.Fatal(err)
		}
	})

	t.Run("env token reads usage", func(t *testing.T) {
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
