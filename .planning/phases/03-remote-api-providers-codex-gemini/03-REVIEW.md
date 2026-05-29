---
phase: 03-remote-api-providers-codex-gemini
reviewed: 2026-05-18T00:00:00Z
depth: standard
files_reviewed: 27
files_reviewed_list:
  - AgentsUsageBar/Aggregation/AggregateStore.swift
  - AgentsUsageBar/App/AppDependencies.swift
  - AgentsUsageBar/Config/AppConfig.swift
  - AgentsUsageBar/Config/ConfigStore.swift
  - AgentsUsageBar/Domain/ProviderID.swift
  - AgentsUsageBar/Domain/UsageSnapshot.swift
  - AgentsUsageBar/Infrastructure/HTTPClient.swift
  - AgentsUsageBar/Infrastructure/URLSessionHTTPClient.swift
  - AgentsUsageBar/Notifications/ThresholdEngine.swift
  - AgentsUsageBar/Providers/Codex/CodexCredentialLoader.swift
  - AgentsUsageBar/Providers/Codex/CodexJSONLProvider.swift
  - AgentsUsageBar/Providers/Codex/CodexModelPricing.swift
  - AgentsUsageBar/Providers/Codex/CodexOAuthClient.swift
  - AgentsUsageBar/Providers/Codex/CodexRolloutParser.swift
  - AgentsUsageBar/Providers/Codex/CodexRolloutScanner.swift
  - AgentsUsageBar/Providers/Codex/CodexRoots.swift
  - AgentsUsageBar/Providers/Codex/Models/CodexOAuthError.swift
  - AgentsUsageBar/Providers/Codex/Models/CodexRolloutEvent.swift
  - AgentsUsageBar/Providers/Codex/Models/CodexUsageResponse.swift
  - AgentsUsageBar/Providers/Gemini/GeminiCredentialLoader.swift
  - AgentsUsageBar/Providers/Gemini/GeminiOAuthClient.swift
  - AgentsUsageBar/Providers/Gemini/GeminiOAuthProvider.swift
  - AgentsUsageBar/Providers/Gemini/GeminiSettingsGate.swift
  - AgentsUsageBar/Providers/Gemini/Models/GeminiLoadCodeAssistResponse.swift
  - AgentsUsageBar/Providers/Gemini/Models/GeminiOAuthCredentials.swift
  - AgentsUsageBar/Providers/Gemini/Models/GeminiOAuthError.swift
  - AgentsUsageBar/Providers/Gemini/Models/GeminiQuotaResponse.swift
  - AgentsUsageBar/Providers/Gemini/Models/GeminiTokenRefreshResponse.swift
  - AgentsUsageBar/Resources/Pricing/codex-models.json
  - AgentsUsageBar/UI/Components/StatusDot.swift
  - AgentsUsageBar/UI/Environment/OpenDashboardURLEnvironmentKey.swift
  - AgentsUsageBar/UI/ProviderDashboardURL.swift
  - AgentsUsageBar/UI/ProviderRowView.swift
  - AgentsUsageBar/UI/TotalsHeaderView.swift
findings:
  critical: 2
  critical_resolved: 2
  warning: 7
  info: 5
  total: 14
status: advisory
resolution:
  CR-01: resolved (commit pending — end-to-end Decimal arithmetic + regression test `cost_matchesComponentwiseDecimalSum_noDoubleAccumulation`)
  CR-02: resolved (commit pending — `lastRejectedAccessToken` tracking + regression test `retryAfter401_forcesRefresh_evenWhenDiskHoldsRejectedToken`)
---

# Phase 3: Code Review Report

**Reviewed:** 2026-05-18T00:00:00Z
**Depth:** standard
**Files Reviewed:** 27 (incl. 1 JSON resource)
**Status:** issues_found

## Summary

Phase 3 adds two new providers (OpenAI Codex via local rollouts + OAuth fallback; Google Gemini via OAuth-personal + `v1internal` endpoints) plus the supporting infrastructure (HTTP client extensions, config sections, UI updates, threshold-engine degraded filter). Overall the SEC-01 secret-wrapping contract, D-09 eager/lazy state machine, D-10 in-memory-only refresh, D-11 degraded notification suppression, and D-07 quota-only rollup exclusion are correctly implemented and well-tested.

