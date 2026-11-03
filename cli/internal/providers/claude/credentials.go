package claude

import (
	"encoding/json"
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

// load treats any Keychain failure, a locked keychain included, as no credential, so a read
// never surfaces as a dialog cascade.
func (l *credentialLoader) load() *oauthToken {
	if data, err := os.ReadFile(l.path); err == nil {
		if token := decodeOAuthBlob(data); token != nil {
			return token
		}
	}
	if l.keychain != nil {
		if data, err := l.keychain(keychainService); err == nil {
			if token := decodeOAuthBlob(data); token != nil {
				return token
			}
		}
	}
	if value := l.getenv(envTokenKey); value != "" {
		return &oauthToken{AccessToken: secret.New(value)}
	}
	return nil
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
