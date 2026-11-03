package decimal

import (
	"bufio"
	"math"
	"os"
	"strconv"
	"strings"
	"testing"
)

// testdata/foundation_corpus.tsv holds random synthetic operations with the result real
// Foundation printed for them, captured on macOS with a Swift driver.
func TestFoundationCorpus(t *testing.T) {
	f, err := os.Open("testdata/foundation_corpus.tsv")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	failures := map[string]int{}
	total := map[string]int{}
	for scanner.Scan() {
		p := strings.Split(scanner.Text(), "\t")
		kind := p[0]
		var got, want string
		switch kind {
		case "parse":
			got, want = MustParse(p[1]).String(), p[2]
		case "add":
			got, want = MustParse(p[1]).Add(MustParse(p[2])).String(), p[3]
		case "mul":
			got, want = MustParse(p[1]).Mul(MustParse(p[2])).String(), p[3]
		case "div":
			got, want = MustParse(p[1]).Div(MustParse(p[2])).String(), p[3]
		case "fromdouble":
			bits, err := strconv.ParseUint(p[1], 10, 64)
			if err != nil {
				t.Fatal(err)
			}
			got, want = FromFloat64(math.Float64frombits(bits)).String(), p[2]
		case "money":
			got, want = MustParse(p[1]).RoundPlain(6).String(), p[2]
		case "usd":
			neg, i, fr := MustParse(p[1]).Fixed(2)
			sign := ""
			if neg {
				sign = "-"
			}
			got = sign + "$" + group(i) + "." + fr
			want = p[2]
		}
		total[kind]++
		if got != want {
			failures[kind]++
			if failures[kind] <= 5 {
				t.Errorf("%s %v: got %s want %s", kind, p[1:len(p)-1], got, want)
			}
		}
	}
	for kind, n := range failures {
		t.Errorf("%s: %d of %d differ", kind, n, total[kind])
	}
}

func group(digits string) string {
	var b strings.Builder
	for i, c := range digits {
		if i > 0 && (len(digits)-i)%3 == 0 {
			b.WriteByte(',')
		}
		b.WriteRune(c)
	}
	return b.String()
}

func TestStringForms(t *testing.T) {
	cases := []struct{ in, want string }{
		{"0", "0"}, {"1.50", "1.5"}, {"0.000001", "0.000001"}, {"1e3", "1000"}, {"-0.5", "-0.5"},
		{"1E-7", "0.0000001"}, {"100", "100"}, {"+2.5", "2.5"}, {".5", "0.5"},
		{"12345678901234567890123456789012345678901234", "12345678901234567890123456789012345678900000"},
	}
	for _, c := range cases {
		if got := MustParse(c.in).String(); got != c.want {
			t.Errorf("%s: got %s want %s", c.in, got, c.want)
		}
	}
	for _, bad := range []string{"", "abc", ".", "1.2.3", "1e"} {
		if _, ok := Parse(bad); ok {
			t.Errorf("%q should not parse", bad)
		}
	}
	var zero Decimal
	if zero.String() != "0" || zero.Add(FromInt(2)).Cmp(FromInt(2)) != 0 {
		t.Error("zero value is not usable as 0")
	}
}
