package config

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/settings"
)

const fixtures = "../../../AgentsUsageBarTests/ConfigTests/Fixtures"

func fixture(t *testing.T, name string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(fixtures, name+".toml"))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestTomlEmptyAndComments(t *testing.T) {
	want := TomlSections{"": {}}
	if got := ParseToml(""); !reflect.DeepEqual(got, want) {
		t.Errorf("%v", got)
	}
	if got := ParseToml(fixture(t, "comments-only")); !reflect.DeepEqual(got, want) {
		t.Errorf("%v", got)
	}
}

func TestTomlScalars(t *testing.T) {
	top := ParseToml("label = \"hello\"\ncount = 42\nratio = 3.14\nenabled = true\noff = false\n")[""]
	want := map[string]TomlValue{"label": "hello", "count": 42, "ratio": 3.14, "enabled": true, "off": false}
	if !reflect.DeepEqual(top, want) {
		t.Errorf("%v", top)
	}
}

func TestTomlSectionsAndComments(t *testing.T) {
	got := ParseToml("[openrouter]\napi_key = \"sk-test\"\n")
	if len(got[""]) != 0 || got["openrouter"]["api_key"] != "sk-test" {
		t.Errorf("%v", got)
	}
	if got := ParseToml("key = \"value\"  # trailing\n")[""]["key"]; got != "value" {
		t.Errorf("%v", got)
	}
	if got := ParseToml("key = \"https://example.com/#frag\"\n")[""]["key"]; got != "https://example.com/#frag" {
		t.Errorf("%v", got)
	}
	if got := ParseToml("[a]\nx = 1\n[b]\ny = 2\n[a]\nz = 3\n")["a"]; !reflect.DeepEqual(got, map[string]TomlValue{"z": 3}) {
		t.Errorf("a repeated section restarts: %v", got)
	}
}

func TestTomlMalformedLinesAreSkipped(t *testing.T) {
	got := ParseToml(fixture(t, "malformed"))
	if got[""]["refresh_interval"] != "5m" || got[""]["threshold"] != 0.80 {
		t.Errorf("%v", got[""])
	}
	or := got["openrouter"]
	if or["api_key"] != "fake-or-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" || or["enabled"] != true {
		t.Errorf("%v", or)
	}
	for _, bad := range []string{"bare_token_no_equals", "models"} {
		if _, ok := or[bad]; ok {
			t.Errorf("%s parsed", bad)
		}
	}
	if _, ok := got[""]["this_line_is_broken"]; ok {
		t.Error("broken line parsed")
	}
	if _, ok := ParseToml("models = [\"a\", \"b\"]\n")[""]["models"]; ok {
		t.Error("array parsed")
	}
}

func TestTomlValidFixtureAndGarbage(t *testing.T) {
	or := ParseToml(fixture(t, "valid"))["openrouter"]
	if or["api_url"] != "https://openrouter.ai/api/v1" || or["x_title"] != "Agents Usage Bar" || or["enabled"] != true {
		t.Errorf("%v", or)
	}
	if ParseToml("=!@#$ [[[ \"\"\" ]]] {{ \x7f")[""] == nil {
		t.Error("top level must exist")
	}
}

