// Package cli is the `aub` command: parsing, dispatch, and every renderer. Output is
// byte-identical to the Swift CLI, which scripts/parity-cli.sh checks.
package cli

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

// Command is a parsed invocation: one of the *Cmd types below.
type Command interface{ isCommand() }

// FilterKind selects providers.
type FilterKind int

// The filters.
const (
	FilterEnabled FilterKind = iota
	FilterAll
	FilterOne
)

// ProviderFilter is enabled, all, or one provider.
type ProviderFilter struct {
	Kind FilterKind
	ID   domain.ProviderID
}

// UsageCmd is `aub usage` and `aub quota`.
type UsageCmd struct {
	QuotaOnly bool
	Filter    ProviderFilter
	JSON      bool
	NoColor   bool
	Cached    bool
	Theme     *domain.CLITheme
}

// StatsFormat is the text table or an export.
type StatsFormat struct {
	JSON bool
	// CSV is the table name, empty when not exporting CSV.
	CSV CSVTable
}

// IsText reports the text table.
func (f StatsFormat) IsText() bool { return !f.JSON && f.CSV == "" }

// StatsCmd is `aub stats`.
type StatsCmd struct {
	Filter  ProviderFilter
	Days    *int
	Since   *string
	Until   *string
	NoColor bool
	Format  StatsFormat
}

// DashboardCmd is `aub dashboard [provider]`.
type DashboardCmd struct {
	Provider *domain.ProviderID
}

// SettingsVerb is list, get, or set.
type SettingsVerb int

// The verbs.
const (
	SettingsList SettingsVerb = iota
	SettingsGet
	SettingsSet
)

// SettingsCmd is `aub settings`.
type SettingsCmd struct {
	Verb       SettingsVerb
	Key, Value string
	JSON       bool
}

// ThemesCmd is `aub themes`.
type ThemesCmd struct {
	JSON  bool
	Theme *domain.CLITheme
}

// InstallCmd is `aub install`.
type InstallCmd struct {
	Prefix *string
}

// UninstallCmd is `aub uninstall`.
type UninstallCmd struct{}

// VersionCmd is `aub version`.
type VersionCmd struct{}

// HelpCmd is `aub help`.
type HelpCmd struct{}

func (UsageCmd) isCommand()     {}
func (StatsCmd) isCommand()     {}
func (DashboardCmd) isCommand() {}
func (SettingsCmd) isCommand()  {}
func (ThemesCmd) isCommand()    {}
func (InstallCmd) isCommand()   {}
func (UninstallCmd) isCommand() {}
func (VersionCmd) isCommand()   {}
func (HelpCmd) isCommand()      {}

// ParseError is a bad invocation. It exits with code 2.
type ParseError struct {
	message string
}

func (e *ParseError) Error() string { return e.message }

func unknownCommand(s string) *ParseError {
	return &ParseError{"unknown command '" + s + "'. Try `aub help`."}
}
func unknownProvider(s string) *ParseError {
	return &ParseError{"unknown provider '" + s + "'. Try `aub help`."}
}
func missingValue(flag string) *ParseError { return &ParseError{"missing value for " + flag} }
func unexpectedArgument(s string) *ParseError {
	return &ParseError{"unexpected argument '" + s + "'. Try `aub help`."}
}
func unknownTheme(s string) *ParseError {
	return &ParseError{"unknown CLI theme '" + s + "'; expected " + domain.ThemeNames}
}
func unknownThemeEnv(s string) *ParseError {
	return &ParseError{"AUB_THEME: " + unknownTheme(s).message}
}
func invalidDays(s string) *ParseError {
	return &ParseError{"--days expects a whole number of days from 1, got '" + s + "'"}
}
func invalidDay(flag, value string) *ParseError {
	return &ParseError{flag + " expects a date as yyyy-MM-dd, got '" + value + "'"}
}
func emptyRange(first, last string) *ParseError {
	return &ParseError{fmt.Sprintf("empty range: %s is after %s", first, last)}
}

var (
	errMissingSettingsKey   = &ParseError{"missing settings key. Try `aub settings`."}
	errMissingSettingsValue = &ParseError{"missing settings value. Usage: aub settings set <key> <value>"}
)

