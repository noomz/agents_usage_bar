package cli

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime/debug"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/clock"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/paths"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/providers"
	"github.com/noomz/agents_usage_bar/cli/internal/providers/httpscript"
	"github.com/noomz/agents_usage_bar/cli/internal/settings"
)

type harness struct {
	*App
	out, errOut *bytes.Buffer
	env         map[string]string
	store       settings.Memory
	opened      []string
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	root := t.TempDir()
	h := &harness{out: &bytes.Buffer{}, errOut: &bytes.Buffer{}, env: map[string]string{}, store: settings.Memory{}}
	h.App = &App{
		Version: "9.9.9", Stdout: h.out, Stderr: h.errOut,
		Layout:   paths.Layout{Home: root, DataDir: filepath.Join(root, "data"), ConfigDir: filepath.Join(root, "config")},
		Settings: h.store,
		Env:      func(k string) (string, bool) { v, ok := h.env[k]; return v, ok },
		Clock:    clock.Fixed(time.Date(2026, 3, 14, 12, 0, 0, 0, time.UTC)), Location: time.UTC, GOOS: "linux",
		Terminal: func() (int, bool) { return 0, false },
		Registry: func(env provider.Env) provider.Registry {
			env.HTTP, env.LocalhostHTTP = httpscript.Refusing(), httpscript.Refusing()
			env.Processes = provider.StaticCatalog{}
			return providers.Build(env)
		},
		Installer: &Installer{newFakeFS()},
		OpenURL:   func(u string) error { h.opened = append(h.opened, u); return nil },
	}
	return h
}

func (h *harness) run(args ...string) (string, string, int) {
	h.out.Reset()
	h.errOut.Reset()
	code := h.Run(args)
	return h.out.String(), h.errOut.String(), code
}

func writeDays(t *testing.T, dir string, days []domain.DayFile) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, d := range days {
		data, err := json.Marshal(dayFileJSON(d))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, d.Date+".json"), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

func dayFileJSON(d domain.DayFile) map[string]any {
	records := []any{}
	for _, r := range d.Records {
		accounts := []any{}
		for _, a := range r.Accounts {
			accounts = append(accounts, map[string]any{"key": a.Key, "label": a.Label, "billingModel": a.BillingModel, "plan": a.Plan, "billingModelAssumed": a.BillingModelAssumed, "quota": map[string]any{}})
		}
		rec := map[string]any{"provider": r.Provider, "tokens": r.Tokens, "costEstimated": r.CostEstimated, "quota": map[string]any{}, "accounts": accounts, "origin": r.Origin}
		if r.CostUSD != nil {
			rec["costUSD"] = r.CostUSD.String()
		}
		records = append(records, rec)
	}
	return map[string]any{"schemaVersion": 1, "date": d.Date, "timeZone": d.TimeZone, "records": records, "events": []any{}, "backfillChecked": []any{}}
}

func TestExitCodesAndStreams(t *testing.T) {
	cases := []struct {
		args   []string
		stderr string
		code   int
	}{
		{[]string{"--frob"}, "error: unknown command '--frob'. Try `aub help`.\n", 2},
		{[]string{"stats", "--days", "0"}, "error: --days expects a whole number of days from 1, got '0'\n", 2},
		{[]string{"settings", "get", "nope"}, "error: unknown key 'nope'. Try `aub settings`.\n", 2},
		{[]string{"settings", "set", "theme", "neon"}, "error: invalid value 'neon' for theme; expected light|dark|auto\n", 2},
		{[]string{"dashboard"}, "error: the dashboard needs the macOS app, which is not available on linux\n", 1},
	}
	for _, c := range cases {
		out, errOut, code := newHarness(t).run(c.args...)
		if out != "" || errOut != c.stderr || code != c.code {
			t.Errorf("%v: out=%q err=%q code=%d", c.args, out, errOut, code)
		}
	}
}

func TestHelpAndVersion(t *testing.T) {
	h := newHarness(t)
	if out, _, code := h.run("--help"); out != HelpText+"\n" || code != 0 {
		t.Error(out)
	}
	if out, _, code := h.run("--version"); out != "aub 9.9.9\n" || code != 0 {
		t.Error(out)
	}
}