func load(t *testing.T, env map[string]string, toml string) App {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.toml")
	if toml != "" {
		if err := os.WriteFile(path, []byte(toml), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return Load(MapEnv(env), path)
}

func TestDefaultsWhenAbsent(t *testing.T) {
	a := load(t, nil, "")
	if a.RefreshInterval != "5m" || a.Threshold != 0.80 || a.OpenRouter.APIKey != nil || !a.OpenRouter.Enabled || a.OpenRouter.XTitle != "Agents Usage Bar" {
		t.Errorf("%+v", a)
	}
	if a.OpenRouter.APIURL.String() != "https://openrouter.ai/api/v1" || a.Grok.APIURL.String() != "https://cli-chat-proxy.grok.com/v1" || a.LMStudio.Port != 1234 || a.LlamaCpp.Port != nil {
		t.Errorf("%+v", a)
	}
	if a.Codex.SessionWindowDays != 2 || len(a.Budgets.Caps) != 0 {
		t.Errorf("%+v", a)
	}
}

func TestEnvBeatsTomlBeatsDefault(t *testing.T) {
	toml := `refresh_interval = "15m"
threshold = 1
[openrouter]
api_key = "toml-key"
management_key = "toml-mgmt"
api_url = "https://toml.example.com/v1"
http_referer = "toml-ref"
x_title = "toml-title"
enabled = false
`
	a := load(t, nil, toml)
	or := a.OpenRouter
	if or.APIKey.Reveal() != "toml-key" || or.ManagementKey.Reveal() != "toml-mgmt" || or.APIURL.Host != "toml.example.com" || *or.HTTPReferer != "toml-ref" || or.XTitle != "toml-title" || or.Enabled {
		t.Errorf("%+v", or)
	}
	if a.RefreshInterval != "15m" || a.Threshold != 1 {
		t.Errorf("%+v", a)
	}
	a = load(t, map[string]string{
		"OPENROUTER_API_KEY": "env-key", "OPENROUTER_MANAGEMENT_KEY": "env-mgmt", "OPENROUTER_API_URL": "https://env.example.com",
		"OPENROUTER_HTTP_REFERER": "env-ref", "OPENROUTER_X_TITLE": "env-title",
	}, toml)
	or = a.OpenRouter
	if or.APIKey.Reveal() != "env-key" || or.ManagementKey.Reveal() != "env-mgmt" || or.APIURL.Host != "env.example.com" || *or.HTTPReferer != "env-ref" || or.XTitle != "env-title" {
		t.Errorf("%+v", or)
	}
}

func TestEmptyEnvIsAbsent(t *testing.T) {
	a := load(t, map[string]string{"OPENROUTER_API_KEY": "", "XAI_API_KEY": "", "CODEX_BEARER_TOKEN": ""}, "[openrouter]\napi_key = \"k\"\n")
	if a.OpenRouter.APIKey.Reveal() != "k" || a.Grok.APIKey != nil || a.Codex.BearerOverride != nil {
		t.Errorf("%+v", a)
	}
}

func TestBadValuesFallBack(t *testing.T) {
	a := load(t, nil, "refresh_interval = \"7m\"\nthreshold = \"high\"\n")
	if a.RefreshInterval != "5m" || a.Threshold != 0.80 {
		t.Errorf("%+v", a)
	}
}

func TestSecretsComeOnlyFromAllowedSources(t *testing.T) {
	a := load(t, nil, "[codex]\nbearer = \"no\"\nCODEX_BEARER_TOKEN = \"no\"\n[grok]\nXAI_API_KEY = \"no\"\napi_key = \"no\"\n")
	if a.Codex.BearerOverride != nil || a.Grok.APIKey != nil {
		t.Error("TOML must not supply env-only credentials")
	}
	a = load(t, map[string]string{"CODEX_BEARER_TOKEN": "b", "XAI_API_KEY": "x", "GEMINI_PROJECT_ID": "p"}, "")
	if a.Codex.BearerOverride.Reveal() != "b" || a.Grok.APIKey.Reveal() != "x" || *a.Gemini.ProjectIDOverride != "p" {
		t.Errorf("%+v", a)
	}
}

func TestGrokSection(t *testing.T) {
	toml := "[grok]\nenabled = false\napi_url = \"https://g.example.com\"\nmanagement_key = \"m\"\nteam_id = \"t\"\n"
	a := load(t, nil, toml)
	if a.Grok.Enabled || a.Grok.APIURL.Host != "g.example.com" || a.Grok.ManagementKey.Reveal() != "m" || *a.Grok.TeamID != "t" {
		t.Errorf("%+v", a.Grok)
	}
	a = load(t, map[string]string{"GROK_CLI_CHAT_PROXY_BASE_URL": "https://e.example.com", "XAI_MANAGEMENT_KEY": "em", "XAI_TEAM_ID": "et"}, toml)
	if a.Grok.APIURL.Host != "e.example.com" || a.Grok.ManagementKey.Reveal() != "em" || *a.Grok.TeamID != "et" {
		t.Errorf("%+v", a.Grok)
	}
	a = load(t, nil, "[grok]\nmanagement_key = \"\"\nteam_id = \"\"\n")
	if a.Grok.ManagementKey != nil || a.Grok.TeamID != nil {
		t.Errorf("%+v", a.Grok)
	}
}

func TestLocalSections(t *testing.T) {
	a := load(t, nil, "[ollama]\nenabled = false\n[lmstudio]\nport = 4321\n[llamacpp]\nport = 8080\n")
	if a.Ollama.Enabled || a.LMStudio.Port != 4321 || *a.LlamaCpp.Port != 8080 {
		t.Errorf("%+v", a)
	}
	a = load(t, nil, "[llamacpp]\nenabled = false\nport = 8080\n[lmstudio]\nport = \"x\"\n")
	if a.LlamaCpp.Enabled || a.LMStudio.Port != 1234 {
		t.Errorf("%+v", a)
	}
	a = load(t, nil, "[llamacpp]\nport = \"garbage\"\n")
	if a.LlamaCpp.Port != nil {
		t.Errorf("%+v", a.LlamaCpp)
	}
}

func TestOllamaCloud(t *testing.T) {
	a := load(t, nil, "[ollama]\ncloud = false\napi_key = \"k\"\nbilling_day = 8\n")
	c := a.OllamaCloud
	if c.Enabled || c.APIKey.Reveal() != "k" || c.APIKeySource != SourceConfig || *c.BillingDay != 8 {
		t.Errorf("%+v", c)
	}
	a = load(t, map[string]string{"OLLAMA_API_KEY": "e"}, "[ollama]\napi_key = \"k\"\n")
	if a.OllamaCloud.APIKey.Reveal() != "e" || a.OllamaCloud.APIKeySource != SourceEnv {
		t.Errorf("%+v", a.OllamaCloud)
	}
	for _, bad := range []string{"0", "32", "\"8\"", "8.5"} {
		a = load(t, nil, "[ollama]\nbilling_day = "+bad+"\n")
		if a.OllamaCloud.BillingDay != nil {
			t.Errorf("%s accepted", bad)
		}
	}
}

func TestBudgets(t *testing.T) {
	a := load(t, nil, "")
	if len(a.Budgets.Caps) != 0 {
		t.Error("no section, no budget")
	}
	a = load(t, nil, "[budgets]\ntotal_usd = 100\nclaude_usd = 50.5\ncodex_usd = 25\nopenrouter_usd = 10\n")
	want := map[string]string{"total": "100", "claude": "50.5", "codex": "25", "openrouter": "10"}
	for _, scope := range domain.AllBudgetScopes() {
		if got := a.Budgets.Caps[scope].String(); got != want[scope.Name()] {
			t.Errorf("%s: %s", scope.Name(), got)
		}
	}
	a = load(t, nil, "[budgets]\ntotal_usd = 0\nclaude_usd = -5\ncodex_usd = \"10\"\ngrok_usd = 5\n")
	if len(a.Budgets.Caps) != 0 {
		t.Errorf("%+v", a.Budgets.Caps)
	}
}

func prefs(m settings.Memory) settings.Preferences { return settings.LoadPreferences(m) }

func TestPreferencesOverlay(t *testing.T) {
	toml := "refresh_interval = \"15m\"\n[openrouter]\napi_key = \"toml-key\"\n[budgets]\ntotal_usd = 100\nclaude_usd = 50\n"
	a := load(t, nil, toml).WithPreferences(prefs(settings.Memory{
		settings.KeyRefreshInterval:                                     "1m",
		settings.KeyThreshold:                                           0.7,
		settings.KeyProviderEnabled(domain.Gemini):                      false,
		settings.KeyProviderEnabled(domain.LMStudioLlamaCpp):            false,
		settings.KeyBudget(domain.BudgetTotal):                          float64(20),
		settings.KeyBudget(domain.BudgetScope{Provider: domain.Claude}): float64(0),
	}))
	if a.RefreshInterval != "1m" || a.Threshold != 0.7 || a.Gemini.Enabled {
		t.Errorf("%+v", a)
	}
	if !a.Codex.Enabled {
		t.Error("an absent flag keeps config")
	}
	if a.OpenRouter.APIKey.Reveal() != "toml-key" {
		t.Error("credentials must not change")
	}
	if a.Engines[0].Enabled {
		t.Error("engine flag")
	}
	if a.Budgets.Caps[domain.BudgetTotal].String() != "20" {
		t.Error("a Settings value wins")
	}
	if _, ok := a.Budgets.Caps[domain.BudgetScope{Provider: domain.Claude}]; ok {
		t.Error("zero turns the budget off")
	}
}

func TestEngines(t *testing.T) {
	builtIn := func(es []LocalEngine) LocalEngine {
		for _, e := range es {
			if e.ID == domain.LMStudioLlamaCpp {
				return e
			}
		}
		t.Fatal("no built-in")
		return LocalEngine{}
	}
	if got := Defaults().Engines; *builtIn(got).MatchPath != "/.lmstudio/extensions/backends/" {
		t.Errorf("%+v", got)
	}
	overlay := builtIn(ParseEngines(ParseToml("[engine.lms-llamacpp]\nenabled = false\n")))
	if overlay.Enabled || *overlay.MatchPath != "/.lmstudio/extensions/backends/" {
		t.Errorf("%+v", overlay)
	}
	custom := ParseEngines(ParseToml("[engine.classifier]\nname = \"DRM classifier\"\nkind = \"llamacpp\"\nport = 8123\n"))
	if len(custom) != 2 || custom[1].ID != "engine.classifier" || custom[1].DisplayName != "DRM classifier" || *custom[1].Port != 8123 {
		t.Errorf("%+v", custom)
	}
	for name, toml := range map[string]string{
		"reserved slug":    "[engine.claude]\nport = 9999\n",
		"unknown kind":     "[engine.vllm]\nkind = \"openai\"\nport = 8000\n",
		"no discovery key": "[engine.x]\nname = \"X\"\n",
		"dotted slug":      "[engine.a.b]\nport = 1\n",
		"empty slug":       "[engine.]\nport = 1\n",
	} {
		if got := ParseEngines(ParseToml(toml)); len(got) != 1 {
			t.Errorf("%s: %+v", name, got)
		}
	}
	named := ParseEngines(ParseToml("[engine.gpu-box]\nport = 1\n[engine.z]\ndisplay_name = \"Zed\"\nmatch_path = \"/z\"\nport = 70000\n"))
	if named[1].DisplayName != "gpu box" || named[2].DisplayName != "Zed" || named[2].Port != nil || *named[2].MatchPath != "/z" {
		t.Errorf("%+v", named)
	}
	a := load(t, nil, "[engine.gpu-box]\nport = 1\n")
	if ids := a.CustomEngineIDs(); len(ids) != 1 || ids[0] != "engine.gpu-box" {
		t.Errorf("%v", ids)
	}
	msg := LocalEngine{ID: "engine.x"}.UnresolvedPlaceholder()
	if msg == nil || !strings.Contains(*msg, "[engine.x] port or match_path") {
		t.Errorf("%v", msg)
	}
	port := 1
	if (LocalEngine{ID: "engine.x", Port: &port}).UnresolvedPlaceholder() != nil {
		t.Error("configured engines have no hint")
	}
}