// HelpText is `aub help`.
const HelpText = `aub — Agents Usage Bar command line

Usage:
  aub [usage] [provider]   Print today's usage with quota bars
  aub quota [provider]     Print quota / limits / reset windows
  aub limits [provider]    Alias of quota
  aub stats [provider]     Usage history: 14-day summary, or one row per day
  aub stats --json | --csv [accounts|events|quota]   Export history (every retained day)
  aub dashboard [provider] Open the dashboard window, launching the app if needed
  aub settings             List settings keys and values
  aub settings get <key>
  aub settings set <key> <value>
  aub themes               List CLI themes and the active one
  aub install [--prefix PATH]   Default: ~/.local/bin
  aub uninstall
  aub version
  aub help

Flags:
  --json          Machine-readable JSON
  --no-color      Disable ANSI bar colors
  --cached        Read the menu-bar cache (default; no live fetch)
  --live          Fetch providers now (slow; ignores the cache)
  --provider ID   Restrict to one provider, or 'all'
  --theme NAME    CLI theme: compact (default) | classic
  --prefix PATH   Install symlink into PATH (install only)
  --days N        Stats range length, ending today (default 14)
  --since DATE    Stats range start, yyyy-MM-dd
  --until DATE    Stats range end, yyyy-MM-dd
  --csv [TABLE]   Stats export as CSV: days (default), accounts, events, quota

Environment:
  AUB_THEME       CLI theme when --theme is absent (overrides the cli-theme setting)
  NO_COLOR        Disable ANSI colors, like --no-color

Providers:
  openrouter, claude, codex, gemini, grok, ollama, lmstudio, lms-llamacpp, llamacpp

Settings keys:
  refresh-interval, threshold, theme, cli-theme, provider-order,
  pace-warnings, reset-notifications, claude-source, open-at-login,
  provider.<id>.enabled

Examples:
  aub
  aub --live
  aub usage --json
  aub quota claude
  aub stats --days 30
  aub stats claude --since 2026-10-01
  aub stats --csv quota --days 30
  aub settings get refresh-interval
  aub settings set threshold 0.7`

