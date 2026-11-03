package provider

import (
	"bytes"
	"encoding/binary"
	"os"
	"path/filepath"
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

// SystemCatalog lists the running processes. A process it may not inspect keeps whatever is
// readable, or is skipped when that is nothing.
type SystemCatalog struct{}

// Processes implements ProcessCatalog.
func (SystemCatalog) Processes() []RunningProcess { return osProcesses() }

// parseCmdline reads NUL-separated argv and drops empty arguments, as the app does.
func parseCmdline(data []byte) []string {
	var args []string
	for _, part := range bytes.Split(data, []byte{0}) {
		if len(part) > 0 {
			args = append(args, string(part))
		}
	}
	return args
}

// procProcesses reads a /proc tree. Another user's exe link is unreadable while its cmdline is
// not, so a system service still classifies by argv[0].
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
		var args []string
		if data, err := os.ReadFile(filepath.Join(root, e.Name(), "cmdline")); err == nil {
			args = parseCmdline(data)
		}
		exe, err := os.Readlink(filepath.Join(root, e.Name(), "exe"))
		if err != nil {
			if len(args) == 0 {
				continue
			}
			exe = args[0]
		}
		out = append(out, RunningProcess{PID: pid, ExecutablePath: exe, Arguments: args})
	}
	return out
}

// parseProcArgs reads a KERN_PROCARGS2 buffer: argc, the exec path, padding NULs, then argv.
func parseProcArgs(buf []byte) []string {
	if len(buf) <= 4 {
		return nil
	}
	argc := int(int32(binary.NativeEndian.Uint32(buf)))
	offset := 4
	for offset < len(buf) && buf[offset] != 0 {
		offset++
	}
	for offset < len(buf) && buf[offset] == 0 {
		offset++
	}
	var args []string
	for i := 0; i < argc && offset < len(buf); i++ {
		start := offset
		for offset < len(buf) && buf[offset] != 0 {
			offset++
		}
		if start < offset {
			args = append(args, string(buf[start:offset]))
		}
		offset++
	}
	return args
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
