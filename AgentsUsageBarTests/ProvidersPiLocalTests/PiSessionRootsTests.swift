import Foundation
import Testing
@testable import AgentsUsageBar

@Suite("PiSessionRootsTests")
struct PiSessionRootsTests {

    @Test func env_override_unions_with_default_and_dedupes_symlink() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pi-roots-\(UUID().uuidString)", isDirectory: true)
        let agent = root.appendingPathComponent(".pi/agent", isDirectory: true)
        let sessions = agent.appendingPathComponent("sessions", isDirectory: true)
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("pi-agent-link", isDirectory: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: agent)
        defer { try? fm.removeItem(at: root) }

        let dirs = PiSessionRoots.sessionDirectories(
            environment: ["PI_CODING_AGENT_DIR": link.path],
            home: root.path
        )
        #expect(dirs.count == 1)
        #expect(dirs[0].resolvingSymlinksInPath().standardizedFileURL.path == sessions.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    @Test func empty_env_uses_home_dot_pi() {
        let home = "/tmp/pi-home-fake-\(UUID().uuidString)"
        let dir = PiSessionRoots.agentDirectory(environment: [:], home: home)
        #expect(dir.path.hasSuffix("/.pi/agent"))
        #expect(dir.path.hasPrefix(home))
    }
}
