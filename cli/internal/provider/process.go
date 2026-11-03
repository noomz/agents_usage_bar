package provider

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"github.com/noomz/agents_usage_bar/cli/internal/config"
)

// RunningProcess is enough identity to classify a local LLM engine.
type RunningProcess struct {
	PID            int
	ExecutablePath string
	Arguments      []string
}

// ProcessCatalog lists processes. Tests inject a fixed list.
type ProcessCatalog interface {
	Processes() []RunningProcess
}

// StaticCatalog is a fixed list.
type StaticCatalog []RunningProcess

// Processes implements ProcessCatalog.
func (s StaticCatalog) Processes() []RunningProcess { return s }

// SystemCatalog reads /proc where it exists and `ps` otherwise. Unreadable processes are
// skipped.
type SystemCatalog struct{}

// Processes implements ProcessCatalog.
func (SystemCatalog) Processes() []RunningProcess {
	if runtime.GOOS == "linux" {
		return procProcesses("/proc")
	}
	return psProcesses()
}

func procProcesses(root string) []RunningProcess {
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil
	}
	var out []RunningProcess
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		exe, err := os.Readlink(filepath.Join(root, e.Name(), "exe"))
		if err != nil {
			continue
		}
		var args []string
		if data, err := os.ReadFile(filepath.Join(root, e.Name(), "cmdline")); err == nil {
			for _, part := range bytes.Split(bytes.TrimRight(data, "\x00"), []byte{0}) {
				args = append(args, string(part))
			}
		}
		out = append(out, RunningProcess{PID: pid, ExecutablePath: exe, Arguments: args})
	}
	return out
}

func psProcesses() []RunningProcess {
	data, err := exec.Command("/bin/ps", "-axww", "-o", "pid=,args=").Output()
	if err != nil {
		return nil
	}
	var out []RunningProcess
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		pid, err := strconv.Atoi(fields[0])
		if err != nil {
			continue
		}
		// `ps` cannot separate a path with spaces from its arguments, so the whole command
		// line is the path. MatchPath is a substring test, which still finds the engine.
		out = append(out, RunningProcess{PID: pid, ExecutablePath: strings.Join(fields[1:], " "), Arguments: fields[1:]})
	}
	return out
}

// PortFromArguments reads `--port 8123` or `--port=8123` from argv.
func PortFromArguments(args []string) *int {
	for i, arg := range args {
		if arg == "--port" && i+1 < len(args) {
			return parsePort(args[i+1])
		}
		if strings.HasPrefix(arg, "--port=") {
			return parsePort(strings.TrimPrefix(arg, "--port="))
		}
	}
	return nil
}

func parsePort(raw string) *int {
	n, err := strconv.Atoi(raw)
	if err != nil || n < 1 || n > 65535 {
		return nil
	}
	return &n
}

// ResolveEnginePort finds an engine's port: the first matching process's --port (or the
// engine's own port for that process), else the engine's explicit port. Reserved ports belong
// to other rows. This is not a port sweep: only ports named by argv or config are used.
func ResolveEnginePort(engine config.LocalEngine, processes []RunningProcess, reserved map[int]bool) *int {
	if engine.MatchPath != nil && *engine.MatchPath != "" {
		for _, p := range processes {
			if !strings.Contains(p.ExecutablePath, *engine.MatchPath) {
				continue
			}
			port := PortFromArguments(p.Arguments)
			if port == nil {
				port = engine.Port
			}
			if port != nil && !reserved[*port] {
				return port
			}
		}
	}
	if engine.Port != nil && !reserved[*engine.Port] {
		return engine.Port
	}
	return nil
}
