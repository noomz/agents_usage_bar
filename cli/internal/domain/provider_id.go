// Package domain holds the types every other package shares. It mirrors AgentsUsageBar/Domain.
package domain

import (
	"sort"
	"strings"
	"unicode"
)

// ProviderID is a provider's stable identifier. Its text appears in caches and settings keys.
type ProviderID string

const (
	OpenRouter       ProviderID = "openrouter"
	Claude           ProviderID = "claude"
	Codex            ProviderID = "codex"
	Gemini           ProviderID = "gemini"
	Grok             ProviderID = "grok"
	PiLocal          ProviderID = "pi-local"
	Ollama           ProviderID = "ollama"
	OllamaCloud      ProviderID = "ollama-cloud"
	LMStudio         ProviderID = "lmstudio"
	LMStudioLlamaCpp ProviderID = "lms-llamacpp"
	LlamaCpp         ProviderID = "llamacpp"
)

const enginePrefix = "engine."

// AllKnown lists known providers in display order.
var AllKnown = []ProviderID{OpenRouter, Claude, Codex, Gemini, Grok, PiLocal, Ollama, OllamaCloud, LMStudio, LMStudioLlamaCpp, LlamaCpp}

var displayHints = map[ProviderID]string{
	OpenRouter: "OpenRouter", Claude: "Claude", Codex: "Codex", Gemini: "Gemini", Grok: "Grok",
	PiLocal: "Local Llama", Ollama: "Ollama", OllamaCloud: "Ollama Cloud", LMStudio: "LM Studio",
	LMStudioLlamaCpp: "LM Studio llama.cpp", LlamaCpp: "llama.cpp",
}

// IsLocalRuntime is true for built-in local runtimes and user-defined `[engine.*]` rows.
func (id ProviderID) IsLocalRuntime() bool {
	switch id {
	case Ollama, LMStudio, LlamaCpp, LMStudioLlamaCpp:
		return true
	}
	return strings.HasPrefix(string(id), enginePrefix)
}

// ContributesToTodayTotal says whether this id's snapshot counts in the Today total.
func (id ProviderID) ContributesToTodayTotal() bool {
	return id == Claude || id == Codex || id == PiLocal || id == Grok
}

// EngineSlug is the slug used in `[engine.<slug>]`.
func (id ProviderID) EngineSlug() string {
	return strings.TrimPrefix(string(id), enginePrefix)
}

// DisplayHint is the human-readable provider name.
func (id ProviderID) DisplayHint() string {
	if hint, ok := displayHints[id]; ok {
		return hint
	}
	if strings.HasPrefix(string(id), enginePrefix) {
		parts := []string{}
		for _, p := range strings.Split(id.EngineSlug(), "-") {
			if p != "" {
				parts = append(parts, capitalized(p))
			}
		}
		return strings.Join(parts, " ")
	}
	return capitalized(string(id))
}

// capitalized is Foundation's String.capitalized: the first letter of each run of letters
// goes upper case and the rest lower case.
func capitalized(s string) string {
	var b strings.Builder
	inWord := false
	for _, r := range s {
		switch {
		case !unicode.IsLetter(r):
			inWord = false
			b.WriteRune(r)
		case inWord:
			b.WriteRune(unicode.ToLower(r))
		default:
			inWord = true
			b.WriteRune(unicode.ToUpper(r))
		}
	}
	return b.String()
}

// NamedProvider resolves a user-typed token: a known id or `engine.<slug>`.
func NamedProvider(token string) (ProviderID, bool) {
	if strings.HasPrefix(token, enginePrefix) && len(token) > len(enginePrefix) {
		return ProviderID(token), true
	}
	for _, id := range AllKnown {
		if string(id) == token {
			return id, true
		}
	}
	return "", false
}

func knownIndex(id ProviderID) int {
	for i, known := range AllKnown {
		if known == id {
			return i
		}
	}
	return -1
}

// OrderProviders is provider-order: ids in preference first, in that order, matched
// case-insensitively because engine ids keep the case from config.toml; then unlisted known
// ids in AllKnown order; then everything else alphabetically.
func OrderProviders[T any](items []T, id func(T) ProviderID, preference []ProviderID) []T {
	type key struct {
		tier, index int
		tie         string
	}
	keyOf := func(pid ProviderID) key {
		lower := strings.ToLower(string(pid))
		for i, p := range preference {
			if strings.ToLower(string(p)) == lower {
				return key{0, i, string(pid)}
			}
		}
		if i := knownIndex(pid); i >= 0 {
			return key{1, i, ""}
		}
		return key{2, 0, string(pid)}
	}
	out := make([]T, len(items))
	copy(out, items)
	keys := make(map[ProviderID]key, len(items))
	for _, it := range items {
		keys[id(it)] = keyOf(id(it))
	}
	sort.SliceStable(out, func(i, j int) bool {
		a, b := keys[id(out[i])], keys[id(out[j])]
		if a.tier != b.tier {
			return a.tier < b.tier
		}
		if a.index != b.index {
			return a.index < b.index
		}
		return a.tie < b.tie
	})
	return out
}

// CLITheme is a built-in terminal layout.
type CLITheme string

const (
	ThemeCompact CLITheme = "compact"
	ThemeClassic CLITheme = "classic"
)

// AllThemes lists themes in listing order.
var AllThemes = []CLITheme{ThemeCompact, ThemeClassic}

// DefaultTheme applies when nothing selects a theme.
const DefaultTheme = ThemeCompact

// ThemeNames is the list every theme error names.
const ThemeNames = "compact|classic"

// NamedTheme is a case-insensitive lookup; the canonical form is lower case.
func NamedTheme(raw string) (CLITheme, bool) {
	lower := CLITheme(strings.ToLower(raw))
	for _, t := range AllThemes {
		if t == lower {
			return t, true
		}
	}
	return "", false
}
