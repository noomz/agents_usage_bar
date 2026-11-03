package claude

import (
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/applog"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/secret"
)

const (
	keychainService = "Claude Code-credentials"
	envTokenKey     = "CLAUDE_CODE_OAUTH_TOKEN"
	refreshBuffer   = 5 * time.Minute
)

type credentialSource int

const (
	sourceFile credentialSource = iota
	sourceKeychain
	sourceEnvironment
)

// oauthToken is a decoded token set. ExpiresAtMs is milliseconds since the epoch. A rotation
// keeps SubscriptionType, which a refresh does not return.
type oauthToken struct {
	AccessToken      secret.Secret
	RefreshToken     *secret.Secret
	ExpiresAtMs      *float64
	SubscriptionType *string
}

type resolvedCredential struct {
	token  oauthToken
	source credentialSource
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
func (l *credentialLoader) load() *resolvedCredential {
	if data, err := os.ReadFile(l.path); err == nil {
		if token := decodeOAuthBlob(data); token != nil {
			return &resolvedCredential{*token, sourceFile}
		}
	}
	if l.keychain != nil {
		if data, err := l.keychain(keychainService); err == nil {
			if token := decodeOAuthBlob(data); token != nil {
				return &resolvedCredential{*token, sourceKeychain}
			}
		}
	}
	if value := l.getenv(envTokenKey); value != "" {
		return &resolvedCredential{oauthToken{AccessToken: secret.New(value)}, sourceEnvironment}
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
	if refresh, ok := blob["refreshToken"].(string); ok {
		wrapped := secret.New(refresh)
		token.RefreshToken = &wrapped
	}
	if expires, ok := blob["expiresAt"].(float64); ok {
		token.ExpiresAtMs = &expires
	}
	if subscription, ok := blob["subscriptionType"].(string); ok {
		token.SubscriptionType = &subscription
	}
	return &token
}

// needsRefresh: an unknown expiry always refreshes.
func needsRefresh(token oauthToken, now time.Time) bool {
	if token.ExpiresAtMs == nil {
		return true
	}
	return float64(now.Add(refreshBuffer).UnixMilli()) >= *token.ExpiresAtMs
}

// saveToFile writes rotated tokens back. The server has already invalidated the old refresh
// token, so this write is the only copy of the new one.
//
// Swift rewrites the file as just its four known fields, which drops `scopes` and anything else
// Claude Code keeps there. This merges instead, because Linux has no Keychain and this file is
// Claude Code's only login. It also follows a symlinked file, keeps the file's mode, and syncs
// before the rename, so a crash leaves the old file or the whole new one.
func (l *credentialLoader) saveToFile(token oauthToken) error {
	path := l.path
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		path = resolved
	}
	mode := os.FileMode(0o600)
	if info, err := os.Stat(path); err == nil {
		mode = info.Mode().Perm()
	}
	root := map[string]json.RawMessage{}
	if data, err := os.ReadFile(path); err == nil {
		if json.Unmarshal(data, &root) != nil || root == nil {
			root = map[string]json.RawMessage{}
		}
	}
	blob := map[string]json.RawMessage{}
	if raw, ok := root["claudeAiOauth"]; ok {
		if json.Unmarshal(raw, &blob) != nil || blob == nil {
			blob = map[string]json.RawMessage{}
		}
	}
	set := func(key string, value any) error {
		data, err := json.Marshal(value)
		if err == nil {
			blob[key] = data
		}
		return err
	}
	if err := set("accessToken", token.AccessToken.Reveal()); err != nil {
		return err
	}
	if token.RefreshToken != nil {
		if err := set("refreshToken", token.RefreshToken.Reveal()); err != nil {
			return err
		}
	}
	if token.ExpiresAtMs != nil {
		if err := set("expiresAt", *token.ExpiresAtMs); err != nil {
			return err
		}
	}
	if token.SubscriptionType != nil {
		if err := set("subscriptionType", *token.SubscriptionType); err != nil {
			return err
		}
	}
	merged, err := json.Marshal(blob)
	if err != nil {
		return err
	}
	root["claudeAiOauth"] = merged
	data, err := json.MarshalIndent(root, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(path, data, mode)
}

func writeAtomic(path string, data []byte, mode os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".credentials-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

func logSaveFailure() {
	applog.Logger.Error("oauth: rotated credentials could not be written back")
}
