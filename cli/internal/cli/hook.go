package cli

import (
	"fmt"
	"strings"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/providers/claude"
)

const claudeSourceKey = "claude-source"

func (a *App) runHook(c HookCmd) (int, error) {
	installer := claude.HookInstaller{
		FeedDir: claude.HookFeedDir(a.Layout.DataDir),
		Targets: claude.DiscoverHookTargets(a.Layout.Home),
	}
	switch c.Verb {
	case HookInstall:
		return a.hookInstall(installer)
	case HookUninstall:
		return a.hookUninstall(installer)
	}
	return a.hookStatus(installer)
}

func (a *App) hookInstall(installer claude.HookInstaller) (int, error) {
	installations, err := installer.Install()
	if err != nil {
		return 0, err
	}
	for _, installation := range installations {
		target := installation.Target
		line := fmt.Sprintf("Installed %s (accounts: %s)", target.SettingsPath, strings.Join(target.Accounts, ", "))
		if installation.Chained {
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

func (a *App) hookUninstall(installer claude.HookInstaller) (int, error) {
	if err := installer.Uninstall(); err != nil {
		return 0, err
	}
	for _, target := range installer.Targets {
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

func (a *App) hookStatus(installer claude.HookInstaller) (int, error) {
	source, err := a.settingsCLI().Get(claudeSourceKey)
	if err != nil {
		return 0, err
	}
	fmt.Fprintln(a.Stdout, source.Key+"="+source.Value)
	for _, target := range installer.Targets {
		fmt.Fprintf(a.Stdout, "%s: %s  %s\n", strings.Join(target.Accounts, ", "), installer.Status(target), target.SettingsPath)
	}
	accounts := claude.HookFeedAccounts(installer.FeedDir)
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
