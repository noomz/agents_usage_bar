import SwiftUI

// App-level environment keys.
//
// B5 NOTE: ClockKey + EnvironmentValues.clockService are OWNED by
// AgentsUsageBar/UI/Environment/ClockEnvironmentKey.swift (Plan 01.06).
// This file does NOT redeclare ClockKey or extend EnvironmentValues for clockService.
// It exists as a stub for future app-level environment keys (e.g., a Dependencies-bag
// accessor, Settings activation policy, theme) that have no UI-layer home.
//
// If no app-level keys are needed in Phase 1, this file contains only this
// comment block — the executor still creates it so the file path listed in
// `files_modified` exists (Phase 5+ plans expect this file as an extension point).

// Reserved for future App-scoped environment keys (Phase 5 Settings, etc.).
