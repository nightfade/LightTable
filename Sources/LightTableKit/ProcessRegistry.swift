import Darwin
import Foundation

/// Records every child LightTable starts, so that after a crash or force quit the next launch can
/// find Gyroflow or ffmpeg processes still running and offer to end them.
public final class ProcessRegistry: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let pid: Int32
        public let executable: String
        public let startedAt: Date
    }

    public static let shared = ProcessRegistry(file: AppPaths.applicationSupport?
        .appendingPathComponent("running-processes.json"))

    private let file: URL?
    private let lock = NSLock()

    public init(file: URL?) {
        self.file = file
    }

    func register(pid: Int32, executable: URL) {
        update { $0.append(Entry(pid: pid, executable: executable.path, startedAt: Date())) }
    }

    func unregister(pid: Int32) {
        update { $0.removeAll { $0.pid == pid } }
    }

    /// Entries from earlier runs whose process is still alive and still the same program.
    /// Entries for processes that are gone are dropped from the file.
    public func leftovers(excludingCurrentRun current: Set<Int32> = []) -> [Entry] {
        var alive: [Entry] = []
        update { entries in
            entries = entries.filter { entry in
                guard Self.isRunning(entry) else { return false }
                if !current.contains(entry.pid) { alive.append(entry) }
                return true
            }
        }
        return alive
    }

    /// Ends a leftover process group: SIGTERM, then SIGKILL after two seconds.
    /// Returns false if it is still running afterwards.
    @discardableResult
    public func terminate(_ entry: Entry) -> Bool {
        guard Self.isRunning(entry) else { unregister(pid: entry.pid); return true }
        if kill(-entry.pid, SIGTERM) != 0 { kill(entry.pid, SIGTERM) }
        for _ in 0..<20 where Self.isRunning(entry) { usleep(100_000) }
        if Self.isRunning(entry) {
            if kill(-entry.pid, SIGKILL) != 0 { kill(entry.pid, SIGKILL) }
            for _ in 0..<20 where Self.isRunning(entry) { usleep(100_000) }
        }
        let gone = !Self.isRunning(entry)
        if gone { unregister(pid: entry.pid) }
        return gone
    }

    /// Alive and running the recorded executable, so a reused PID is never mistaken for ours.
    static func isRunning(_ entry: Entry) -> Bool {
        guard kill(entry.pid, 0) == 0 || errno == EPERM else { return false }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(entry.pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let path = String(cString: buffer)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: entry.executable).resolvingSymlinksInPath().path
    }

    private func update(_ change: (inout [Entry]) -> Void) {
        guard let file else { return }
        lock.lock()
        defer { lock.unlock() }
        var entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))) ?? []
        change(&entries)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }
}
