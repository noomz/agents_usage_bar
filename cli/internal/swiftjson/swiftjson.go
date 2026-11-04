// Package swiftjson writes JSON with the exact bytes of Swift's JSONEncoder: `"key" : value`
// pretty printing, blank lines inside empty containers, bytewise sorted keys, `\/` unless
// disabled, and Double's shortest description.
//
// Values are map[string]any, []any, string, int, int64, float64, bool, Raw, and nil.
package swiftjson

import (
	"math"
	"sort"
	"strconv"
	"strings"
)

// Raw is written verbatim, for numbers that must keep every digit.
type Raw string

// Options selects JSONEncoder.OutputFormatting.
type Options struct {
	Pretty               bool
	WithoutEscapeSlashes bool
}

// Encode writes v. Map keys are always sorted, which makes output deterministic even where
// the Swift side is unsorted and random per process.
func Encode(v any, o Options) string {
	var b strings.Builder
	write(&b, v, o, 0)
	return b.String()
}

func write(b *strings.Builder, v any, o Options, depth int) {
	switch x := v.(type) {
	case nil:
		b.WriteString("null")
	case string:
		writeString(b, x, o)
	case Raw:
		b.WriteString(string(x))
	case bool:
		b.WriteString(strconv.FormatBool(x))
	case int:
		b.WriteString(strconv.Itoa(x))
	case int64:
		b.WriteString(strconv.FormatInt(x, 10))
	case uint64:
		b.WriteString(strconv.FormatUint(x, 10))
	case float64:
		b.WriteString(JSONDouble(x))
	case []any:
		writeArray(b, x, o, depth)
	case map[string]any:
		writeObject(b, x, o, depth)
	default:
		panic("swiftjson: unsupported value type")
	}
}

func newline(b *strings.Builder, o Options, depth int) {
	if o.Pretty {
		b.WriteByte('\n')
		b.WriteString(strings.Repeat("  ", depth))
	}
}

func writeArray(b *strings.Builder, items []any, o Options, depth int) {
	b.WriteByte('[')
	if len(items) == 0 {
		if o.Pretty {
			b.WriteString("\n\n")
			b.WriteString(strings.Repeat("  ", depth))
		}
		b.WriteByte(']')
		return
	}
	for i, item := range items {
		if i > 0 {
			b.WriteByte(',')
		}
		newline(b, o, depth+1)
		write(b, item, o, depth+1)
	}
	newline(b, o, depth)
	b.WriteByte(']')
}

func writeObject(b *strings.Builder, m map[string]any, o Options, depth int) {
	b.WriteByte('{')
	if len(m) == 0 {
		if o.Pretty {
			b.WriteString("\n\n")
			b.WriteString(strings.Repeat("  ", depth))
		}
		b.WriteByte('}')
		return
	}
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	separator := ":"
	if o.Pretty {
		separator = " : "
	}
	for i, k := range keys {
		if i > 0 {
			b.WriteByte(',')
		}
		newline(b, o, depth+1)
		writeString(b, k, o)
		b.WriteString(separator)
		write(b, m[k], o, depth+1)
	}
	newline(b, o, depth)
	b.WriteByte('}')
}

func writeString(b *strings.Builder, s string, o Options) {
	const hex = "0123456789abcdef"
	b.WriteByte('"')
	for _, r := range s {
		switch {
		case r == '"':
			b.WriteString(`\"`)
		case r == '\\':
			b.WriteString(`\\`)
		case r == '/' && !o.WithoutEscapeSlashes:
			b.WriteString(`\/`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\t':
			b.WriteString(`\t`)
		case r == '\b':
			b.WriteString(`\b`)
		case r == '\f':
			b.WriteString(`\f`)
		case r < 0x20:
			b.WriteString(`\u00`)
			b.WriteByte(hex[r>>4])
			b.WriteByte(hex[r&0xf])
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
}

// DoubleDescription is Swift's `"\(double)"`: shortest round-trip digits, plain notation for
// magnitudes from 0.0001 through 2^53, exponent form otherwise.
func DoubleDescription(f float64) string {
	switch {
	case math.IsNaN(f):
		return "nan"
	case math.IsInf(f, 1):
		return "inf"
	case math.IsInf(f, -1):
		return "-inf"
	case f == 0:
		if math.Signbit(f) {
			return "-0.0"
		}
		return "0.0"
	}
	abs := math.Abs(f)
	if abs < 0.0001 || abs > 1<<53 {
		return strconv.FormatFloat(f, 'e', -1, 64)
	}
	s := strconv.FormatFloat(f, 'f', -1, 64)
	if !strings.Contains(s, ".") {
		s += ".0"
	}
	return s
}

// JSONDouble is JSONEncoder's number form: the description without a trailing `.0`.
func JSONDouble(f float64) string {
	return strings.TrimSuffix(DoubleDescription(f), ".0")
}
