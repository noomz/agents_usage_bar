// Package paths is the single source of on-disk locations. macOS uses the app's own
// locations so existing data is read in place. Other systems use XDG with the same layout.
package paths

import (
	"os"
	"path/filepath"
	"runtime"
)

// Layout holds every resolved location.
type Layout struct {
	Home string
	// DataDir holds today.json and history/.
	DataDir string
	// ConfigDir holds config.toml, and settings.json where there is no UserDefaults.
	ConfigDir string
}

// Current resolves the layout for this process.
func Current() Layout {
	home, _ := os.UserHomeDir()
	return For(runtime.GOOS, home, os.Getenv)
}

// For resolves the layout for an operating system, home directory, and environment.
func For(goos, home string, getenv func(string) string) Layout {
	if goos == "darwin" {
		return Layout{
			Home:      home,
			DataDir:   filepath.Join(home, "Library", "Application Support", "AgentsUsageBar"),
			ConfigDir: filepath.Join(home, ".config", "agents-usage-bar"),
		}
	}
	return Layout{
		Home:      home,
		DataDir:   filepath.Join(xdg(getenv("XDG_DATA_HOME"), home, ".local", "share"), "AgentsUsageBar"),
		ConfigDir: filepath.Join(xdg(getenv("XDG_CONFIG_HOME"), home, ".config"), "agents-usage-bar"),
	}
}

// XDG ignores a relative value, as the base directory spec requires.
func xdg(value, home string, fallback ...string) string {
	if filepath.IsAbs(value) {
		return value
	}
	return filepath.Join(append([]string{home}, fallback...)...)
}

func (l Layout) CacheFile() string { return filepath.Join(l.DataDir, "today.json") }

// HistoryDir holds one yyyy-MM-dd.json per day.
func (l Layout) HistoryDir() string { return filepath.Join(l.DataDir, "history") }

func (l Layout) ConfigFile() string { return filepath.Join(l.ConfigDir, "config.toml") }

// SettingsFile stores settings on systems without UserDefaults.
func (l Layout) SettingsFile() string { return filepath.Join(l.ConfigDir, "settings.json") }
