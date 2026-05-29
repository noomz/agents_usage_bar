import os.log

/// Factory for `os.Logger` instances scoped to this app's subsystem.
///
/// SEC-02: All logging in the app must go through `AppLogger.logger(category:)` to ensure
/// consistent subsystem tagging and filterable Console.app output.
///
/// Canonical categories (one per major subsystem):
/// - `"openrouter"` — OpenRouter provider fetch and decode
/// - `"poll"`       — polling scheduler lifecycle
/// - `"store"`      — AggregateStore state mutations
/// - `"notify"`     — notification scheduling and deduplication
/// - `"config"`     — config.toml read and validation
/// - `"cache"`      — FileCacheStore read/write
/// - `"http"`       — URLSessionHTTPClient request/response (path + status only — SEC-02)
public enum AppLogger {

    /// The shared subsystem identifier — matches the app bundle ID.
    public static let subsystem = "app.agents-usage-bar"

    /// Returns a `Logger` for the given category under the app subsystem.
    ///
    /// Filtering in Console.app: Subsystem = "app.agents-usage-bar", Category = <category>.
    public static func logger(category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