Two correctness blockers were identified:

1. **Numerical correctness regression in `CodexModelPricing.cost(...)`** — `Decimal(micro / 1_000_000.0)` converts a `Double` to `Decimal` *after* the IEEE 754 divide, defeating the whole reason for using `Decimal`. The Claude pricing module has the identical bug (precedent), but Phase 3 propagates it. This visibly drifts cost displays once token counts grow past tens of millions and breaks the STATE #28 "Decimal at the final step" claim in the doc comment.
2. **Stale-token reuse risk in `GeminiOAuthClient.freshAccessToken(now:)`** — Step 3 unconditionally accepts the on-disk `accessToken` whenever its `expiry_date` is >60s in the future, even when the actor's in-memory cache holds a *fresher* access token from a more recent refresh that has not yet been written to disk (D-10 = no write-back). On the next poll, if the cache happens to be invalidated (`retryAfter401` cleared it) and the user's gemini-cli updated `expiry_date` to a near-future value via a concurrent path, the OAuth client may return a stale string instead of refreshing. The hot path also re-reads disk on every poll inside the actor, which is fine, but the algorithm trusts disk over cache freshness without comparing the two `accessToken` strings.

Beyond those, several smaller defects and warnings: the `CodexConfig.bearerOverride` env override (`CODEX_BEARER_TOKEN`) and `GeminiConfig.projectIDOverride` env override (`GEMINI_PROJECT_ID`) are parsed by `ConfigStore` but never consumed by `AppDependencies.makeProduction()` — users will think the env vars work; they silently don't. The empty-env vs. unset-env contract is also asymmetric between OpenRouter (Phase 1) and the new sections.

## Critical Issues

### CR-01: `CodexModelPricing.cost(...)` performs the division in `Double` *before* the `Decimal` cast — IEEE 754 drift survives

**File:** `AgentsUsageBar/Providers/Codex/CodexModelPricing.swift:187-190`
**Issue:** The doc comment promises "Uses `Decimal` at the final step per STATE #28 — avoids IEEE 754 drift" but the implementation does:

```swift
let micro = Double(nonCachedInput)         * rate.inputPerMToken
          + Double(cachedInputTokens)      * rate.cachedInputPerMToken
          + Double(outputTokens)           * rate.outputPerMToken
return Decimal(micro / 1_000_000.0)
```

Both the multiplications and the `/ 1_000_000.0` happen in `Double` arithmetic. By the time we hand the value to `Decimal.init(_ value: Double)`, every bit of binary-float imprecision is already baked in — the constructor is a lossy `Double → Decimal` bit reinterpretation, not a re-evaluation in base-10. Once `inputTokens × inputPerMToken` exceeds `2^53 ≈ 9.0 × 10^15` micro-cents (which a high-token-count session can approach when summed across the day), Double silently rounds. Even below that threshold the rounded-to-nearest-Double cost will display as e.g. `$0.061585999999…` once converted back via `formatted(.currency(code:))`.

The same anti-pattern was inherited from `ClaudeModelPricing.swift:178` (Phase 2), so the regression isn't novel — but Phase 3 codifies it on a NEW pricing module, doubling the surface that needs a real `Decimal` rewrite.

**Fix:** Perform the arithmetic in `Decimal`:

```swift
public func cost(
    inputTokens: Int,
    cachedInputTokens: Int,
    outputTokens: Int,
    reasoningOutputTokens: Int,
    modelID: String?
) -> Decimal {
    _ = reasoningOutputTokens
    let (rate, _) = self.rate(for: modelID)
    let nonCachedInput = max(0, inputTokens - cachedInputTokens)

    let perMillion: Decimal = 1_000_000
    let inputCost  = Decimal(nonCachedInput)    * Decimal(rate.inputPerMToken)        / perMillion
    let cachedCost = Decimal(cachedInputTokens) * Decimal(rate.cachedInputPerMToken)  / perMillion
    let outputCost = Decimal(outputTokens)      * Decimal(rate.outputPerMToken)       / perMillion
    return inputCost + cachedCost + outputCost
}
```

