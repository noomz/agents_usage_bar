package settings

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

func newCLI() (CLI, Memory) {
	m := Memory{}
	return CLI{Store: m, CustomEngines: func() []domain.ProviderID { return []domain.ProviderID{"engine.gpu-box"} }}, m
}

func get(t *testing.T, c CLI, key string) string {
	t.Helper()
	e, err := c.Get(key)
	if err != nil {
		t.Fatalf("get %s: %v", key, err)
	}
	return e.Value
}

func set(t *testing.T, c CLI, key, value string) SetResult {
	t.Helper()
	r, err := c.Set(key, value)
	if err != nil {
		t.Fatalf("set %s=%s: %v", key, value, err)
	}
	return r
}

func TestAbsentDefaults(t *testing.T) {
	c, _ := newCLI()
	for key, want := range map[string]string{
		"refresh-interval": "5m", "threshold": "0.80", "theme": "auto", "pace-warnings": "true",
		"reset-notifications": "true", "claude-source": "sessionReads", "provider.claude.enabled": "true",
		"open-at-login": "false", "has-seen-welcome": "false", "cli-theme": "compact",
	} {
		if got := get(t, c, key); got != want {
			t.Errorf("%s: got %s want %s", key, got, want)
		}
	}
}

func TestRoundTrip(t *testing.T) {
	c, m := newCLI()
	cases := []struct {
		key, in, shown string
		stored         any
		rawKey         string
	}{
		{"refresh-interval", "1m", "1m", "1m", KeyRefreshInterval},
		{"theme", "dark", "dark", "dark", KeyTheme},
		{"pace-warnings", "no", "false", false, KeyPaceWarnings},
		{"reset-notifications", "NO", "false", false, KeyResetNotification},
		{"claude-source", "hook", "hook", "hook", KeyClaudeSource},
		{"provider.openrouter.enabled", "0", "false", false, KeyProviderEnabled(domain.OpenRouter)},
		{"threshold", "0.70", "0.70", 0.7, KeyThreshold},
		{"cli-theme", "Classic", "classic", "classic", KeyCLITheme},
	}
	for _, tc := range cases {
		if r := set(t, c, tc.key, tc.in); r.Value != tc.shown || r.Key != tc.key {
			t.Errorf("%s: set shows %s", tc.key, r.Value)
		}
		if got := get(t, c, tc.key); got != tc.shown {
			t.Errorf("%s: get %s", tc.key, got)
		}
		if m[tc.rawKey] != tc.stored {
			t.Errorf("%s: stored %#v want %#v", tc.key, m[tc.rawKey], tc.stored)
		}
	}
}

func TestRejections(t *testing.T) {
	cases := []struct{ key, value, message string }{
		{"threshold", "0.40", "invalid value '0.40' for threshold; expected number in 0.50…0.95"},
		{"threshold", "1.2", "invalid value '1.2' for threshold; expected number in 0.50…0.95"},
		{"threshold", "nan", "invalid value 'nan' for threshold; expected number in 0.50…0.95"},
		{"refresh-interval", "7m", "invalid value '7m' for refresh-interval; expected manual|1m|2m|5m|15m|30m"},
		{"theme", "neon", "invalid value 'neon' for theme; expected light|dark|auto"},
		{"cli-theme", "fancy", "invalid value 'fancy' for cli-theme; expected compact|classic"},
		{"pace-warnings", "maybe", "invalid value 'maybe' for pace-warnings; expected true|false"},
		{"claude-source", "x", "invalid value 'x' for claude-source; expected sessionReads|hook"},
		{"nope", "1", "unknown key 'nope'. Try `aub settings`."},
	}
	for _, tc := range cases {
		c, m := newCLI()
		_, err := c.Set(tc.key, tc.value)
		var se Error
		if !errors.As(err, &se) || se.Error() != tc.message {
			t.Errorf("%s=%s: got %v", tc.key, tc.value, err)
		}
		if len(m) != 0 {
			t.Errorf("%s=%s: rejected value was stored", tc.key, tc.value)
		}
	}
}

func TestOpenAtLoginWarns(t *testing.T) {
	c, _ := newCLI()
	r := set(t, c, "open-at-login", "true")
	if r.Value != "true" || r.Warning == nil {
		t.Errorf("got %+v", r)
	}
}

func TestListIncludesEveryProvider(t *testing.T) {
	c, _ := newCLI()
	keys := map[string]bool{}
	for _, e := range c.List() {
		keys[e.Key] = true
	}
	for _, id := range domain.AllKnown {
		if !keys["provider."+string(id)+".enabled"] {
			t.Errorf("missing %s", id)
		}
	}
}

