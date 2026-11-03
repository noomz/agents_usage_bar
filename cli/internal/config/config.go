package config

import (
	"net/url"
	"os"
	"sort"
	"strings"

	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/secret"
	"github.com/noomz/agents_usage_bar/cli/internal/settings"
)

// Env reads the environment. An empty value counts as absent, so `KEY=` does not look set.
type Env func(key string) (string, bool)

// ProcessEnv reads the process environment.
func ProcessEnv(key string) (string, bool) {
	v := os.Getenv(key)
	return v, v != ""
}

// MapEnv is an Env for tests.
func MapEnv(m map[string]string) Env {
	return func(key string) (string, bool) {
		v := m[key]
		return v, v != ""
	}
}

// App is the resolved configuration.
type App struct {
	RefreshInterval string
	Threshold       float64
	OpenRouter      OpenRouter
	Codex           Codex
	Gemini          Gemini
	Grok            Grok
	Ollama          Ollama
	OllamaCloud     OllamaCloud
	LMStudio        LMStudio
	LlamaCpp        LlamaCpp
	Engines         []LocalEngine
	Budgets         domain.BudgetConfig
}

// OpenRouter configures the OpenRouter provider.
type OpenRouter struct {
	APIKey        *secret.Secret
	APIURL        *url.URL
	HTTPReferer   *string
	XTitle        string
	Enabled       bool
	ManagementKey *secret.Secret
}

// Codex configures the Codex provider. BearerOverride comes only from the environment.
type Codex struct {
	Enabled           bool
	BearerOverride    *secret.Secret
	SessionWindowDays int
}

// Gemini configures the Gemini provider.
type Gemini struct {
	Enabled           bool
	ProjectIDOverride *string
}

// Grok configures the Grok provider. APIKey comes only from the environment.
type Grok struct {
	Enabled       bool
	APIKey        *secret.Secret
	APIURL        *url.URL
	ManagementKey *secret.Secret
	TeamID        *string
}

// Ollama configures the localhost Ollama row.
type Ollama struct {
	Enabled bool
}

// CredentialSource says where an API key came from.
type CredentialSource string

// The sources.
const (
	SourceEnv    CredentialSource = "env"
	SourceConfig CredentialSource = "config"
)

// OllamaCloud configures the cloud usage row, keyed from the `[ollama]` section.
type OllamaCloud struct {
	Enabled      bool
	APIKey       *secret.Secret
	APIKeySource CredentialSource
	// BillingDay is 1 through 31; nil means the reset is unknown.
	BillingDay *int
}

// LMStudio configures LM Studio.
type LMStudio struct {
	Enabled bool
	Port    int
}

// LlamaCpp configures llama.cpp. No port means no live row: this app never scans ports.
type LlamaCpp struct {
	Enabled bool
	Port    *int
}

func mustURL(s string) *url.URL {
	u, err := url.Parse(s)
	if err != nil {
		panic(err)
	}
	return u
}

// Defaults is the baseline under environment and config.toml.
func Defaults() App {
	return App{
		RefreshInterval: domain.DefaultRefreshInterval,
		Threshold:       0.80,
		OpenRouter:      OpenRouter{APIURL: mustURL("https://openrouter.ai/api/v1"), XTitle: "Agents Usage Bar", Enabled: true},
		Codex:           Codex{Enabled: true, SessionWindowDays: 2},
		Gemini:          Gemini{Enabled: true},
		Grok:            Grok{Enabled: true, APIURL: mustURL("https://cli-chat-proxy.grok.com/v1")},
		Ollama:          Ollama{Enabled: true},
		OllamaCloud:     OllamaCloud{Enabled: true},
		LMStudio:        LMStudio{Enabled: true, Port: 1234},
		LlamaCpp:        LlamaCpp{Enabled: true},
		Engines:         []LocalEngine{builtInLMStudioLlamaCpp()},
		Budgets:         domain.BudgetConfig{Caps: map[domain.BudgetScope]domain.Money{}},
	}
}

// resolver reads one section with env-over-toml layering.
type resolver struct {
	env     Env
	section map[string]TomlValue
}