(`Decimal(_: Double)` still incurs a one-time Double→Decimal conversion on the *rate*, which is fine — rates are sub-$5 constants; the drift surface there is < $10^-15. The token counts must use `Decimal(Int)` which is exact.)

**Resolution (2026-05-18):** Applied the suggested per-column Decimal arithmetic; division by `Decimal(1_000_000)` happens inside Decimal, eliminating cross-column Double accumulation. Doc comment updated to honestly describe the one-time per-rate cliff. Regression test added: `CodexModelPricingTests/cost_matchesComponentwiseDecimalSum_noDoubleAccumulation` asserts `cost(...)` equals the component-wise Decimal sum at high token counts where Double accumulation would diverge. ClaudeModelPricing carries the same pre-existing pattern but is out of Phase 3 scope (tracked separately).

### CR-02: `GeminiOAuthClient` trusts disk `access_token` over the actor's in-memory cache without freshness comparison

**File:** `AgentsUsageBar/Providers/Gemini/GeminiOAuthClient.swift:100-136`
**Issue:** The state machine in `freshAccessToken(now:)` proceeds in this order:

1. If the in-memory `cachedAccessToken` has `expiry > now + 60s` → use cache.
2. Otherwise, load creds from disk.
3. If the *on-disk* `access_token` has `expiry_date > now + 60s` → overwrite the in-memory cache with the on-disk value and return it.
4. Otherwise, refresh via Google.

Step 3 happens whenever step 1 missed — i.e. whenever the cache was nil OR the cached token's expiry was within the skew window. Crucially, `retryAfter401(now:)` (lines 141-145) sets `cachedAccessToken = nil` to force a refresh. The next caller hits step 2 and finds the (potentially still-stale) on-disk `access_token` that the gemini-cli or another process happened to update concurrently to a value with a non-imminent expiry. The client then **returns the disk token instead of forcing the refresh that `retryAfter401` was supposed to compel**, defeating the lazy-401 invariant documented at the top of the file:

> "Lazy 401 catch (D-09): if a downstream call (Plan 03-06) returns 401, invalidate the cache and force one fresh refresh."

The contract says "force one fresh refresh" — but the *implementation* says "force a re-read from disk and only refresh if the disk copy looks stale." If gemini-cli sat in the background and rotated `oauth_creds.json` between our 401 and our retry, we'd happily return the same token Google just rejected.

The race is hard to hit deliberately, but the consequence is a stuck `.error(401)` loop: the provider thinks it refreshed, Google rejects again, `retryAfter401` clears the cache again, file re-read returns the *same* on-disk token, and so on indefinitely until either the on-disk token actually expires or the user manually re-authenticates.

**Fix:** `retryAfter401` should signal "skip the disk fast-path on the next refresh," not just clear the cache. Add an internal flag or take a `forceRefresh` parameter on the private path:

```swift
private var skipFileFastPath: Bool = false

public func retryAfter401(now: Date) async throws -> Secret {
    cachedAccessToken = nil
    cachedExpiryDate = nil
    skipFileFastPath = true
    return try await freshAccessToken(now: now)
}

public func freshAccessToken(now: Date) async throws -> Secret {
    if let cached = cachedAccessToken, let expiry = cachedExpiryDate,
       expiry.timeIntervalSince(now) > Self.refreshSkewSeconds {
        return Secret(cached)
    }
    guard let result = credentialLoader.loadCredentials() else {
        throw GeminiOAuthError.notSignedIn
    }
    lastRefreshTokenSeen = result.credentials.refreshToken

    if !skipFileFastPath,
       let fileAccess = result.credentials.accessToken, !fileAccess.isEmpty {
        let fileExpiry = result.credentials.expiryDateAsDate()
        if fileExpiry.timeIntervalSince(now) > Self.refreshSkewSeconds {
            cachedAccessToken = fileAccess
            cachedExpiryDate = fileExpiry
            return Secret(fileAccess)
        }
    }
    skipFileFastPath = false  // consumed
    let refreshed = try await performRefresh(...)
    ...
}
```

A simpler alternative: compare the disk token string against the (just-cleared) `lastRefreshTokenSeen` token from the prior poll — if they match, skip the file fast-path. Either way the current implementation has the bug.

