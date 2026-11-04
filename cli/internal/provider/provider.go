// Package provider is the seam between the CLI and one usage source.
//
// To add a provider, create cli/internal/providers/<name>/ with a function of type Build and
// add one line to the `builds` map in cli/internal/providers/registry.go. Nothing else changes:
// enable logic, the placeholder row while unregistered, ordering, filtering, rendering, and
// error handling already live outside the provider.
//
// Contract, ported from Providers/UsageProvider.swift and ProviderRegistryFactory.swift:
//
//   - Build decides whether the provider exists on this machine. It runs only when the provider
//     is enabled. Return nil when nothing is configured (no credential, no transcript root): the
//     registry then shows the provider's standard placeholder row. Do no network I/O in Build.
//   - ID, DisplayName, and Capabilities are constants. Use the domain.ProviderID constant and
//     the name Swift passes. Capabilities.HasTokens decides whether the row counts in the Today
//     total and IsLocal decides whether it renders on the `local` line.
//   - Fetch returns the snapshot and status as of now. It runs on its own goroutine once per `aub --live`,
//     concurrently with other providers, so a provider must not assume another has finished.
//     It may hold fields, since one Provider value is used by one goroutine at a time.
//   - On failure, return an error from the httpclient or a domain.ProviderError. Never return a
//     partial snapshot with an error. The session then keeps the cached snapshot as stale, or
//     shows an error row. Error text never reaches the output.
//   - The status Fetch returns is what the row prints, so a provider that has no data source
//     must return Unauthenticated and a stopped local runtime must return NotRunning, even
//     though Fetch succeeded. Set snapshot.Raw[domain.RawProviderStatus] as Swift does too.
//   - Money is decimal.Decimal, never float64. Decimal(Double) in Swift is decimal.FromFloat64
//     and Decimal(string:) is decimal.Parse, so totals print the same bytes. Time-of-day and day
//     boundaries use env.DayKeys, never time.Now or a locale calendar.
//   - Set snapshot.ProviderID and snapshot.AsOf. Leave Raw non-nil. Nil pointers and nil slices
//     mean "not reported" and print differently from zero and empty.
//   - Credentials are secret.Secret, revealed only inside an httpclient call. Read env through
//     env.Getenv and files through env.Paths, so tests can redirect them. Credentials are
//     read-only: never write a credential file and never spend a refresh token. An expired token
//     waits for the CLI that owns it to refresh it.
//   - Use env.HTTP for remote hosts and env.LocalhostHTTP for localhost. Providers log through
//     applog only; nothing may reach stdout or stderr.
//   - Use env.Cache for transcript offsets, baselines, and the daily accumulator. Do not read
//     or write today.json yourself. Use package jsonl to read transcripts incrementally.
package provider

import (
	"context"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/cache"
	"github.com/noomz/agents_usage_bar/cli/internal/clock"
	"github.com/noomz/agents_usage_bar/cli/internal/config"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/httpclient"
	"github.com/noomz/agents_usage_bar/cli/internal/paths"
	"github.com/noomz/agents_usage_bar/cli/internal/settings"
)

// Provider reports one source's usage. See the package comment for the contract.
type Provider interface {
	ID() domain.ProviderID
	DisplayName() string
	Capabilities() domain.Capabilities
	Fetch(ctx context.Context, now time.Time) (domain.UsageSnapshot, domain.ProviderStatus, error)
}

// Env is everything a provider may depend on.
type Env struct {
	Config        config.App
	Preferences   settings.Preferences
	HTTP          httpclient.Client
	LocalhostHTTP httpclient.Client
	Cache         cache.Store
	Clock         clock.Clock
	DayKeys       *domain.DayKeyOwner
	Paths         paths.Layout
	// Getenv reads the process environment. An unset variable reads as "".
	Getenv func(string) string
	// Processes lists running processes, for finding local engines.
	Processes ProcessCatalog
	// Keychain reads a generic-password item by service, nil where no Keychain exists.
	Keychain func(service string) ([]byte, error)
}

// Build creates a provider, or returns nil when it has nothing to read on this machine.
type Build func(Env) Provider

// EngineBuild creates a llama.cpp-compatible row for a resolved `[engine.*]` port.
type EngineBuild func(env Env, engine config.LocalEngine, port int) Provider

// PlaceholderSeed is the row shown for an enabled provider that is not registered.
type PlaceholderSeed struct {
	ProviderID         domain.ProviderID
	DisplayName        string
	PlaceholderMessage *string
	Status             domain.ProviderStatus
}

// Registry is the composed set of providers for one run.
type Registry struct {
	Providers    []Provider
	Placeholders []PlaceholderSeed
}
