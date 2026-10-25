import Darwin
import Foundation

/// A child process LightTable owns from start to finish.
///
/// The old batch-gyroflow GUI wrote a script and ran it in Terminal, so the page never knew when
/// Gyroflow had died and could not stop it. Here:
/// - running/finished comes only from `waitpid`, never from output or guesswork;
/// - the child gets its own process group, so stopping it also stops anything it spawned;
/// - a heartbeat (new output or a growing file) detects a child that is alive but doing nothing;
/// - `stop()` always resolves: SIGTERM, then SIGKILL after a grace period, then a final verdict
///   naming the PID if even SIGKILL did not take.
public final class SupervisedProcess: @unchecked Sendable {
    public enum Exit: Equatable, Sendable, CustomStringConvertible {
        case exited(Int32)
        case signaled(Int32)

        public var description: String {
            switch self {
            case .exited(let code): "退出码 \(code)"
            case .signaled(let signal): "被信号 \(signal) 结束"
            }
        }
    }

    /// Why the process ended, from LightTable's point of view.
    public enum Ending: Equatable, Sendable {
        case finished(Exit)
        /// No output and no progress for `stallTimeout`; LightTable killed it.
        case stalled(Exit?)
        /// Ran past `hardTimeout`; LightTable killed it.
        case timedOut(Exit?)
        /// `stop()` was called.
        case stopped(Exit?)
        /// SIGKILL sent but the process is still there; the PID is reported to the user.
        case unkillable(pid: Int32)
    }

    public struct Result: Sendable {
        public let ending: Ending
        public let stdout: String
        public let stderrTail: String

        /// The exit status when the process ended on its own or was killed and reaped.
        public var exit: Exit? {
            switch ending {
            case .finished(let exit): exit
            case .stalled(let exit), .timedOut(let exit), .stopped(let exit): exit
            case .unkillable: nil
            }
        }
    }

    public enum Stream: Sendable { case stdout, stderr }

    public struct Options: Sendable {
        /// Kill the process after this long without output or probe progress. nil: never.
        public var stallTimeout: TimeInterval?
        /// Kill the process after this long in total. nil: never.
        public var hardTimeout: TimeInterval?
        /// Returns a number that grows while the child makes progress, e.g. the size of the file
        /// it is writing. Checked every `heartbeatInterval`.
        public var progressProbe: (@Sendable () -> Int64?)?
        public var heartbeatInterval: TimeInterval = 1
        /// Time between SIGTERM and SIGKILL.
        public var terminationGrace: TimeInterval = 5
        /// Time to wait for the process to disappear after SIGKILL before calling it unkillable.
        public var killGrace: TimeInterval = 3
        /// Keep at most this many bytes of stdout; stderr keeps only a short tail.
        public var stdoutLimit: Int = 4 << 20
        public var workingDirectory: URL?
        public var environment: [String: String]?

        public init(stallTimeout: TimeInterval? = nil, hardTimeout: TimeInterval? = nil,
                    progressProbe: (@Sendable () -> Int64?)? = nil) {
            self.stallTimeout = stallTimeout
            self.hardTimeout = hardTimeout
            self.progressProbe = progressProbe
        }
    }

    public let executable: URL
    public let arguments: [String]
    public let options: Options

    /// Each output line as it arrives.
    public var onLine: (@Sendable (Stream, String) -> Void)?
    /// Called once per heartbeat while the process has made no progress for a while, with the
    /// number of seconds since the last progress. The UI uses it to show "seems stuck".
    public var onQuiet: (@Sendable (TimeInterval) -> Void)?

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var started = false
    private var reaped: Exit?
    private var requestedEnding: Ending?
    private var stdoutData = Data()
    private var stderrTailData = Data()
    private var lastActivity = Date()
    private var lastProbe: Int64?
    private var stallDeadlineExtension: TimeInterval = 0
    private var continuation: CheckedContinuation<Result, Never>?
    private var finalResult: Result?
    private let exitSignal = DispatchSemaphore(value: 0)
    private var readersDone = DispatchGroup()

    public init(executable: URL, arguments: [String], options: Options = Options()) {
        self.executable = executable
        self.arguments = arguments
        self.options = options
    }

    public var processID: Int32 { lock.withLock { pid } }

    // MARK: Start

    public func start() throws {
        try lock.withLock {
            precondition(!started, "SupervisedProcess can only start once")
            started = true
            lastActivity = Date()
        }

        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else { throw posixError("pipe") }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        if let directory = options.workingDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own process group (pgid = child pid), and close every other inherited descriptor.
        // Reset signal handling too: ignored signals and the signal mask survive exec, and a parent
        // that ignores SIGTERM would otherwise hand that on, leaving only SIGKILL to stop the child.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        sigdelset(&defaultSignals, SIGKILL)
        sigdelset(&defaultSignals, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attributes, &emptyMask)

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let environment = (options.environment ?? ProcessInfo.processInfo.environment)
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { environment.forEach { free($0) } }

        var child: pid_t = 0
        let status = posix_spawn(&child, executable.path, &actions, &attributes, argv, environment)
        close(outPipe[1])
        close(errPipe[1])
        guard status == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            throw ToolError.failed(executable.lastPathComponent, "无法启动", String(cString: strerror(status)))
        }
        lock.withLock { pid = child }
        ProcessRegistry.shared.register(pid: child, executable: executable)

