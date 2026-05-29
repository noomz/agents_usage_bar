import Foundation
import os.log

// Hand-rolled minimal TOML reader per CONTEXT.md D-16.
// Intentionally INCOMPLETE vs full TOML 1.0 — supports scalars + sections + comments only.
// Fail-soft per D-18: bad lines log and skip, never throw.

// MARK: - TomlValue

/// A scalar value parsed from a TOML file (D-16 subset).
///
/// Supported types: string (double-quoted), integer, double, boolean.
/// Arrays, inline tables, multi-line strings are explicitly NOT supported (D-16 scope).
public enum TomlValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

// MARK: - TomlReader

/// Hand-rolled minimal TOML parser (D-16, ~100 LOC).
///
/// Supported TOML subset:
/// - Bare key = scalar value pairs (`key = "value"`, `key = 42`, `key = 3.14`, `key = true`)
/// - Section headers: `[section]` (one nesting level only)
/// - Line comments: `# ...` (bare-line and trailing)
/// - Double-quoted strings (no escape processing per D-16)
/// - Integers (`Int(_:)`)
/// - Doubles (`Double(_:)`)
/// - Booleans (literal `true` / `false`)
///
/// NOT supported (silently skip per D-16):
/// - Arrays: `models = ["a", "b"]`
/// - Inline tables: `quota = { limit = 10 }`
/// - Tables-of-tables: `[[providers]]`
/// - Multi-line strings: `"""..."""`
/// - Escape sequences in strings: `\n`, `\t`, `\"`
public enum TomlReader {

    /// Parses a TOML string and returns a nested map of section → key → value.
    ///
    /// - Parameters:
    ///   - text: The raw TOML file contents.
    ///   - logger: Optional `os.Logger` for warning messages on invalid lines (D-18 fail-soft).
    /// - Returns: `[sectionName: [key: TomlValue]]`. The empty string key `""` holds top-level
    ///   (before any `[section]` header) key-value pairs. The map always contains at least
    ///   `["": [:]]` — never nil, never throws.
    ///
    /// Fail-soft per D-18: invalid lines are logged (if logger provided) and skipped; the
    /// surrounding valid lines are still extracted and returned.
    public static func parse(
        _ text: String,
        logger: Logger? = nil
    ) -> [String: [String: TomlValue]] {
        var result: [String: [String: TomlValue]] = ["": [:]]
        var currentSection = ""

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (lineNo, rawLine) in lines.enumerated() {
            let stripped = stripComment(String(rawLine))
            let line = stripped.trimmingCharacters(in: .whitespaces)

            // Skip blank lines (empty or whitespace-only after comment strip)
            if line.isEmpty { continue }

            // Section header: [sectionName]
            if line.hasPrefix("[") && line.hasSuffix("]") && !line.hasPrefix("[[") {
                let sectionName = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                // Guard against empty section name
                if sectionName.isEmpty {
                    logger?.warning("toml line \(lineNo + 1, privacy: .public) invalid: \(line, privacy: .public)")
                    continue
                }
                currentSection = sectionName
                result[currentSection, default: [:]] = [:]
                continue
            }

            // Key = value pair
            guard let eqIndex = line.firstIndex(of: "=") else {
                logger?.warning("toml line \(lineNo + 1, privacy: .public) invalid: \(line, privacy: .public)")
                continue
            }

            let key = line[line.startIndex..<eqIndex]
                .trimmingCharacters(in: .whitespaces)
            let valueText = line[line.index(after: eqIndex)...]
                .trimmingCharacters(in: .whitespaces)

            guard !key.isEmpty else {
                logger?.warning("toml line \(lineNo + 1, privacy: .public) invalid: \(line, privacy: .public)")
                continue
            }

            guard let parsedValue = parseScalar(valueText) else {
                logger?.warning("toml line \(lineNo + 1, privacy: .public) invalid: \(line, privacy: .public)")
                continue
            }

            result[currentSection, default: [:]][key] = parsedValue
        }

        return result
    }

    // MARK: - Private helpers

    /// Strips the trailing comment from a TOML line, respecting quoted strings.
    ///
    /// Walks character-by-character tracking whether we are inside a `"..."` double-quoted
    /// string (no escape processing per D-16). Returns the slice of the line before the
    /// first unquoted `#`.
    private static func stripComment(_ line: String) -> String {
        var inString = false
        var idx = line.startIndex

        while idx < line.endIndex {
            let ch = line[idx]
            if ch == "\"" {
                inString.toggle()
            } else if ch == "#" && !inString {
                return String(line[line.startIndex..<idx])
            }
            idx = line.index(after: idx)
        }

        return line
    }

    /// Parses a trimmed TOML scalar value text into a `TomlValue`.
    ///
    /// Supported formats (D-16):
    /// - `"..."` → `.string(unquoted content)` (no escape processing)
    /// - `true` / `false` → `.bool(...)`
    /// - An integer-parseable string → `.int(...)`
    /// - A double-parseable string → `.double(...)`
    ///
    /// Returns `nil` for anything else (arrays `[...]`, inline tables `{...}`,
    /// unquoted bare words that are not bool/int/double, etc.).
    private static func parseScalar(_ text: String) -> TomlValue? {
        // Double-quoted string
        if text.hasPrefix("\"") && text.hasSuffix("\"") && text.count >= 2 {
            let inner = String(text.dropFirst().dropLast())
            return .string(inner)
        }

        // Boolean literals (must check before Int/Double to avoid "true" being Int-parsed)
        if text == "true" { return .bool(true) }
        if text == "false" { return .bool(false) }

        // Reject array/table syntax explicitly (D-16 scope)
        if text.hasPrefix("[") || text.hasPrefix("{") { return nil }

        // Integer (attempt before Double to prefer .int for whole numbers)
        if let intVal = Int(text) { return .int(intVal) }

        // Double
        if let dblVal = Double(text) { return .double(dblVal) }

        // Unrecognised scalar — fail-soft per D-18
        return nil
    }
}
