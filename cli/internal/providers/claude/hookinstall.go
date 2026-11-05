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

// HookInstaller wires every target's statusLine slot to the tee. Install and Uninstall plan first
// and only then write, so a refusal on any target leaves every target as it was.
type HookInstaller struct {
	FeedDir string
	Targets []HookTarget
}

// HookInstallation is the outcome for one target. Chained says an existing status line runs
// through the tee.
type HookInstallation struct {
	Target  HookTarget
	Chained bool
}

// Status never writes.
func (i HookInstaller) Status(target HookTarget) HookState {
	settings, err := loadHookSettings(target.SettingsPath)
	if err != nil {
		return HookUnreadable
	}
	return slotState(settings.values)
}

// Install writes the scripts before any settings file points at them.
func (i HookInstaller) Install() ([]HookInstallation, error) {
	slots, err := i.planSlots()
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(i.FeedDir, 0o755); err != nil {
		return nil, err
	}
	for _, slot := range slots {
		if err := i.writeFiles(slot); err != nil {
			return nil, err
		}
	}
	installations := make([]HookInstallation, len(slots))
	for index, slot := range slots {
		if err := slot.wire(); err != nil {
			return nil, err
		}
		installations[index] = HookInstallation{slot.target, strings.TrimSpace(slot.originalCommand()) != ""}
	}
	return installations, nil
}

// Uninstall puts back the saved status line only when the slot is still ours: one set after
// install is the user's newer choice. Targets can share a script, so files go only after every
// settings file is written. The sessions feed stays.
func (i HookInstaller) Uninstall() error {
	slots, err := i.planSlots()
	if err != nil {
		return err
	}
	for _, slot := range slots {
		if err := slot.restore(); err != nil {
			return err
		}
	}
	for _, slot := range slots {
		if err := removeIfPresent(slot.files.original); err != nil {
			return err
		}
		if err := removeIfPresent(slot.files.script); err != nil {
			return err
		}
	}
	return nil
}

// hookSlot is one target as planning found it. Everything Install and Uninstall write comes from
// it, with no second read.
type hookSlot struct {
	target     HookTarget
	settings   hookSettings
	state      HookState
	statusLine map[string]any
	files      hookFiles
	// original is the status line behind the tee: chained by install, restored by uninstall.
	original map[string]any
	// unsaved says no saved file holds original yet.
	unsaved bool
}

func (i HookInstaller) planSlots() ([]hookSlot, error) {
	slots := make([]hookSlot, len(i.Targets))
	for index, target := range i.Targets {
		slot, err := i.planSlot(target)
		if err != nil {
			return nil, err
		}
		slots[index] = slot
	}
	if err := refuseSharedFiles(slots); err != nil {
		return nil, err
	}
	return slots, nil
}

// refuseSharedFiles allows sharing only between slots that are already ours: one script then
// serves them all and routes at runtime. In any other pair, one target's status line would
// overwrite the other's saved copy and chain.
func refuseSharedFiles(slots []hookSlot) error {
	byScript := map[string]hookSlot{}
	for _, slot := range slots {
		other, shared := byScript[slot.files.script]
		if shared && (slot.state != HookInstalled || other.state != HookInstalled) {
			return fmt.Errorf("%s and %s both use %s: rename the ccs instance or fix its status line first", other.target.SettingsPath, slot.target.SettingsPath, slot.files.script)
		}
		byScript[slot.files.script] = slot
	}
	return nil
}

func (i HookInstaller) planSlot(target HookTarget) (hookSlot, error) {
	settings, err := loadHookSettings(target.SettingsPath)
	if err != nil {
		return hookSlot{}, err
	}
	state := slotState(settings.values)
	statusLine, isObject := settings.values["statusLine"].(map[string]any)
	if state == HookForeignStatusline && !isObject {
		return hookSlot{}, fmt.Errorf("%s: statusLine is not an object", target.SettingsPath)
	}
	files := i.files(target, settings.values)
	saved, err := readOriginalStatusLine(files.original)
	if err != nil {
		return hookSlot{}, err
	}
	slot := hookSlot{target: target, settings: settings, state: state, statusLine: statusLine, files: files}
	switch state {
	case HookForeignStatusline:
		slot.original, slot.unsaved = statusLine, true
	case HookInstalled:
		slot.original = saved
	}
	if i.runsFeedScript(slot.originalCommand()) {
		return hookSlot{}, fmt.Errorf("%s: status line %q runs our own script: it would recurse if chained and break on uninstall, so change it first", target.SettingsPath, slot.originalCommand())
	}
	return slot, nil
}

func (s hookSlot) originalCommand() string {
	command, _ := s.original["command"].(string)
	return command
}

