// Package clock is the seam for wall-clock time.
package clock

import "time"

type Clock interface {
	Now() time.Time
}

type System struct{}

func (System) Now() time.Time { return time.Now() }

// Fixed always returns the same instant.
type Fixed time.Time

func (f Fixed) Now() time.Time { return time.Time(f) }
