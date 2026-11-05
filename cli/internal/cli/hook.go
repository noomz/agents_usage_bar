package cli

import (
	"fmt"
	"strings"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/providers/claude"
)

const claudeSourceKey = "claude-source"

func (a *App) runHook(c HookCmd) (int, error) {
	feedDir := claude.HookFeedDir(a.Layout.DataDir)
	targets := claude.DiscoverHookTargets(a.Layout.Home)
	switch c.Verb {
	case HookInstall:
		return a.hookInstall(feedDir, targets)
	case HookUninstall:
		return a.hookUninstall(feedDir, targets)
	}
	return a.hookStatus(feedDir, targets)
}

func (a *App) hookInstall(feedDir string, targets []claude.HookTarget) (int, error) {
	for _, target := range targets {
		chained, err := claude.HookInstaller{FeedDir: feedDir, Target: target}.Install()
		if err != nil {
			return 0, err
		}
		line := fmt.Sprintf("Installed %s (accounts: %s)", target.SettingsPath, strings.Join(target.Accounts, ", "))
		if chained {
			line += ", chained the existing status line"
		}
		fmt.Fprintln(a.Stdout, line)
	}
	if err := a.setClaudeSource("hook"); err != nil {
		return 0, err
	}
	fmt.Fprintln(a.Stdout, "Data appears after the next Claude Code status line update.")
	return 0, nil
}

func (a *App) hookUninstall(feedDir string, targets []claude.HookTarget) (int, error) {
	for _, target := range targets {
		if err := (claude.HookInstaller{FeedDir: feedDir, Target: target}).Uninstall(); err != nil {
			return 0, err
		}
		fmt.Fprintf(a.Stdout, "Uninstalled %s (accounts: %s)\n", target.SettingsPath, strings.Join(target.Accounts, ", "))
	}
	return 0, a.setClaudeSource("sessionReads")
}

func (a *App) setClaudeSource(value string) error {
	result, err := a.settingsCLI().Set(claudeSourceKey, value)
	if err != nil {
		return err
	}
	fmt.Fprintln(a.Stdout, result.Key+"="+result.Value)
	return nil
}

func (a *App) hookStatus(feedDir string, targets []claude.HookTarget) (int, error) {
	source, err := a.settingsCLI().Get(claudeSourceKey)
	if err != nil {
		return 0, err
	}
	fmt.Fprintln(a.Stdout, source.Key+"="+source.Value)
	for _, target := range targets {
		state := claude.HookInstaller{FeedDir: feedDir, Target: target}.Status()
		fmt.Fprintf(a.Stdout, "%s: %s  %s\n", strings.Join(target.Accounts, ", "), state, target.SettingsPath)
	}
	accounts := claude.HookFeedAccounts(feedDir)
	if len(accounts) == 0 {
		fmt.Fprintln(a.Stdout, "feed: no data yet")
	}
	now := a.Clock.Now()
	for _, account := range accounts {
		fmt.Fprintf(a.Stdout, "feed %s: updated %s ago\n", account.Name, formatFeedAge(now.Sub(account.Newest)))
	}
	return 0, nil
}

func formatFeedAge(age time.Duration) string {
	switch {
	case age < time.Minute:
		return "under 1m"
	case age < time.Hour:
		return fmt.Sprintf("%dm", int(age.Minutes()))
	case age < 48*time.Hour:
		return fmt.Sprintf("%dh", int(age.Hours()))
	}
	return fmt.Sprintf("%dd", int(age.Hours()/24))
}