func (r resolver) boolOr(key string, fallback bool) bool {
	if b, ok := r.section[key].(bool); ok {
		return b
	}
	return fallback
}

func (r resolver) tomlString(key string) (string, bool) {
	s, ok := r.section[key].(string)
	return s, ok
}

func (r resolver) nonEmpty(key string) (string, bool) {
	s, ok := r.tomlString(key)
	return s, ok && s != ""
}

func (r resolver) secret(envKey, tomlKey string, allowEmpty bool) *secret.Secret {
	if v, ok := r.env(envKey); ok {
		s := secret.New(v)
		return &s
	}
	if tomlKey == "" {
		return nil
	}
	v, ok := r.tomlString(tomlKey)
	if !ok || (!allowEmpty && v == "") {
		return nil
	}
	s := secret.New(v)
	return &s
}

func (r resolver) url(envKey, tomlKey string, fallback *url.URL) *url.URL {
	if v, ok := r.env(envKey); ok {
		if u, err := url.Parse(v); err == nil {
			return u
		}
	}
	if v, ok := r.tomlString(tomlKey); ok && v != "" {
		if u, err := url.Parse(v); err == nil {
			return u
		}
	}
	return fallback
}

// Load resolves env > toml > defaults. It never fails: a missing or unreadable file is empty.
func Load(env Env, tomlPath string) App {
	var toml TomlSections
	if data, err := os.ReadFile(tomlPath); err == nil {
		toml = ParseToml(string(data))
	} else {
		toml = TomlSections{"": {}}
	}
	return resolve(env, toml)
}

func resolve(env Env, toml TomlSections) App {
	defaults := Defaults()
	section := func(name string) resolver { return resolver{env, toml[name]} }
	top, or, codex, gemini, grok := toml[""], section("openrouter"), section("codex"), section("gemini"), section("grok")
	ollama, lmstudio, llamacpp := section("ollama"), section("lmstudio"), section("llamacpp")

	app := defaults
	if s, ok := top["refresh_interval"].(string); ok && domain.ValidRefreshInterval(s) {
		app.RefreshInterval = s
	}
	switch t := top["threshold"].(type) {
	case float64:
		app.Threshold = t
	case int:
		app.Threshold = float64(t)
	}

	app.OpenRouter = OpenRouter{
		APIKey:        or.secret("OPENROUTER_API_KEY", "api_key", true),
		APIURL:        or.url("OPENROUTER_API_URL", "api_url", defaults.OpenRouter.APIURL),
		XTitle:        defaults.OpenRouter.XTitle,
		Enabled:       or.boolOr("enabled", defaults.OpenRouter.Enabled),
		ManagementKey: or.secret("OPENROUTER_MANAGEMENT_KEY", "management_key", true),
	}
	if v, ok := env("OPENROUTER_HTTP_REFERER"); ok {
		app.OpenRouter.HTTPReferer = &v
	} else if v, ok := or.tomlString("http_referer"); ok {
		app.OpenRouter.HTTPReferer = &v
	}
	if v, ok := env("OPENROUTER_X_TITLE"); ok {
		app.OpenRouter.XTitle = v
	} else if v, ok := or.tomlString("x_title"); ok {
		app.OpenRouter.XTitle = v
	}

	app.Codex = Codex{
		Enabled:           codex.boolOr("enabled", defaults.Codex.Enabled),
		BearerOverride:    codex.secret("CODEX_BEARER_TOKEN", "", false),
		SessionWindowDays: defaults.Codex.SessionWindowDays,
	}

	app.Gemini = Gemini{Enabled: gemini.boolOr("enabled", defaults.Gemini.Enabled)}
	if v, ok := env("GEMINI_PROJECT_ID"); ok {
		app.Gemini.ProjectIDOverride = &v
	}

	app.Grok = Grok{
		Enabled:       grok.boolOr("enabled", defaults.Grok.Enabled),
		APIKey:        grok.secret("XAI_API_KEY", "", false),
		APIURL:        grok.url("GROK_CLI_CHAT_PROXY_BASE_URL", "api_url", defaults.Grok.APIURL),
		ManagementKey: grok.secret("XAI_MANAGEMENT_KEY", "management_key", false),
	}
	if v, ok := env("XAI_TEAM_ID"); ok {
		app.Grok.TeamID = &v
	} else if v, ok := grok.nonEmpty("team_id"); ok {
		app.Grok.TeamID = &v
	}

	app.Ollama = Ollama{Enabled: ollama.boolOr("enabled", defaults.Ollama.Enabled)}
	app.OllamaCloud = OllamaCloud{Enabled: ollama.boolOr("cloud", defaults.OllamaCloud.Enabled)}
	if v, ok := env("OLLAMA_API_KEY"); ok {
		s := secret.New(v)
		app.OllamaCloud.APIKey, app.OllamaCloud.APIKeySource = &s, SourceEnv
	} else if v, ok := ollama.nonEmpty("api_key"); ok {
		s := secret.New(v)
		app.OllamaCloud.APIKey, app.OllamaCloud.APIKeySource = &s, SourceConfig
	}
	if d, ok := ollama.section["billing_day"].(int); ok && d >= 1 && d <= 31 {
		app.OllamaCloud.BillingDay = &d
	}

	app.LMStudio = LMStudio{Enabled: lmstudio.boolOr("enabled", defaults.LMStudio.Enabled), Port: defaults.LMStudio.Port}
	if p, ok := lmstudio.section["port"].(int); ok {
		app.LMStudio.Port = p
	}

	app.LlamaCpp = LlamaCpp{Enabled: llamacpp.boolOr("enabled", defaults.LlamaCpp.Enabled)}
	if p, ok := llamacpp.section["port"].(int); ok {
		app.LlamaCpp.Port = &p
	}

	app.Budgets = parseBudgets(toml["budgets"])
	app.Engines = ParseEngines(toml)
	return app
}

