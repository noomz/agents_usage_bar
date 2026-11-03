package providers

import (
	"context"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/config"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/settings"
)

type fake struct{ id domain.ProviderID }

func (f fake) ID() domain.ProviderID             { return f.id }
func (f fake) DisplayName() string               { return string(f.id) }
func (f fake) Capabilities() domain.Capabilities { return domain.Capabilities{} }
func (f fake) Status() domain.ProviderStatus     { return domain.OK(time.Unix(0, 0)) }
func (f fake) Fetch(context.Context, time.Time) (domain.UsageSnapshot, error) {
	return domain.UsageSnapshot{ProviderID: f.id, Raw: map[string]string{}}, nil
}

func env() provider.Env {
	return provider.Env{Config: config.Defaults(), Preferences: settings.LoadPreferences(settings.Memory{})}
}

func TestNothingImplementedShowsEveryPlaceholder(t *testing.T) {
	r := compose(env(), nil, nil)
	if len(r.Providers) != 0 {
		t.Fatalf("providers %v", r.Providers)
	}
	type row struct {
		id     domain.ProviderID
		status domain.StatusKind
		msg    string
	}
	want := []row{
		{domain.OpenRouter, domain.StatusUnauthenticated, ""},
		{domain.Claude, domain.StatusUnauthenticated, ""},
		{domain.Codex, domain.StatusUnauthenticated, ""},
		{domain.Gemini, domain.StatusUnauthenticated, ""},
		{domain.Grok, domain.StatusUnauthenticated, ""},
		{domain.PiLocal, domain.StatusUnauthenticated, ""},
		{domain.Ollama, domain.StatusNotRunning, ""},
		{domain.LMStudio, domain.StatusNotRunning, ""},
		{domain.LlamaCpp, domain.StatusNotRunning, "Set [llamacpp] port in config.toml to enable"},
		{domain.LMStudioLlamaCpp, domain.StatusNotRunning, ""},
	}
	if len(r.Placeholders) != len(want) {
		t.Fatalf("got %d placeholders: %+v", len(r.Placeholders), r.Placeholders)
	}
	for i, w := range want {
		p := r.Placeholders[i]
		msg := ""
		if p.PlaceholderMessage != nil {
			msg = *p.PlaceholderMessage
		}
		if p.ProviderID != w.id || p.Status.Kind != w.status || msg != w.msg {
			t.Errorf("%d: %+v want %+v", i, p, w)
		}
	}
}

func TestDisplayNamesMatchTheApp(t *testing.T) {
	for _, p := range compose(env(), nil, nil).Placeholders {
		if p.ProviderID == domain.PiLocal && p.DisplayName != "Local Llama" {
			t.Errorf("pi-local: %s", p.DisplayName)
		}
		if p.ProviderID == domain.LlamaCpp && p.DisplayName != "llama.cpp" {
			t.Errorf("llamacpp: %s", p.DisplayName)
		}
	}
}

func TestRegisteredProviderReplacesItsPlaceholder(t *testing.T) {
	builds := map[domain.ProviderID]provider.Build{
		domain.Claude:     func(provider.Env) provider.Provider { return fake{domain.Claude} },
		domain.OpenRouter: func(provider.Env) provider.Provider { return nil },
	}
	r := compose(env(), builds, nil)
	if len(r.Providers) != 1 || r.Providers[0].ID() != domain.Claude {
		t.Fatalf("%+v", r.Providers)
	}
	for _, p := range r.Placeholders {
		if p.ProviderID == domain.Claude {
			t.Error("registered provider still seeded")
		}
	}
	if r.Placeholders[0].ProviderID != domain.OpenRouter {
		t.Errorf("a Build returning nil keeps the placeholder: %+v", r.Placeholders[0])
	}
}

