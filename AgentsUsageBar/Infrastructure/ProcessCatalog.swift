import Foundation
import Darwin

/// A running OS process with enough identity to classify local LLM engines.
public struct RunningProcess: Sendable, Equatable {
    public let pid: Int32
    public let executablePath: String
    public let arguments: [String]

    public init(pid: Int32, executablePath: String, arguments: [String]) {
        self.pid = pid
        self.executablePath = executablePath
        self.arguments = arguments
    }
}

/// Snapshot of user processes. Injected so tests never depend on the host `ps`.
public protocol ProcessCatalog: Sendable {
    func processes() -> [RunningProcess]
}

/// Fixed list for tests and for callers that already enumerated processes.
public struct StaticProcessCatalog: ProcessCatalog {
    private let snapshot: [RunningProcess]

    public init(_ snapshot: [RunningProcess] = []) {
        self.snapshot = snapshot
    }

    public func processes() -> [RunningProcess] {
        snapshot
    }
}

/// Live catalog via `proc_listallpids` + `KERN_PROCARGS2`.
public struct ProcProcessCatalog: ProcessCatalog {
    public init() {}

    public func processes() -> [RunningProcess] {
        let byteCount = proc_listallpids(nil, 0)
        guard byteCount > 0 else { return [] }
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: max(capacity, 1))
        let filledBytes = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return 0 }
            return proc_listallpids(base, Int32(buf.count * MemoryLayout<pid_t>.size))
        }
        guard filledBytes > 0 else { return [] }
        let filled = Int(filledBytes) / MemoryLayout<pid_t>.size
        return pids.prefix(filled).compactMap { pid -> RunningProcess? in
            guard pid > 0 else { return nil }
            var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let n = proc_pidpath(pid, &pathBuf, UInt32(MAXPATHLEN))
            guard n > 0 else { return nil }
            let path = String(cString: pathBuf)
            return RunningProcess(
                pid: pid,
                executablePath: path,
                arguments: Self.arguments(for: pid)
            )
        }
    }

    /// argv for `pid` from `KERN_PROCARGS2`. Empty on permission miss.
    static func arguments(for pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            var sz = size
            return sysctl(&mib, 3, raw.baseAddress, &sz, nil, 0) == 0
        }
        guard ok else { return [] }
        let argc = buffer.prefix(4).withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0 else { return [] }
        var offset = 4
        while offset < buffer.count, buffer[offset] != 0 { offset += 1 }
        offset += 1
        while offset < buffer.count, buffer[offset] == 0 { offset += 1 }
        var args: [String] = []
        args.reserveCapacity(Int(argc))
        for _ in 0..<argc {
            guard offset < buffer.count else { break }
            let start = offset
            while offset < buffer.count, buffer[offset] != 0 { offset += 1 }
            if start < offset {
                args.append(String(decoding: buffer[start..<offset], as: UTF8.self))
            }
            offset += 1
        }
        return args
    }
}
