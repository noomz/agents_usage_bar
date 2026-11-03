package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/cache"
	"github.com/noomz/agents_usage_bar/cli/internal/clock"
	"github.com/noomz/agents_usage_bar/cli/internal/config"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/history"
	"github.com/noomz/agents_usage_bar/cli/internal/httpclient"
	"github.com/noomz/agents_usage_bar/cli/internal/paths"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/providers"
	"github.com/noomz/agents_usage_bar/cli/internal/settings"
	"github.com/noomz/agents_usage_bar/cli/internal/swiftjson"
)

// App holds everything one invocation touches, so tests can redirect all of it.
type App struct {
	Version  string
	Stdout   io.Writer
	Stderr   io.Writer
	Layout   paths.Layout
	Settings settings.Store
	Env      func(string) (string, bool)
	Clock    clock.Clock
	Location *time.Location
	GOOS     string
	// Terminal reports the stdout terminal's columns, ok=false when not a terminal.
	Terminal  func() (columns int, isTTY bool)
	Registry  func(provider.Env) provider.Registry
	Installer *Installer
	// OpenURL opens a URL with the system handler.
	OpenURL func(string) error
}

// NewApp wires the real system.
func NewApp(version string) *App {
	layout := paths.Current()
	return &App{
		Version: version, Stdout: os.Stdout, Stderr: os.Stderr, Layout: layout,
		Settings: settings.Default(layout), Env: os.LookupEnv, Clock: clock.System{}, Location: time.Local,
		GOOS: runtime.GOOS, Terminal: terminalColumns, Registry: providers.Build,
		Installer: &Installer{FS: SystemFS{}},
		OpenURL:   func(u string) error { return exec.Command("/usr/bin/open", u).Run() },
	}
}

func (a *App) errorf(format string, args ...any) {
	fmt.Fprintf(a.Stderr, "error: "+format+"\n", args...)
}

// Run executes one invocation and returns the exit code: 2 for a bad invocation or setting,
// 1 for anything else that failed.
func (a *App) Run(args []string) int {
	command, parseErr := Parse(args)
	if parseErr != nil {
		a.errorf("%s", parseErr.Error())
		return 2
	}
	useSystemLocaleFor(a.GOOS, command)
	code, err := a.execute(command)
	if err == nil {
		return code
	}
	a.errorf("%s", err.Error())
	var parse *ParseError
	var setting settings.Error
	if errors.As(err, &parse) || errors.As(err, &setting) {
		return 2
	}
	return 1
}

// Only text that prints money or tokens pays for the locale lookup.
func useSystemLocaleFor(goos string, command Command) {
	switch c := command.(type) {
	case UsageCmd:
		if !c.JSON {
			useSystemLocale(goos)
		}
	case StatsCmd:
		if c.Format.IsText() {
			useSystemLocale(goos)
		}
	}
}

func (a *App) execute(command Command) (int, error) {
	switch c := command.(type) {
	case HelpCmd:
		fmt.Fprintln(a.Stdout, HelpText)
		return 0, nil
	case VersionCmd:
		fmt.Fprintln(a.Stdout, "aub "+a.Version)
		return 0, nil
	case SettingsCmd:
		return a.runSettings(c)
	case ThemesCmd:
		active, err := a.resolveTheme(c.Theme)
		if err != nil {
			return 0, err
		}
		if c.JSON {
			fmt.Fprint(a.Stdout, renderThemesJSON(active))
		} else {
			fmt.Fprint(a.Stdout, renderThemes(active))
		}
		return 0, nil
	case InstallCmd:
		path, err := a.Installer.Install(c.Prefix)
		if err != nil {
			return 0, err
		}
		fmt.Fprintln(a.Stdout, "Installed aub → "+path)
		if hint := a.Installer.PathHint(dirOf(path)); hint != nil {
			fmt.Fprintln(a.Stdout, *hint)
		}
		return 0, nil
	case UninstallCmd:
		if err := a.Installer.Uninstall(); err != nil {
			return 0, err
		}
		fmt.Fprintln(a.Stdout, "Uninstalled aub symlinks that pointed at this app.")
		return 0, nil
	case UsageCmd:
		return a.runUsage(c)
	case StatsCmd:
		return a.runStats(c)
	case DashboardCmd:
		return a.runDashboard(c)
	}
	return 0, errors.New("unhandled command")
}

