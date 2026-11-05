package cli

import (
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/providers/claude"
	"github.com/noomz/agents_usage_bar/cli/internal/settings"
)

func writeHookFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func (h *harness) claudeSettings() string {
	return filepath.Join(h.Layout.Home, ".claude", "settings.json")
}

func (h *harness) instanceSettings(slug string) string {
	return filepath.Join(h.Layout.Home, ".ccs", "instances", slug, "settings.json")
}

func TestParseHook(t *testing.T) {
	cases := []struct {
		args []string
		want Command
	}{
		{[]string{"hook"}, HookCmd{Verb: HookStatus}},
		{[]string{"hook", "status"}, HookCmd{Verb: HookStatus}},
		{[]string{"hook", "install"}, HookCmd{Verb: HookInstall}},
		{[]string{"hook", "uninstall"}, HookCmd{Verb: HookUninstall}},
	}
	for _, c := range cases {
		got, err := Parse(c.args)
		if err != nil || !reflect.DeepEqual(got, c.want) {
			t.Errorf("%v: got %#v, err %v", c.args, got, err)
		}
	}
	errors := []struct {
		args []string
		want string
	}{
		{[]string{"hook", "nope"}, unknownCommand("hook nope").Error()},
		{[]string{"hook", "install", "extra"}, unexpectedArgument("extra").Error()},
		{[]string{"hook", "status", "extra"}, unexpectedArgument("extra").Error()},
		{[]string{"hook", "--json"}, unexpectedArgument("--json").Error()},
	}
	for _, c := range errors {
		if _, err := Parse(c.args); err == nil || err.Error() != c.want {
			t.Errorf("%v: got %v", c.args, err)
		}
	}
}

func TestHookInstallWiresEveryTargetAndFlipsThePreference(t *testing.T) {
	h := newHarness(t)
	writeHookFile(t, h.claudeSettings(), `{"statusLine":{"type":"command","command":"omc-hud"}}`)
	writeHookFile(t, h.instanceSettings("work"), `{}`)

	out, errOut, code := h.run("hook", "install")

	if code != 0 || errOut != "" {
		t.Fatalf("code %d, stderr %q", code, errOut)
	}
	for _, want := range []string{
		"Installed " + h.claudeSettings() + " (accounts: default), chained the existing status line\n",
		"Installed " + h.instanceSettings("work") + " (accounts: work)\n",
		"claude-source=hook\n",
		"next Claude Code status line update",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in:\n%s", want, out)
		}
	}
	if h.store[settings.KeyClaudeSource] != "hook" {
		t.Fatalf("preference %v", h.store[settings.KeyClaudeSource])
	}
	if h.preferences().ClaudeSource != "hook" {
		t.Fatal("the provider must see hook mode")
	}
	for _, script := range []string{"aub-statusline.sh", "aub-statusline-work.sh"} {
		if _, err := os.Stat(filepath.Join(h.Layout.DataDir, "claude-hook", script)); err != nil {
			t.Error(err)
		}
	}
}

