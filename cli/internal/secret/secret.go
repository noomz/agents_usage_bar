// Package secret wraps credentials so no formatter, logger, or encoder can print them.
package secret

import (
	"fmt"
	"log/slog"
)

const redacted = "<redacted>"

// Secret holds a credential. Reveal is the only way to read it and belongs only where a
// request header or body is built.
type Secret struct {
	value string
}

// New wraps a credential.
func New(value string) Secret { return Secret{value: value} }

// Reveal returns the plaintext. Call it only while building a request.
func (s Secret) Reveal() string { return s.value }

func (Secret) String() string { return redacted }

func (Secret) GoString() string { return redacted }

// Format redacts every verb, including %x and %q.
func (Secret) Format(f fmt.State, _ rune) { _, _ = f.Write([]byte(redacted)) }

// MarshalJSON redacts.
func (Secret) MarshalJSON() ([]byte, error) { return []byte(`"` + redacted + `"`), nil }

func (Secret) MarshalText() ([]byte, error) { return []byte(redacted), nil }

// LogValue redacts structured logs.
func (Secret) LogValue() slog.Value { return slog.StringValue(redacted) }