// The dashboard is a window in the app, the one command the CLI cannot serve alone.
func (a *App) runDashboard(c DashboardCmd) (int, error) {
	if a.GOOS != "darwin" {
		return 0, fmt.Errorf("the dashboard needs the macOS app, which is not available on %s", a.GOOS)
	}
	if err := a.OpenURL(DashboardURL(c.Provider)); err != nil {
		return 0, errors.New("the dashboard needs the macOS app: nothing on this Mac can open agentsusagebar:// URLs. Install AgentsUsageBar.app")
	}
	return 0, nil
}

// DashboardURL is `agentsusagebar://dashboard[?provider=<id>]`. Opening it changes nothing;
// the app only shows a view.
func DashboardURL(id *domain.ProviderID) string {
	u := url.URL{Scheme: "agentsusagebar", Host: "dashboard"}
	if id != nil {
		u.RawQuery = "provider=" + strings.ReplaceAll(url.QueryEscape(string(*id)), "+", "%20")
	}
	return u.String()
}

func (a *App) preferences() settings.Preferences { return settings.LoadPreferences(a.Settings) }

func (a *App) envValue(key string) (string, bool) {
	v, ok := a.Env(key)
	return v, ok && v != ""
}

func (a *App) config(prefs settings.Preferences) config.App {
	return config.Load(a.envValue, a.Layout.ConfigFile()).WithPreferences(prefs)
}

func (a *App) dayKeys() *domain.DayKeyOwner {
	return domain.NewDayKeyOwner(a.Clock, a.Location)
}

func (a *App) runSettings(c SettingsCmd) (int, error) {
	store := settings.CLI{
		Store:         a.Settings,
		CustomEngines: func() []domain.ProviderID { return config.Load(a.envValue, a.Layout.ConfigFile()).CustomEngineIDs() },
	}
	switch c.Verb {
	case SettingsList:
		rows := store.List()
		if c.JSON {
			tree := make(map[string]any, len(rows))
			for _, row := range rows {
				tree[row.Key] = row.Value
			}
			fmt.Fprintln(a.Stdout, swiftjson.Encode(tree, swiftjson.Options{}))
			return 0, nil
		}
		for _, row := range rows {
			fmt.Fprintln(a.Stdout, row.Key+"="+row.Value)
		}
		return 0, nil
	case SettingsGet:
		row, err := store.Get(c.Key)
		if err != nil {
			return 0, err
		}
		if c.JSON {
			fmt.Fprintln(a.Stdout, swiftjson.Encode(map[string]any{"key": row.Key, "value": row.Value}, swiftjson.Options{}))
		} else {
			fmt.Fprintln(a.Stdout, row.Value)
		}
		return 0, nil
	default:
		result, err := store.Set(c.Key, c.Value)
		if err != nil {
			return 0, err
		}
		fmt.Fprintln(a.Stdout, result.Key+"="+result.Value)
		if result.Warning != nil {
			fmt.Fprintln(a.Stderr, "warning: "+*result.Warning)
		}
		return 0, nil
	}
}

func (a *App) session(prefs settings.Preferences, cached bool) Session {
	store := cache.Store(cache.NewFile(a.Layout.CacheFile(), a.dayKeys()))
	session := Session{Cache: store, IsEnabled: prefs.IsEnabled}
	if !cached {
		registry := a.Registry(provider.Env{
			Config: a.config(prefs), Preferences: prefs,
			HTTP:          httpclient.New(httpclient.RemoteTimeout),
			LocalhostHTTP: httpclient.New(httpclient.LocalhostTimeout),
			Cache:         store, Clock: a.Clock, DayKeys: a.dayKeys(), Paths: a.Layout,
			Getenv:    func(key string) string { v, _ := a.Env(key); return v },
			Processes: provider.SystemCatalog{},
			Keychain:  provider.KeychainFor(a.GOOS),
		})
		session.Providers, session.Placeholders = registry.Providers, registry.Placeholders
	}
	return session
}