func (i HookInstaller) writeFiles(slot hookSlot) error {
	switch {
	case slot.unsaved:
		data, err := encodeJSON(slot.original)
		if err != nil {
			return err
		}
		if err := writeFileAtomic(slot.files.original, data, 0o644); err != nil {
			return err
		}
	case slot.state == HookNotInstalled:
		if err := removeIfPresent(slot.files.original); err != nil {
			return err
		}
	}
	script := hookScript(hookSessionsDir(i.FeedDir), slot.originalCommand())
	return writeFileAtomic(slot.files.script, []byte(script), 0o755)
}

func (s hookSlot) wire() error {
	wanted := "sh " + shellQuote(s.files.script)
	if s.state == HookInstalled && s.statusLine["type"] == "command" && s.statusLine["command"] == wanted {
		return nil
	}
	if s.settings.exists {
		if err := s.backUp(); err != nil {
			return err
		}
	}
	statusLine := maps.Clone(s.statusLine)
	if statusLine == nil {
		statusLine = map[string]any{}
	}
	statusLine["type"], statusLine["command"] = "command", wanted
	s.settings.values["statusLine"] = statusLine
	return s.settings.save()
}

func (s hookSlot) restore() error {
	if s.state != HookInstalled {
		return nil
	}
	if s.original != nil {
		s.settings.values["statusLine"] = s.original
	} else {
		delete(s.settings.values, "statusLine")
	}
	return s.settings.save()
}

type hookFiles struct{ script, original string }

// files names the script and saved status line. An installed command's own slug wins over
// discovery: removing the first ccs instance renames a folded target, and following the new name
// would orphan the saved status line and lose the chain.
func (i HookInstaller) files(target HookTarget, values map[string]any) hookFiles {
	slug := target.Slug
	if own, ok := parseOwnCommand(commandOf(values["statusLine"])); ok {
		slug = own.slug
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

// ownCommand is a statusLine command that runs one of our scripts and nothing else.
type ownCommand struct{ scriptPath, slug string }

var (
	ownCommandPattern = regexp.MustCompile("^sh\\s+(?:'((?:[^']|'\\\\'')*)'|\"([^\"$`\\\\]*)\"|([^\\s'\"\\\\;|&<>()$`*?#]+))$")
	ownScriptPattern  = regexp.MustCompile(`^` + hookScriptMarker + `(?:-(.+))?\.sh$`)
)

func parseOwnCommand(command string) (ownCommand, bool) {
	match := ownCommandPattern.FindStringSubmatch(strings.TrimSpace(command))
	if match == nil {
		return ownCommand{}, false
	}
	path := strings.ReplaceAll(match[1], `'\''`, "'") + match[2] + match[3]
	script := ownScriptPattern.FindStringSubmatch(filepath.Base(path))
	if script == nil {
		return ownCommand{}, false
	}
	slug := script[1]
	if slug == "" {
		slug = defaultAccount
	}
	return ownCommand{path, slug}, true
}

// runsFeedScript matches on the feed's last two path parts so that `~` and `$HOME` spellings count.
func (i HookInstaller) runsFeedScript(command string) bool {
	suffix := filepath.Join(filepath.Base(filepath.Dir(i.FeedDir)), filepath.Base(i.FeedDir), hookScriptMarker)
	return strings.Contains(command, suffix)
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
	}
	if _, ok := parseOwnCommand(commandOf(statusLine)); ok {
		return HookInstalled
	}
	return HookForeignStatusline
}

// backUp sits beside the path as configured, not the symlink's target. It copies bytes, so a
// backup of a symlinked file does not follow later edits. Within one second the first copy holds
// the state before that second's writes, and is kept.
func (s hookSlot) backUp() error {
	prefix := s.target.SettingsPath + ".aub-backup-"
	path := prefix + strconv.FormatInt(time.Now().Unix(), 10)
	if _, err := os.Lstat(path); errors.Is(err, fs.ErrNotExist) {
		if err := writeFileAtomic(path, s.settings.raw, s.settings.mode); err != nil {
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

// readOriginalStatusLine is nil when none was saved. An empty saved file is malformed, not "none":
// treating it as none would make uninstall delete the status line.
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
	if object == nil {
		return nil, fmt.Errorf("%s: empty", path)
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

const (
	chainMarker = "# --- chained original statusline (embedded verbatim) ---"
	chainPrefix = `printf '%s' "$input" | `
)

// hookScript is the tee. The account is read at runtime because instances can share one
// settings.json, so the script's own name cannot say who is running. The original command goes on
// its own lines, not in a variable, so it parses exactly as its author wrote it. The braces give
// all of a compound or multi-line command the pipe, not only its first part.
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
			chainMarker,
			chainPrefix+"{",
			originalCommand,
			"}",
		)
	}
	return strings.Join(lines, "\n") + "\n"
}
