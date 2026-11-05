package claude

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	defaultAccount   = "default"
	hookScriptMarker = "aub-statusline"
	keepBackups      = 3
)

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

// HookInstaller wires one target's statusLine slot to the tee. settings.json is written only by
// Install and Uninstall. Every read and check comes before the first write, so a refusal leaves
// the disk as it was.
type HookInstaller struct {
	FeedDir string
	Target  HookTarget
}

// Status never writes.
func (i HookInstaller) Status() HookState {
	settings, err := loadHookSettings(i.Target.SettingsPath)
	if err != nil {
		return HookUnreadable
	}
	return slotState(settings.values)
}

// Install reports whether an existing status line was chained.
func (i HookInstaller) Install() (chained bool, err error) {
	settings, err := loadHookSettings(i.Target.SettingsPath)
	if err != nil {
		return false, err
	}
	state := slotState(settings.values)
	existing, isObject := settings.values["statusLine"].(map[string]any)
	if state == HookForeignStatusline && !isObject {
		return false, fmt.Errorf("%s: statusLine is not an object", i.Target.SettingsPath)
	}
	files := i.files(settings.values)
	saved, err := readOriginalStatusLine(files.original)
	if err != nil {
		return false, err
	}
	original := saved
	if state != HookInstalled {
		original = existing
	}

	if err := os.MkdirAll(i.FeedDir, 0o755); err != nil {
		return false, err
	}
	switch state {
	case HookForeignStatusline:
		data, err := encodeJSON(original)
		if err != nil {
			return false, err
		}
		if err := writeFileAtomic(files.original, data, 0o644); err != nil {
			return false, err
		}
	case HookNotInstalled:
		if err := removeIfPresent(files.original); err != nil {
			return false, err
		}
	}
	command, _ := original["command"].(string)
	script := hookScript(hookSessionsDir(i.FeedDir), command)
	if err := writeFileAtomic(files.script, []byte(script), 0o755); err != nil {
		return false, err
	}
	chained = strings.TrimSpace(command) != ""

	wanted := "sh " + shellQuote(files.script)
	if state == HookInstalled && existing["type"] == "command" && existing["command"] == wanted {
		return chained, nil
	}
	if settings.exists {
		if err := i.backUp(settings); err != nil {
			return false, err
		}
	}
	statusLine := maps.Clone(existing)
	if statusLine == nil {
		statusLine = map[string]any{}
	}
	statusLine["type"], statusLine["command"] = "command", wanted
	settings.values["statusLine"] = statusLine
	return chained, settings.save()
}

// Uninstall puts back the saved status line only when the slot is still ours: one set after
// install is the user's newer choice. The sessions feed stays.
func (i HookInstaller) Uninstall() error {
	settings, err := loadHookSettings(i.Target.SettingsPath)
	if err != nil {
		return err
	}
	files := i.files(settings.values)
	saved, err := readOriginalStatusLine(files.original)
	if err != nil {
		return err
	}
	if slotState(settings.values) == HookInstalled {
		if saved != nil {
			settings.values["statusLine"] = saved
		} else {
			delete(settings.values, "statusLine")
		}
		if err := settings.save(); err != nil {
			return err
		}
	}
	if err := removeIfPresent(files.original); err != nil {
		return err
	}
	return removeIfPresent(files.script)
}

type hookFiles struct{ script, original string }

// files names the script and saved status line. An installed command's own slug wins over
// discovery: removing the first ccs instance renames a folded target, and following the new name
// would orphan the saved status line and lose the chain.
func (i HookInstaller) files(values map[string]any) hookFiles {
	slug := i.Target.Slug
	if fromCommand, ok := slugFromCommand(commandOf(values["statusLine"])); ok {
		slug = fromCommand
	}
	suffix := ""
	if slug != defaultAccount {
		suffix = "-" + slug
	}
	return hookFiles{
		script:   filepath.Join(i.FeedDir, hookScriptMarker+suffix+".sh"),
		original: filepath.Join(i.FeedDir, "original-statusline"+suffix+".json"),
	}
}

// scriptSlugPattern matches from the last marker on, in the single or double quoted form either
// installer writes.
var scriptSlugPattern = regexp.MustCompile(`^` + hookScriptMarker + `(?:-(.+?))?\.sh(?:['"\s]|$)`)

func slugFromCommand(command string) (string, bool) {
	at := strings.LastIndex(command, hookScriptMarker)
	if at < 0 {
		return "", false
	}
	match := scriptSlugPattern.FindStringSubmatch(command[at:])
	if match == nil {
		return "", false
	}
	slug := strings.ReplaceAll(match[1], `'\''`, "'")
	if slug == "" {
		return defaultAccount, true
	}
	if strings.Contains(slug, "/") {
		return "", false
	}
	return slug, true
}

func commandOf(statusLine any) string {
	object, _ := statusLine.(map[string]any)
	command, _ := object["command"].(string)
	return command
}

func slotState(values map[string]any) HookState {
	statusLine := values["statusLine"]
	switch {
	case statusLine == nil:
		return HookNotInstalled
	case strings.Contains(commandOf(statusLine), hookScriptMarker):
		return HookInstalled
	}
	return HookForeignStatusline
}