**Resolution (2026-05-18):** Adopted the simpler-alternative variant. Added `private var lastRejectedAccessToken: String?` on the actor. `retryAfter401(now:)` records whichever bearer the caller saw rejected (cache first, then on-disk) before clearing the cache. `freshAccessToken(now:)` STEP 3 now compares `fileAccess != lastRejectedAccessToken` and skips the fast-path on match, forcing the POST to `oauth2.googleapis.com/token`. Cleared after a successful refresh. Regression test added: `GeminiOAuthClientTests/retryAfter401_forcesRefresh_evenWhenDiskHoldsRejectedToken` proves the POST fires even when the on-disk file still holds the rejected access_token with a non-imminent expiry.

## Warnings

### WR-01: `CodexConfig.bearerOverride` and `GeminiConfig.projectIDOverride` are parsed but never consumed — dead env knobs

**File:** `AgentsUsageBar/App/AppDependencies.swift:142-206` (and `Config/ConfigStore.swift:154-181`)
**Issue:** `ConfigStore.load()` reads `CODEX_BEARER_TOKEN` into `CodexConfig.bearerOverride` and `GEMINI_PROJECT_ID` into `GeminiConfig.projectIDOverride`. Neither value is then read by `AppDependencies.makeProduction()`:

- The Codex composition root at line 147 instantiates `CodexCredentialLoader()` (no override) and the Codex OAuth client reads only that loader.
- The Gemini composition root at line 196 instantiates `GeminiOAuthClient(http: http, clock: clock)` (no project ID) and the provider captures projects from the `loadCodeAssist` response with no override path.

This means the documented env-override mechanism in `AppConfig.swift:106-115` and `:149-160` (with prominent "advanced testing knob" and "lets advanced users bypass the loadCodeAssist project capture" doc comments) silently does nothing. A user who sets `GEMINI_PROJECT_ID=abc` to debug a stuck project capture will see no behaviour change — the worst kind of config-knob failure.

**Fix:** Wire both values, or remove them from the config struct entirely. Minimum wiring:

```swift
// In the Codex composition block:
let codexCredsLoader: CodexCredentialLoader
if let override = config.codex.bearerOverride {
    // Build a synthetic auth.json or a loader variant that injects the override.
    // (Requires a new init on CodexCredentialLoader that accepts a Secret directly.)
} else {
    codexCredsLoader = CodexCredentialLoader()
}

// In the Gemini composition block:
let geminiProvider = GeminiOAuthProvider(
    http: http, oauth: geminiOAuth, clock: clock,
    projectIDOverride: config.gemini.projectIDOverride  // new init param
)
```

If wiring is genuinely out of scope (deferred to Phase 4/5), the fields should be deleted from `AppConfig` and `ConfigStore`, not left as misleading no-ops.

### WR-02: `CodexConfig.sessionWindowDays` field is read only to assign itself back to the default

**File:** `AgentsUsageBar/Config/ConfigStore.swift:160-162`
**Issue:**

```swift
// codex.sessionWindowDays: hard-coded 2 in v1 per 03-CONTEXT
// "Deferred Ideas — Configurable session_window_days".
let codexSessionWindowDays = defaults.codex.sessionWindowDays
```

`sessionWindowDays` is then passed to `CodexConfig(sessionWindowDays: codexSessionWindowDays)` and never consumed by `CodexRolloutScanner` (which hard-codes today + yesterday in lines 76-80). The field is a documentary placeholder that doesn't even *let* a TOML knob override it. Either expose the TOML knob now (one-liner mirroring the `enabled` parser) or delete the field; the current shape mis-signals "this is configurable" to future maintainers.

**Fix:** Either remove the field from `CodexConfig` until Phase 4 needs it, or wire it through:

```swift
let codexSessionWindowDays: Int
if case .int(let i) = codexSection["session_window_days"], i >= 1 {
    codexSessionWindowDays = i
} else {
    codexSessionWindowDays = defaults.codex.sessionWindowDays
}
```

…and then have `CodexRolloutScanner` accept the window count as a constructor parameter and loop over `0..<window` days.

### WR-03: `ConfigStore` env-empty-string vs unset asymmetry between OpenRouter (Phase 1) and Codex/Gemini (Phase 3)

