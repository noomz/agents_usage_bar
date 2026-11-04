package pilocal

import (
	"bytes"
	"encoding/json"
	"strconv"
	"strings"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
)

// Record is one spend event from a Pi session line.
type Record struct {
	Timestamp time.Time
	Provider  string
	Model     string
	Tokens    int
	CostUSD   decimal.Decimal
}

var linePrefilters = [][]byte{
	[]byte(`"type":"message"`), []byte(`"type": "message"`),
	[]byte(`"type":"usage"`), []byte(`"type": "usage"`),
}

// DecodeRecord returns false for any line that is not spend: another type, no usage block, or
// malformed. Compaction and branch summaries carry usage blocks that are not spend.
func DecodeRecord(line []byte) (Record, bool) {
	matched := false
	for _, needle := range linePrefilters {
		if bytes.Contains(line, needle) {
			matched = true
			break
		}
	}
	if !matched {
		return Record{}, false
	}
	var top map[string]json.RawMessage
	if json.Unmarshal(line, &top) != nil {
		return Record{}, false
	}
	stamp, ok := stringOf(top["timestamp"])
	if !ok {
		return Record{}, false
	}
	timestamp, err := time.Parse(time.RFC3339Nano, stamp)
	if err != nil {
		return Record{}, false
	}
	kind, _ := stringOf(top["type"])
	entry := top
	switch kind {
	case "usage":
	case "message":
		message, ok := objectOf(top["message"])
		if !ok {
			return Record{}, false
		}
		if role, _ := stringOf(message["role"]); role != "assistant" {
			return Record{}, false
		}
		entry = message
	default:
		return Record{}, false
	}
	usage, ok := objectOf(entry["usage"])
	if !ok {
		return Record{}, false
	}
	provider, ok := stringOf(entry["provider"])
	if !ok {
		return Record{}, false
	}
	model, _ := stringOf(entry["model"])
	return Record{Timestamp: timestamp, Provider: provider, Model: model, Tokens: tokens(usage), CostUSD: cost(usage)}, true
}

// tokens prefers totalTokens and never adds it to the part sum.
func tokens(usage map[string]json.RawMessage) int {
	if total, ok := intValue(usage["totalTokens"]); ok {
		return total
	}
	sum := 0
	for _, key := range []string{"input", "output", "cacheRead", "cacheWrite", "reasoning"} {
		part, _ := intValue(usage[key])
		sum += part
	}
	return sum
}

func cost(usage map[string]json.RawMessage) decimal.Decimal {
	if block, ok := objectOf(usage["cost"]); ok {
		if total, ok := decimalValue(block["total"]); ok {
			return total
		}
	}
	return decimal.FromInt(0)
}

func stringOf(raw json.RawMessage) (string, bool) {
	var s *string
	if len(raw) == 0 || json.Unmarshal(raw, &s) != nil || s == nil {
		return "", false
	}
	return *s, true
}

func objectOf(raw json.RawMessage) (map[string]json.RawMessage, bool) {
	var m map[string]json.RawMessage
	if len(raw) == 0 || json.Unmarshal(raw, &m) != nil || m == nil {
		return nil, false
	}
	return m, true
}

// intValue accepts what JSONSerialization's NSNumber accepts: integers, truncated fractions,
// and booleans as 0 or 1. A numeric string also counts.
func intValue(raw json.RawMessage) (int, bool) {
	var v any
	if len(raw) == 0 || json.Unmarshal(raw, &v) != nil {
		return 0, false
	}
	switch n := v.(type) {
	case float64:
		return int(n), true
	case bool:
		if n {
			return 1, true
		}
		return 0, true
	case string:
		i, err := strconv.Atoi(n)
		return i, err == nil
	}
	return 0, false
}

func decimalValue(raw json.RawMessage) (decimal.Decimal, bool) {
	var v any
	if len(raw) == 0 || json.Unmarshal(raw, &v) != nil {
		return decimal.Decimal{}, false
	}
	switch n := v.(type) {
	case float64:
		return numberDecimal(strings.TrimSpace(string(raw))), true
	case bool:
		if n {
			return decimal.FromInt(1), true
		}
		return decimal.FromInt(0), true
	case string:
		return decimal.Parse(n)
	}
	return decimal.Decimal{}, false
}

// numberDecimal is NSNumber.decimalValue of a JSONSerialization number. The parser keeps a
// literal with 18 or more fraction digits exactly and reads anything else as a Double, whose
// decimalValue has 16 significant digits. Fitted on 13166 literals against Foundation with no
// miss, and neither decimal.Parse nor decimal.FromFloat64 alone matches it.
func numberDecimal(literal string) decimal.Decimal {
	if i := strings.IndexByte(literal, '.'); i >= 0 && !strings.ContainsAny(literal, "eE") && len(literal)-i-1 >= 18 {
		d, _ := decimal.Parse(literal)
		return d
	}
	f, err := strconv.ParseFloat(literal, 64)
	if err != nil {
		return decimal.FromInt(0)
	}
	d, _ := decimal.Parse(strconv.FormatFloat(f, 'g', 16, 64))
	return d
}
