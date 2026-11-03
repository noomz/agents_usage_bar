// Package config resolves configuration: settings over environment over config.toml over
// defaults. Secrets come only from the process environment and config.toml. It never reads
// shell rc files or runs a command.
package config

import (
	"strconv"
	"strings"
	"unicode"
)

// TomlValue is a scalar: string, int, float64, or bool.
type TomlValue any

// TomlSections maps a section name to its keys. "" holds top-level keys.
type TomlSections map[string]map[string]TomlValue

// ParseToml reads a small TOML subset: scalar key/value pairs, `[section]` headers, comments,
// and double-quoted strings with no escapes. Arrays, inline tables, and anything else are
// skipped line by line; it never fails.
func ParseToml(text string) TomlSections {
	result := TomlSections{"": {}}
	current := ""
	for _, raw := range strings.Split(text, "\n") {
		line := trimWhitespace(stripComment(raw))
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") && !strings.HasPrefix(line, "[[") {
			name := trimWhitespace(line[1 : len(line)-1])
			if name == "" {
				continue
			}
			current = name
			result[current] = map[string]TomlValue{}
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		key := trimWhitespace(line[:eq])
		if key == "" {
			continue
		}
		value, ok := parseScalar(trimWhitespace(line[eq+1:]))
		if !ok {
			continue
		}
		if result[current] == nil {
			result[current] = map[string]TomlValue{}
		}
		result[current][key] = value
	}
	return result
}

func trimWhitespace(s string) string {
	return strings.TrimFunc(s, func(r rune) bool { return r == '\t' || unicode.Is(unicode.Zs, r) })
}

func stripComment(line string) string {
	inString := false
	for i := 0; i < len(line); i++ {
		switch line[i] {
		case '"':
			inString = !inString
		case '#':
			if !inString {
				return line[:i]
			}
		}
	}
	return line
}

func parseScalar(text string) (TomlValue, bool) {
	if strings.HasPrefix(text, `"`) && strings.HasSuffix(text, `"`) && len(text) >= 2 {
		return text[1 : len(text)-1], true
	}
	if text == "true" {
		return true, true
	}
	if text == "false" {
		return false, true
	}
	if strings.HasPrefix(text, "[") || strings.HasPrefix(text, "{") {
		return nil, false
	}
	if i, err := strconv.Atoi(text); err == nil {
		return i, true
	}
	if d, err := strconv.ParseFloat(text, 64); err == nil {
		return d, true
	}
	return nil, false
}
