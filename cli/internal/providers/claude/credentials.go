package claude

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/secret"
)

const (
	keychainService = "Claude Code-credentials"
	envTokenKey     = "CLAUDE_CODE_OAUTH_TOKEN"
)

// oauthToken is a decoded token set. ExpiresAtMs is milliseconds since the epoch, nil when the
// source states no expiry.
type oauthToken struct {
	AccessToken secret.Secret
	ExpiresAtMs *float64
}

// Format redacts, as the other credential structs do.
func (oauthToken) Format(f fmt.State, _ rune) { _, _ = f.Write([]byte("<redacted>")) }

// credentialLoader resolves the file, then the Keychain, then the environment. The Keychain
// seam is nil where no Keychain exists.
type credentialLoader struct {
	path     string
	keychain func(service string) ([]byte, error)
	getenv   func(string) string
}

func newCredentialLoader(env provider.Env) *credentialLoader {
	return &credentialLoader{path: filepath.Join(env.Paths.Home, ".claude", ".credentials.json"), keychain: env.Keychain, getenv: env.Getenv}
}

// load returns the first unexpired token, and an expired one only if nothing else exists. The app
// takes the first token of any age because it can refresh; the CLI cannot, so an expired file would
// hide a valid Keychain token.
func (l *credentialLoader) load(now time.Time) *oauthToken {
	var expired *oauthToken
	for _, source := range []func() *oauthToken{l.fromFile, l.fromKeychain, l.fromEnv} {
		token := source()
		if token == nil {
			continue
		}
		if !token.expired(now) {
			return token
		}
		if expired == nil {
			expired = token
		}
	}
	return expired
}

func (l *credentialLoader) fromFile() *oauthToken {
	data, err := os.ReadFile(l.path)
	if err != nil {
		return nil
	}
	return decodeOAuthBlob(data)
}

// fromKeychain treats any failure, a locked keychain included, as no credential, so a read never
// surfaces as a dialog cascade.
func (l *credentialLoader) fromKeychain() *oauthToken {
	if l.keychain == nil {
		return nil
	}
	data, err := l.keychain(keychainService)
	if err != nil {
		return nil
	}
	return decodeOAuthBlob(data)
}

func (l *credentialLoader) fromEnv() *oauthToken {
	value := l.getenv(envTokenKey)
	if value == "" {
		return nil
	}
	return &oauthToken{AccessToken: secret.New(value)}
}

func decodeOAuthBlob(data []byte) *oauthToken {
	var root map[string]any
	if json.Unmarshal(data, &root) != nil {
		return nil
	}
	blob, ok := root["claudeAiOauth"].(map[string]any)
	if !ok {
		blob, ok = root["mcpOAuth"].(map[string]any)
		if !ok {
			return nil
		}
	}
	access, ok := blob["accessToken"].(string)
	if !ok || access == "" {
		return nil
	}
	token := oauthToken{AccessToken: secret.New(access)}
	if expires, ok := blob["expiresAt"].(float64); ok {
		token.ExpiresAtMs = &expires
	}
	return &token
}

// expired is false for an unknown expiry: the server decides.
func (t oauthToken) expired(now time.Time) bool {
	return t.ExpiresAtMs != nil && float64(now.UnixMilli()) >= *t.ExpiresAtMs
}
