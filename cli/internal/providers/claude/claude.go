// Package claude is the Claude row: session reads (transcripts plus the OAuth usage endpoint) or
// the statusline hook feed, chosen by the claude-source preference on every fetch.
package claude

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/resources"
)

const sourceHook = "hook"

// Provider owns the Claude identity and delegates each fetch.
type Provider struct {
	useHook bool
	reads   *sessionReads
	hook    *hookFeed
}

// Build always registers the row: Fetch reports a machine with no credential and no transcripts
// as unauthenticated, and hook mode can have data with neither. No network here.
func Build(env provider.Env) provider.Provider {
	loader := newCredentialLoader(env)
	var oauth usageSource
	if loader.load() != nil {
		oauth = &oauthClient{http: env.HTTP, creds: loader, now: env.Clock.Now}
	}
	return &Provider{
		useHook: env.Preferences.ClaudeSource == sourceHook,
		reads: &sessionReads{
			roots:   func() []string { return defaultRoots(env.Paths.Home) },
			pricing: decodePricing(resources.ClaudePricing),
			oauth:   oauth,
			cache:   env.Cache,
			dayKeys: env.DayKeys,
		},
		hook: &hookFeed{dir: filepath.Join(env.Paths.DataDir, "claude-hook", "sessions"), dayKeys: env.DayKeys},
	}
}

// defaultRoots are the transcript trees that exist: ~/.claude/projects and the projects
// directory of every ccs context group and instance.
func defaultRoots(home string) []string {
	var roots []string
	claude := filepath.Join(home, ".claude", "projects")
	if _, err := os.Stat(claude); err == nil {
		roots = append(roots, claude)
	}
	for _, parent := range []string{filepath.Join(home, ".ccs", "shared", "context-groups"), filepath.Join(home, ".ccs", "instances")} {
		children, err := os.ReadDir(parent)
		if err != nil {
			continue
		}
		for _, child := range children {
			if strings.HasPrefix(child.Name(), ".") {
				continue
			}
			projects := filepath.Join(parent, child.Name(), "projects")
			if _, err := os.Stat(projects); err == nil {
				roots = append(roots, projects)
			}
		}
	}
	return roots
}

func (*Provider) ID() domain.ProviderID { return domain.Claude }

func (*Provider) DisplayName() string { return "Claude Code" }

func (*Provider) Capabilities() domain.Capabilities {
	return domain.Capabilities{HasQuota: true, HasCost: true, HasTokens: true}
}

func (p *Provider) Fetch(ctx context.Context, now time.Time) (domain.UsageSnapshot, domain.ProviderStatus, error) {
	if p.useHook {
		return p.fetchHook(ctx, now)
	}
	p.hook.prune(now)
	snapshot, status, _, err := p.reads.fetch(ctx, now)
	return snapshot, status, err
}

// fetchHook is hybrid for tokens: the statusline pushes real cost and rate limits but no token
// totals, so only tokensToday comes from the session read. A read failure leaves tokens nil and
// never fails the fetch.
func (p *Provider) fetchHook(ctx context.Context, now time.Time) (domain.UsageSnapshot, domain.ProviderStatus, error) {
	read, _, sessions, readErr := p.reads.fetch(ctx, now)
	snapshot, err := p.hook.fetch(now)
	if err != nil {
		return domain.UsageSnapshot{}, domain.ProviderStatus{}, err
	}
	if readErr != nil {
		sessions = nil
	} else {
		snapshot.TokensToday = read.TokensToday
	}
	today := p.hook.dayKeys.StartOfDay(now)
	owners := p.hook.sessionAccounts(nil)
	active := map[string]bool{}
	for _, owner := range p.hook.sessionAccounts(&today) {
		active[owner] = true
	}
	tokensByAccount := map[string]int{}
	for session, tokens := range sessions {
		if owner, ok := owners[session]; ok {
			tokensByAccount[owner] += tokens
		}
	}
	for i := range snapshot.Accounts {
		account := &snapshot.Accounts[i]
		// A read that worked knows an account with no session today has 0. One with a session
		// today but no tokens read stays unknown.
		if tokens, ok := tokensByAccount[account.Name]; ok {
			account.TokensToday = &tokens
		} else if sessions != nil && !active[account.Name] {
			zero := 0
			account.TokensToday = &zero
		}
	}
	return snapshot, domain.OK(now), nil
}
