// Package decimal is exact money arithmetic with the observable behaviour of Foundation's
// Decimal: a 128-bit mantissa and a base-10 exponent. Values that fit are exact. Values that
// do not lose digits the way Foundation loses them, so sums print the same bytes as the app.
// Never use float64 for money.
package decimal

import (
	"math"
	"math/big"
	"strconv"
	"strings"
)

// Decimal is an immutable value. The zero value is 0.
type Decimal struct {
	mant *big.Int
	exp  int
}

const mantissaWords = 8

var (
	maxMantissa = new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 16*mantissaWords), big.NewInt(1))
	bigTen      = big.NewInt(10)
)

func pow10(n int) *big.Int {
	return new(big.Int).Exp(bigTen, big.NewInt(int64(n)), nil)
}

// FromInt converts exactly.
func FromInt(n int64) Decimal {
	return compact(big.NewInt(n), 0)
}

// Parse reads a decimal string, optionally signed, with an optional exponent. Digits beyond
// the mantissa are dropped, as `Decimal(string:)` and JSONDecoder drop them.
func Parse(s string) (Decimal, bool) {
	body := s
	neg := false
	if strings.HasPrefix(body, "-") || strings.HasPrefix(body, "+") {
		neg = body[0] == '-'
		body = body[1:]
	}
	expPart := 0
	if i := strings.IndexAny(body, "eE"); i >= 0 {
		e, err := strconv.Atoi(body[i+1:])
		if err != nil {
			return Decimal{}, false
		}
		expPart = e
		body = body[:i]
	}
	mant := new(big.Int)
	exp := 0
	seenPoint, seenDigit, full := false, false, false
	for _, c := range body {
		switch {
		case c == '.' && !seenPoint:
			seenPoint = true
		case c >= '0' && c <= '9':
			seenDigit = true
			if full {
				if !seenPoint {
					exp++
				}
				continue
			}
			next := new(big.Int).Mul(mant, bigTen)
			next.Add(next, big.NewInt(int64(c-'0')))
			if next.Cmp(maxMantissa) > 0 {
				full = true
				if !seenPoint {
					exp++
				}
				continue
			}
			mant = next
			if seenPoint {
				exp--
			}
		default:
			return Decimal{}, false
		}
	}
	if !seenDigit {
		return Decimal{}, false
	}
	if neg {
		mant.Neg(mant)
	}
	return compact(mant, exp+expPart), true
}

// MustParse is for literals known to be valid.
func MustParse(s string) Decimal {
	d, ok := Parse(s)
	if !ok {
		panic("decimal: invalid literal " + s)
	}
	return d
}

// FromFloat64 mirrors `Decimal(Double)`. It carries the same binary expansion
// (0.07 becomes 0.07000000000000001024) because the app stores and sums those values.
func FromFloat64(value float64) Decimal {
	if value == 0 || math.IsNaN(value) || math.IsInf(value, 0) {
		return Decimal{}
	}
	const limit = float64(1 << 63 * 2.0)
	val := math.Abs(value)
	exponent := 0
	for val < limit {
		if exponent < -128 {
			return Decimal{}
		}
		val *= 10
		exponent--
	}
	for limit <= val {
		val /= 10
		exponent++
	}
	if exponent > 127 {
		return Decimal{}
	}
	mant, _ := new(big.Float).SetFloat64(val).Int(nil)
	if value < 0 {
		mant.Neg(mant)
	}
	return compact(mant, exponent)
}

func compact(mant *big.Int, exp int) Decimal {
	if mant.Sign() == 0 {
		return Decimal{}
	}
	m := new(big.Int).Set(mant)
	q, r := new(big.Int), new(big.Int)
	for {
		q.QuoRem(m, bigTen, r)
		if r.Sign() != 0 {
			break
		}
		m, q = q, m
		exp++
	}
	return Decimal{mant: m, exp: exp}
}

func (d Decimal) mantissa() *big.Int {
	if d.mant == nil {
		return new(big.Int)
	}
	return d.mant
}

func words(m *big.Int) int {
	return (m.BitLen() + 15) / 16
}

// fit cuts a mantissa to 128 bits by truncation, as Foundation's Decimal operators do.
func fit(m *big.Int, exp int) (*big.Int, int) {
	abs := new(big.Int).Abs(m)
	for abs.Cmp(maxMantissa) > 0 {
		abs.Quo(abs, bigTen)
		exp++
	}
	if m.Sign() < 0 {
		abs.Neg(abs)
	}
	return abs, exp
}

