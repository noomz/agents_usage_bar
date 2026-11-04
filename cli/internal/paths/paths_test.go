package paths

import "testing"

func TestLayouts(t *testing.T) {
	env := func(m map[string]string) func(string) string {
		return func(k string) string { return m[k] }
	}
	cases := []struct {
		name, goos                string
		env                       map[string]string
		cache, history, conf, set string
	}{
		{
			"macOS ignores XDG", "darwin", map[string]string{"XDG_DATA_HOME": "/x", "XDG_CONFIG_HOME": "/y"},
			"/h/Library/Application Support/AgentsUsageBar/today.json",
			"/h/Library/Application Support/AgentsUsageBar/history",
			"/h/.config/agents-usage-bar/config.toml",
			"/h/.config/agents-usage-bar/settings.json",
		},
		{
			"linux defaults", "linux", nil,
			"/h/.local/share/AgentsUsageBar/today.json",
			"/h/.local/share/AgentsUsageBar/history",
			"/h/.config/agents-usage-bar/config.toml",
			"/h/.config/agents-usage-bar/settings.json",
		},
		{
			"linux XDG", "linux", map[string]string{"XDG_DATA_HOME": "/d", "XDG_CONFIG_HOME": "/c"},
			"/d/AgentsUsageBar/today.json", "/d/AgentsUsageBar/history",
			"/c/agents-usage-bar/config.toml", "/c/agents-usage-bar/settings.json",
		},
		{
			"relative XDG is ignored", "linux", map[string]string{"XDG_DATA_HOME": "rel", "XDG_CONFIG_HOME": "rel"},
			"/h/.local/share/AgentsUsageBar/today.json", "/h/.local/share/AgentsUsageBar/history",
			"/h/.config/agents-usage-bar/config.toml", "/h/.config/agents-usage-bar/settings.json",
		},
	}
	for _, c := range cases {
		l := For(c.goos, "/h", env(c.env))
		got := []string{l.CacheFile(), l.HistoryDir(), l.ConfigFile(), l.SettingsFile()}
		want := []string{c.cache, c.history, c.conf, c.set}
		for i := range got {
			if got[i] != want[i] {
				t.Errorf("%s: got %s want %s", c.name, got[i], want[i])
			}
		}
	}
}