func TestDisabledProviderHasNoRow(t *testing.T) {
	e := env()
	e.Preferences = settings.LoadPreferences(settings.Memory{settings.KeyProviderEnabled(domain.Claude): false})
	e.Config = e.Config.WithPreferences(settings.LoadPreferences(settings.Memory{settings.KeyProviderEnabled(domain.Gemini): false}))
	for _, p := range compose(e, nil, nil).Placeholders {
		if p.ProviderID == domain.Claude || p.ProviderID == domain.Gemini {
			t.Errorf("disabled %s has a row", p.ProviderID)
		}
	}
}

func TestLlamaCppWithPortHasNoHint(t *testing.T) {
	e := env()
	port := 8080
	e.Config.LlamaCpp.Port = &port
	for _, p := range compose(e, nil, nil).Placeholders {
		if p.ProviderID == domain.LlamaCpp && p.PlaceholderMessage != nil {
			t.Errorf("hint with a port: %s", *p.PlaceholderMessage)
		}
	}
}

func TestEnginesResolveAndReservePorts(t *testing.T) {
	e := env()
	match := "/.lmstudio/extensions/backends/"
	e.Config.Engines = []config.LocalEngine{
		{ID: domain.LMStudioLlamaCpp, DisplayName: "LM Studio llama.cpp", Enabled: true, MatchPath: &match},
		{ID: "engine.same", DisplayName: "same", Enabled: true, MatchPath: &match},
		{ID: "engine.none", DisplayName: "none", Enabled: true},
		{ID: "engine.off", DisplayName: "off", Enabled: false},
	}
	e.Processes = provider.StaticCatalog{{PID: 1, ExecutablePath: "/u/.lmstudio/extensions/backends/llama-server", Arguments: []string{"llama-server", "--port", "8123"}}}
	var built []int
	engine := func(_ provider.Env, cfg config.LocalEngine, port int) provider.Provider {
		built = append(built, port)
		return fake{cfg.ID}
	}
	r := compose(e, nil, engine)
	if len(built) != 1 || built[0] != 8123 {
		t.Errorf("built %v: the second engine must not take a reserved port", built)
	}
	seeds := map[domain.ProviderID]provider.PlaceholderSeed{}
	for _, p := range r.Placeholders {
		seeds[p.ProviderID] = p
	}
	if _, ok := seeds["engine.same"]; !ok {
		t.Error("engine.same should fall back to a placeholder")
	}
	if m := seeds["engine.none"].PlaceholderMessage; m == nil || *m != "Set [engine.none] port or match_path in config.toml" {
		t.Errorf("engine.none: %v", m)
	}
	if _, ok := seeds["engine.off"]; ok {
		t.Error("disabled engine has a row")
	}
}

func TestResolveEnginePortRules(t *testing.T) {
	match := "llama-server"
	explicit := 9000
	engine := config.LocalEngine{MatchPath: &match, Port: &explicit}
	proc := func(args ...string) []provider.RunningProcess {
		return []provider.RunningProcess{{ExecutablePath: "/x/llama-server", Arguments: args}}
	}
	cases := []struct {
		name     string
		engine   config.LocalEngine
		procs    []provider.RunningProcess
		reserved map[int]bool
		want     int
	}{
		{"argv wins", engine, proc("--port", "8123"), nil, 8123},
		{"equals form", engine, proc("--port=8124"), nil, 8124},
		{"no flag falls to explicit", engine, proc("x"), nil, 9000},
		{"bad flag falls to explicit", engine, proc("--port", "99999"), nil, 9000},
		{"reserved argv falls to explicit", engine, proc("--port", "8123"), map[int]bool{8123: true}, 9000},
		{"explicit reserved", engine, proc("x"), map[int]bool{9000: true}, 0},
		{"no process", engine, nil, nil, 9000},
		{"no discovery key", config.LocalEngine{}, proc("--port", "1"), nil, 0},
	}
	for _, c := range cases {
		got := provider.ResolveEnginePort(c.engine, c.procs, c.reserved)
		g := 0
		if got != nil {
			g = *got
		}
		if g != c.want {
			t.Errorf("%s: got %d want %d", c.name, g, c.want)
		}
	}
}
