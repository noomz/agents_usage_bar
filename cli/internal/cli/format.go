package cli

import (
	"math"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"unicode"
	"unsafe"

	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

const (
	ansiReset = "\x1b[0m"
	ansiDim   = "\x1b[2m"
)

var bandCodes = map[domain.QuotaBand]string{
	domain.BandNone:     "\x1b[90m",
	domain.BandCritical: "\x1b[31m",
	domain.BandWarning:  "\x1b[33m",
	domain.BandHealthy:  "\x1b[32m",
}

// paint wraps text in the band's colour. Blank text stays bare so no empty escapes appear.
func paint(text string, band domain.QuotaBand, color bool) string {
	if !color || strings.TrimFunc(text, unicode.IsSpace) == "" {
		return text
	}
	return bandCodes[band] + text + ansiReset
}

func dim(text string, color bool) string {
	if color {
		return ansiDim + text + ansiReset
	}
	return text
}

// chars approximates Swift's Character count: combining marks and joined sequences do not add
// a column.
func chars(s string) int {
	n := 0
	afterJoiner := false
	for _, r := range s {
		switch {
		case r == '‍':
			afterJoiner = true
		case unicode.Is(unicode.M, r), r == '️':
		case afterJoiner:
			afterJoiner = false
		default:
			n++
		}
	}
	return n
}

func pad(s string, n int) string {
	if width := chars(s); width < n {
		return s + strings.Repeat(" ", n-width)
	}
	return s
}

func spaces(n int) string {
	if n <= 0 {
		return ""
	}
	return strings.Repeat(" ", n)
}

func trimTrailingSpaces(s string) string { return strings.TrimRight(s, " ") }

func clamp01(x float64) float64 {
	if x < 0 {
		return 0
	}
	if x > 1 {
		return 1
	}
	return x
}

// blockBar is a whole-cell fill. A nil fraction is a full bar, meaning no limit.
func blockBar(consumed *float64, width int) string {
	if consumed == nil {
		return strings.Repeat("█", width)
	}
	filled := int(math.Round(clamp01(*consumed) * float64(width)))
	if filled > width {
		filled = width
	}
	return strings.Repeat("█", filled) + strings.Repeat("░", width-filled)
}

var partialBlocks = []string{"▏", "▎", "▍", "▌", "▋", "▊", "▉"}

// eighthBar is an eighth-block fill plus a track, returned apart so they colour separately.
func eighthBar(consumed float64, width int) (fill, track string) {
	eighths := int(math.Round(clamp01(consumed) * float64(width*8)))
	full, partial := eighths/8, eighths%8
	fill = strings.Repeat("█", full)
	used := full
	if partial > 0 {
		fill += partialBlocks[partial-1]
		used++
	}
	return fill, strings.Repeat("░", max(0, width-used))
}

func percent(fraction float64) string {
	return strconv.Itoa(int(math.Round(fraction*100))) + "%"
}

// MoneyStyle is a locale's USD and number format, as ICU renders it.
type MoneyStyle struct {
	Prefix, Suffix, Group, Decimal string
}

const (
	nbsp   = " "
	nnbsp  = " "
	dollar = "$"
	usDol  = "US$"
)

var (
	styleUS      = MoneyStyle{dollar, "", ",", "."}
	styleForeign = MoneyStyle{usDol, "", ",", "."}
)

// moneyStyles holds the formats verified against Foundation. A locale matches by full id, then
// by language; everything else uses styleForeign, which is ICU's form for most locales.
var moneyStyles = map[string]MoneyStyle{
	"en_US": styleUS,
	"en":    styleUS,
	"en_IN": styleUS,
	"en_AU": {"USD" + nbsp, "", ",", "."},
	"ja":    styleUS,
	"de":    {"", nbsp + dollar, ".", ","},
	"fr":    {"", nbsp + "$US", nnbsp, ","},
	"ru":    {"", nbsp + dollar, nbsp, ","},
}

// StyleForLocale resolves an identifier such as en_TH or en_US.UTF-8.
func StyleForLocale(id string) MoneyStyle {
	id = strings.NewReplacer("-", "_").Replace(id)
	if i := strings.IndexAny(id, ".@"); i >= 0 {
		id = id[:i]
	}
	if id == "" || id == "C" || id == "POSIX" {
		return styleUS
	}
	if s, ok := moneyStyles[id]; ok {
		return s
	}
	language, _, _ := strings.Cut(id, "_")
	if s, ok := moneyStyles[language]; ok && language != "en" {
		return s
	}
	return styleForeign
}

// activeStyle is the current locale's format. Tests leave it at the en_US default.
var (
	activeStyle = styleUS
	styleOnce   sync.Once
)

// useSystemLocale resolves the locale the first time money or tokens print: AppleLocale on
// macOS, which is what Foundation reads, and LC_ALL, LC_MONETARY, or LANG elsewhere.
func useSystemLocale(goos string) {
	styleOnce.Do(func() {
		if goos == "darwin" {
			if out, err := exec.Command("/usr/bin/defaults", "read", "-g", "AppleLocale").Output(); err == nil {
				activeStyle = StyleForLocale(strings.TrimSpace(string(out)))
			}
			return
		}
		for _, key := range []string{"LC_ALL", "LC_MONETARY", "LANG"} {
			if v := os.Getenv(key); v != "" {
				activeStyle = StyleForLocale(v)
				return
			}
		}
	})
}

func groupDigits(digits, group string) string {
	var b strings.Builder
	for i, c := range digits {
		if i > 0 && (len(digits)-i)%3 == 0 {
			b.WriteString(group)
		}
		b.WriteRune(c)
	}
	return b.String()
}

// usd is a currency amount such as $273.86, rounded half to even like ICU.
func usd(amount decimal.Decimal) string {
	negative, integer, fraction := amount.Fixed(2)
	sign := ""
	if negative {
		sign = "-"
	}
	s := activeStyle
	return sign + s.Prefix + groupDigits(integer, s.Group) + s.Decimal + fraction + s.Suffix
}

func tokenCount(n int) string {
	sign := ""
	if n < 0 {
		sign = "-"
		n = -n
	}
	return sign + groupDigits(strconv.Itoa(n), activeStyle.Group)
}

// terminalColumns is the stdout terminal's width, ok=false when stdout is not a terminal or the
// size is unknown. A successful ioctl also proves stdout is a terminal.
func terminalColumns() (columns int, isTTY bool) {
	var size struct{ Row, Col, Xpixel, Ypixel uint16 }
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, os.Stdout.Fd(), uintptr(syscall.TIOCGWINSZ), uintptr(unsafe.Pointer(&size)))
	if errno != 0 {
		return 0, false
	}
	return int(size.Col), true
}