// Parse reads arguments. It does no I/O.
func Parse(args []string) (Command, *ParseError) {
	var (
		jsonFlag, noColor bool
		cached            = true
		providerFlag      *string
		prefix            *string
		theme             *domain.CLITheme
		days              *int
		since, until      *string
		rangeFlag         string
		csv               CSVTable
		positionals       []string
	)
	tokens := make([]string, 0, len(args))
	for _, a := range args {
		if a != "--cli" {
			tokens = append(tokens, a)
		}
	}
	for i := 0; i < len(tokens); i++ {
		t := tokens[i]
		next := func() (string, *ParseError) {
			i++
			if i >= len(tokens) {
				return "", missingValue(t)
			}
			return tokens[i], nil
		}
		switch t {
		case "--help", "-h":
			return HelpCmd{}, nil
		case "--version", "-V":
			return VersionCmd{}, nil
		case "--json":
			jsonFlag = true
		case "--no-color":
			noColor = true
		case "--cached":
			cached = true
		case "--live":
			cached = false
		case "--provider":
			v, err := next()
			if err != nil {
				return nil, err
			}
			providerFlag = &v
		case "--prefix":
			v, err := next()
			if err != nil {
				return nil, err
			}
			prefix = &v
		case "--theme":
			v, err := next()
			if err != nil {
				return nil, err
			}
			named, ok := domain.NamedTheme(v)
			if !ok {
				return nil, unknownTheme(v)
			}
			theme = &named
		case "--days":
			v, err := next()
			if err != nil {
				return nil, err
			}
			n, convErr := strconv.Atoi(v)
			if convErr != nil || n < 1 {
				return nil, invalidDays(v)
			}
			days = &n
			rangeFlag = t
		case "--since", "--until":
			v, err := next()
			if err != nil {
				return nil, err
			}
			if !IsDayKey(v) {
				return nil, invalidDay(t, v)
			}
			if t == "--since" {
				since = &v
			} else {
				until = &v
			}
			rangeFlag = t
		case "--csv":
			// The table name is optional, so only a known table is taken as its value.
			csv = CSVDays
			if i+1 < len(tokens) && validCSVTable(tokens[i+1]) {
				csv = CSVTable(tokens[i+1])
				i++
			}
		default:
			if strings.HasPrefix(t, "-") {
				return nil, unknownCommand(t)
			}
			positionals = append(positionals, t)
		}
	}

	head := ""
	hasHead := len(positionals) > 0
	var rest []string
	if hasHead {
		head = positionals[0]
		rest = positionals[1:]
	}
	if rangeFlag != "" && head != "stats" {
		return nil, unexpectedArgument(rangeFlag)
	}
	if csv != "" && head != "stats" {
		return nil, unexpectedArgument("--csv")
	}

	usageOptions := func(quotaOnly bool) (UsageCmd, *ParseError) {
		var filter ProviderFilter
		var err *ParseError
		switch {
		case providerFlag != nil:
			filter, err = parseProviderToken(*providerFlag)
		case len(rest) > 0:
			filter, err = parseProviderToken(rest[0])
		}
		if err != nil {
			return UsageCmd{}, err
		}
		if len(rest) > 1 {
			return UsageCmd{}, unexpectedArgument(rest[1])
		}
		return UsageCmd{QuotaOnly: quotaOnly, Filter: filter, JSON: jsonFlag, NoColor: noColor, Cached: cached, Theme: theme}, nil
	}

	if !hasHead {
		var filter ProviderFilter
		if providerFlag != nil {
			f, err := parseProviderToken(*providerFlag)
			if err != nil {
				return nil, err
			}
			filter = f
		}
		return UsageCmd{Filter: filter, JSON: jsonFlag, NoColor: noColor, Cached: cached, Theme: theme}, nil
	}

	switch head {
	case "help":
		return HelpCmd{}, nil
	case "version":
		return VersionCmd{}, nil
	case "usage", "quota", "limits":
		opts, err := usageOptions(head != "usage")
		if err != nil {
			return nil, err
		}
		return opts, nil
	case "stats":
		if jsonFlag && csv != "" {
			return nil, unexpectedArgument("--csv")
		}
		opts, err := usageOptions(false)
		if err != nil {
			return nil, err
		}
		format := StatsFormat{JSON: jsonFlag}
		if !jsonFlag {
			format.CSV = csv
		}
		return StatsCmd{Filter: opts.Filter, Days: days, Since: since, Until: until, NoColor: noColor, Format: format}, nil
	case "dashboard":
		if len(rest) > 1 {
			return nil, unexpectedArgument(rest[1])
		}
		if len(rest) == 0 {
			return DashboardCmd{}, nil
		}
		id, ok := domain.NamedProvider(rest[0])
		if !ok {
			return nil, unknownProvider(rest[0])
		}
		return DashboardCmd{Provider: &id}, nil
	case "settings":
		return parseSettings(rest, jsonFlag)
	case "themes":
		if len(rest) > 0 {
			return nil, unexpectedArgument(rest[0])
		}
		return ThemesCmd{JSON: jsonFlag, Theme: theme}, nil
	case "install":
		if len(rest) > 0 {
			return nil, unexpectedArgument(rest[0])
		}
		return InstallCmd{Prefix: prefix}, nil
	case "uninstall":
		if len(rest) > 0 {
			return nil, unexpectedArgument(rest[0])
		}
		return UninstallCmd{}, nil
	}
	if id, ok := domain.NamedProvider(head); ok {
		if len(rest) > 0 {
			return nil, unexpectedArgument(rest[0])
		}
		return UsageCmd{Filter: ProviderFilter{Kind: FilterOne, ID: id}, JSON: jsonFlag, NoColor: noColor, Cached: cached, Theme: theme}, nil
	}
	return nil, unknownCommand(head)
}

func parseSettings(rest []string, jsonFlag bool) (Command, *ParseError) {
	if len(rest) == 0 {
		return SettingsCmd{Verb: SettingsList, JSON: jsonFlag}, nil
	}
	switch rest[0] {
	case "get":
		if len(rest) < 2 {
			return nil, errMissingSettingsKey
		}
		if len(rest) > 2 {
			return nil, unexpectedArgument(rest[2])
		}
		return SettingsCmd{Verb: SettingsGet, Key: rest[1], JSON: jsonFlag}, nil
	case "set":
		if len(rest) < 2 {
			return nil, errMissingSettingsKey
		}
		if len(rest) < 3 {
			return nil, errMissingSettingsValue
		}
		if len(rest) > 3 {
			return nil, unexpectedArgument(rest[3])
		}
		return SettingsCmd{Verb: SettingsSet, Key: rest[1], Value: rest[2], JSON: jsonFlag}, nil
	}
	return nil, unknownCommand("settings " + rest[0])
}

func parseProviderToken(token string) (ProviderFilter, *ParseError) {
	if token == "all" {
		return ProviderFilter{Kind: FilterAll}, nil
	}
	if id, ok := domain.NamedProvider(token); ok {
		return ProviderFilter{Kind: FilterOne, ID: id}, nil
	}
	return ProviderFilter{}, unknownProvider(token)
}
