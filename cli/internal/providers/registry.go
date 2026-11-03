// Package providers composes the provider registry, the one place that knows every provider.
package providers

import (
	"github.com/noomz/agents_usage_bar/cli/internal/config"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/providers/pilocal"
)

// builds registers implemented providers: one line each, such as
//
//	domain.OpenRouter: openrouter.Build,
//
// A known provider with no line here shows its placeholder row.
var builds = map[domain.ProviderID]provider.Build{
	domain.PiLocal: pilocal.Build,
}

// engineBuild registers the llama.cpp-compatible engine row, such as llamacpp.BuildEngine.
var engineBuild provider.EngineBuild

// entry is one provider's composition metadata, in the app's composition order.
type entry struct {
	id      domain.ProviderID
	enabled func(provider.Env) bool
	// seed is the row while unregistered. Nil means no row at all.
	seed func(provider.Env) *provider.PlaceholderSeed
}

func unauthenticated(id domain.ProviderID) func(provider.Env) *provider.PlaceholderSeed {
	return func(provider.Env) *provider.PlaceholderSeed {
		return &provider.PlaceholderSeed{ProviderID: id, DisplayName: id.DisplayHint(), Status: domain.Unauthenticated()}
	}
}

func notRunning(id domain.ProviderID) func(provider.Env) *provider.PlaceholderSeed {
	return func(provider.Env) *provider.PlaceholderSeed {
		return &provider.PlaceholderSeed{ProviderID: id, DisplayName: id.DisplayHint(), Status: domain.NotRunning()}
	}
}

func preferenceEnabled(id domain.ProviderID) func(provider.Env) bool {
	return func(env provider.Env) bool { return env.Preferences.IsEnabled(id) }
}

var entries = []entry{
	{domain.OpenRouter, func(e provider.Env) bool { return e.Config.OpenRouter.Enabled }, unauthenticated(domain.OpenRouter)},
	{domain.Claude, preferenceEnabled(domain.Claude), unauthenticated(domain.Claude)},
	{domain.Codex, func(e provider.Env) bool { return e.Config.Codex.Enabled }, unauthenticated(domain.Codex)},
	{domain.Gemini, func(e provider.Env) bool { return e.Config.Gemini.Enabled }, unauthenticated(domain.Gemini)},
	{domain.Grok, func(e provider.Env) bool { return e.Config.Grok.Enabled }, unauthenticated(domain.Grok)},
	{domain.PiLocal, preferenceEnabled(domain.PiLocal), unauthenticated(domain.PiLocal)},
	{domain.Ollama, func(e provider.Env) bool { return e.Config.Ollama.Enabled }, notRunning(domain.Ollama)},
	{domain.OllamaCloud, func(e provider.Env) bool { return e.Config.OllamaCloud.Enabled }, nil},
	{domain.LMStudio, func(e provider.Env) bool { return e.Config.LMStudio.Enabled }, notRunning(domain.LMStudio)},
	{domain.LlamaCpp, func(e provider.Env) bool { return e.Config.LlamaCpp.Enabled }, llamaCppSeed},
}

func llamaCppSeed(env provider.Env) *provider.PlaceholderSeed {
	seed := notRunning(domain.LlamaCpp)(env)
	if env.Config.LlamaCpp.Port == nil {
		message := "Set [llamacpp] port in config.toml to enable"
		seed.PlaceholderMessage = &message
	}
	return seed
}

// Build composes the registry. An enabled provider either registers or shows its seed row; a
// disabled provider does neither.
func Build(env provider.Env) provider.Registry {
	return compose(env, builds, engineBuild)
}

func compose(env provider.Env, builds map[domain.ProviderID]provider.Build, engine provider.EngineBuild) provider.Registry {
	var registry provider.Registry
	for _, e := range entries {
		if !e.enabled(env) {
			continue
		}
		var built provider.Provider
		if build := builds[e.id]; build != nil {
			built = build(env)
		}
		if built != nil {
			registry.Providers = append(registry.Providers, built)
			continue
		}
		if e.seed != nil {
			if seed := e.seed(env); seed != nil {
				registry.Placeholders = append(registry.Placeholders, *seed)
			}
		}
	}
	composeEngines(env, engine, &registry)
	return registry
}

// composeEngines registers `[engine.*]` rows and the built-in LM Studio llama.cpp row. Ports
// claimed by Ollama, LM Studio, and `[llamacpp]` are reserved, so an LM Studio sidecar cannot
// steal the llama.cpp row.
func composeEngines(env provider.Env, engine provider.EngineBuild, registry *provider.Registry) {
	reserved := map[int]bool{11434: true, env.Config.LMStudio.Port: true}
	if env.Config.LlamaCpp.Port != nil {
		reserved[*env.Config.LlamaCpp.Port] = true
	}
	var processes []provider.RunningProcess
	if engine != nil && env.Processes != nil {
		processes = env.Processes.Processes()
	}
	for _, e := range env.Config.Engines {
		if !e.Enabled {
			continue
		}
		port := provider.ResolveEnginePort(e, processes, reserved)
		if port != nil && engine != nil {
			registry.Providers = append(registry.Providers, engine(env, e, *port))
			reserved[*port] = true
			continue
		}
		registry.Placeholders = append(registry.Placeholders, engineSeed(e, port))
	}
}

func engineSeed(e config.LocalEngine, port *int) provider.PlaceholderSeed {
	seed := provider.PlaceholderSeed{ProviderID: e.ID, DisplayName: e.DisplayName, Status: domain.NotRunning()}
	if port == nil {
		seed.PlaceholderMessage = e.UnresolvedPlaceholder()
	}
	return seed
}