func TestDashboardOpensTheAppURL(t *testing.T) {
	h := newHarness(t)
	h.GOOS = "darwin"
	if _, _, code := h.run("dashboard"); code != 0 {
		t.Error(code)
	}
	if _, _, code := h.run("dashboard", "claude"); code != 0 {
		t.Error(code)
	}
	if strings.Join(h.opened, " ") != "agentsusagebar://dashboard agentsusagebar://dashboard?provider=claude" {
		t.Errorf("%v", h.opened)
	}
	id := domain.ProviderID("engine.a b")
	if got := DashboardURL(&id); got != "agentsusagebar://dashboard?provider=engine.a%20b" {
		t.Error(got)
	}
}

func TestDashboardWithoutTheAppIsAClearError(t *testing.T) {
	h := newHarness(t)
	h.GOOS = "darwin"
	h.OpenURL = func(string) error { return errors.New("exit status 1") }
	out, errOut, code := h.run("dashboard", "claude")
	want := "error: the dashboard needs the macOS app: nothing on this Mac can open agentsusagebar:// URLs. Install AgentsUsageBar.app\n"
	if out != "" || errOut != want || code != 1 {
		t.Errorf("%q %q %d", out, errOut, code)
	}
}

func TestVersionResolution(t *testing.T) {
	module := func(v string) *debug.BuildInfo { return &debug.BuildInfo{Main: debug.Module{Version: v}} }
	cases := []struct {
		ldflags string
		info    *debug.BuildInfo
		want    string
	}{
		{"1.2.3", module("v9.9.9"), "1.2.3"},
		{"", module("v0.4.0"), "v0.4.0"},
		{"", module("(devel)"), "dev"},
		{"", module(""), "dev"},
		{"", nil, "dev"},
	}
	for _, c := range cases {
		if got := ResolveVersion(c.ldflags, c.info); got != c.want {
			t.Errorf("%+v: %s", c, got)
		}
	}
}

// Standalone install: no app, cache, history, or stored setting is a normal state.
func TestNoAppStateIsNormalAndCreatesNothing(t *testing.T) {
	cases := []struct {
		args []string
		want string
	}{
		{nil, "no cached data yet — run aub --live"},
		{[]string{"usage", "--theme", "classic"}, "Today total"},
		{[]string{"quota"}, "no cached data yet — run aub --live"},
		{[]string{"usage", "--json"}, `"source" : "cached"`},
		{[]string{"quota", "--json"}, "["},
		{[]string{"--live"}, "! Claude"},
		{[]string{"stats"}, noHistoryText},
		{[]string{"stats", "claude"}, noHistoryText},
		{[]string{"stats", "--json"}, `"schemaVersion" : 1`},
		{[]string{"stats", "--csv"}, "date,provider,tokens"},
		{[]string{"themes"}, "active: compact (from default)"},
		{[]string{"settings"}, "refresh-interval=5m"},
		{[]string{"settings", "get", "threshold"}, "0.80"},
	}
	for _, c := range cases {
		h := newHarness(t)
		out, errOut, code := h.run(c.args...)
		if code != 0 || errOut != "" || !strings.Contains(out, c.want) {
			t.Errorf("%v: code=%d err=%q out=%q", c.args, code, errOut, out)
		}
		if entries, err := os.ReadDir(h.Layout.Home); err != nil || len(entries) != 0 {
			t.Errorf("%v created %v (%v)", c.args, entries, err)
		}
	}
}

func TestThemeSelection(t *testing.T) {
	cases := []struct {
		name    string
		env     string
		setting string
		args    []string
		want    string
		code    int
	}{
		{"default", "", "", nil, "active: compact (from default)", 0},
		{"setting", "", "classic", nil, "active: classic (from setting)", 0},
		{"env beats setting", "classic", "compact", nil, "active: classic (from AUB_THEME)", 0},
		{"flag beats env", "compact", "", []string{"--theme", "classic"}, "active: classic (from flag)", 0},
		{"flag skips a bad env", "fancy", "", []string{"--theme", "classic"}, "active: classic (from flag)", 0},
		{"garbage setting falls through", "", "garbage", nil, "active: compact (from default)", 0},
		{"empty env is absent", "", "", nil, "active: compact (from default)", 0},
	}
	for _, c := range cases {
		h := newHarness(t)
		if c.env != "" {
			h.env["AUB_THEME"] = c.env
		}
		if c.setting != "" {
			h.store[settings.KeyCLITheme] = c.setting
		}
		out, _, code := h.run(append([]string{"themes"}, c.args...)...)
		if !strings.HasSuffix(out, c.want+"\n") || code != c.code {
			t.Errorf("%s: %q %d", c.name, out, code)
		}
	}
	h := newHarness(t)
	h.env["AUB_THEME"] = "fancy"
	if _, errOut, code := h.run("themes"); errOut != "error: AUB_THEME: unknown CLI theme 'fancy'; expected compact|classic\n" || code != 2 {
		t.Errorf("%q %d", errOut, code)
	}
	if _, _, code := h.run("usage", "--json"); code != 0 {
		t.Error("JSON must not read AUB_THEME")
	}
}