// backUp sits beside the path as configured, not the symlink's target. It copies bytes, so a
// backup of a symlinked file does not follow later edits. Within one second the first copy holds
// the state before that second's writes, and is kept.
func (i HookInstaller) backUp(settings hookSettings) error {
	prefix := i.Target.SettingsPath + ".aub-backup-"
	path := prefix + strconv.FormatInt(time.Now().Unix(), 10)
	if _, err := os.Lstat(path); errors.Is(err, fs.ErrNotExist) {
		if err := writeFileAtomic(path, settings.raw, settings.mode); err != nil {
			return err
		}
	}
	pruneBackups(prefix)
	return nil
}

func pruneBackups(prefix string) {
	dir := filepath.Dir(prefix)
	children, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	type backup struct {
		path  string
		epoch int64
	}
	var backups []backup
	for _, child := range children {
		path := filepath.Join(dir, child.Name())
		rest, found := strings.CutPrefix(path, prefix)
		if !found {
			continue
		}
		if epoch, err := strconv.ParseInt(rest, 10, 64); err == nil {
			backups = append(backups, backup{path, epoch})
		}
	}
	sort.Slice(backups, func(a, b int) bool { return backups[a].epoch > backups[b].epoch })
	for _, stale := range backups[min(keepBackups, len(backups)):] {
		_ = os.Remove(stale.path)
	}
}

// hookSettings is a parsed settings.json and where to write it back. dest is the symlink-resolved
// file, so a link into ~/.ccs/shared survives.
type hookSettings struct {
	values map[string]any
	raw    []byte
	dest   string
	mode   fs.FileMode
	exists bool
}

func loadHookSettings(path string) (hookSettings, error) {
	settings := hookSettings{dest: path, mode: 0o644}
	info, err := os.Lstat(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		settings.values = map[string]any{}
		return settings, nil
	case err != nil:
		return settings, err
	case info.Mode()&os.ModeSymlink != 0:
		if settings.dest, err = filepath.EvalSymlinks(path); err != nil {
			return settings, fmt.Errorf("%s: dangling symlink: %w", path, err)
		}
	}
	if info, err = os.Stat(settings.dest); err != nil {
		return settings, err
	}
	settings.mode, settings.exists = info.Mode().Perm(), true
	if settings.raw, err = os.ReadFile(settings.dest); err != nil {
		return settings, err
	}
	object, err := decodeObject(settings.raw)
	if err != nil {
		return settings, fmt.Errorf("%s: %w", path, err)
	}
	if object == nil {
		object = map[string]any{}
	}
	settings.values = object
	return settings, nil
}

func (s hookSettings) save() error {
	data, err := encodeJSON(s.values)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.dest), 0o755); err != nil {
		return err
	}
	return writeFileAtomic(s.dest, data, s.mode)
}

// readOriginalStatusLine is nil when none was saved.
func readOriginalStatusLine(path string) (map[string]any, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	object, err := decodeObject(data)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return object, nil
}

// decodeObject is nil for an empty document. UseNumber keeps number text as the user wrote it.
func decodeObject(data []byte) (map[string]any, error) {
	if len(bytes.TrimSpace(data)) == 0 {
		return nil, nil
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, fmt.Errorf("malformed JSON: %w", err)
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return nil, errors.New("malformed JSON: data after the top-level value")
	}
	object, ok := value.(map[string]any)
	if !ok {
		return nil, errors.New("not a JSON object")
	}
	return object, nil
}

// encodeJSON leaves `&&` and `>` readable: status line commands contain them.
func encodeJSON(value any) ([]byte, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		return nil, err
	}
	return buffer.Bytes(), nil
}

func writeFileAtomic(path string, data []byte, mode fs.FileMode) error {
	temp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	_, err = temp.Write(data)
	if err == nil {
		err = temp.Chmod(mode)
	}
	if closeErr := temp.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return os.Rename(temp.Name(), path)
}

func removeIfPresent(path string) error {
	if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return nil
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// hookScript is the tee. The account is read at runtime because instances can share one
// settings.json, so the script's own name cannot say who is running. The original command goes on
// its own line, not in a variable, so it parses exactly as its author wrote it.
func hookScript(sessionsDir, originalCommand string) string {
	lines := []string{
		"#!/bin/sh",
		"# Agents Usage Bar — statusline tee. Captures Claude Code statusline JSON,",
		"# then chains to the original statusline. Managed by Agents Usage Bar —",
		"# do not edit by hand; reinstall with: aub hook install",
		"FEED_ROOT=" + shellQuote(sessionsDir),
		`# Account = ccs instance dir name from CLAUDE_CONFIG_DIR; "default" for ~/.claude.`,
		`acct="${CLAUDE_CONFIG_DIR:+$(basename "$CLAUDE_CONFIG_DIR")}"`,
		`acct="${acct:-default}"`,
		`FEED_DIR="$FEED_ROOT/$acct"`,
		`input=$(cat)`,
		`sid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)`,
		`if [ -n "$sid" ]; then`,
		`  mkdir -p "$FEED_DIR"`,
		`  tmp="$FEED_DIR/.$sid.tmp.$$"`,
		`  # Remove the temp file on ANY exit — a failed mv must not strand hidden files.`,
		`  trap 'rm -f "$tmp"' EXIT`,
		`  printf '%s' "$input" > "$tmp" && mv -f "$tmp" "$FEED_DIR/$sid.json"`,
		`fi`,
	}
	if strings.TrimSpace(originalCommand) != "" {
		lines = append(lines,
			"# --- chained original statusline (embedded verbatim) ---",
			`printf '%s' "$input" | `+originalCommand,
		)
	}
	return strings.Join(lines, "\n") + "\n"
}