// A missing, non-number, or non-positive cap is no budget.
func parseBudgets(section map[string]TomlValue) domain.BudgetConfig {
	caps := map[domain.BudgetScope]domain.Money{}
	for _, scope := range domain.AllBudgetScopes() {
		var cap decimal.Decimal
		switch v := section[scope.TomlKey()].(type) {
		case int:
			cap = decimal.FromInt(int64(v))
		case float64:
			cap = decimal.FromFloat64(v)
		default:
			continue
		}
		if cap.Sign() > 0 {
			caps[scope] = domain.NewMoney(cap)
		}
	}
	return domain.BudgetConfig{Caps: caps}
}

// WithPreferences overlays the user-mutable knobs. Credentials are never touched.
func (a App) WithPreferences(p settings.Preferences) App {
	a.RefreshInterval = p.RefreshInterval
	a.Threshold = p.Threshold
	override := func(id domain.ProviderID, current bool) bool {
		if enabled, ok := p.ProviderEnabled[id]; ok {
			return enabled
		}
		return current
	}
	a.OpenRouter.Enabled = override(domain.OpenRouter, a.OpenRouter.Enabled)
	a.Codex.Enabled = override(domain.Codex, a.Codex.Enabled)
	a.Gemini.Enabled = override(domain.Gemini, a.Gemini.Enabled)
	a.Grok.Enabled = override(domain.Grok, a.Grok.Enabled)
	a.Ollama.Enabled = override(domain.Ollama, a.Ollama.Enabled)
	a.OllamaCloud.Enabled = override(domain.OllamaCloud, a.OllamaCloud.Enabled)
	a.LMStudio.Enabled = override(domain.LMStudio, a.LMStudio.Enabled)
	a.LlamaCpp.Enabled = override(domain.LlamaCpp, a.LlamaCpp.Enabled)
	engines := make([]LocalEngine, len(a.Engines))
	for i, e := range a.Engines {
		e.Enabled = override(e.ID, e.Enabled)
		engines[i] = e
	}
	a.Engines = engines
	caps := make(map[domain.BudgetScope]domain.Money, len(a.Budgets.Caps))
	for k, v := range a.Budgets.Caps {
		caps[k] = v
	}
	for scope, value := range p.BudgetOverrides {
		if value > 0 {
			caps[scope] = domain.NewMoney(decimal.FromFloat64(value))
		} else {
			delete(caps, scope)
		}
	}
	a.Budgets = domain.BudgetConfig{Caps: caps}
	return a
}