func TestThemeListing(t *testing.T) {
	got := renderThemes(ThemeSelection{domain.ThemeClassic, ThemeFromFlag})
	want := "  compact  One row per provider with severity glyphs (default)\n● classic  Original multi-line layout\nactive: classic (from flag)\n"
	if got != want {
		t.Errorf("%q", got)
	}
	gotJSON := renderThemesJSON(ThemeSelection{domain.ThemeCompact, ThemeFromEnv})
	wantJSON := `{"active":"compact","source":"env","themes":[{"default":true,"description":"One row per provider with severity glyphs","name":"compact"},{"default":false,"description":"Original multi-line layout","name":"classic"}]}` + "\n"
	if gotJSON != wantJSON {
		t.Error(gotJSON)
	}
}

func TestColorRules(t *testing.T) {
	cases := []struct {
		noColor, tty bool
		env          map[string]string
		want         bool
	}{
		{false, true, nil, true},
		{false, false, nil, false},
		{true, true, nil, false},
		{false, true, map[string]string{"NO_COLOR": ""}, false},
		{false, true, map[string]string{"NO_COLOR": "1"}, false},
		{false, true, map[string]string{"TERM": "dumb"}, false},
		{false, true, map[string]string{"TERM": "xterm"}, true},
	}
	for _, c := range cases {
		h := newHarness(t)
		h.env = c.env
		if h.env == nil {
			h.env = map[string]string{}
		}
		h.Terminal = func() (int, bool) { return 80, c.tty }
		if got := h.shouldColor(c.noColor); got != c.want {
			t.Errorf("%+v: %v", c, got)
		}
	}
}

func TestTerminalWidth(t *testing.T) {
	cases := []struct {
		columns int
		tty     bool
		env     string
		want    string
	}{
		{120, true, "90", "120"},
		{0, true, "90", "90"},
		{0, false, "90", "90"},
		{0, false, "wide", "nil"},
		{0, false, "0", "nil"},
		{0, false, "", "nil"},
	}
	for _, c := range cases {
		h := newHarness(t)
		if c.env != "" {
			h.env["COLUMNS"] = c.env
		}
		h.Terminal = func() (int, bool) { return c.columns, c.tty }
		got := "nil"
		if w := h.terminalWidth(); w != nil {
			got = strconv.Itoa(*w)
		}
		if got != c.want {
			t.Errorf("%+v: %s", c, got)
		}
	}
}

func TestNoHistoryPrintsOneLineAndCreatesNothing(t *testing.T) {
	h := newHarness(t)
	out, errOut, code := h.run("stats")
	if out != noHistoryText+"\n" || errOut != "" || code != 0 {
		t.Errorf("%q %q %d", out, errOut, code)
	}
	if _, err := os.Stat(h.Layout.DataDir); err == nil {
		t.Error("stats created the data directory")
	}
}

func TestUnreadableHistoryIsExitOne(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("root reads everything")
	}
	h := newHarness(t)
	if err := os.MkdirAll(h.Layout.DataDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(h.Layout.HistoryDir(), 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(h.Layout.HistoryDir(), 0o700) })
	out, errOut, code := h.run("stats")
	want := "error: cannot read usage history at " + h.Layout.HistoryDir() + "/: The file “history” couldn’t be opened because you don’t have permission to view it.\n"
	if out != "" || errOut != want || code != 1 {
		t.Errorf("%q %q %d", out, errOut, code)
	}
}

func TestTodayNeverGoesBehindNewestFile(t *testing.T) {
	h := newHarness(t)
	writeDays(t, h.Layout.HistoryDir(), syntheticDays(statsToday, 3))
	h.Clock = clock.Fixed(time.Date(2026, 3, 1, 12, 0, 0, 0, time.UTC))
	out, _, code := h.run("stats", "openrouter", "--days", "3", "--no-color")
	if code != 0 || !strings.HasPrefix(out, "OpenRouter · 2026-03-12 – 2026-03-14 · 3 days (today open)") {
		t.Errorf("%d %s", code, out)
	}
}

