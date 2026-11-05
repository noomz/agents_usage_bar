package claude

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/clock"
	"github.com/noomz/agents_usage_bar/cli/internal/paths"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
)

type installEnv struct {
	root, settings, feed string
	installer            HookInstaller
}

func newInstallEnv(t *testing.T) installEnv {
	t.Helper()
	root := t.TempDir()
	settings := filepath.Join(root, ".claude", "settings.json")
	feed := filepath.Join(root, "claude-hook")
	return installEnv{root, settings, feed, HookInstaller{feed, HookTarget{"default", []string{"default"}, settings}}}
}

func (e installEnv) script() string   { return filepath.Join(e.feed, "aub-statusline.sh") }
func (e installEnv) original() string { return filepath.Join(e.feed, "original-statusline.json") }

func (e installEnv) readSettings(t *testing.T) map[string]any {
	t.Helper()
	var values map[string]any
	if err := json.Unmarshal(readBytes(t, e.settings), &values); err != nil {
		t.Fatal(err)
	}
	return values
}

func (e installEnv) statusLine(t *testing.T) map[string]any {
	t.Helper()
	statusLine, ok := e.readSettings(t)["statusLine"].(map[string]any)
	if !ok {
		t.Fatalf("no statusLine object in %s", readBytes(t, e.settings))
	}
	return statusLine
}

func (e installEnv) mustInstall(t *testing.T) bool {
	t.Helper()
	chained, err := e.installer.Install()
	if err != nil {
		t.Fatal(err)
	}
	return chained
}

func (e installEnv) mustUninstall(t *testing.T) {
	t.Helper()
	if err := e.installer.Uninstall(); err != nil {
		t.Fatal(err)
	}
}

