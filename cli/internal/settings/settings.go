package settings

import (
	"fmt"
	"math"
	"strconv"
	"strings"
	"unicode"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

// The `aub.*` keys the app reads.
const (
	KeyRefreshInterval   = "aub.refreshInterval"
	KeyThreshold         = "aub.threshold"
	KeyTheme             = "aub.theme"
	KeyCLITheme          = "aub.cliTheme"
	KeyProviderOrder     = "aub.providerOrder"
	KeyOpenAtLogin       = "aub.openAtLogin"
	KeyHasSeenWelcome    = "aub.hasSeenWelcome"
	KeyClaudeSource      = "aub.provider.claude.source"
	KeyPaceWarnings      = "aub.paceWarningsEnabled"
	KeyResetNotification = "aub.resetNotificationsEnabled"
)

// KeyProviderEnabled is a provider's enable flag.
func KeyProviderEnabled(id domain.ProviderID) string {
	return "aub.provider." + string(id) + ".enabled"
}

// KeyBudget is a budget cap edited in Settings, in USD; 0 means no budget.
func KeyBudget(scope domain.BudgetScope) string { return "aub.budget." + scope.Name() }

type kind int

const (
	kindInterval kind = iota
	kindThreshold
	kindTheme
	kindCLITheme
	kindProviderOrder
	kindBool
	kindClaudeSource
)

type spec struct {
	cli, key, defaultValue string
	kind                   kind
}

func catalog() []spec {
	rows := []spec{
		{"refresh-interval", KeyRefreshInterval, domain.DefaultRefreshInterval, kindInterval},
		{"threshold", KeyThreshold, "0.80", kindThreshold},
		{"theme", KeyTheme, "auto", kindTheme},
		{"cli-theme", KeyCLITheme, string(domain.DefaultTheme), kindCLITheme},
		{"provider-order", KeyProviderOrder, defaultProviderOrder(), kindProviderOrder},
		{"pace-warnings", KeyPaceWarnings, "true", kindBool},
		{"reset-notifications", KeyResetNotification, "true", kindBool},
		{"claude-source", KeyClaudeSource, "sessionReads", kindClaudeSource},
		{"open-at-login", KeyOpenAtLogin, "false", kindBool},
		{"has-seen-welcome", KeyHasSeenWelcome, "false", kindBool},
	}
	for _, id := range domain.AllKnown {
		rows = append(rows, spec{"provider." + string(id) + ".enabled", KeyProviderEnabled(id), "true", kindBool})
	}
	return rows
}

func defaultProviderOrder() string {
	ids := make([]string, len(domain.AllKnown))
	for i, id := range domain.AllKnown {
		ids[i] = string(id)
	}
	return strings.Join(ids, ",")
}

// AppThemes and ClaudeSources are the valid values of `theme` and `claude-source`.
var (
	appThemes     = []string{"light", "dark", "auto"}
	claudeSources = []string{"sessionReads", "hook"}
)

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

// Error is a rejected setting. It exits with code 2.
type Error struct {
	message string
}

func (e Error) Error() string { return e.message }

func unknownKey(key string) Error {
	return Error{"unknown key '" + key + "'. Try `aub settings`."}
}

func invalidValue(key, value, expected string) Error {
	return Error{fmt.Sprintf("invalid value '%s' for %s; expected %s", value, key, expected)}
}

// Entry is one row of `aub settings`.
type Entry struct {
	Key, Value, DefaultValue string
}

// SetResult is what `aub settings set` prints.
type SetResult struct {
	Key, Value string
	Warning    *string
}

// CLI is get/set over a Store. CustomEngines supplies configured `[engine.<slug>]` ids and is
// read only when validating provider-order.
type CLI struct {
	Store         Store
	CustomEngines func() []domain.ProviderID
}

// List returns every setting.
func (c CLI) List() []Entry {
	rows := catalog()
	out := make([]Entry, len(rows))
	for i, s := range rows {
		out[i] = Entry{s.cli, c.current(s), s.defaultValue}
	}
	return out
}

func find(key string) (spec, bool) {
	for _, s := range catalog() {
		if s.cli == key {
			return s, true
		}
	}
	return spec{}, false
}

// Get returns one setting.
func (c CLI) Get(key string) (Entry, error) {
	s, ok := find(key)
	if !ok {
		return Entry{}, unknownKey(key)
	}
	return Entry{s.cli, c.current(s), s.defaultValue}, nil
}

// Set validates and stores one setting. An Error is a bad request; any other error is a
// store failure.
func (c CLI) Set(key, value string) (SetResult, error) {
	s, ok := find(key)
	if !ok {
		return SetResult{}, unknownKey(key)
	}
	stored := func(v any, shown string) (SetResult, error) {
		if err := c.Store.Set(s.key, v); err != nil {
			return SetResult{}, err
		}
		return SetResult{Key: s.cli, Value: shown}, nil
	}
	switch s.kind {
	case kindInterval:
		if !domain.ValidRefreshInterval(value) {
			return SetResult{}, invalidValue(key, value, "manual|1m|2m|5m|15m|30m")
		}
		return stored(value, value)
	case kindThreshold:
		n, err := strconv.ParseFloat(value, 64)
		if err != nil || math.IsNaN(n) || n < 0.50 || n > 0.95 {
			return SetResult{}, invalidValue(key, value, "number in 0.50…0.95")
		}
		return stored(n, formatThreshold(n))
	case kindTheme:
		if !contains(appThemes, value) {
			return SetResult{}, invalidValue(key, value, "light|dark|auto")
		}
		return stored(value, value)
	case kindBool:
		b, ok := parseBool(value)
		if !ok {
			return SetResult{}, invalidValue(key, value, "true|false")
		}
		result, err := stored(b, strconv.FormatBool(b))
		if err == nil && s.cli == "open-at-login" {
			warning := "Login Items registration only happens in Settings; the flag was stored."
			result.Warning = &warning
		}
		return result, err
	case kindClaudeSource:
		if !contains(claudeSources, value) {
			return SetResult{}, invalidValue(key, value, "sessionReads|hook")
		}
		return stored(value, value)
	case kindCLITheme:
		theme, ok := domain.NamedTheme(value)
		if !ok {
			return SetResult{}, invalidValue(key, value, domain.ThemeNames)
		}
		return stored(string(theme), string(theme))
	case kindProviderOrder:
		return c.setProviderOrder(s, key, value)
	}
	return SetResult{}, unknownKey(key)
}

func (c CLI) setProviderOrder(s spec, key, value string) (SetResult, error) {
	if trimWhitespace(value) == "" {
		if err := c.Store.Delete(s.key); err != nil {
			return SetResult{}, err
		}
		return SetResult{Key: s.cli, Value: c.current(s)}, nil
	}
	valid := make([]string, 0, len(domain.AllKnown))
	for _, id := range domain.AllKnown {
		valid = append(valid, strings.ToLower(string(id)))
	}
	if c.CustomEngines != nil {
		for _, id := range c.CustomEngines() {
			valid = append(valid, strings.ToLower(string(id)))
		}
	}
	parts := strings.Split(value, ",")
	seen := map[string]bool{}
	ids := make([]string, len(parts))
	for i, part := range parts {
		id := strings.ToLower(trimWhitespace(part))
		if !contains(valid, id) || seen[id] {
			return SetResult{}, invalidValue(key, value, "comma list of distinct ids from "+strings.Join(valid, ", "))
		}
		seen[id] = true
		ids[i] = id
	}
	joined := strings.Join(ids, ",")
	if err := c.Store.Set(s.key, joined); err != nil {
		return SetResult{}, err
	}
	return SetResult{Key: s.cli, Value: joined}, nil
}

// StoredTheme is the stored cli-theme, ok=false when unset or unreadable.
func (c CLI) StoredTheme() (domain.CLITheme, bool) {
	return StoredTheme(c.Store)
}

// StoredTheme is the stored cli-theme, ok=false when unset or unreadable.
func StoredTheme(store Store) (domain.CLITheme, bool) {
	v, ok := store.Get(KeyCLITheme)
	s, ok := stringValue(v, ok)
	if !ok {
		return "", false
	}
	return domain.NamedTheme(s)
}

func (c CLI) current(s spec) string {
	v, present := c.Store.Get(s.key)
	text, isText := stringValue(v, present)
	switch s.kind {
	case kindInterval:
		if isText && domain.ValidRefreshInterval(text) {
			return text
		}
	case kindThreshold:
		if n, ok := doubleValue(v, present); ok {
			return formatThreshold(n)
		}
	case kindTheme:
		if isText && contains(appThemes, text) {
			return text
		}
	case kindCLITheme:
		if theme, ok := c.StoredTheme(); ok {
			return string(theme)
		}
	case kindProviderOrder:
		if isText && text != "" {
			return text
		}
	case kindClaudeSource:
		if isText && contains(claudeSources, text) {
			return text
		}
	case kindBool:
		if present {
			return strconv.FormatBool(boolValue(v))
		}
	}
	return s.defaultValue
}

func formatThreshold(n float64) string { return fmt.Sprintf("%.2f", n) }

func parseBool(raw string) (bool, bool) {
	switch strings.ToLower(raw) {
	case "true", "1", "yes":
		return true, true
	case "false", "0", "no":
		return false, true
	}
	return false, false
}

// trimWhitespace is CharacterSet.whitespaces: spaces and tabs, not newlines.
func trimWhitespace(s string) string {
	return strings.TrimFunc(s, func(r rune) bool { return r == '\t' || unicode.Is(unicode.Zs, r) })
}

// Preferences is the typed view of the store that config and providers read.
type Preferences struct {
	RefreshInterval string
	Threshold       float64
	ClaudeSource    string
	// ProviderEnabled holds only explicitly stored flags; absent means enabled.
	ProviderEnabled map[domain.ProviderID]bool
	BudgetOverrides map[domain.BudgetScope]float64
	ProviderOrder   []domain.ProviderID
}

// LoadPreferences reads every knob with its default applied.
func LoadPreferences(store Store) Preferences {
	all := store.All()
	p := Preferences{
		RefreshInterval: domain.DefaultRefreshInterval,
		Threshold:       0.80,
		ClaudeSource:    "sessionReads",
		ProviderEnabled: map[domain.ProviderID]bool{},
		BudgetOverrides: map[domain.BudgetScope]float64{},
	}
	v, ok := all[KeyRefreshInterval]
	if s, isText := stringValue(v, ok); isText && domain.ValidRefreshInterval(s) {
		p.RefreshInterval = s
	}
	v, ok = all[KeyThreshold]
	if n, isNum := doubleValue(v, ok); isNum {
		p.Threshold = n
	}
	v, ok = all[KeyClaudeSource]
	if s, isText := stringValue(v, ok); isText && contains(claudeSources, s) {
		p.ClaudeSource = s
	}
	const prefix, suffix = "aub.provider.", ".enabled"
	for key, value := range all {
		if strings.HasPrefix(key, prefix) && strings.HasSuffix(key, suffix) && len(key) > len(prefix)+len(suffix) {
			p.ProviderEnabled[domain.ProviderID(key[len(prefix):len(key)-len(suffix)])] = boolValue(value)
		}
	}
	for _, scope := range domain.AllBudgetScopes() {
		v, ok := all[KeyBudget(scope)]
		if n, isNum := doubleValue(v, ok); isNum {
			p.BudgetOverrides[scope] = n
		}
	}
	v, ok = all[KeyProviderOrder]
	order, _ := stringValue(v, ok)
	for _, part := range strings.Split(order, ",") {
		if id := strings.ToLower(trimWhitespace(part)); id != "" {
			p.ProviderOrder = append(p.ProviderOrder, domain.ProviderID(id))
		}
	}
	return p
}

// IsEnabled is a provider's flag; absent means enabled.
func (p Preferences) IsEnabled(id domain.ProviderID) bool {
	if enabled, ok := p.ProviderEnabled[id]; ok {
		return enabled
	}
	return true
}
