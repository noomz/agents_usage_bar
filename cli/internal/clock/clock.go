// Package clock is the seam for wall-clock time.
package clock

import "time"

// Clock returns the current time.
type Clock interface {
	Now() time.Time
}

// System is the production clock.
type System struct{}

// Now returns the current time.
func (System) Now() time.Time { return time.Now() }

// Fixed always returns the same instant.
type Fixed time.Time

// Now returns the fixed instant.
func (f Fixed) Now() time.Time { return time.Time(f) }