func TestGarbageThemeFallsBack(t *testing.T) {
	c, m := newCLI()
	m[KeyCLITheme] = "garbage"
	if got := get(t, c, "cli-theme"); got != "compact" {
		t.Errorf("got %s", got)
	}
	if _, ok := c.StoredTheme(); ok {
		t.Error("garbage must read as unset")
	}
}

func TestProviderOrder(t *testing.T) {
	c, m := newCLI()
	all := "openrouter,claude,codex,gemini,grok,pi-local,ollama,ollama-cloud,lmstudio,lms-llamacpp,llamacpp"
	if got := get(t, c, "provider-order"); got != all {
		t.Errorf("default %s", got)
	}
	if r := set(t, c, "provider-order", "Codex, engine.gpu-box,claude"); r.Value != "codex,engine.gpu-box,claude" {
		t.Errorf("got %s", r.Value)
	}
	want := []domain.ProviderID{"codex", "engine.gpu-box", "claude"}
	got := LoadPreferences(m).ProviderOrder
	if len(got) != 3 || got[0] != want[0] || got[1] != want[1] || got[2] != want[2] {
		t.Errorf("order %v", got)
	}
	for _, bad := range []string{"codex,nope", "codex,Codex", "engine.unknown", "codex,,claude"} {
		_, err := c.Set("provider-order", bad)
		var se Error
		if !errors.As(err, &se) || !strings.Contains(se.Error(), "openrouter, claude") || !strings.Contains(se.Error(), "engine.gpu-box") {
			t.Errorf("%s: %v", bad, err)
		}
	}
	if m[KeyProviderOrder] != "codex,engine.gpu-box,claude" {
		t.Errorf("bad values changed the store: %v", m[KeyProviderOrder])
	}
	if r := set(t, c, "provider-order", ""); r.Value != all {
		t.Errorf("reset shows %s", r.Value)
	}
	if _, ok := m[KeyProviderOrder]; ok {
		t.Error("reset must delete the key")
	}
}

func TestMixedCaseEngineIsStoredLowerAndStillOrders(t *testing.T) {
	m := Memory{}
	live := domain.ProviderID("engine.GPU")
	c := CLI{Store: m, CustomEngines: func() []domain.ProviderID { return []domain.ProviderID{live} }}
	if r := set(t, c, "provider-order", "engine.GPU,claude"); r.Value != "engine.gpu,claude" {
		t.Errorf("got %s", r.Value)
	}
	ordered := domain.OrderProviders([]domain.ProviderID{live, domain.Claude, domain.Codex},
		func(id domain.ProviderID) domain.ProviderID { return id }, LoadPreferences(m).ProviderOrder)
	if ordered[0] != live || ordered[1] != domain.Claude || ordered[2] != domain.Codex {
		t.Errorf("order %v", ordered)
	}
}

func TestDefaultsCoercions(t *testing.T) {
	c, m := newCLI()
	m[KeyThreshold] = int64(1)
	m[KeyPaceWarnings] = int64(0)
	m[KeyResetNotification] = "YES"
	m[KeyOpenAtLogin] = "0"
	m[KeyRefreshInterval] = "nonsense"
	for key, want := range map[string]string{
		"threshold": "1.00", "pace-warnings": "false", "reset-notifications": "true", "open-at-login": "false", "refresh-interval": "5m",
	} {
		if got := get(t, c, key); got != want {
			t.Errorf("%s: got %s want %s", key, got, want)
		}
	}
}

// Expected values were printed by UserDefaults on macOS.
func TestUserDefaultsCoercionTable(t *testing.T) {
	cases := []struct {
		value   any
		text    string
		boolean bool
		number  string
	}{
		{true, "1", true, "1"}, {false, "0", false, "0"}, {int64(0), "0", false, "0"}, {int64(2), "2", true, "2"},
		{0.0, "0", false, "0"}, {0.5, "0.5", true, "0.5"}, {"YES", "YES", true, "nil"}, {"yes", "yes", true, "nil"},
		{"Y", "Y", false, "nil"}, {"no", "no", false, "nil"}, {"true", "true", true, "nil"}, {"TRUE", "TRUE", true, "nil"},
		{"false", "false", false, "nil"}, {"0", "0", false, "nil"}, {"1", "1", true, "nil"}, {"2", "2", false, "nil"},
		{"0.5", "0.5", false, "nil"}, {"word", "word", false, "nil"}, {"", "", false, "nil"}, {" yes ", " yes ", false, "nil"},
	}
	for _, c := range cases {
		text, _ := stringValue(c.value, true)
		number := "nil"
		if n, ok := doubleValue(c.value, true); ok {
			number = strconv.FormatFloat(n, 'g', -1, 64)
		}
		if text != c.text || boolValue(c.value) != c.boolean || number != c.number {
			t.Errorf("%#v: text=%q bool=%v number=%s", c.value, text, boolValue(c.value), number)
		}
	}
}