func (a *App) runUsage(c UsageCmd) (int, error) {
	prefs := a.preferences()
	now := a.Clock.Now()
	if c.JSON {
		report := a.session(prefs, c.Cached).Fetch(context.Background(), c.Filter, c.Cached, now)
		if c.QuotaOnly {
			fmt.Fprint(a.Stdout, renderQuotaJSON(report))
		} else {
			fmt.Fprint(a.Stdout, renderUsageJSON(report))
		}
		return 0, nil
	}
	// Resolve before fetching so a bad AUB_THEME fails fast; JSON never reads it.
	selection, err := a.resolveTheme(c.Theme)
	if err != nil {
		return 0, err
	}
	report := a.session(prefs, c.Cached).Fetch(context.Background(), c.Filter, c.Cached, now)
	view := ViewUsage
	if c.QuotaOnly {
		view = ViewQuota
	}
	fmt.Fprint(a.Stdout, a.renderTheme(selection.Theme, report, view, a.shouldColor(c.NoColor), prefs.ProviderOrder))
	return 0, nil
}

func (a *App) renderTheme(theme domain.CLITheme, report UsageReport, view View, color bool, order []domain.ProviderID) string {
	if theme == domain.ThemeClassic {
		if view == ViewUsage {
			return renderClassicUsage(report, color)
		}
		return renderClassicQuota(report, color)
	}
	return renderCompact(report, view, color, a.terminalWidth(), a.Location, order)
}

// shouldColor: --no-color, NO_COLOR at any value, and TERM=dumb turn colour off; otherwise a
// terminal turns it on.
func (a *App) shouldColor(noColor bool) bool {
	if noColor {
		return false
	}
	if _, set := a.Env("NO_COLOR"); set {
		return false
	}
	if term, _ := a.Env("TERM"); term == "dumb" {
		return false
	}
	_, isTTY := a.Terminal()
	return isTTY
}

// terminalWidth is the terminal's columns on a terminal, else $COLUMNS, else nil.
func (a *App) terminalWidth() *int {
	columns, isTTY := a.Terminal()
	if isTTY && columns > 0 {
		return &columns
	}
	if raw, ok := a.Env("COLUMNS"); ok {
		if n, err := strconv.Atoi(raw); err == nil && n > 0 {
			return &n
		}
	}
	return nil
}

func (a *App) runStats(c StatsCmd) (int, error) {
	prefs := a.preferences()
	budgets := a.config(prefs).Budgets
	reader := history.Reader{Dir: a.Layout.HistoryDir()}
	owner := a.dayKeys()

	keys, err := reader.DayKeys()
	if err != nil {
		fmt.Fprintf(a.Stderr, "error: cannot read usage history at %s/: %s\n", reader.Dir, err.Error())
		return 1, nil
	}
	if !c.Format.IsText() {
		return a.runExport(c, keys, reader, owner, prefs)
	}
	if len(keys) == 0 {
		fmt.Fprintln(a.Stdout, noHistoryText)
		return 0, nil
	}
	owner.AdvanceNewest(keys[len(keys)-1])
	statsRange, parseErr := ResolveRange(owner.Today(), c.Days, c.Since, c.Until, nil)
	if parseErr != nil {
		return 0, parseErr
	}
	days, err := reader.Days(statsRange.Keys[0], statsRange.Keys[len(statsRange.Keys)-1])
	if err != nil {
		return 0, err
	}
	color := a.shouldColor(c.NoColor)
	if c.Filter.Kind == FilterOne {
		fmt.Fprint(a.Stdout, renderStatsProvider(days, c.Filter.ID, statsRange, color))
		return 0, nil
	}
	// Month spend for the budget footer covers this month, whatever the range.
	var monthDays []domain.DayFile
	if len(budgets.Caps) > 0 {
		today := statsRange.Today
		if monthDays, err = reader.Days(today[:8]+"01", today); err != nil {
			return 0, err
		}
	}
	fmt.Fprint(a.Stdout, renderStatsSummary(days, statsRange, c.Filter.Kind == FilterAll, prefs.ProviderOrder, budgets, monthDays, color))
	return 0, nil
}

