package cli

import (
	"reflect"
	"testing"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

func themeP(th domain.CLITheme) *domain.CLITheme { return &th }

func one(id domain.ProviderID) ProviderFilter { return ProviderFilter{Kind: FilterOne, ID: id} }

var filterAll = ProviderFilter{Kind: FilterAll}

func usage(mutate ...func(*UsageCmd)) UsageCmd {
	c := UsageCmd{}
	for _, m := range mutate {
		m(&c)
	}
	return c
}

func TestParseCommands(t *testing.T) {
	since, until := "2026-10-01", "2026-10-07"
	claude := domain.Claude
	prefix := "/tmp/bin"
	cases := []struct {
		args []string
		want Command
	}{
		{nil, usage()},
		{[]string{"usage", "--json", "--cached", "--no-color"}, usage(func(c *UsageCmd) { c.JSON, c.NoColor, c.Freshness = true, true, FreshnessCached })},
		{[]string{"--cached"}, usage(func(c *UsageCmd) { c.Freshness = FreshnessCached })},
		{[]string{"--live"}, usage(func(c *UsageCmd) { c.Freshness = FreshnessLive })},
		{[]string{"--live", "--cached"}, usage(func(c *UsageCmd) { c.Freshness = FreshnessCached })},
		{[]string{"--cached", "--live"}, usage(func(c *UsageCmd) { c.Freshness = FreshnessLive })},
		{[]string{"quota", "claude", "--live"}, usage(func(c *UsageCmd) { c.QuotaOnly, c.Filter, c.Freshness = true, one(domain.Claude), FreshnessLive })},
		{[]string{"usage", "claude"}, usage(func(c *UsageCmd) { c.Filter = one(domain.Claude) })},
		{[]string{"grok"}, usage(func(c *UsageCmd) { c.Filter = one(domain.Grok) })},
		{[]string{"engine.gpu-box"}, usage(func(c *UsageCmd) { c.Filter = one("engine.gpu-box") })},
		{[]string{"--provider", "all"}, usage(func(c *UsageCmd) { c.Filter = filterAll })},
		{[]string{"quota"}, usage(func(c *UsageCmd) { c.QuotaOnly = true })},
		{[]string{"limits", "codex"}, usage(func(c *UsageCmd) { c.QuotaOnly, c.Filter = true, one(domain.Codex) })},
		{[]string{"dashboard"}, DashboardCmd{}},
		{[]string{"dashboard", "claude"}, DashboardCmd{Provider: &claude}},
		{[]string{"settings"}, SettingsCmd{Verb: SettingsList}},
		{[]string{"settings", "--json"}, SettingsCmd{Verb: SettingsList, JSON: true}},
		{[]string{"settings", "get", "theme"}, SettingsCmd{Verb: SettingsGet, Key: "theme"}},
		{[]string{"settings", "set", "theme", "dark"}, SettingsCmd{Verb: SettingsSet, Key: "theme", Value: "dark"}},
		{[]string{"settings", "--theme", "classic"}, SettingsCmd{Verb: SettingsList}},
		{[]string{"install", "--prefix", "/tmp/bin"}, InstallCmd{Prefix: &prefix}},
		{[]string{"install", "--theme", "classic"}, InstallCmd{}},
		{[]string{"uninstall"}, UninstallCmd{}},
		{[]string{"--help"}, HelpCmd{}},
		{[]string{"-h"}, HelpCmd{}},
		{[]string{"help"}, HelpCmd{}},
		{[]string{"usage", "--nope", "--help"}, nil},
		{[]string{"--version"}, VersionCmd{}},
		{[]string{"-V"}, VersionCmd{}},
		{[]string{"version"}, VersionCmd{}},
		{[]string{"--cli", "usage", "--json"}, usage(func(c *UsageCmd) { c.JSON = true })},
		{[]string{"--theme", "classic"}, usage(func(c *UsageCmd) { c.Theme = themeP(domain.ThemeClassic) })},
		{[]string{"quota", "--theme", "Compact"}, usage(func(c *UsageCmd) { c.QuotaOnly, c.Theme = true, themeP(domain.ThemeCompact) })},
		{[]string{"claude", "--theme", "CLASSIC"}, usage(func(c *UsageCmd) { c.Filter, c.Theme = one(domain.Claude), themeP(domain.ThemeClassic) })},
		{[]string{"themes"}, ThemesCmd{}},
		{[]string{"themes", "--json", "--theme", "classic"}, ThemesCmd{JSON: true, Theme: themeP(domain.ThemeClassic)}},
		{[]string{"stats"}, StatsCmd{}},
		{[]string{"stats", "claude", "--days", "30"}, StatsCmd{Filter: one(domain.Claude), Days: intp(30)}},
		{[]string{"stats", "--provider", "all", "--no-color"}, StatsCmd{Filter: filterAll, NoColor: true}},
		{[]string{"stats", "--since", since, "--until", until}, StatsCmd{Since: &since, Until: &until}},
		{[]string{"stats", "--json"}, StatsCmd{Format: StatsFormat{JSON: true}}},
		{[]string{"stats", "--csv"}, StatsCmd{Format: StatsFormat{CSV: CSVDays}}},
		{[]string{"stats", "--csv", "quota", "--days", "30"}, StatsCmd{Days: intp(30), Format: StatsFormat{CSV: CSVQuota}}},
		{[]string{"stats", "--csv", "claude"}, StatsCmd{Filter: one(domain.Claude), Format: StatsFormat{CSV: CSVDays}}},
		{[]string{"stats", "--theme", "classic"}, StatsCmd{}},
	}
	for _, c := range cases {
		if c.want == nil {
			continue
		}
		got, err := Parse(c.args)
		if err != nil {
			t.Errorf("%v: %v", c.args, err)
			continue
		}
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("%v:\n got %#v\nwant %#v", c.args, got, c.want)
		}
	}
}