func readBytes(t *testing.T, path string) []byte {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func assertAbsent(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Lstat(path); !os.IsNotExist(err) {
		t.Fatalf("%s should not exist (err %v)", path, err)
	}
}

// snapshotTree is every path under root with its mode and content.
func snapshotTree(t *testing.T, root string) map[string]string {
	t.Helper()
	tree := map[string]string{}
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		tree[path] = info.Mode().String()
		if info.Mode().IsRegular() {
			tree[path] += ":" + string(readBytes(t, path))
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return tree
}

func backupEpochs(t *testing.T, settingsPath string) map[int]bool {
	t.Helper()
	children, err := os.ReadDir(filepath.Dir(settingsPath))
	if err != nil {
		t.Fatal(err)
	}
	epochs := map[int]bool{}
	prefix := filepath.Base(settingsPath) + ".aub-backup-"
	for _, child := range children {
		if rest, found := strings.CutPrefix(child.Name(), prefix); found {
			if epoch, err := strconv.Atoi(rest); err == nil {
				epochs[epoch] = true
			}
		}
	}
	return epochs
}

func TestInstallFreshWiresStatusLineAndKeepsOtherKeys(t *testing.T) {
	env := newInstallEnv(t)
	writeFile(t, env.settings, `{"model":"opusplan","env":{"FOO":"bar"},"permissions":{"allow":["Bash"]}}`)

	if env.mustInstall(t) {
		t.Fatal("nothing to chain on a fresh install")
	}

	if env.installer.Status() != HookInstalled {
		t.Fatalf("status %v", env.installer.Status())
	}
	statusLine := env.statusLine(t)
	if statusLine["type"] != "command" || statusLine["command"] != "sh '"+env.script()+"'" {
		t.Fatalf("statusLine %+v", statusLine)
	}
	values := env.readSettings(t)
	if values["model"] != "opusplan" || values["env"].(map[string]any)["FOO"] != "bar" {
		t.Fatalf("unknown keys lost: %+v", values)
	}
	assertAbsent(t, env.original())
	script := string(readBytes(t, env.script()))
	if !strings.HasPrefix(script, "#!/bin/sh\n") || strings.Contains(script, "chained original statusline") {
		t.Fatalf("script:\n%s", script)
	}
	info, err := os.Stat(env.script())
	if err != nil || info.Mode().Perm() != 0o755 {
		t.Fatalf("script mode %v, err %v", info.Mode(), err)
	}
}

func TestInstallCreatesMissingOrEmptySettings(t *testing.T) {
	for name, seed := range map[string]*string{"missing": nil, "empty": ptr(""), "blank": ptr(" \n")} {
		t.Run(name, func(t *testing.T) {
			env := newInstallEnv(t)
			if seed != nil {
				writeFile(t, env.settings, *seed)
			}
			env.mustInstall(t)
			if env.installer.Status() != HookInstalled {
				t.Fatalf("status %v", env.installer.Status())
			}
		})
	}
}

func ptr(s string) *string { return &s }

func TestInstallOverForeignSavesAndChainsItVerbatim(t *testing.T) {
	env := newInstallEnv(t)
	foreign := `sh -c 'printf "hud: %s\n" "$USER"'`
	data, _ := json.Marshal(map[string]any{"statusLine": map[string]any{"type": "command", "command": foreign}, "model": "sonnet"})
	writeFile(t, env.settings, string(data))
	if env.installer.Status() != HookForeignStatusline {
		t.Fatalf("status %v", env.installer.Status())
	}

	if !env.mustInstall(t) {
		t.Fatal("install must report the chain")
	}

	var saved map[string]any
	if err := json.Unmarshal(readBytes(t, env.original()), &saved); err != nil {
		t.Fatal(err)
	}
	if saved["command"] != foreign {
		t.Fatalf("saved %+v", saved)
	}
	if want := "\nprintf '%s' \"$input\" | " + foreign + "\n"; !strings.Contains(string(readBytes(t, env.script())), want) {
		t.Fatalf("script does not chain verbatim:\n%s", readBytes(t, env.script()))
	}
	if env.installer.Status() != HookInstalled || env.readSettings(t)["model"] != "sonnet" {
		t.Fatalf("settings %s", readBytes(t, env.settings))
	}
}

func TestUninstallRestoresForeignAndRemovesOurFiles(t *testing.T) {
	env := newInstallEnv(t)
	foreign := `my-hud --json '{"k":"v"}'`
	data, _ := json.Marshal(map[string]any{"statusLine": map[string]any{"type": "command", "command": foreign}})
	writeFile(t, env.settings, string(data))
	env.mustInstall(t)
	feedFile := writeSession(t, filepath.Join(env.feed, "sessions", "work"), "s", costJSON("s", 1), time.Now())

	env.mustUninstall(t)

	if env.statusLine(t)["command"] != foreign || env.installer.Status() != HookForeignStatusline {
		t.Fatalf("settings %s", readBytes(t, env.settings))
	}
	assertAbsent(t, env.original())
	assertAbsent(t, env.script())
	if _, err := os.Stat(feedFile); err != nil {
		t.Fatalf("sessions feed must survive uninstall: %v", err)
	}
}

func TestUninstallAfterFreshInstallRemovesTheKey(t *testing.T) {
	env := newInstallEnv(t)
	writeFile(t, env.settings, `{"model":"opus"}`)
	env.mustInstall(t)

	env.mustUninstall(t)

	values := env.readSettings(t)
	if _, present := values["statusLine"]; present || values["model"] != "opus" {
		t.Fatalf("values %+v", values)
	}
	if env.installer.Status() != HookNotInstalled {
		t.Fatalf("status %v", env.installer.Status())
	}
	assertAbsent(t, env.script())
}

func TestUninstallWithNothingInstalledCreatesNoSettings(t *testing.T) {
	env := newInstallEnv(t)
	env.mustUninstall(t)
	assertAbsent(t, env.settings)
}

func TestSettingsSurviveARoundTripValueForValue(t *testing.T) {
	env := newInstallEnv(t)
	writeFile(t, env.settings, `{
		"cleanupPeriodDays": 30, "ratio": 1.50, "huge": 12345678901234567890,
		"includeCoAuthoredBy": false, "nothing": null,
		"env": {"A": "1"},
		"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "a && b > c"}]}]}
	}`)

	env.mustInstall(t)
	env.mustUninstall(t)

	got := string(readBytes(t, env.settings))
	want := `{
  "cleanupPeriodDays": 30,
  "env": {
    "A": "1"
  },
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "command": "a && b > c",
            "type": "command"
          }
        ]
      }
    ]
  },
  "huge": 12345678901234567890,
  "includeCoAuthoredBy": false,
  "nothing": null,
  "ratio": 1.50
}
`
	if got != want {
		t.Fatalf("got:\n%s", got)
	}
}

func TestInstallWritesThroughSymlinkAndKeepsMode(t *testing.T) {
	env := newInstallEnv(t)
	shared := filepath.Join(env.root, "shared", "settings.json")
	writeFile(t, shared, `{"model":"opusplan"}`)
	if err := os.Chmod(shared, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(env.settings), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(shared, env.settings); err != nil {
		t.Fatal(err)
	}

	env.mustInstall(t)

	if dest, err := os.Readlink(env.settings); err != nil || dest != shared {
		t.Fatalf("link now %q, err %v", dest, err)
	}
	if !strings.Contains(string(readBytes(t, shared)), "aub-statusline") {
		t.Fatalf("shared file not updated: %s", readBytes(t, shared))
	}
	if info, _ := os.Stat(shared); info.Mode().Perm() != 0o600 {
		t.Fatalf("mode %v", info.Mode())
	}
	epochs := backupEpochs(t, env.settings)
	if len(epochs) != 1 {
		t.Fatalf("backups %v", epochs)
	}
	var backup string
	for epoch := range epochs {
		backup = fmt.Sprintf("%s.aub-backup-%d", env.settings, epoch)
	}
	if info, _ := os.Lstat(backup); !info.Mode().IsRegular() || string(readBytes(t, backup)) != `{"model":"opusplan"}` {
		t.Fatalf("backup must be a regular copy of the old content, mode %v", info.Mode())
	}
}

func TestDanglingSymlinkIsAnErrorAndNotReplaced(t *testing.T) {
	env := newInstallEnv(t)
	if err := os.MkdirAll(filepath.Dir(env.settings), 0o755); err != nil {
		t.Fatal(err)
	}
	gone := filepath.Join(env.root, "gone.json")
	if err := os.Symlink(gone, env.settings); err != nil {
		t.Fatal(err)
	}
	before := snapshotTree(t, env.root)

	if _, err := env.installer.Install(); err == nil {
		t.Fatal("install must refuse")
	}
	if err := env.installer.Uninstall(); err == nil {
		t.Fatal("uninstall must refuse")
	}
	if env.installer.Status() != HookUnreadable {
		t.Fatalf("status %v", env.installer.Status())
	}
	if after := snapshotTree(t, env.root); !reflect.DeepEqual(before, after) {
		t.Fatalf("wrote something:\n%v\n%v", before, after)
	}
}

func TestInstallPrunesBackupsToNewestThreeByNumericEpoch(t *testing.T) {
	env := newInstallEnv(t)
	writeFile(t, env.settings, `{"model":"opusplan"}`)
	// 999 sorts after 10000 as text, so a lexical sort would keep the wrong ones.
	for _, epoch := range []int{999, 1000, 2000, 10000} {
		writeFile(t, fmt.Sprintf("%s.aub-backup-%d", env.settings, epoch), `{}`)
	}
	unrelated := env.settings + ".aub-backup-notes"
	writeFile(t, unrelated, `keep`)
	started := int(time.Now().Unix())

	env.mustInstall(t)

	epochs := backupEpochs(t, env.settings)
	if len(epochs) != 3 || !epochs[2000] || !epochs[10000] {
		t.Fatalf("kept %v", epochs)
	}
	for epoch := range epochs {
		if epoch != 2000 && epoch != 10000 && epoch < started {
			t.Fatalf("kept %v, want the fresh backup", epochs)
		}
	}
	if _, err := os.Stat(unrelated); err != nil {
		t.Fatal("pruning must ignore files without a numeric epoch")
	}
}

func TestSlugTargetsInstallSideBySide(t *testing.T) {
	env := newInstallEnv(t)
	writeFile(t, env.settings, `{"model":"opusplan"}`)
	personalSettings := filepath.Join(env.root, ".ccs", "instances", "personal", "settings.json")
	personal := HookInstaller{env.feed, HookTarget{"personal", []string{"personal"}, personalSettings}}

	env.mustInstall(t)
	if _, err := personal.Install(); err != nil {
		t.Fatal(err)
	}

	personalScript := filepath.Join(env.feed, "aub-statusline-personal.sh")
	if !reflect.DeepEqual(readBytes(t, env.script()), readBytes(t, personalScript)) {
		t.Fatal("both scripts route at runtime and differ only by chain")
	}
	if env.installer.Status() != HookInstalled || personal.Status() != HookInstalled {
		t.Fatal("both slots must be wired")
	}

	if err := personal.Uninstall(); err != nil {
		t.Fatal(err)
	}
	if personal.Status() != HookNotInstalled || env.installer.Status() != HookInstalled {
		t.Fatalf("statuses %v %v", personal.Status(), env.installer.Status())
	}
	assertAbsent(t, personalScript)
	if _, err := os.Stat(env.script()); err != nil {
		t.Fatal("default script must stay")
	}
}

func TestStatusReportsEveryStateAndNeverWrites(t *testing.T) {
	cases := []struct {
		name, body string
		want       HookState
	}{
		{"no key", `{"model":"x"}`, HookNotInstalled},
		{"null key", `{"statusLine":null}`, HookNotInstalled},
		{"ours", `{"statusLine":{"type":"command","command":"sh '/x/aub-statusline-work.sh'"}}`, HookInstalled},
		{"foreign", `{"statusLine":{"type":"command","command":"omc-hud"}}`, HookForeignStatusline},
		{"foreign without command", `{"statusLine":{"type":"static"}}`, HookForeignStatusline},
		{"foreign non-object", `{"statusLine":"omc-hud"}`, HookForeignStatusline},
		{"malformed", `{"statusLine":`, HookUnreadable},
		{"non-object", `[1]`, HookUnreadable},
		{"null document", `null`, HookUnreadable},
		{"trailing data", `{} {}`, HookUnreadable},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			env := newInstallEnv(t)
			writeFile(t, env.settings, c.body)
			before := snapshotTree(t, env.root)
			if got := env.installer.Status(); got != c.want {
				t.Fatalf("status %v, want %v", got, c.want)
			}
			if after := snapshotTree(t, env.root); !reflect.DeepEqual(before, after) {
				t.Fatal("status wrote something")
			}
		})
	}
	if got := newInstallEnv(t).installer.Status(); got != HookNotInstalled {
		t.Fatalf("missing file: %v", got)
	}
}

func TestInstallRefusesANonObjectStatusLineItCannotChain(t *testing.T) {
	env := newInstallEnv(t)
	writeFile(t, env.settings, `{"statusLine":"omc-hud"}`)
	before := snapshotTree(t, env.root)
	if _, err := env.installer.Install(); err == nil {
		t.Fatal("install must refuse rather than lose the value")
	}
	if after := snapshotTree(t, env.root); !reflect.DeepEqual(before, after) {
		t.Fatal("wrote something")
	}
}

func TestUninstallLeavesAStatusLineSetAfterInstall(t *testing.T) {
	env := newInstallEnv(t)
	data, _ := json.Marshal(map[string]any{"statusLine": map[string]any{"type": "command", "command": "old-hud"}})
	writeFile(t, env.settings, string(data))
	env.mustInstall(t)
	newer := `{"statusLine":{"type":"command","command":"newer-hud"}}`
	writeFile(t, env.settings, newer)

	env.mustUninstall(t)

	if got := string(readBytes(t, env.settings)); got != newer {
		t.Fatalf("settings rewritten: %s", got)
	}
	assertAbsent(t, env.original())
	assertAbsent(t, env.script())
}

func TestInstallKeepsOtherStatusLineKeysAndUninstallRestoresVerbatim(t *testing.T) {
	env := newInstallEnv(t)
	writeFile(t, env.settings, `{"statusLine":{"type":"command","command":"omc-hud","padding":0,"ratio":1.50}}`)

	env.mustInstall(t)

	statusLine := env.statusLine(t)
	if statusLine["padding"] != float64(0) || statusLine["ratio"] != 1.5 || !strings.Contains(statusLine["command"].(string), "aub-statusline") {
		t.Fatalf("statusLine %+v", statusLine)
	}

	// The user edits padding on our statusLine. The saved one is what comes back.
	settings := string(readBytes(t, env.settings))
	writeFile(t, env.settings, strings.Replace(settings, `"padding": 0`, `"padding": 9`, 1))
	env.mustUninstall(t)

	want := "{\n  \"statusLine\": {\n    \"command\": \"omc-hud\",\n    \"padding\": 0,\n    \"ratio\": 1.50,\n    \"type\": \"command\"\n  }\n}\n"
	if got := string(readBytes(t, env.settings)); got != want {
		t.Fatalf("got:\n%s", got)
	}
}

func TestMalformedFilesAreErrorsThatWriteNothing(t *testing.T) {
	seeds := map[string]func(t *testing.T, env installEnv){
		"settings": func(t *testing.T, env installEnv) {
			writeFile(t, env.settings, `{"statusLine":`)
		},
		"settings non-object": func(t *testing.T, env installEnv) {
			writeFile(t, env.settings, `"text"`)
		},
		"backup with ours": func(t *testing.T, env installEnv) {
			writeFile(t, env.settings, `{"statusLine":{"type":"command","command":"sh '`+env.script()+`'"}}`)
			writeFile(t, env.original(), `{broken`)
		},
		"backup with foreign": func(t *testing.T, env installEnv) {
			writeFile(t, env.settings, `{"statusLine":{"type":"command","command":"omc-hud"}}`)
			writeFile(t, env.original(), `[1,2]`)
		},
	}
	for name, seed := range seeds {
		t.Run(name, func(t *testing.T) {
			env := newInstallEnv(t)
			seed(t, env)
			before := snapshotTree(t, env.root)
			if _, err := env.installer.Install(); err == nil {
				t.Fatal("install must refuse")
			}
			if err := env.installer.Uninstall(); err == nil {
				t.Fatal("uninstall must refuse")
			}
			if after := snapshotTree(t, env.root); !reflect.DeepEqual(before, after) {
				t.Fatalf("wrote something:\n%v\n%v", before, after)
			}
		})
	}
}

// Removing ccs instance "personal" makes discovery name the folded target "work", while the
// settings still run the "personal" script and the chain is saved under that name.
func TestInstalledCommandSlugWinsOverDiscovery(t *testing.T) {
	env := newInstallEnv(t)
	shared := filepath.Join(env.root, "shared", "settings.json")
	writeFile(t, shared, `{"statusLine":{"type":"command","command":"omc-hud"}}`)
	first := HookInstaller{env.feed, HookTarget{"personal", []string{"personal", "work"}, shared}}
	if _, err := first.Install(); err != nil {
		t.Fatal(err)
	}
	personalScript := filepath.Join(env.feed, "aub-statusline-personal.sh")
	personalOriginal := filepath.Join(env.feed, "original-statusline-personal.json")

	later := HookInstaller{env.feed, HookTarget{"work", []string{"work"}, shared}}
	chained, err := later.Install()
	if err != nil {
		t.Fatal(err)
	}
	if !chained || !strings.Contains(string(readBytes(t, personalScript)), "| omc-hud\n") {
		t.Fatalf("chain lost, chained=%v", chained)
	}
	assertAbsent(t, filepath.Join(env.feed, "aub-statusline-work.sh"))
	assertAbsent(t, filepath.Join(env.feed, "original-statusline-work.json"))

	if err := later.Uninstall(); err != nil {
		t.Fatal(err)
	}
	var values map[string]any
	if err := json.Unmarshal(readBytes(t, shared), &values); err != nil {
		t.Fatal(err)
	}
	if got := commandOf(values["statusLine"]); got != "omc-hud" {
		t.Fatalf("restored %q", got)
	}
	assertAbsent(t, personalScript)
	assertAbsent(t, personalOriginal)
}

func TestSwiftInstallKeepsItsNamesAndGainsSingleQuotes(t *testing.T) {
	env := newInstallEnv(t)
	personalSettings := filepath.Join(env.root, ".ccs", "instances", "personal", "settings.json")
	swiftCommand := `sh "` + env.script() + `"`
	data, _ := json.Marshal(map[string]any{"statusLine": map[string]any{"type": "command", "command": swiftCommand}})
	writeFile(t, personalSettings, string(data))
	writeFile(t, env.original(), `{"type":"command","command":"omc-hud"}`)
	installer := HookInstaller{env.feed, HookTarget{"personal", []string{"personal"}, personalSettings}}

	chained, err := installer.Install()
	if err != nil {
		t.Fatal(err)
	}
	if !chained || !strings.Contains(string(readBytes(t, env.script())), "| omc-hud\n") {
		t.Fatal("the Swift install's chain must survive")
	}
	var values map[string]any
	if err := json.Unmarshal(readBytes(t, personalSettings), &values); err != nil {
		t.Fatal(err)
	}
	if got := commandOf(values["statusLine"]); got != "sh '"+env.script()+"'" {
		t.Fatalf("command %q", got)
	}
}

func TestSlugFromCommand(t *testing.T) {
	cases := []struct {
		command, slug string
		ok            bool
	}{
		{`sh '/feed/aub-statusline.sh'`, "default", true},
		{`sh "/feed/aub-statusline.sh"`, "default", true},
		{`sh /feed/aub-statusline.sh`, "default", true},
		{`sh '/feed/aub-statusline-work.sh'`, "work", true},
		{`sh "/App Support/aub-statusline-work.sh"`, "work", true},
		{`sh '/feed/aub-statusline-a.shell.sh'`, "a.shell", true},
		{`sh '/feed/aub-statusline-it'\''s.sh'`, "it's", true},
		{`sh '/aub-statusline-dir/aub-statusline-work.sh'`, "work", true},
		{`sh '/aub-statusline-dir/hud.sh'`, "", false},
		{`aub-statusline-wrapper`, "", false},
		{`omc-hud`, "", false},
	}
	for _, c := range cases {
		if slug, ok := slugFromCommand(c.command); slug != c.slug || ok != c.ok {
			t.Errorf("%s: got %q %v", c.command, slug, ok)
		}
	}
}

func TestReinstallIsIdempotent(t *testing.T) {
	env := newInstallEnv(t)
	writeFile(t, env.settings, `{"statusLine":{"type":"command","command":"omc-hud"}}`)
	env.mustInstall(t)
	settingsBefore := readBytes(t, env.settings)
	backupsBefore := backupEpochs(t, env.settings)
	originalBefore := readBytes(t, env.original())
	past := time.Now().Add(-time.Hour).Truncate(time.Second)
	if err := os.Chtimes(env.settings, past, past); err != nil {
		t.Fatal(err)
	}
	scriptWanted := readBytes(t, env.script())
	writeFile(t, env.script(), "stale")

	if !env.mustInstall(t) {
		t.Fatal("chain must still be reported")
	}

	if got := readBytes(t, env.script()); string(got) != string(scriptWanted) {
		t.Fatalf("script not rewritten: %s", got)
	}
	info, err := os.Stat(env.settings)
	if err != nil {
		t.Fatal(err)
	}
	if !info.ModTime().Equal(past) {
		t.Fatalf("settings rewritten at %v", info.ModTime())
	}
	if string(readBytes(t, env.settings)) != string(settingsBefore) {
		t.Fatal("settings changed")
	}
	if !reflect.DeepEqual(backupEpochs(t, env.settings), backupsBefore) {
		t.Fatal("reinstall added a backup")
	}
	if string(readBytes(t, env.original())) != string(originalBefore) {
		t.Fatal("saved status line changed")
	}
}

func TestStatusLineFeedsTheReaderThroughRealShell(t *testing.T) {
	root := t.TempDir()
	dataDir := filepath.Join(root, "App Support", "it's")
	configDir := filepath.Join(root, ".ccs", "instances", "work")
	settingsPath := filepath.Join(configDir, "settings.json")

	captured := filepath.Join(root, "captured.json")
	hud := filepath.Join(root, "hud.sh")
	writeFile(t, hud, "cat > \"$1\"\necho 'hud: ok'\n")
	original := fmt.Sprintf(`sh '%s' '%s' && true`, hud, captured)
	data, _ := json.Marshal(map[string]any{"statusLine": map[string]any{"type": "command", "command": original, "padding": 0}})
	writeFile(t, settingsPath, string(data))

	feedDir := HookFeedDir(dataDir)
	installer := HookInstaller{feedDir, HookTarget{"work", []string{"work"}, settingsPath}}
	chained, err := installer.Install()
	if err != nil {
		t.Fatal(err)
	}
	if !chained {
		t.Fatal("install must report the chain")
	}

	if raw := string(readBytes(t, filepath.Join(feedDir, "original-statusline-work.json"))); !strings.Contains(raw, "&&") {
		t.Fatalf("saved status line escaped its command: %s", raw)
	}
	var settings map[string]any
	if err := json.Unmarshal(readBytes(t, settingsPath), &settings); err != nil {
		t.Fatal(err)
	}
	command := commandOf(settings["statusLine"])

	payload := `{"session_id":"sess-1","model":{"id":"claude-test","display_name":"Test"},` +
		`"cost":{"total_cost_usd":1.25},` +
		`"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1778600000},"seven_day":{"used_percentage":17,"resets_at":1779000000}}}`
	run := func(configDir string, stdin string) string {
		t.Helper()
		shell := exec.Command("sh", "-c", command)
		shell.Stdin = strings.NewReader(stdin)
		shell.Env = []string{"PATH=" + os.Getenv("PATH")}
		if configDir != "" {
			shell.Env = append(shell.Env, "CLAUDE_CONFIG_DIR="+configDir)
		}
		out, err := shell.CombinedOutput()
		if err != nil {
			t.Fatalf("status line failed: %v\n%s", err, out)
		}
		return string(out)
	}

	if out := run(configDir, payload); out != "hud: ok\n" {
		t.Fatalf("chained output %q", out)
	}
	if got := string(readBytes(t, captured)); got != payload {
		t.Fatalf("chained original got %q", got)
	}

	workFeed := filepath.Join(feedDir, "sessions", "work")
	children, err := os.ReadDir(workFeed)
	if err != nil {
		t.Fatal(err)
	}
	if len(children) != 1 || children[0].Name() != "sess-1.json" {
		t.Fatalf("feed dir holds %v, want only the session file", children)
	}
	feedFile := filepath.Join(workFeed, "sess-1.json")
	if err := os.Chtimes(feedFile, earlierToday, earlierToday); err != nil {
		t.Fatal(err)
	}

	built := Build(provider.Env{
		Paths: paths.Layout{Home: root, DataDir: dataDir}, DayKeys: testDayKeys(), Clock: clock.Fixed(testNow),
		Getenv: func(string) string { return "" },
	}).(*Provider)
	snapshot, err := built.hook.fetch(testNow)
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.Accounts) != 1 || snapshot.Accounts[0].Name != "work" {
		t.Fatalf("accounts %+v", snapshot.Accounts)
	}
	account := snapshot.Accounts[0]
	if account.Quota == nil || snapshot.Raw["quota.work"] != "42%" || account.CostTodayUSD == nil || account.CostTodayUSD.String() != "1.25" {
		t.Fatalf("account %+v raw %+v", account, snapshot.Raw)
	}
	if len(account.QuotaWindows) != 2 || account.QuotaWindows[0].Name != "5h" || account.QuotaWindows[1].Name != "7d" {
		t.Fatalf("windows %+v", account.QuotaWindows)
	}

	run("", `{"session_id":"sess-2"}`)
	if _, err := os.Stat(filepath.Join(feedDir, "sessions", "default", "sess-2.json")); err != nil {
		t.Fatalf("no CLAUDE_CONFIG_DIR routes to default: %v", err)
	}

	// No session id: nothing to file, and the chain still runs.
	if out := run(configDir, `{}`); out != "hud: ok\n" {
		t.Fatalf("chained output %q", out)
	}
}