// LocalEngine is a llama.cpp-compatible HTTP server found by executable path, explicit port,
// or both.
type LocalEngine struct {
	ID          domain.ProviderID
	DisplayName string
	Enabled     bool
	// MatchPath is matched as a substring of a process's executable path.
	MatchPath *string
	Port      *int
}

const engineKindLlamaCpp = "llamacpp"

func builtInLMStudioLlamaCpp() LocalEngine {
	path := "/.lmstudio/extensions/backends/"
	return LocalEngine{ID: domain.LMStudioLlamaCpp, DisplayName: "LM Studio llama.cpp", Enabled: true, MatchPath: &path}
}

// UnresolvedPlaceholder is the row caption when no port resolves: a discoverability hint when
// nothing is configured, otherwise nil.
func (e LocalEngine) UnresolvedPlaceholder() *string {
	if (e.MatchPath == nil || *e.MatchPath == "") && e.Port == nil {
		msg := "Set [engine." + e.ID.EngineSlug() + "] port or match_path in config.toml"
		return &msg
	}
	return nil
}

// ParseEngines reads `[engine.<slug>]` sections, sorted by name because Swift's order is a
// per-process hash order. `[engine.lms-llamacpp]` overlays the built-in; any other slug
// becomes `engine.<slug>`; slugs naming hosted providers are skipped.
func ParseEngines(toml TomlSections) []LocalEngine {
	engines := []LocalEngine{builtInLMStudioLlamaCpp()}
	reserved := map[string]bool{}
	for _, id := range domain.AllKnown {
		if id != domain.LMStudioLlamaCpp {
			reserved[string(id)] = true
		}
	}
	names := make([]string, 0, len(toml))
	for name := range toml {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		if !strings.HasPrefix(name, "engine.") {
			continue
		}
		slug := strings.TrimPrefix(name, "engine.")
		if slug == "" || strings.Contains(slug, ".") || reserved[slug] {
			continue
		}
		keys := toml[name]
		if kind, ok := keys["kind"].(string); ok && kind != engineKindLlamaCpp {
			continue
		}
		enabled, isBool := keys["enabled"].(bool)
		if !isBool {
			enabled = true
		}
		display := strings.ReplaceAll(slug, "-", " ")
		if s, _ := keys["name"].(string); s != "" {
			display = s
		} else if s, _ := keys["display_name"].(string); s != "" {
			display = s
		}
		var match *string
		if s, _ := keys["match_path"].(string); s != "" {
			match = &s
		}
		var port *int
		if p, ok := keys["port"].(int); ok && p >= 1 && p <= 65535 {
			port = &p
		}
		id := domain.ProviderID("engine." + slug)
		if slug == string(domain.LMStudioLlamaCpp) {
			id = domain.LMStudioLlamaCpp
		}
		// An overlay of the built-in may only flip enabled; a new engine needs a discovery key.
		if match == nil && port == nil && id != domain.LMStudioLlamaCpp && !hasEngine(engines, id) {
			continue
		}
		if match == nil && id == domain.LMStudioLlamaCpp {
			match = builtInLMStudioLlamaCpp().MatchPath
		}
		parsed := LocalEngine{ID: id, DisplayName: display, Enabled: enabled, MatchPath: match, Port: port}
		replaced := false
		for i := range engines {
			if engines[i].ID == id {
				engines[i] = parsed
				replaced = true
			}
		}
		if !replaced {
			engines = append(engines, parsed)
		}
	}
	return engines
}

func hasEngine(engines []LocalEngine, id domain.ProviderID) bool {
	for _, e := range engines {
		if e.ID == id {
			return true
		}
	}
	return false
}

// CustomEngineIDs lists configured `[engine.<slug>]` ids.
func (a App) CustomEngineIDs() []domain.ProviderID {
	var ids []domain.ProviderID
	for _, e := range a.Engines {
		if strings.HasPrefix(string(e.ID), "engine.") {
			ids = append(ids, e.ID)
		}
	}
	return ids
}