func TestParseErrorText(t *testing.T) {
	cases := []struct {
		args []string
		want string
	}{
		{[]string{"usage", "nope"}, "unknown provider 'nope'. Try `aub help`."},
		{[]string{"frobnicate"}, "unknown command 'frobnicate'. Try `aub help`."},
		{[]string{"usage", "--nope", "--help"}, "unknown command '--nope'. Try `aub help`."},
		{[]string{"dashboard", "nope"}, "unknown provider 'nope'. Try `aub help`."},
		{[]string{"dashboard", "claude", "codex"}, "unexpected argument 'codex'. Try `aub help`."},
		{[]string{"settings", "get"}, "missing settings key. Try `aub settings`."},
		{[]string{"settings", "set"}, "missing settings key. Try `aub settings`."},
		{[]string{"settings", "set", "theme"}, "missing settings value. Usage: aub settings set <key> <value>"},
		{[]string{"settings", "set", "a", "b", "c"}, "unexpected argument 'c'. Try `aub help`."},
		{[]string{"settings", "frob"}, "unknown command 'settings frob'. Try `aub help`."},
		{[]string{"--theme", "fancy"}, "unknown CLI theme 'fancy'; expected compact|classic"},
		{[]string{"--theme"}, "missing value for --theme"},
		{[]string{"--theme=classic"}, "unknown command '--theme=classic'. Try `aub help`."},
		{[]string{"settings", "--theme", "nope"}, "unknown CLI theme 'nope'; expected compact|classic"},
		{[]string{"themes", "classic"}, "unexpected argument 'classic'. Try `aub help`."},
		{[]string{"stats", "--json", "--csv"}, "unexpected argument '--csv'. Try `aub help`."},
		{[]string{"usage", "--csv"}, "unexpected argument '--csv'. Try `aub help`."},
		{[]string{"stats", "--days", "0"}, "--days expects a whole number of days from 1, got '0'"},
		{[]string{"stats", "--days"}, "missing value for --days"},
		{[]string{"stats", "--since", "2026-13-01"}, "--since expects a date as yyyy-MM-dd, got '2026-13-01'"},
		{[]string{"usage", "--days", "3"}, "unexpected argument '--days'. Try `aub help`."},
		{[]string{"stats", "nope"}, "unknown provider 'nope'. Try `aub help`."},
	}
	for _, c := range cases {
		_, err := Parse(c.args)
		if err == nil || err.Error() != c.want {
			t.Errorf("%v: got %v want %s", c.args, err, c.want)
		}
	}
}
