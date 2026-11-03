// Package resources embeds the data files the app bundles, so `aub` is one file with no
// siblings. Embed cannot reach outside this module, so these are copies of
// AgentsUsageBar/Resources; a test fails when they drift.
package resources

import _ "embed"

// ClaudePricing is Pricing/claude-models.json.
//
//go:embed claude-models.json
var ClaudePricing []byte

// CodexPricing is Pricing/codex-models.json.
//
//go:embed codex-models.json
var CodexPricing []byte

// Providers is Onboarding/providers.json.
//
//go:embed providers.json
var Providers []byte
