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
	return installEnv{root, settings, feed, oneTarget(feed, "default", settings)}
}

func oneTarget(feed, slug, settings string) HookInstaller {
	return HookInstaller{feed, []HookTarget{{slug, []string{slug}, settings}}}
}

func statusOf(i HookInstaller) HookState { return i.Status(i.Targets[0]) }

func installOne(t *testing.T, i HookInstaller) bool {
	t.Helper()
	installations, err := i.Install()
	if err != nil {
		t.Fatal(err)
	}
	return installations[0].Chained
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
	return installOne(t, e.installer)
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

func runScript(t *testing.T, shell, script, stdin string, env ...string) string {
	t.Helper()
	command := exec.Command(shell, script)
	command.Stdin = strings.NewReader(stdin)
	command.Env = append([]string{"PATH=" + os.Getenv("PATH")}, env...)
	out, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("%s %s: %v\n%s", shell, script, err, out)
	}
	return string(out)
}

func TestChainGivesTheWholeOriginalTheInput(t *testing.T) {
	const payload = "{\"session_id\":\"s1\"}"
	cases := []struct{ name, original, want string }{
		{"reads a line", `read -r l; echo "$l"`, payload + "\n"},
		{"second command reads", `echo x; cat`, "x\n" + payload},
		{"multi-line", "x=1\necho \"$x:$(cat)\"", "1:" + payload + "\n"},
		{"plain pipeline", `cat | tr 1 2`, "{\"session_id\":\"s2\"}"},
		{"trailing comment", `cat # a note`, payload},
	}
	shells := []string{"sh"}
	if _, err := exec.LookPath("dash"); err == nil {
		shells = append(shells, "dash")
	}
	for _, shell := range shells {
		for _, c := range cases {
			t.Run(shell+"/"+c.name, func(t *testing.T) {
				dir := t.TempDir()
				script := filepath.Join(dir, "tee.sh")
				writeFile(t, script, hookScript(filepath.Join(dir, "sessions"), c.original))
				if got := runScript(t, shell, script, payload); got != c.want {
					t.Fatalf("got %q, want %q", got, c.want)
				}
			})
		}
		t.Run(shell+"/config dir form", func(t *testing.T) {
			dir := t.TempDir()
			config := filepath.Join(dir, "instance")
			writeFile(t, filepath.Join(config, "hud", "hud.sh"), `echo "$1 $(cat)"`+"\n")
			script := filepath.Join(dir, "tee.sh")
			writeFile(t, script, hookScript(filepath.Join(dir, "sessions"), `sh ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hud/hud.sh arg`))
			if got := runScript(t, shell, script, payload, "CLAUDE_CONFIG_DIR="+config); got != "arg "+payload+"\n" {
				t.Fatalf("got %q", got)
			}
		})
	}
}

