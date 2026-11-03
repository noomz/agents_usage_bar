package grok

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/providers/pilocal"
	"github.com/noomz/agents_usage_bar/cli/internal/secret"
)

type credentialSource int

const (
	sourceAPIKey credentialSource = iota
	sourceSession
	sourcePiOAuth
)

// credential is a bearer the billing client may try. Grok CLI sessions need CLI headers.
type credential struct {
	token  secret.Secret
	source credentialSource
}

// Format redacts: fmt cannot reach Secret's own Format through an unexported field.
func (credential) Format(f fmt.State, _ rune) { _, _ = f.Write([]byte("<redacted>")) }

func grokHome(env provider.Env) string {
	if override := env.Getenv("GROK_HOME"); override != "" {
		return override
	}
	return filepath.Join(env.Paths.Home, ".grok")
}

// loadCandidates orders the bearers to try on 401: Grok CLI session, unexpired Pi xAI OAuth,
// then XAI_API_KEY and the configured key. Nothing here refreshes or writes: an expired Pi token
// is skipped, and Pi keeps ownership of its file.
func loadCandidates(env provider.Env, now time.Time) []credential {
	var out []credential
	seen := map[secret.Secret]bool{}
	add := func(token secret.Secret, source credentialSource) {
		if !seen[token] {
			seen[token] = true
			out = append(out, credential{token, source})
		}
	}
	if key, ok := sessionKey(filepath.Join(grokHome(env), "auth.json")); ok {
		add(secret.New(key), sourceSession)
	}
	if access, ok := piOAuthAccess(filepath.Join(pilocal.AgentDir(env.Getenv, env.Paths.Home), "auth.json"), now); ok {
		add(secret.New(access), sourcePiOAuth)
	}
	if key := env.Getenv("XAI_API_KEY"); key != "" {
		add(secret.New(key), sourceAPIKey)
	}
	if env.Config.Grok.APIKey != nil {
		add(*env.Config.Grok.APIKey, sourceAPIKey)
	}
	return out
}

// sessionKey walks issuer-keyed objects for the first non-empty `key`.
func sessionKey(path string) (string, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	var root map[string]any
	if json.Unmarshal(data, &root) != nil {
		return "", false
	}
	issuers := make([]string, 0, len(root))
	for issuer := range root {
		issuers = append(issuers, issuer)
	}
	sort.Strings(issuers)
	for _, issuer := range issuers {
		if entry, ok := root[issuer].(map[string]any); ok {
			if key, ok := entry["key"].(string); ok && key != "" {
				return key, true
			}
		}
	}
	return "", false
}

func piOAuthAccess(path string, now time.Time) (string, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	var root struct {
		XAI *struct {
			Type    *string `json:"type"`
			Access  *string `json:"access"`
			Expires any     `json:"expires"`
		} `json:"xai"`
	}
	if json.Unmarshal(data, &root) != nil || root.XAI == nil || root.XAI.Type == nil || root.XAI.Access == nil {
		return "", false
	}
	if *root.XAI.Type != "oauth" || *root.XAI.Access == "" {
		return "", false
	}
	if expires, ok := root.XAI.Expires.(float64); ok {
		seconds := expires
		if seconds > 1_000_000_000_000 {
			seconds /= 1000
		}
		if !time.UnixMilli(int64(seconds * 1000)).After(now) {
			return "", false
		}
	}
	return *root.XAI.Access, true
}