**File:** `AgentsUsageBar/Config/ConfigStore.swift:67-73` vs. `:154-158` and `:177-181`
**Issue:** The Phase 1 OpenRouter path uses `env.value(forKey:)` directly — which (per `EnvReader` contract / STATE #22) treats empty-string env values as absent. The Phase 3 Codex/Gemini paths use the same call, but the inline comments at line 110 and 122 of `AppConfig.swift` claim "empty-env strings are treated as absent; `ConfigStore` enforces this rule." That claim is true only if `EnvReader` enforces it — `ConfigStore` itself does not check `!envBearer.isEmpty`. If a future `EnvReader` implementation forgets the empty-string filter, the Phase 3 code silently wraps `Secret("")` and ships an empty bearer string into the Authorization header.

**Fix:** Belt-and-suspenders — guard at the consumer:

```swift
if let envBearer = env.value(forKey: "CODEX_BEARER_TOKEN"), !envBearer.isEmpty {
    codexBearer = Secret(envBearer)
} else {
    codexBearer = nil
}
```

Identical fix for `GEMINI_PROJECT_ID`. The cost is one branch; the benefit is the doc-comment claim becomes locally enforced rather than relying on an out-of-file invariant.

### WR-04: `CodexRolloutScanner.rolloutFiles()` may return duplicates when today+yesterday point at the same date dir or symlinks alias them

**File:** `AgentsUsageBar/Providers/Codex/CodexRolloutScanner.swift:82-95`
**Issue:** The scanner loops `[todayStart, yesterdayStart]` and appends results from both directories. There is no de-duplication. Two realistic ways duplicates appear:

1. **DST "fall back" boundary (US-PT at 02:00 local):** `calendar.startOfDay(for: now)` and `calendar.date(byAdding: .day, value: -1, to: todayStart)` are guaranteed to differ as `Date`s, but the rendered `YYYY/MM/DD` directory components can collide if `now` falls within the repeated 01:00-02:00 hour and the locale's calendar interprets the math differently from the formatter. Component extraction (`calendar.dateComponents([.year,.month,.day])`) usually saves us, but the safety net assumes Foundation's behaviour is identical across both `Date`s in the ambiguous window — which has been a Foundation regression source historically.
2. **User-side symlinks** — if `~/.codex/sessions/2026/05/17` is a symlink to `…/2026/05/18`, both scans canonicalise to the same `/private/var/…` URL and the downstream `CodexRolloutParser.lastTokenCount` will read each file twice. The parser fold by max-timestamp tolerates this *for now* (idempotent), but it doubles file I/O and inflates the `setTranscriptOffsets` batch size — and there's no guarantee future consumers of `rolloutFiles()` will be idempotent.

**Fix:** De-duplicate against the canonical URL set before returning:

```swift
var seen: Set<URL> = []
var results: [URL] = []
for date in [todayStart, yesterdayStart] {
    let comps = calendar.dateComponents([.year,.month,.day], from: date)
    let dir = root.appendingPathComponent(String(format: "%04d", comps.year!), isDirectory: true)
        .appendingPathComponent(String(format: "%02d", comps.month!), isDirectory: true)
        .appendingPathComponent(String(format: "%02d", comps.day!), isDirectory: true)
    for url in jsonlFiles(in: dir) where !seen.contains(url) {
        seen.insert(url)
        results.append(url)
    }
}
return results
```

### WR-05: `CodexRolloutParser.lastTokenCount` reads the WHOLE rollout file synchronously every poll, by-passing the byte-offset cache

**File:** `AgentsUsageBar/Providers/Codex/CodexRolloutParser.swift:62-111` (called from `CodexJSONLProvider.swift:183`)
**Issue:** `CodexJSONLProvider.fetch` does run `reader.readDelta(...)` for offset-cache bookkeeping (lines 152-159) so the *cache* tracks each file's last-seen byte offset. BUT the actual token-count fold runs `CodexRolloutParser.lastTokenCount(in: rolloutFiles)` (line 183) which calls `String(contentsOf: url, encoding: .utf8)` on every file every poll, regardless of cache state. The doc comment (parser line 22-25) admits this is intentional — "Plan 03-04 (`TranscriptReader` integration with offset cache) is when streaming-by-delta lands" — but Plan 03-04 is what wired this provider in, and the integration didn't happen.

Once a Codex user has 5 MB of rollouts over today + yesterday, every poll re-reads ~10 MB end-to-end with a fresh `JSONDecoder` per line. At the default 5-minute interval that's 120 MB/hour of useless re-decode work. Not a correctness bug (Phase 3 is explicitly out of scope for perf) but it directly contradicts the "STATE #43 batched offset cache" rationale the surrounding code documents — and the cache writes are now load-bearing only for bookkeeping that no consumer reads.

**Fix (in scope for a follow-up, not this review):** Make `CodexRolloutParser` accept a per-file `startOffset` and seek into the file before scanning. The fold semantic ("LATEST `token_count` event by timestamp") still works if we maintain per-file "best-so-far event" state in the cache.

### WR-06: `URLSessionHTTPClient.postFormURLEncoded` does NOT use the `extraHeaders` Content-Type — silent header override risk

**File:** `AgentsUsageBar/Infrastructure/URLSessionHTTPClient.swift:79-121`
**Issue:** The method sets `Content-Type: application/x-www-form-urlencoded` *before* applying `extraHeaders`:

```swift
req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
for (key, value) in extraHeaders {
    req.setValue(value, forHTTPHeaderField: key)
}
```

If a caller passes `extraHeaders["Content-Type"] = "application/json"` (e.g. by accident — perhaps a copy-pasted header dict from a JSON call site), it silently overrides the form-URL-encoded content type while the body is still form-encoded. The server then 400s and we surface an opaque `refreshFailed(status: 400)` with no debug breadcrumb.

The Authorization-bearer JSON path at line 175-185 has the same shape but at least the failure mode is harder to trip (no one passes an explicit Content-Type alongside `bearer:`). For the form-URL-encoded path, the call is a documented OAuth-refresh — sufficient blast radius that we should defend it.

**Fix:** Either (a) drop the caller's Content-Type override:

```swift
for (key, value) in extraHeaders where key.lowercased() != "content-type" {
    req.setValue(value, forHTTPHeaderField: key)
}
```

or (b) `assert(extraHeaders["Content-Type"] == nil, "postFormURLEncoded fixes the Content-Type")`. The current behaviour is a footgun.

### WR-07: `GeminiOAuthError.transport` equates ALL transport errors — `#expect(throws: .transport)` passes regardless of underlying

**File:** `AgentsUsageBar/Providers/Gemini/Models/GeminiOAuthError.swift:50-55`
**Issue:** The custom `==` implementation declares "any two `.transport` cases are equal" purely for test-assertion convenience:

```swift
case (.transport, .transport):
    // Underlying Error is not generally Equatable; treat any two
    // transport errors as equal for assertion convenience.
    return true
```

This is the same anti-pattern that bit Phase 2 (STATE #54): a test asserts `error == .transport(underlying: NSError(...))` and passes even when the underlying error has nothing to do with what the test claims to be checking. Any test using `#expect(throws: GeminiOAuthError.transport(...))` will succeed on, e.g., a `DecodingError` it never intended to catch. Worse, the disposition guidance in the same file at line 39 says ".transport(underlying:) — network / DecodingError / non-HTTPError failures bubbled from the HTTP layer" — these are semantically *very* different errors that the FSM in `GeminiOAuthProvider.fetch` treats identically (degraded UX), so a test that fails to discriminate will mask real-world misclassification (e.g. accidental retry-loop on `DecodingError`, which is non-transient).

**Fix:** Either remove the `==` overload for `.transport` entirely (and have tests assert on the `if case .transport = err` form), or compare the underlying error's `localizedDescription`:

```swift
case (.transport(let a), .transport(let b)):
    return String(describing: a) == String(describing: b)
```

The latter at least catches the "I expected a URLError, I got a DecodingError" mistake.

## Info

### IN-01: `GeminiOAuthClient.lastRefreshTokenSeen` is dead state — written, never read

**File:** `AgentsUsageBar/Providers/Gemini/GeminiOAuthClient.swift:71, 114`
**Issue:** The doc comment says "Diagnostics-only mirror of the last refresh_token observed on disk. Never used as a bearer; never logged." It's assigned in line 114 (`lastRefreshTokenSeen = result.credentials.refreshToken`) and never read anywhere — the name implies a planned diagnostic surface that never landed. Holding the refresh_token plaintext in actor state for an unused purpose is a SEC-01 risk (no `Secret` wrap, no redaction in `dump`/`String(reflecting:)`).

**Fix:** Delete the property. If/when diagnostics need it, re-introduce wrapped in `Secret`.

### IN-02: `GeminiSettingsGate.isOAuthPersonal` accepts `fileManager` parameter that it never uses

**File:** `AgentsUsageBar/Providers/Gemini/GeminiSettingsGate.swift:40-43`
**Issue:** The doc comment notes "Reserved for symmetry with other loaders; not used directly (`Data(contentsOf:)` performs the file read)." The parameter has a default of `.default`, so call sites don't notice — but the symmetry is illusory (the parameter has no effect even if a test injects a non-default `FileManager`), and it adds a "this was tested with X" claim that isn't true. The Codex `CodexCredentialLoader` has the same useless parameter.

**Fix:** Remove the parameter, OR pass it through to `Data(contentsOf:)` if a real symmetry use case exists.

### IN-03: `CodexRolloutEvent.RateLimits.credits.balance` Decimal parse is silent on garbage strings

**File:** `AgentsUsageBar/Providers/Codex/CodexJSONLProvider.swift:300-306`
**Issue:** `Decimal(string: balanceStr)` returns `nil` for garbage input. The provider then sets `balanceUSD = nil`. There's no `logger.notice("could not parse balance string: ...")` breadcrumb — a future Codex schema change that ships balances as integers ("`100`") instead of strings ("`100.00`") would silently drop balances from the row with no log. Same omission at line 372 for the OAuth path.

**Fix:** Log at `.notice` when parsing fails on a non-nil input string:

```swift
if let balanceStr = event.payload.rateLimits?.credits?.balance {
    if let dec = Decimal(string: balanceStr) {
        balanceUSD = dec
    } else {
        logger.notice("rollout balance string did not parse as Decimal")
        balanceUSD = nil
    }
}
```

### IN-04: `CodexModelPricing` `reasoningOutputTokens` parameter is silently ignored — `_ = reasoningOutputTokens` is a smell

**File:** `AgentsUsageBar/Providers/Codex/CodexModelPricing.swift:177-183`
**Issue:** The signature includes a parameter that is documented to be intentionally unused. The body acknowledges this with `_ = reasoningOutputTokens // The reasoning…`. This is a maintenance landmine — a future contributor reading the call site `pricing.cost(..., reasoningOutputTokens: 0, …)` may assume the value matters and start passing real numbers, with no compile-time signal that the parameter is a no-op. Better to either remove the parameter from the public API or to encode the "documentary" nature in a typed wrapper.

**Fix:** Drop the parameter:

```swift
public func cost(
    inputTokens: Int,
    cachedInputTokens: Int,
    outputTokens: Int,
    modelID: String?
) -> Decimal { ... }
```

…and update call sites (`CodexJSONLProvider.swift:248-254`) to drop the unused argument. If the parameter must remain for an upcoming schema split, mark it `@_disfavoredOverload` or wrap in a `// swiftlint:disable:next unused_parameter` so the no-op signal is local.

### IN-05: `codex-models.json` carries an inline `source` URL string that the decoder ignores — drift surface

**File:** `AgentsUsageBar/Resources/Pricing/codex-models.json:4`
**Issue:** The JSON file includes a top-level `"source"` field with a multi-sentence URL + caveat ("reviewer checkpoint deferred (page 403 at research time per RESEARCH §Embedded Pricing); draft values …"). `JSONDecoder` ignores it (Decodable ignores unknown keys), so the value is documentary-only. Two side effects:

1. The bundled JSON now declares "values are draft / unreviewed" in a place that the Swift type system never validates. A future audit script that lints the file for "draft" will catch it, but the runtime trusts the numbers as if they were reviewed.
2. The pricing struct's `lastUpdated` says `"2026-05-15"` but `source` admits the numbers are draft from RESEARCH §Embedded Pricing. The two metadata fields disagree on the data's authority.

**Fix:** Either (a) parse `source` into the struct so we can surface "draft pricing" warnings in the UI or in CI; or (b) delete the `source` field from the JSON until the values are reviewed.

## Structural Findings (fallow)

_No `<structural_findings>` block was provided by the workflow — narrative-only review._

---

## Summary Table

| # | Severity | File | Issue |
|---|---|---|---|
| CR-01 | Critical | `Providers/Codex/CodexModelPricing.swift:187-190` | Cost arithmetic in `Double` defeats `Decimal` precision claim |
| CR-02 | Critical | `Providers/Gemini/GeminiOAuthClient.swift:100-136` | Disk fast-path defeats `retryAfter401` lazy-refresh contract |
| WR-01 | Warning | `App/AppDependencies.swift:142-206` | `CODEX_BEARER_TOKEN` + `GEMINI_PROJECT_ID` env overrides parsed but never consumed |
| WR-02 | Warning | `Config/ConfigStore.swift:160-162` | `sessionWindowDays` field is a self-assigning no-op |
| WR-03 | Warning | `Config/ConfigStore.swift:154-181` | Empty-env-as-absent claim not locally enforced |
| WR-04 | Warning | `Providers/Codex/CodexRolloutScanner.swift:82-95` | `rolloutFiles()` may emit duplicates under symlink/DST corner cases |
| WR-05 | Warning | `Providers/Codex/CodexRolloutParser.swift:62-111` | Whole-file re-read every poll defeats offset-cache rationale |
| WR-06 | Warning | `Infrastructure/URLSessionHTTPClient.swift:79-121` | Caller-supplied `Content-Type` can silently overwrite form encoding |
| WR-07 | Warning | `Providers/Gemini/Models/GeminiOAuthError.swift:50-55` | `.transport == .transport` is always true — masks test misses |
| IN-01 | Info | `Providers/Gemini/GeminiOAuthClient.swift:71, 114` | `lastRefreshTokenSeen` is dead state holding plaintext credential |
| IN-02 | Info | `Providers/Gemini/GeminiSettingsGate.swift:40-43` | Unused `fileManager` parameter (also in CodexCredentialLoader) |
| IN-03 | Info | `Providers/Codex/CodexJSONLProvider.swift:300-306, 370-376` | Silent Decimal-parse failure on `credits.balance` |
| IN-04 | Info | `Providers/Codex/CodexModelPricing.swift:177-183` | `reasoningOutputTokens` parameter is a documented no-op — API smell |
| IN-05 | Info | `Resources/Pricing/codex-models.json:4` | `"source"` field declares draft status that the runtime ignores |

### Cross-cutting positives (no finding required)

- **SEC-01 (single reveal site):** Verified — `revealForRequest()` appears only inside `URLSessionHTTPClient.performGet` (line 230) and `performPostJSON` (line 181). Codex/Gemini code never calls it.
- **SEC-02 (no token literals in logs):** Verified — all `AppLogger.*` calls in Phase 3 use `privacy: .public` only on status codes / category labels / error descriptions; bearer values and refresh-token values never appear in log interpolations.
- **D-09 eager + lazy state machine:** Correctly implemented modulo CR-02.
- **D-10 in-memory-only refresh:** Test `successfulRefresh_doesNotWriteCredsFile` proves no file write on refresh.
- **D-07 quota-only exclusion:** `AggregateStore.rollupTotals()` correctly skips `hasTokensByID[id] == false` providers; the `hasAnyQuotaOnlyProvider` flag drives `TotalsHeaderView`'s footnote correctly.
- **D-11 degraded notification suppression:** `ThresholdEngine.decisions` filters degraded snapshots *before* band arithmetic; both Phase 1 back-compat and Phase 2 FSM overloads honour it.
- **D-10 keypath gate:** `GeminiSettingsGate.isOAuthPersonal` only accepts the nested `security.auth.selectedType` keypath — confirmed no flat-shape fallthrough.
- **Swift 6 strict concurrency:** `nonisolated(unsafe)` is used only for `ISO8601DateFormatter` static caches (Apple-documented thread-safe) and `FileManager.default` (singleton); each call site carries a justification comment.
- **Lenient decoding tests:** Every decoded response type uses `decodeIfPresent` and the test suites assert "extra keys do not throw."

---

_Reviewed: 2026-05-18T00:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
