package claude

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const defaultAccount = "default"

// HookFeedDir holds the tee scripts, the saved original status lines, and the sessions feed.
func HookFeedDir(dataDir string) string { return filepath.Join(dataDir, "claude-hook") }

func hookSessionsDir(feedDir string) string { return filepath.Join(feedDir, "sessions") }

// HookTarget is one settings file to wire. Slug names the script and backup. Accounts are every
// account whose settings resolve to this file; the script tells them apart at runtime.
type HookTarget struct {
	Slug         string
	Accounts     []string
	SettingsPath string
}

// HookState is a target's statusLine slot relative to the tee.
type HookState int

const (
	HookNotInstalled HookState = iota
	HookInstalled
	HookForeignStatusline
	// HookUnreadable is a settings.json that cannot be read or parsed.
	HookUnreadable
)

func (s HookState) String() string {
	switch s {
	case HookInstalled:
		return "installed"
	case HookForeignStatusline:
		return "foreign status line"
	case HookUnreadable:
		return "unreadable"
	}
	return "not installed"
}

// DiscoverHookTargets lists ~/.claude first, then each ccs instance sorted by name. ccs can
// symlink every instance's settings.json to one shared file, so targets that resolve to the same
// file fold into the first.
func DiscoverHookTargets(home string) []HookTarget {
	candidates := []HookTarget{{defaultAccount, []string{defaultAccount}, filepath.Join(home, ".claude", "settings.json")}}
	instances := filepath.Join(home, ".ccs", "instances")
	if children, err := os.ReadDir(instances); err == nil {
		for _, child := range children {
			dir := filepath.Join(instances, child.Name())
			if info, err := os.Stat(dir); err != nil || !info.IsDir() || strings.HasPrefix(child.Name(), ".") {
				continue
			}
			candidates = append(candidates, HookTarget{child.Name(), []string{child.Name()}, filepath.Join(dir, "settings.json")})
		}
	}
	var targets []HookTarget
	indexByResolved := map[string]int{}
	for _, candidate := range candidates {
		resolved, err := filepath.EvalSymlinks(candidate.SettingsPath)
		if err != nil {
			resolved = candidate.SettingsPath
		}
		if index, seen := indexByResolved[resolved]; seen {
			targets[index].Accounts = append(targets[index].Accounts, candidate.Slug)
			continue
		}
		indexByResolved[resolved] = len(targets)
		targets = append(targets, candidate)
	}
	return targets
}

// HookFeedAccount is an account with feed data and when its newest session file was written.
type HookFeedAccount struct {
	Name   string
	Newest time.Time
}

// HookFeedAccounts reads the feed as fetch attributes it. It deletes nothing, unlike fetch.
func HookFeedAccounts(feedDir string) []HookFeedAccount {
	entries, err := enumerateFeed(hookSessionsDir(feedDir))
	if err != nil {
		return nil
	}
	newest := map[string]time.Time{}
	for _, entry := range newestCopies(entries) {
		payload, ok := readPayload(entry.path)
		if !ok {
			continue
		}
		name := entry.owner(payload)
		if current, seen := newest[name]; !seen || entry.mtime.After(current) {
			newest[name] = entry.mtime
		}
	}
	names := make([]string, 0, len(newest))
	for name := range newest {
		names = append(names, name)
	}
	sortAccounts(names)
	accounts := make([]HookFeedAccount, len(names))
	for i, name := range names {
		accounts[i] = HookFeedAccount{name, newest[name]}
	}
	return accounts
}

func sortAccounts(names []string) {
	sort.Slice(names, func(i, j int) bool {
		if (names[i] == defaultAccount) != (names[j] == defaultAccount) {
			return names[i] == defaultAccount
		}
		return names[i] < names[j]
	})
}