// Add follows NSDecimalNormalize: the operand with the larger exponent is scaled up as far
// as its free 16-bit words allow, and the other operand is truncated to meet it.
func (d Decimal) Add(o Decimal) Decimal {
	if d.IsZero() {
		return o
	}
	if o.IsZero() {
		return d
	}
	high, low := d, o
	if high.exp < low.exp {
		high, low = low, high
	}
	diff := high.exp - low.exp
	hm := new(big.Int).Set(high.mant)
	lm := new(big.Int).Set(low.mant)
	exp := low.exp
	scaled := new(big.Int).Mul(hm, pow10(diff))
	if new(big.Int).Abs(scaled).Cmp(maxMantissa) <= 0 {
		hm = scaled
	} else {
		const logBase10of2to16 = 4.81647993
		maxPow := int(math.Floor(float64(mantissaWords-words(hm)) * logBase10of2to16))
		hm.Mul(hm, pow10(maxPow))
		drop := diff - maxPow
		lm.Quo(lm, pow10(drop))
		exp = low.exp + drop
	}
	m, e := fit(new(big.Int).Add(hm, lm), exp)
	return compact(m, e)
}

// Mul is exact until the product overflows the mantissa.
func (d Decimal) Mul(o Decimal) Decimal {
	if d.IsZero() || o.IsZero() {
		return Decimal{}
	}
	m, e := fit(new(big.Int).Mul(d.mant, o.mant), d.exp+o.exp)
	return compact(m, e)
}

// Div divides by o. A zero divisor gives zero; callers divide by constants.
func (d Decimal) Div(o Decimal) Decimal {
	if d.IsZero() || o.IsZero() {
		return Decimal{}
	}
	const scale = 38
	num := new(big.Int).Mul(d.mant, pow10(scale))
	q := new(big.Int).Quo(num, o.mant)
	m, e := fit(q, d.exp-o.exp-scale)
	return compact(m, e)
}

// Neg returns -d.
func (d Decimal) Neg() Decimal {
	if d.IsZero() {
		return d
	}
	return Decimal{mant: new(big.Int).Neg(d.mant), exp: d.exp}
}

// IsZero reports d == 0.
func (d Decimal) IsZero() bool { return d.mant == nil || d.mant.Sign() == 0 }

// Sign is -1, 0, or 1.
func (d Decimal) Sign() int { return d.mantissa().Sign() }

func (d Decimal) rat() *big.Rat {
	r := new(big.Rat).SetInt(d.mantissa())
	if d.exp >= 0 {
		return r.Mul(r, new(big.Rat).SetInt(pow10(d.exp)))
	}
	return r.Quo(r, new(big.Rat).SetInt(pow10(-d.exp)))
}

// Cmp compares exactly.
func (d Decimal) Cmp(o Decimal) int { return d.rat().Cmp(o.rat()) }

// Float64 is for ratios only, such as a sparkline height. Never for money.
func (d Decimal) Float64() float64 {
	f, _ := d.rat().Float64()
	return f
}

// RoundPlain keeps scale fractional digits, rounding half away from zero.
func (d Decimal) RoundPlain(scale int) Decimal {
	if d.exp >= -scale {
		return d
	}
	drop := -scale - d.exp
	divisor := pow10(drop)
	abs := new(big.Int).Abs(d.mant)
	q, r := new(big.Int).QuoRem(abs, divisor, new(big.Int))
	if r.Mul(r, big.NewInt(2)).Cmp(divisor) >= 0 {
		q.Add(q, big.NewInt(1))
	}
	if d.mant.Sign() < 0 {
		q.Neg(q)
	}
	return compact(q, -scale)
}

// Fixed renders with exactly scale fractional digits, rounding half to even as the ICU
// currency formatter does. The sign is returned apart so callers can place a currency symbol.
func (d Decimal) Fixed(scale int) (negative bool, integer, fraction string) {
	abs := new(big.Int).Abs(d.mantissa())
	exp := d.exp + scale
	if exp >= 0 {
		abs.Mul(abs, pow10(exp))
	} else {
		divisor := pow10(-exp)
		q, r := new(big.Int).QuoRem(abs, divisor, new(big.Int))
		c := r.Mul(r, big.NewInt(2)).Cmp(divisor)
		if c > 0 || (c == 0 && q.Bit(0) == 1) {
			q.Add(q, big.NewInt(1))
		}
		abs = q
	}
	digits := abs.String()
	if len(digits) <= scale {
		digits = strings.Repeat("0", scale-len(digits)+1) + digits
	}
	return d.Sign() < 0, digits[:len(digits)-scale], digits[len(digits)-scale:]
}

// String is byte-identical to `NSDecimalNumber(decimal:).stringValue` and `Decimal.description`.
func (d Decimal) String() string {
	if d.IsZero() {
		return "0"
	}
	digits := new(big.Int).Abs(d.mant).String()
	sign := ""
	if d.mant.Sign() < 0 {
		sign = "-"
	}
	switch {
	case d.exp >= 0:
		return sign + digits + strings.Repeat("0", d.exp)
	case len(digits) > -d.exp:
		cut := len(digits) + d.exp
		return sign + digits[:cut] + "." + digits[cut:]
	default:
		return sign + "0." + strings.Repeat("0", -d.exp-len(digits)) + digits
	}
}