func snapshotHookTree(t *testing.T, h *harness) map[string]string {
	t.Helper()
	tree := map[string]string{}
	err := filepath.WalkDir(h.Layout.Home, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		tree[path] = d.Type().String()
		if d.Type().IsRegular() {
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			tree[path] += ":" + string(data)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return tree
}

func TestHookInstallRefusalWritesNothingOnAnyTarget(t *testing.T) {
	h := newHarness(t)
	h.store[settings.KeyClaudeSource] = "sessionReads"
	writeHookFile(t, h.claudeSettings(), `{"statusLine":{"type":"command","command":"omc-hud"}}`)
	writeHookFile(t, h.instanceSettings("a-first"), `{}`)
	writeHookFile(t, h.instanceSettings("broken"), `{not json`)
	writeHookFile(t, h.instanceSettings("work"), `{}`)
	before := snapshotHookTree(t, h)

	_, errOut, code := h.run("hook", "install")

	if code != 1 || !strings.Contains(errOut, h.instanceSettings("broken")) {
		t.Fatalf("code %d, stderr %q", code, errOut)
	}
	if h.store[settings.KeyClaudeSource] != "sessionReads" {
		t.Fatalf("preference flipped to %v", h.store[settings.KeyClaudeSource])
	}
	if after := snapshotHookTree(t, h); !reflect.DeepEqual(before, after) {
		t.Fatalf("a refusal wrote something:\n%v\n%v", before, after)
	}
}

func TestHookUninstallRefusalWritesNothingOnAnyTarget(t *testing.T) {
	h := newHarness(t)
	writeHookFile(t, h.claudeSettings(), `{"statusLine":{"type":"command","command":"omc-hud"}}`)
	writeHookFile(t, h.instanceSettings("work"), `{"statusLine":{"type":"command","command":"work-hud"}}`)
	if _, errOut, code := h.run("hook", "install"); code != 0 {
		t.Fatal(errOut)
	}
	writeHookFile(t, h.instanceSettings("zz-broken"), `{not json`)
	before := snapshotHookTree(t, h)

	_, errOut, code := h.run("hook", "uninstall")

	if code != 1 || !strings.Contains(errOut, h.instanceSettings("zz-broken")) {
		t.Fatalf("code %d, stderr %q", code, errOut)
	}
	if h.store[settings.KeyClaudeSource] != "hook" {
		t.Fatalf("preference flipped to %v", h.store[settings.KeyClaudeSource])
	}
	if after := snapshotHookTree(t, h); !reflect.DeepEqual(before, after) {
		t.Fatalf("a refusal wrote something:\n%v\n%v", before, after)
	}
}

func statusLineJSON(command string) string {
	data, _ := json.Marshal(map[string]any{"statusLine": map[string]any{"type": "command", "command": command}})
	return string(data)
}

func TestHookRefusesTwoTargetsSharingFilesUnlessBothAreOurs(t *testing.T) {
	feedScript := func(h *harness) string {
		return filepath.Join(claude.HookFeedDir(h.Layout.DataDir), "aub-statusline.sh")
	}
	cases := map[string]func(h *harness) (string, string){
		"instance named default, both foreign": func(h *harness) (string, string) {
			writeHookFile(t, h.claudeSettings(), statusLineJSON("hud-a"))
			writeHookFile(t, h.instanceSettings("default"), statusLineJSON("hud-b"))
			return h.claudeSettings(), h.instanceSettings("default")
		},
		"instance named default, one empty": func(h *harness) (string, string) {
			writeHookFile(t, h.claudeSettings(), statusLineJSON("hud-a"))
			writeHookFile(t, h.instanceSettings("default"), `{}`)
			return h.claudeSettings(), h.instanceSettings("default")
		},
		"copied settings beside a foreign slot": func(h *harness) (string, string) {
			writeHookFile(t, h.claudeSettings(), statusLineJSON("newer-hud"))
			writeHookFile(t, h.instanceSettings("copy"), statusLineJSON("sh '"+feedScript(h)+"'"))
			writeHookFile(t, filepath.Join(claude.HookFeedDir(h.Layout.DataDir), "original-statusline.json"), statusLineJSON("old-hud"))
			return h.claudeSettings(), h.instanceSettings("copy")
		},
	}
	for name, seed := range cases {
		t.Run(name, func(t *testing.T) {
			for _, verb := range []string{"install", "uninstall"} {
				h := newHarness(t)
				first, second := seed(h)
				before := snapshotHookTree(t, h)

				_, errOut, code := h.run("hook", verb)

				if code != 1 {
					t.Fatalf("%s: code %d", verb, code)
				}
				for _, want := range []string{first, second, feedScript(h)} {
					if !strings.Contains(errOut, want) {
						t.Errorf("%s: stderr %q does not name %s", verb, errOut, want)
					}
				}
				if after := snapshotHookTree(t, h); !reflect.DeepEqual(before, after) {
					t.Fatalf("%s wrote something:\n%v\n%v", verb, before, after)
				}
				if len(h.store) != 0 {
					t.Fatalf("%s wrote a setting: %v", verb, h.store)
				}
			}
		})
	}
}

func TestHookUninstallRestoresEveryCopyOfASharedSlot(t *testing.T) {
	h := newHarness(t)
	writeHookFile(t, h.claudeSettings(), statusLineJSON("omc-hud"))
	if _, errOut, code := h.run("hook", "install"); code != 0 {
		t.Fatal(errOut)
	}
	installed, err := os.ReadFile(h.claudeSettings())
	if err != nil {
		t.Fatal(err)
	}
	writeHookFile(t, h.instanceSettings("copy"), string(installed))

	if _, errOut, code := h.run("hook", "uninstall"); code != 0 {
		t.Fatal(errOut)
	}

	for _, path := range []string{h.claudeSettings(), h.instanceSettings("copy")} {
		restored, _ := os.ReadFile(path)
		if !strings.Contains(string(restored), `"command": "omc-hud"`) {
			t.Errorf("%s: %s", path, restored)
		}
	}
}

func TestHookUninstallRestoresAndResetsThePreference(t *testing.T) {
	h := newHarness(t)
	writeHookFile(t, h.claudeSettings(), `{"statusLine":{"type":"command","command":"omc-hud"}}`)
	if _, errOut, code := h.run("hook", "install"); code != 0 {
		t.Fatal(errOut)
	}

	out, errOut, code := h.run("hook", "uninstall")

	if code != 0 || !strings.Contains(out, "claude-source=sessionReads\n") {
		t.Fatalf("code %d, out %q, stderr %q", code, out, errOut)
	}
	if h.store[settings.KeyClaudeSource] != "sessionReads" {
		t.Fatalf("preference %v", h.store[settings.KeyClaudeSource])
	}
	restored, _ := os.ReadFile(h.claudeSettings())
	if !strings.Contains(string(restored), "omc-hud") || strings.Contains(string(restored), "aub-statusline") {
		t.Fatalf("settings %s", restored)
	}
}

func TestHookUninstallFailureLeavesThePreference(t *testing.T) {
	h := newHarness(t)
	h.store[settings.KeyClaudeSource] = "hook"
	writeHookFile(t, h.claudeSettings(), `{not json`)

	if _, _, code := h.run("hook", "uninstall"); code != 1 {
		t.Fatalf("code %d", code)
	}
	if h.store[settings.KeyClaudeSource] != "hook" {
		t.Fatalf("preference %v", h.store[settings.KeyClaudeSource])
	}
}

func TestHookStatusPrintsStateWithoutWriting(t *testing.T) {
	h := newHarness(t)
	writeHookFile(t, h.claudeSettings(), `{"statusLine":{"type":"command","command":"omc-hud"}}`)
	writeHookFile(t, h.instanceSettings("broken"), `{not json`)
	shared := filepath.Join(h.Layout.Home, ".ccs", "shared", "settings.json")
	writeHookFile(t, shared, `{"statusLine":{"type":"command","command":"sh '/x/aub-statusline-personal.sh'"}}`)
	for _, slug := range []string{"personal", "work"} {
		if err := os.MkdirAll(filepath.Dir(h.instanceSettings(slug)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(shared, h.instanceSettings(slug)); err != nil {
			t.Fatal(err)
		}
	}
	feed := filepath.Join(h.Layout.DataDir, "claude-hook", "sessions")
	session := filepath.Join(feed, "work", "s.json")
	writeHookFile(t, session, `{"session_id":"s"}`)
	expired := filepath.Join(feed, "default", "old.json")
	writeHookFile(t, expired, `{"session_id":"old"}`)
	now := h.Clock.Now()
	if err := os.Chtimes(session, now.Add(-5*time.Minute), now.Add(-5*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(expired, now.Add(-72*time.Hour), now.Add(-72*time.Hour)); err != nil {
		t.Fatal(err)
	}

	for _, args := range [][]string{{"hook"}, {"hook", "status"}} {
		out, errOut, code := h.run(args...)
		if code != 0 || errOut != "" {
			t.Fatalf("code %d, stderr %q", code, errOut)
		}
		want := "claude-source=sessionReads\n" +
			"default: foreign status line  " + h.claudeSettings() + "\n" +
			"broken: unreadable  " + h.instanceSettings("broken") + "\n" +
			"personal, work: installed  " + h.instanceSettings("personal") + "\n" +
			"feed default: updated 3d ago\n" +
			"feed work: updated 5m ago\n"
		if out != want {
			t.Fatalf("got:\n%s\nwant:\n%s", out, want)
		}
	}
	if _, err := os.Stat(expired); err != nil {
		t.Fatal("status must not prune the feed")
	}
	if len(h.store) != 0 {
		t.Fatalf("status wrote a setting: %v", h.store)
	}
	if _, err := os.Stat(filepath.Join(h.Layout.DataDir, "claude-hook", "aub-statusline.sh")); !os.IsNotExist(err) {
		t.Fatal("status must not write a script")
	}
}

func TestHookStatusWithoutFeedSaysSo(t *testing.T) {
	h := newHarness(t)
	out, _, code := h.run("hook")
	if code != 0 || !strings.Contains(out, "default: not installed") || !strings.Contains(out, "feed: no data yet\n") {
		t.Fatalf("code %d, out:\n%s", code, out)
	}
}

func TestHelpListsHook(t *testing.T) {
	h := newHarness(t)
	out, _, _ := h.run("help")
	for _, want := range []string{"aub hook [status]", "aub hook install", "aub hook uninstall"} {
		if !strings.Contains(out, want) {
			t.Errorf("help is missing %q", want)
		}
	}
}