func TestStatsJSONOnEmptyStoreIsValid(t *testing.T) {
	h := newHarness(t)
	out, _, code := h.run("stats", "--json")
	var doc map[string]any
	if err := json.Unmarshal([]byte(out), &doc); err != nil || code != 0 || doc["schemaVersion"].(float64) != 1 {
		t.Errorf("%v %d %s", err, code, out)
	}
	if _, err := os.Stat(h.Layout.HistoryDir()); err == nil {
		t.Error("export created history")
	}
}

func TestStatsCSVReadsEveryRetainedDay(t *testing.T) {
	h := newHarness(t)
	writeDays(t, h.Layout.HistoryDir(), syntheticDays(statsToday, 7))
	out, _, _ := h.run("stats", "--csv")
	dates := map[string]bool{}
	for _, l := range lines(out)[1:] {
		dates[l[:10]] = true
	}
	if len(dates) != 7 {
		t.Errorf("%d dates", len(dates))
	}
}

func TestBudgetFromConfigAppearsInStats(t *testing.T) {
	h := newHarness(t)
	writeDays(t, h.Layout.HistoryDir(), syntheticDays(statsToday, 14))
	if err := os.MkdirAll(h.Layout.ConfigDir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(h.Layout.ConfigFile(), []byte("[budgets]\ntotal_usd = 50\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	out, _, _ := h.run("stats", "--no-color")
	if !strings.Contains(out, " / $50.00 budget") {
		t.Error(out)
	}
	h.store[settings.KeyBudget(domain.BudgetTotal)] = float64(0)
	out, _, _ = h.run("stats", "--no-color")
	if strings.Contains(out, "budget") {
		t.Error("a zero Settings value turns the budget off")
	}
}

func TestSettingsListAndJSON(t *testing.T) {
	h := newHarness(t)
	out, _, _ := h.run("settings")
	if !strings.HasPrefix(out, "refresh-interval=5m\nthreshold=0.80\ntheme=auto\ncli-theme=compact\nprovider-order=openrouter,claude,") {
		t.Error(out)
	}
	out, _, _ = h.run("settings", "--json")
	if !strings.HasPrefix(out, `{"claude-source":"sessionReads","cli-theme":"compact",`) {
		t.Error(out)
	}
	out, _, _ = h.run("settings", "get", "theme")
	if out != "auto\n" {
		t.Error(out)
	}
	out, _, _ = h.run("settings", "get", "theme", "--json")
	if out != `{"key":"theme","value":"auto"}`+"\n" {
		t.Error(out)
	}
	out, errOut, code := h.run("settings", "set", "open-at-login", "yes")
	if out != "open-at-login=true\n" || errOut != "warning: Login Items registration only happens in Settings; the flag was stored.\n" || code != 0 {
		t.Errorf("%q %q %d", out, errOut, code)
	}
}

func TestLiveUsageWithNoProvidersShowsPlaceholders(t *testing.T) {
	h := newHarness(t)
	out, _, code := h.run("--live", "--no-color")
	if code != 0 {
		t.Fatal(code)
	}
	all := lines(out)
	if all[1] != "0 at ≥80% · 0 at 50–79% · 6 unavailable" {
		t.Error(out)
	}
	firstLine(t, all, func(l string) bool {
		return strings.HasPrefix(l, "! Claude") && strings.HasSuffix(l, "unauthenticated")
	})
	firstLine(t, all, func(l string) bool { return strings.HasPrefix(l, "  local ○ Ollama stopped") })
}

func TestLiveFiltersDisabledProviders(t *testing.T) {
	h := newHarness(t)
	h.store[settings.KeyProviderEnabled(domain.Gemini)] = false
	out, _, _ := h.run("--live", "--json")
	if strings.Contains(out, `"gemini"`) {
		t.Error("disabled provider listed")
	}
	if !strings.Contains(out, `"source" : "live"`) || !strings.Contains(out, `"status" : "unauthenticated"`) {
		t.Error(out)
	}
	out, _, _ = h.run("--live", "--json", "--provider", "gemini")
	if strings.Contains(out, `"gemini"`) {
		t.Error("a disabled provider has no registered row")
	}
}

// Provider is the contract the registry and session rely on.
var _ provider.Provider = (*fakeProvider)(nil)
