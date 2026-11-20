import Foundation
import Darwin

struct AntigravityCLI: Sendable {
    let executable: URL
    let home: URL
    var timeout: TimeInterval = 12

    static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Self? {
        let home = environment["HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? fileManager.homeDirectoryForCurrentUser
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let directories = path + [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
        for directory in directories where directory.hasPrefix("/") {
            let executable = URL(fileURLWithPath: directory).appendingPathComponent("agy")
            if fileManager.isExecutableFile(atPath: executable.path) {
                return Self(executable: executable, home: home)
            }
        }
        return nil
    }

    var hasLogin: Bool {
        let login = home.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
        return (try? login.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    func usage() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try runUsage() })
            }
        }
    }

    private func runUsage() throws -> Data {
        let unavailable = ProviderError(kind: .unknown, message: "Could not run agy /usage")
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let output = directory.appendingPathComponent("usage.json")
        guard files.createFile(atPath: output.path, contents: nil) else { throw unavailable }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--print", "/usage", "--output-format", "json", "--print-timeout", "8s"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardOutput = handle
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw unavailable
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw ProviderError(kind: .network, message: "agy /usage timed out")
        }
        guard process.terminationStatus == 0 else { throw unavailable }
        return try Data(contentsOf: output)
    }
}

actor AntigravityProvider: UsageProvider {
    nonisolated let id: ProviderID = .antigravity
    nonisolated let displayName = "Antigravity"
    nonisolated let capabilities = ProviderCapabilities(hasQuota: true, hasCost: false, hasTokens: false, isLocal: false)

    private let cli: AntigravityCLI
    private var lastStatus: ProviderStatus = .error(.notYetFetched)

    init(cli: AntigravityCLI) {
        self.cli = cli
    }

    func status() -> ProviderStatus { lastStatus }

    func fetch(now: Date) async throws -> UsageSnapshot {
        guard cli.hasLogin else {
            lastStatus = .unauthenticated
            return UsageSnapshot(providerID: id, asOf: now, tokensToday: nil, costTodayUSD: nil,
                                 balanceUSD: nil, quota: nil, raw: ["providerStatus": "unauthenticated"])
        }
        do {
            let windows = try AntigravityUsage.windows(from: await cli.usage())
            var snapshot = UsageSnapshot(
                providerID: id, asOf: now, tokensToday: nil, costTodayUSD: nil, balanceUSD: nil,
                quota: windows.compactMap(\.asQuota).max { $0.used < $1.used }, raw: [:], quotaWindows: windows
            )
            snapshot.accountInfo = AccountInfo(billingModel: .subscription)
            lastStatus = .ok(lastSuccess: now)
            return snapshot
        } catch {
            let failure = ProviderError.from(error)
            lastStatus = .error(failure)
            throw failure
        }
    }
}

private struct AntigravityUsage: Decodable {
    struct Command: Decodable {
        struct Payload: Decodable {
            struct Group: Decodable {
                struct Bucket: Decodable {
                    let name: String
                    let window: String
                    let remainingFraction: Double?
                    let resetTime: String?
                }
                let name: String
                let buckets: [Bucket]
            }
            let groups: [Group]
        }
        let name: String
        let data: Payload
    }
    let status: String
    let command: Command

    static func windows(from data: Data) throws -> [QuotaWindow] {
        let invalid = ProviderError(kind: .decode, message: "Invalid quota from agy /usage")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? decoder.decode(Self.self, from: data),
              response.status == "SUCCESS", response.command.name == "usage" else { throw invalid }
        let date = ISO8601DateFormatter()
        let fractionalDate = ISO8601DateFormatter()
        fractionalDate.formatOptions.insert(.withFractionalSeconds)
        var names: Set<String> = []
        var windows: [QuotaWindow] = []
        for group in response.command.data.groups {
            for bucket in group.buckets {
                guard let remaining = bucket.remainingFraction, (0...1).contains(remaining) else { continue }
                let (label, duration): (String, TimeInterval?) = switch bucket.window {
                case "5h": ("5h", 18_000)
                case "weekly": ("7d", 604_800)
                default: (bucket.name, nil)
                }
                let name = "\(group.name) \(label)"
                guard !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      names.insert(name).inserted else { throw invalid }
                let reset = bucket.resetTime.flatMap { date.date(from: $0) ?? fractionalDate.date(from: $0) }
                windows.append(QuotaWindow(name: name, utilization: 1 - remaining, resetsAt: reset, duration: duration))
            }
        }
        guard !windows.isEmpty else { throw invalid }
        return windows
    }
}