func TestPreferences(t *testing.T) {
	p := LoadPreferences(Memory{
		KeyThreshold:                      0.7,
		KeyRefreshInterval:                "15m",
		KeyProviderEnabled(domain.Gemini): false,
		KeyProviderEnabled("engine.x"):    true,
		KeyClaudeSource:                   "hook",
		KeyBudget(domain.BudgetTotal):     float64(50),
		"unrelated":                       true,
	})
	if p.Threshold != 0.7 || p.RefreshInterval != "15m" || p.ClaudeSource != "hook" {
		t.Errorf("%+v", p)
	}
	if p.IsEnabled(domain.Gemini) || !p.IsEnabled(domain.Claude) || !p.IsEnabled("engine.x") {
		t.Errorf("enabled %+v", p.ProviderEnabled)
	}
	if p.BudgetOverrides[domain.BudgetTotal] != 50 {
		t.Errorf("budgets %+v", p.BudgetOverrides)
	}
}

func TestJSONFileRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "sub", "settings.json")
	s := &JSONFile{Path: path}
	if len(s.All()) != 0 {
		t.Fatal("missing file must read as empty")
	}
	if _, err := os.Stat(filepath.Dir(path)); err == nil {
		t.Fatal("reading must not create the directory")
	}
	c := CLI{Store: s}
	set(t, c, "threshold", "0.7")
	set(t, c, "pace-warnings", "false")
	set(t, c, "theme", "dark")
	fresh := CLI{Store: &JSONFile{Path: path}}
	for key, want := range map[string]string{"threshold": "0.70", "pace-warnings": "false", "theme": "dark"} {
		if got := get(t, fresh, key); got != want {
			t.Errorf("%s: %s", key, got)
		}
	}
	if err := s.Delete(KeyTheme); err != nil {
		t.Fatal(err)
	}
	if got := get(t, fresh, "theme"); got != "auto" {
		t.Errorf("after delete: %s", got)
	}
	if err := os.WriteFile(path, []byte("not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := s.Set(KeyTheme, "dark"); err == nil {
		t.Error("a corrupt file must not be replaced")
	}
}

func TestParsePlist(t *testing.T) {
	plist := `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSWindow Frame</key>
	<string>1 2 3 4</string>
	<key>aub.threshold</key>
	<real>0.7</real>
	<key>aub.count</key>
	<integer>3</integer>
	<key>aub.on</key>
	<true/>
	<key>aub.off</key>
	<false/>
	<key>notif.claude</key>
	<dict>
		<key>inner</key>
		<string>skip me</string>
		<key>deep</key>
		<dict><key>x</key><true/></dict>
	</dict>
	<key>blob</key>
	<data>AAAA</data>
	<key>aub.after</key>
	<string>a &amp; b</string>
</dict>
</plist>`
	got, err := parsePlistDict([]byte(plist))
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]any{"NSWindow Frame": "1 2 3 4", "aub.threshold": 0.7, "aub.count": int64(3), "aub.on": true, "aub.off": false, "aub.after": "a & b"}
	if len(got) != len(want) {
		t.Errorf("got %v", got)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s: got %#v want %#v", k, got[k], v)
		}
	}
}

// Real `defaults` round trip on a throwaway domain; never the app's domain.
func TestDefaultsStoreOnThrowawayDomain(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS only")
	}
	domainName := "app.agents-usage-bar.gotest." + strconv.FormatInt(time.Now().UnixNano(), 36)
	t.Cleanup(func() { _ = exec.Command(defaultsTool, "delete", domainName).Run() })
	s := &Defaults{Domain: domainName}
	c := CLI{Store: s}
	if len(s.All()) != 0 {
		t.Errorf("a domain that does not exist reads as empty: %v", s.All())
	}
	if got := get(t, c, "threshold"); got != "0.80" {
		t.Errorf("absent: %s", got)
	}
	set(t, c, "threshold", "0.7")
	set(t, c, "pace-warnings", "false")
	set(t, c, "refresh-interval", "1m")
	if got := s.All()[KeyThreshold]; got != 0.7 {
		t.Errorf("threshold must stay a 64-bit real: %#v", got)
	}
	if got := s.All()[KeyPaceWarnings]; got != false {
		t.Errorf("bool stored as %#v", got)
	}
	fresh := CLI{Store: &Defaults{Domain: domainName}}
	for key, want := range map[string]string{"threshold": "0.70", "pace-warnings": "false", "refresh-interval": "1m"} {
		if got := get(t, fresh, key); got != want {
			t.Errorf("%s: %s", key, got)
		}
	}
	if err := s.Delete(KeyRefreshInterval); err != nil {
		t.Fatal(err)
	}
	if got := get(t, c, "refresh-interval"); got != "5m" {
		t.Errorf("after delete: %s", got)
	}
}