func TestInstallFreshWiresStatusLineAndKeepsOtherKeys(t *testing.T) {
	env := newInstallEnv(t)
	writeFile(t, env.settings, `{"model":"opusplan","env":{"FOO":"bar"},"permissions":{"allow":["Bash"]}}`)

	if env.mustInstall(t) {
		t.Fatal("nothing to chain on a fresh install")
	}

	if statusOf(env.installer) != HookInstalled {
		t.Fatalf("status %v", statusOf(env.installer))
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
			if statusOf(env.installer) != HookInstalled {
				t.Fatalf("status %v", statusOf(env.installer))
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
	if statusOf(env.installer) != HookForeignStatusline {
		t.Fatalf("status %v", statusOf(env.installer))
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
	if got := runScript(t, "sh", env.script(), "{}", "USER=me"); got != "hud: me\n" {
		t.Fatalf("chained output %q", got)
	}
	if statusOf(env.installer) != HookInstalled || env.readSettings(t)["model"] != "sonnet" {
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

	if env.statusLine(t)["command"] != foreign || statusOf(env.installer) != HookForeignStatusline {
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
	if statusOf(env.installer) != HookNotInstalled {
		t.Fatalf("status %v", statusOf(env.installer))
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
	if statusOf(env.installer) != HookUnreadable {
		t.Fatalf("status %v", statusOf(env.installer))
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
	personal := oneTarget(env.feed, "personal", personalSettings)

	env.mustInstall(t)
	installOne(t, personal)

	personalScript := filepath.Join(env.feed, "aub-statusline-personal.sh")
	if !reflect.DeepEqual(readBytes(t, env.script()), readBytes(t, personalScript)) {
		t.Fatal("both scripts route at runtime and differ only by chain")
	}
	if statusOf(env.installer) != HookInstalled || statusOf(personal) != HookInstalled {
		t.Fatal("both slots must be wired")
	}

	if err := personal.Uninstall(); err != nil {
		t.Fatal(err)
	}
	if statusOf(personal) != HookNotInstalled || statusOf(env.installer) != HookInstalled {
		t.Fatalf("statuses %v %v", statusOf(personal), statusOf(env.installer))
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
			if got := statusOf(env.installer); got != c.want {
				t.Fatalf("status %v, want %v", got, c.want)
			}
			if after := snapshotTree(t, env.root); !reflect.DeepEqual(before, after) {
				t.Fatal("status wrote something")
			}
		})
	}
	if got := statusOf(newInstallEnv(t).installer); got != HookNotInstalled {
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
		"empty backup with ours": func(t *testing.T, env installEnv) {
			writeFile(t, env.settings, `{"statusLine":{"type":"command","command":"sh '`+env.script()+`'"}}`)
			writeFile(t, env.original(), " \n")
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
	writeFile(t, shared, `{"statusLine":{"type":"command","command":"echo hud"}}`)
	first := HookInstaller{env.feed, []HookTarget{{"personal", []string{"personal", "work"}, shared}}}
	installOne(t, first)
	personalScript := filepath.Join(env.feed, "aub-statusline-personal.sh")
	personalOriginal := filepath.Join(env.feed, "original-statusline-personal.json")

	later := oneTarget(env.feed, "work", shared)
	if !installOne(t, later) || runScript(t, "sh", personalScript, "{}") != "hud\n" {
		t.Fatal("chain lost")
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
	if got := commandOf(values["statusLine"]); got != "echo hud" {
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
	writeFile(t, env.original(), `{"type":"command","command":"echo hud"}`)
	installer := oneTarget(env.feed, "personal", personalSettings)

	if !installOne(t, installer) || runScript(t, "sh", env.script(), "{}") != "hud\n" {
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

func TestOwnCommandIsAWholeCommandMatch(t *testing.T) {
	cases := []struct {
		command, path, slug string
		ok                  bool
	}{
		{`sh '/feed/aub-statusline.sh'`, "/feed/aub-statusline.sh", "default", true},
		{`sh "/feed/aub-statusline.sh"`, "/feed/aub-statusline.sh", "default", true},
		{`sh /feed/aub-statusline.sh`, "/feed/aub-statusline.sh", "default", true},
		{`sh '/feed/aub-statusline-work.sh'`, "/feed/aub-statusline-work.sh", "work", true},
		{`sh "/App Support/aub-statusline-work.sh"`, "/App Support/aub-statusline-work.sh", "work", true},
		{`sh '/feed/aub-statusline-a.shell.sh'`, "/feed/aub-statusline-a.shell.sh", "a.shell", true},
		{`sh '/feed/aub-statusline-it'\''s.sh'`, "/feed/aub-statusline-it's.sh", "it's", true},
		{`sh '/aub-statusline-dir/aub-statusline-work.sh'`, "/aub-statusline-dir/aub-statusline-work.sh", "work", true},
		{`sh '/aub-statusline-dir/hud.sh'`, "", "", false},
		{`sh '/x/aub-statusline.sh' | my-prefix`, "", "", false},
		{`sh /x/aub-statusline.sh; other`, "", "", false},
		{`sh '/x/aub-statusline.sh' 'second'`, "", "", false},
		{`sh ~/aub-statusline-tools/hud.sh`, "", "", false},
		{`sh "$(hud)/aub-statusline.sh"`, "", "", false},
		{`sh /x/aub-statusline-.sh`, "", "", false},
		{`bash /x/aub-statusline.sh`, "", "", false},
		{`aub-statusline-wrapper`, "", "", false},
		{`omc-hud`, "", "", false},
		{``, "", "", false},
	}
	for _, c := range cases {
		own, ok := parseOwnCommand(c.command)
		if own.scriptPath != c.path || own.slug != c.slug || ok != c.ok {
			t.Errorf("%s: got %+v %v", c.command, own, ok)
		}
	}
}

func TestStatusLinesThatOnlyMentionTheMarkerSurviveARoundTrip(t *testing.T) {
	for _, foreign := range []string{`sh '/x/aub-statusline.sh' | my-prefix`, `sh ~/aub-statusline-tools/hud.sh`} {
		t.Run(foreign, func(t *testing.T) {
			env := newInstallEnv(t)
			data, _ := json.Marshal(map[string]any{"statusLine": map[string]any{"type": "command", "command": foreign}})
			writeFile(t, env.settings, string(data))
			if statusOf(env.installer) != HookForeignStatusline {
				t.Fatalf("status %v", statusOf(env.installer))
			}

			if !env.mustInstall(t) {
				t.Fatal("a foreign status line must be chained")
			}
			env.mustUninstall(t)

			if got := env.statusLine(t)["command"]; got != foreign {
				t.Fatalf("restored %q", got)
			}
		})
	}
}

func TestStatusLineRunningOurOwnScriptIsRefused(t *testing.T) {
	env := newInstallEnv(t)
	rel := filepath.Join(filepath.Base(filepath.Dir(env.feed)), filepath.Base(env.feed))
	for _, command := range []string{
		`sh '` + env.script() + `' | my-prefix`,
		`sh "$HOME/` + rel + `/aub-statusline-work.sh" | my-prefix`,
	} {
		t.Run(command, func(t *testing.T) {
			data, _ := json.Marshal(map[string]any{"statusLine": map[string]any{"type": "command", "command": command}})
			writeFile(t, env.settings, string(data))
			before := snapshotTree(t, env.root)
			if _, err := env.installer.Install(); err == nil {
				t.Fatal("install must refuse to chain our own script")
			}
			if err := env.installer.Uninstall(); err == nil {
				t.Fatal("uninstall must refuse to delete a script the status line runs")
			}
			if after := snapshotTree(t, env.root); !reflect.DeepEqual(before, after) {
				t.Fatal("wrote something")
			}
		})
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

func TestParseChainReadsEveryFormItEmits(t *testing.T) {
	for _, command := range []string{"omc-hud", "a; b", "x=1\necho \"$x\"", "{ grouped; }"} {
		got, err := parseChain(hookScript("/feed/sessions", command))
		if err != nil || got != command {
			t.Errorf("%q: got %q, err %v", command, got, err)
		}
	}
	got, err := parseChain("#!/bin/sh\n" + chainMarker + "\n" + chainPrefix + "swift-hud --flag\n")
	if err != nil || got != "swift-hud --flag" {
		t.Errorf("Swift form: got %q, err %v", got, err)
	}
	if got, err := parseChain(hookScript("/feed/sessions", "")); err != nil || got != "" {
		t.Errorf("no chain: got %q, err %v", got, err)
	}
	for name, script := range map[string]string{
		"marker last":   "#!/bin/sh\n" + chainMarker,
		"no prefix":     "#!/bin/sh\n" + chainMarker + "\nomc-hud\n",
		"empty command": "#!/bin/sh\n" + chainMarker + "\n" + chainPrefix + "\n",
		"open brace":    "#!/bin/sh\n" + chainMarker + "\n" + chainPrefix + "{\nomc-hud\n",
		"empty braces":  "#!/bin/sh\n" + chainMarker + "\n" + chainPrefix + "{\n\n}\n",
	} {
		if got, err := parseChain(script); err == nil {
			t.Errorf("%s: must refuse, got %q", name, got)
		}
	}
}

func TestOursWithoutASavedFileRecoversOrProceeds(t *testing.T) {
	ours := func(env installEnv) string {
		return `{"statusLine":{"type":"command","padding":2,"command":"sh \"` + env.script() + `\""}}`
	}
	t.Run("script without a chain has no original", func(t *testing.T) {
		env := newInstallEnv(t)
		writeFile(t, env.settings, ours(env))
		writeFile(t, env.script(), hookScript(filepath.Join(env.feed, "sessions"), ""))
		if env.mustInstall(t) {
			t.Fatal("nothing to chain")
		}
		assertAbsent(t, env.original())
		env.mustUninstall(t)
		if _, present := env.readSettings(t)["statusLine"]; present {
			t.Fatalf("settings %s", readBytes(t, env.settings))
		}
	})
	t.Run("missing script is repaired without a chain", func(t *testing.T) {
		env := newInstallEnv(t)
		writeFile(t, env.settings, ours(env))
		if env.mustInstall(t) {
			t.Fatal("nothing to chain")
		}
		if _, err := os.Stat(env.script()); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("marker with an unreadable body refuses", func(t *testing.T) {
		env := newInstallEnv(t)
		writeFile(t, env.settings, ours(env))
		writeFile(t, env.script(), "#!/bin/sh\n"+chainMarker+"\nomc-hud\n")
		before := snapshotTree(t, env.root)
		if _, err := env.installer.Install(); err == nil {
			t.Fatal("install must refuse")
		}
		if err := env.installer.Uninstall(); err == nil {
			t.Fatal("uninstall must refuse")
		}
		if after := snapshotTree(t, env.root); !reflect.DeepEqual(before, after) {
			t.Fatal("wrote something")
		}
	})
	t.Run("recovered original keeps the other keys and is saved", func(t *testing.T) {
		env := newInstallEnv(t)
		writeFile(t, env.settings, ours(env))
		writeFile(t, env.script(), hookScript(filepath.Join(env.feed, "sessions"), "a\nb"))
		if !env.mustInstall(t) {
			t.Fatal("install must report the chain")
		}
		var saved map[string]any
		if err := json.Unmarshal(readBytes(t, env.original()), &saved); err != nil {
			t.Fatal(err)
		}
		if saved["command"] != "a\nb" || saved["padding"] != float64(2) {
			t.Fatalf("saved %+v", saved)
		}
	})
	t.Run("script named by the command is read when it is outside the feed", func(t *testing.T) {
		env := newInstallEnv(t)
		elsewhere := filepath.Join(env.root, "old-feed", "aub-statusline.sh")
		writeFile(t, env.settings, `{"statusLine":{"type":"command","command":"sh '`+elsewhere+`'"}}`)
		writeFile(t, elsewhere, hookScript(filepath.Join(env.root, "sessions"), "echo hud"))
		if !env.mustInstall(t) || runScript(t, "sh", env.script(), "{}") != "hud\n" {
			t.Fatal("chain lost")
		}
	})
}

func TestSessionIDCannotEscapeTheFeed(t *testing.T) {
	for _, id := range []string{"../../evil", "/../../original-statusline", "a/b"} {
		t.Run(id, func(t *testing.T) {
			root := t.TempDir()
			feed := filepath.Join(root, "claude-hook")
			saved := filepath.Join(feed, "original-statusline.json")
			writeFile(t, saved, `{"type":"command","command":"omc-hud"}`)
			script := filepath.Join(feed, "aub-statusline.sh")
			writeFile(t, script, hookScript(hookSessionsDir(feed), "echo hud"))
			before := snapshotTree(t, root)

			out := runScript(t, "sh", script, `{"session_id":"`+id+`"}`)

			if out != "hud\n" {
				t.Fatalf("chain must still run, got %q", out)
			}
			if after := snapshotTree(t, root); !reflect.DeepEqual(before, after) {
				t.Fatalf("wrote something:\n%v\n%v", before, after)
			}
		})
	}
}

func TestStatusLineFeedsTheReaderThroughRealShell(t *testing.T) {
	root := t.TempDir()
	dataDir := filepath.Join(root, "App Support", "it's $HOME")
	configDir := filepath.Join(root, ".ccs", "instances", "work")
	settingsPath := filepath.Join(configDir, "settings.json")

	captured := filepath.Join(root, "captured.json")
	hud := filepath.Join(root, "hud.sh")
	writeFile(t, hud, "cat > \"$1\"\necho 'hud: ok'\n")
	original := fmt.Sprintf(`sh '%s' '%s' && true`, hud, captured)
	data, _ := json.Marshal(map[string]any{"statusLine": map[string]any{"type": "command", "command": original, "padding": 0}})
	writeFile(t, settingsPath, string(data))

	feedDir := HookFeedDir(dataDir)
	installer := oneTarget(feedDir, "work", settingsPath)
	if !installOne(t, installer) {
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
