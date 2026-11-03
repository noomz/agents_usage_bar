package provider

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/noomz/agents_usage_bar/cli/internal/config"
)

func procArgsBuffer(argc int32, rest string) []byte {
	return append(binary.NativeEndian.AppendUint32(nil, uint32(argc)), rest...)
}

func TestParseProcArgs(t *testing.T) {
	for _, tc := range []struct {
		name string
		buf  []byte
		want []string
	}{
		{"empty", nil, nil},
		{"header only", procArgsBuffer(1, ""), nil},
		{"zero argc", procArgsBuffer(0, "/bin/x\x00\x00a\x00"), nil},
		{"negative argc", procArgsBuffer(-1, "/bin/x\x00\x00a\x00"), nil},
		{"padding then argv", procArgsBuffer(3, "/bin/x\x00\x00\x00\x00x\x00--port\x008123\x00KEY=value\x00"), []string{"x", "--port", "8123"}},
		{"path with spaces", procArgsBuffer(2, "/A B/x\x00/A B/x\x00--port=1\x00"), []string{"/A B/x", "--port=1"}},
		{"empty argument dropped", procArgsBuffer(3, "/x\x00x\x00\x00y\x00"), []string{"x", "y"}},
		{"truncated", procArgsBuffer(5, "/x\x00a\x00b"), []string{"a", "b"}},
	} {
		if got := parseProcArgs(tc.buf); !reflect.DeepEqual(got, tc.want) {
			t.Errorf("%s: %q want %q", tc.name, got, tc.want)
		}
	}
}

func TestProcProcesses(t *testing.T) {
	root := t.TempDir()
	write := func(pid, exe, cmdline string) {
		dir := filepath.Join(root, pid)
		if err := os.Mkdir(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if exe != "" {
			if err := os.Symlink(exe, filepath.Join(dir, "exe")); err != nil {
				t.Fatal(err)
			}
		}
		if err := os.WriteFile(filepath.Join(dir, "cmdline"), []byte(cmdline), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("10", "/opt/llama-server", "llama-server\x00--port\x008123\x00")
	write("11", "", "/srv/llama-server\x00--port=9000\x00")
	write("12", "", "")
	write("13", "/bin/idle", "")
	if err := os.Mkdir(filepath.Join(root, "self-not-a-pid"), 0o755); err != nil {
		t.Fatal(err)
	}
	want := []RunningProcess{
		{10, "/opt/llama-server", []string{"llama-server", "--port", "8123"}},
		{11, "/srv/llama-server", []string{"/srv/llama-server", "--port=9000"}},
		{13, "/bin/idle", nil},
	}
	if got := procProcesses(root); !reflect.DeepEqual(got, want) {
		t.Errorf("%+v\nwant %+v", got, want)
	}
	if got := procProcesses(filepath.Join(root, "missing")); got != nil {
		t.Errorf("missing root: %v", got)
	}
}

func TestSystemCatalogFindsThisProcess(t *testing.T) {
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	for _, p := range (SystemCatalog{}).Processes() {
		if p.PID != os.Getpid() {
			continue
		}
		if p.ExecutablePath != exe {
			t.Errorf("path %q want %q", p.ExecutablePath, exe)
		}
		if !reflect.DeepEqual(p.Arguments, os.Args) {
			t.Errorf("args %q want %q", p.Arguments, os.Args)
		}
		return
	}
	t.Error("this process is not listed")
}

func TestPortFromArguments(t *testing.T) {
	for _, tc := range []struct {
		args []string
		want int
	}{
		{[]string{"llama-server", "--port", "8123"}, 8123},
		{[]string{"llama-server", "--port=9000"}, 9000},
		{[]string{"llama-server", "--port", "0"}, 0},
		{[]string{"llama-server", "--port=70000"}, 0},
		{[]string{"llama-server", "--port"}, 0},
		{[]string{"llama-server"}, 0},
	} {
		got := 0
		if p := PortFromArguments(tc.args); p != nil {
			got = *p
		}
		if got != tc.want {
			t.Errorf("%v: %d want %d", tc.args, got, tc.want)
		}
	}
}

func TestResolveEnginePort(t *testing.T) {
	match, explicit := "/.lmstudio/extensions/backends/", 8124
	sidecar := RunningProcess{1, "/u/.lmstudio/extensions/backends/llama-server", []string{"llama-server", "--port", "8123"}}
	brew := RunningProcess{2, "/opt/homebrew/bin/llama-server", []string{"llama-server", "--port", "8123"}}
	noPort := RunningProcess{3, "/u/.lmstudio/extensions/backends/llama-server", []string{"llama-server"}}
	for _, tc := range []struct {
		name      string
		engine    config.LocalEngine
		processes []RunningProcess
		reserved  map[int]bool
		want      int
	}{
		{"argv port of the matching process", config.LocalEngine{MatchPath: &match}, []RunningProcess{sidecar}, nil, 8123},
		{"reserved port skipped", config.LocalEngine{MatchPath: &match}, []RunningProcess{sidecar}, map[int]bool{8123: true}, 0},
		{"another binary ignored", config.LocalEngine{MatchPath: &match}, []RunningProcess{brew}, nil, 0},
		{"explicit port without a process", config.LocalEngine{MatchPath: &match, Port: &explicit}, nil, nil, 8124},
		{"explicit port for a process without --port", config.LocalEngine{MatchPath: &match, Port: &explicit}, []RunningProcess{noPort}, nil, 8124},
		{"reserved explicit port", config.LocalEngine{Port: &explicit}, nil, map[int]bool{8124: true}, 0},
	} {
		got := 0
		if p := ResolveEnginePort(tc.engine, tc.processes, tc.reserved); p != nil {
			got = *p
		}
		if got != tc.want {
			t.Errorf("%s: %d want %d", tc.name, got, tc.want)
		}
	}
}