// runExport: every retained day by default, narrowed by the range flags and --provider. No
// history is a valid, empty export rather than the text line.
func (a *App) runExport(c StatsCmd, keys []string, reader history.Reader, owner *domain.DayKeyOwner, prefs settings.Preferences) (int, error) {
	var oldest *string
	if len(keys) > 0 {
		owner.AdvanceNewest(keys[len(keys)-1])
		oldest = &keys[0]
	}
	statsRange, parseErr := ResolveRange(owner.Today(), c.Days, c.Since, c.Until, oldest)
	if parseErr != nil {
		return 0, parseErr
	}
	days, err := reader.Days(statsRange.Keys[0], statsRange.Keys[len(statsRange.Keys)-1])
	if err != nil {
		return 0, err
	}
	scope := exportScope{statsRange: statsRange, isEnabled: prefs.IsEnabled}
	if c.Filter.Kind == FilterOne {
		id := c.Filter.ID
		scope.provider = &id
	}
	if c.Format.CSV != "" {
		fmt.Fprint(a.Stdout, renderExportCSV(days, scope, c.Format.CSV))
	} else {
		fmt.Fprint(a.Stdout, renderExportJSON(days, scope, a.Clock.Now()))
	}
	return 0, nil
}

// ThemeSource says what chose the active theme. The text is the `source` field in JSON.
type ThemeSource string

// The sources.
const (
	ThemeFromFlag    ThemeSource = "flag"
	ThemeFromEnv     ThemeSource = "env"
	ThemeFromSetting ThemeSource = "setting"
	ThemeFromDefault ThemeSource = "default"
)

// ThemeSelection is the active theme and its source.
type ThemeSelection struct {
	Theme  domain.CLITheme
	Source ThemeSource
}

var themeSummaries = map[domain.CLITheme]string{
	domain.ThemeCompact: "One row per provider with severity glyphs",
	domain.ThemeClassic: "Original multi-line layout",
}

// resolveTheme is --theme, then AUB_THEME, then the setting, then compact. Lower sources are
// read only when no higher one won.
func (a *App) resolveTheme(flag *domain.CLITheme) (ThemeSelection, error) {
	if flag != nil {
		return ThemeSelection{*flag, ThemeFromFlag}, nil
	}
	if raw, ok := a.envValue("AUB_THEME"); ok {
		theme, valid := domain.NamedTheme(raw)
		if !valid {
			return ThemeSelection{}, unknownThemeEnv(raw)
		}
		return ThemeSelection{theme, ThemeFromEnv}, nil
	}
	if theme, ok := settings.StoredTheme(a.Settings); ok {
		return ThemeSelection{theme, ThemeFromSetting}, nil
	}
	return ThemeSelection{domain.DefaultTheme, ThemeFromDefault}, nil
}

func renderThemes(active ThemeSelection) string {
	width := 0
	for _, t := range domain.AllThemes {
		width = max(width, len(t))
	}
	var b strings.Builder
	for _, t := range domain.AllThemes {
		mark, suffix := " ", ""
		if t == active.Theme {
			mark = "●"
		}
		if t == domain.DefaultTheme {
			suffix = " (default)"
		}
		fmt.Fprintf(&b, "%s %s  %s%s\n", mark, pad(string(t), width), themeSummaries[t], suffix)
	}
	label := string(active.Source)
	if active.Source == ThemeFromEnv {
		label = "AUB_THEME"
	}
	fmt.Fprintf(&b, "active: %s (from %s)\n", active.Theme, label)
	return b.String()
}

func renderThemesJSON(active ThemeSelection) string {
	themes := make([]any, len(domain.AllThemes))
	for i, t := range domain.AllThemes {
		themes[i] = map[string]any{"name": string(t), "description": themeSummaries[t], "default": t == domain.DefaultTheme}
	}
	return swiftjson.Encode(map[string]any{"themes": themes, "active": string(active.Theme), "source": string(active.Source)}, swiftjson.Options{}) + "\n"
}