        read(outPipe[0], stream: .stdout)
        read(errPipe[0], stream: .stderr)
        Thread.detachNewThread { [self] in waitForExit(child) }
        Thread.detachNewThread { [self] in heartbeat() }
    }

    // MARK: Waiting

    /// Waits until the process is gone (or declared unkillable) and returns how it ended.
    public func wait() async -> Result {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let finalResult {
                lock.unlock()
                continuation.resume(returning: finalResult)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    /// Blocking convenience for short probes.
    public static func runToCompletion(executable: URL, arguments: [String], timeout: TimeInterval) throws -> Result {
        let process = SupervisedProcess(executable: executable, arguments: arguments,
                                        options: Options(hardTimeout: timeout))
        try process.start()
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task.detached {
            box.value = await process.wait()
            done.signal()
        }
        done.wait()
        return box.value!
    }

    // MARK: Stop

    /// Stops the process and everything in its group. Safe to call at any time, any number of
    /// times; `wait()` resolves within `terminationGrace + killGrace` seconds no matter what.
    public func stop() {
        terminate(as: .stopped(nil))
    }

    /// Gives a quiet process more time before the stall timeout kills it ("再等等").
    public func extendStallDeadline(by seconds: TimeInterval) {
        lock.withLock {
            stallDeadlineExtension += seconds
            lastActivity = Date()
        }
    }

    private func terminate(as ending: Ending) {
        let target: pid_t = lock.withLock {
            guard started, finalResult == nil, reaped == nil, requestedEnding == nil else { return 0 }
            requestedEnding = ending
            return pid
        }
        guard target > 0 else { return }
        Thread.detachNewThread { [self] in
            signalGroup(target, SIGTERM)
            if exitSignal.wait(timeout: .now() + options.terminationGrace) == .success { return }
            signalGroup(target, SIGKILL)
            if exitSignal.wait(timeout: .now() + options.killGrace) == .success { return }
            finish(ending: .unkillable(pid: target))
        }
    }

    private func signalGroup(_ target: pid_t, _ signal: Int32) {
        // The child is its own group leader; -pid reaches it and its descendants.
        if kill(-target, signal) != 0 { kill(target, signal) }
    }

    // MARK: Internals

    private func waitForExit(_ child: pid_t) {
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(child, &status, 0) } while result == -1 && errno == EINTR
        let exit: Exit = if result == -1 {
            .exited(-1)
        } else if (status & 0x7f) == 0 {
            .exited((status >> 8) & 0xff)
        } else {
            .signaled(status & 0x7f)
        }
        lock.withLock { reaped = exit }
        // The child may have spawned a grandchild that keeps the pipes open; a missing EOF must
        // not keep the process looking alive.
        _ = readersDone.wait(timeout: .now() + 0.5)
        exitSignal.signal()
        exitSignal.signal()
        let ending: Ending = lock.withLock {
            switch requestedEnding {
            case .stalled?: .stalled(exit)
            case .timedOut?: .timedOut(exit)
            case .stopped?: .stopped(exit)
            default: .finished(exit)
            }
        }
        finish(ending: ending)
    }

    private func finish(ending: Ending) {
        lock.lock()
        guard finalResult == nil else { lock.unlock(); return }
        let result = Result(
            ending: ending,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderrTail: String(decoding: stderrTailData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        finalResult = result
        let waiting = continuation
        continuation = nil
        let finishedPID = pid
        lock.unlock()
        if case .unkillable = ending {} else { ProcessRegistry.shared.unregister(pid: finishedPID) }
        waiting?.resume(returning: result)
    }

    private func heartbeat() {
        let start = Date()
        while true {
            Thread.sleep(forTimeInterval: options.heartbeatInterval)
            let (done, quietFor, extensionSeconds): (Bool, TimeInterval, TimeInterval) = lock.withLock {
                if finalResult != nil || reaped != nil || requestedEnding != nil { return (true, 0, 0) }
                if let probe = options.progressProbe, let value = probe(), value != lastProbe {
                    lastProbe = value
                    lastActivity = Date()
                }
                return (false, Date().timeIntervalSince(lastActivity), stallDeadlineExtension)
            }
            if done { return }
            if let hard = options.hardTimeout, Date().timeIntervalSince(start) > hard + extensionSeconds {
                terminate(as: .timedOut(nil))
                return
            }
            if quietFor >= max(2, options.heartbeatInterval * 2) { onQuiet?(quietFor) }
            if let stall = options.stallTimeout, quietFor > stall {
                terminate(as: .stalled(nil))
                return
            }
        }
    }

    private func read(_ descriptor: Int32, stream: Stream) {
        readersDone.enter()
        Thread.detachNewThread { [self] in
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var pending = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.withLock {
                    lastActivity = Date()
                    switch stream {
                    case .stdout:
                        if stdoutData.count < options.stdoutLimit { stdoutData.append(chunk) }
                    case .stderr:
                        stderrTailData.append(chunk)
                        if stderrTailData.count > 4096 { stderrTailData = stderrTailData.suffix(4096) }
                    }
                }
                guard let onLine else { continue }
                pending.append(chunk)
                // Gyroflow and ffmpeg end progress lines with \r.
                while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let line = String(decoding: pending[pending.startIndex..<index], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...index)
                    if !line.isEmpty { onLine(stream, line) }
                }
            }
            if let onLine, !pending.isEmpty { onLine(stream, String(decoding: pending, as: UTF8.self)) }
            readersDone.leave()
        }
    }

    private func posixError(_ call: String) -> Error {
        ToolError.failed(call, "errno \(errno)", String(cString: strerror(errno)))
    }
}

private final class ResultBox: @unchecked Sendable {
    var value: SupervisedProcess.Result?
}
