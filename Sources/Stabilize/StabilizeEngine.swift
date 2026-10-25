import Darwin
import Foundation
import LightTableKit

/// Runs a batch of stabilise / grade jobs, one clip at a time.
///
/// Every Gyroflow and ffmpeg child goes through `SupervisedProcess`, so the engine always knows
/// whether a child is alive, can stop it with everything it spawned, and notices a child that is
/// alive but stuck. Results are written under temp names and only renamed after ffprobe confirms
/// the duration, so a final-looking file is always complete and a re-run can skip it.
public final class StabilizeEngine: @unchecked Sendable {
    public let settings: StabilizeSettings

    private let lock = NSLock()
    private var current: SupervisedProcess?
    private var currentStallTimeout: TimeInterval = 120
    private var stopRequested = false
    private var skipRequested = false
    private var isPaused = false
    private var resumeArrived = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?

    /// Extra bytes kept free beyond the estimate, so the disk never fills to the last byte.
    static let spaceMargin: Int64 = 200 << 20

    public init(settings: StabilizeSettings) {
        self.settings = settings
    }

    // MARK: Controls

    /// Stops the current child (SIGTERM, then SIGKILL), cleans its temp files and ends the batch.
    public func stop() {
        let (process, continuation): (SupervisedProcess?, CheckedContinuation<Void, Never>?) = lock.withLock {
            stopRequested = true
            let waiting = pauseContinuation
            pauseContinuation = nil
            isPaused = false
            return (current, waiting)
        }
        process?.stop()
        continuation?.resume()
    }

    /// 跳过这段: stops the current child and marks the clip skipped; the batch goes on.
    public func skipCurrent() {
        let process: SupervisedProcess? = lock.withLock {
            skipRequested = true
            return current
        }
        process?.stop()
    }

    /// 再等等: gives the quiet child another full stall period.
    public func waitLonger() {
        let (process, extra) = lock.withLock { (current, currentStallTimeout) }
        process?.extendStallDeadline(by: extra)
    }

    /// Continues after `.paused` (disk reconnected, space freed).
    public func resume() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            guard isPaused else { return nil }
            if let waiting = pauseContinuation {
                pauseContinuation = nil
                isPaused = false
                return waiting
            }
            resumeArrived = true
            return nil
        }
        continuation?.resume()
    }

    private var stopped: Bool { lock.withLock { stopRequested } }

    // MARK: Plan

    struct Plan {
        let job: StabilizeJob
        let output: URL
        /// Gyroflow runs: asked for and the clip has a gyro track.
        let stabilize: Bool
        let lut: URL?
        let skipReason: String?
        let bitrate: Double
        let expectedSeconds: Double
        let finalBytes: Int64
        let stagingBytes: Int64

        var name: String { job.source.url.deletingPathExtension().lastPathComponent }
        var partial: URL { StabilizeCommands.partialURL(for: output) }
        /// Hidden note of the settings that produced `output` / `staging`, so a final made with
        /// another LUT, crop or codec is redone instead of reported as already done.
        var recipeFile: URL { output.deletingLastPathComponent().appendingPathComponent(".\(output.lastPathComponent).recipe") }
        var stagingRecipeFile: URL { output.deletingLastPathComponent().appendingPathComponent(".\(output.lastPathComponent).staging-recipe") }

        func recipe(_ settings: StabilizeSettings) -> String {
            var parts = ["v1", "codec=\(settings.codec.rawValue)", "stabilize=\(stabilize)"]
            if stabilize { parts.append(stagingRecipe(settings)) }
            if let lut {
                let modified = (try? lut.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
                    .timeIntervalSince1970 ?? 0
                parts.append("lut=\(lut.standardizedFileURL.path)@\(Int(modified))")
            }
            return parts.joined(separator: ";")
        }

        func stagingRecipe(_ settings: StabilizeSettings) -> String {
            "zoom=\(settings.maxZoom.map { String($0) } ?? "-"),readout=\(settings.readoutTime.map { String($0) } ?? "-")"
        }
        var staging: URL { StabilizeCommands.stagingURL(for: output) }
    }

    func plans(for jobs: [StabilizeJob]) -> [Plan] {
        let outputs = StabilizeCommands.uniqueOutputs(for: jobs.map(\.source.relativePath),
                                                      outputRoot: settings.outputRoot, codec: settings.codec)
        return zip(jobs, outputs).map { job, output in
            let source = job.source
            let stabilize = job.stabilize && source.canStabilize
            var skip: String?
            if !stabilize && job.lut == nil {
                skip = job.stabilize
                    ? "这段视频没有陀螺仪数据，无法增稳，也没有选 LUT，所以没有处理。"
                    : "没有选增稳，也没有选 LUT，所以没有处理。"
            }
            let bitrate = settings.bitrateMbps
                ?? StabilizeCommands.defaultBitrate(width: source.width, height: source.height, frameRate: source.frameRate)
            let expected = StabilizeCommands.expectedSeconds(
                duration: source.duration, width: source.width, height: source.height, frameRate: source.frameRate,
                stabilize: stabilize, lut: job.lut != nil)
            let staging = stabilize && job.lut != nil
                ? StabilizeCommands.stagingBytes(duration: source.duration, width: source.width, height: source.height,
                                                 frameRate: source.frameRate)
                : 0
            return Plan(job: job, output: output, stabilize: stabilize, lut: job.lut, skipReason: skip, bitrate: bitrate,
                        expectedSeconds: expected,
                        finalBytes: StabilizeCommands.finalBytes(duration: source.duration, bitrateMbps: bitrate),
                        stagingBytes: staging)
        }
    }

    // MARK: Estimate

    /// Time and space for the whole batch, before it starts. Peak space is every final file plus
    /// the largest ProRes staging file, since only one clip is in flight.
    public func estimate(_ jobs: [StabilizeJob]) -> StabilizeEstimate {
        let work = plans(for: jobs).filter { $0.skipReason == nil }
        let finals = work.reduce(Int64(0)) { $0 + $1.finalBytes }
        return StabilizeEstimate(
            seconds: work.reduce(0) { $0 + $1.expectedSeconds },
            finalBytes: finals,
            peakBytes: finals + (work.map(\.stagingBytes).max() ?? 0),
            availableBytes: freeSpace(at: settings.outputRoot)
        )
    }

    // MARK: Run

    struct Context {
        let ffmpeg: URL?
        let ffprobe: URL?
        let exiftool: URL?
        let gyroflow: GyroflowStatus?
        let events: @Sendable (StabilizeEvent) -> Void
        let total: Int
        let sourceVolume: URL?
        let outputVolume: URL?
    }

    enum Outcome {
        case finished(ClipResult)
        /// Volume gone or space short: wait for `resume()` and try the clip again.
        case pause(String)
    }

    public func run(_ jobs: [StabilizeJob], events: @escaping @Sendable (StabilizeEvent) -> Void) async -> StabilizeSummary {
        // stopRequested is not reset: a stop() that lands before run() starts must still count.
        lock.withLock {
            skipRequested = false
            isPaused = false
            resumeArrived = false
        }
        let plans = plans(for: jobs)
        let needsGyroflow = plans.contains { $0.stabilize && $0.skipReason == nil }
        // `Gyroflow.check` blocks while `--version` runs; keep it off the cooperative pool.
        let gyroflowStatus: GyroflowStatus? = needsGyroflow ? await withCheckedContinuation { continuation in
            let override = settings.gyroflow
            let timeout = settings.timing.probeTimeout
            DispatchQueue.global().async {
                continuation.resume(returning: Gyroflow.check(override: override, timeout: timeout))
            }
        } : nil
        let context = Context(
            ffmpeg: settings.ffmpeg ?? Tools.find(.ffmpeg),
            ffprobe: settings.ffprobe ?? Tools.find(.ffprobe),
            exiftool: settings.exiftool ?? Tools.find(.exiftool),
            gyroflow: gyroflowStatus,
            events: events,
            total: plans.count,
            sourceVolume: Self.volume(of: settings.sourceRoot),
            outputVolume: Self.volume(of: settings.outputRoot)
        )
        var map = StabilizeMap(outputRoot: settings.outputRoot)
        var results: [ClipResult] = []

        for (index, plan) in plans.enumerated() {
            if stopped { break }
            lock.withLock { skipRequested = false }
            events(.clipStarted(index: index, total: plans.count, name: plan.name))
            events(.progress(overall: Double(index) / Double(max(plans.count, 1)), clip: 0, message: "\(index + 1)/\(plans.count)：\(plan.name)"))
            var result: ClipResult?
            while result == nil {
                switch await process(plan, index: index, context: context) {
                case .finished(let finished):
                    result = finished
                case .pause(let reason):
                    await pause(reason, events: events)
                    if stopped { result = ClipResult(job: plan.job, output: nil, status: .skipped("已停止")) }
                }
            }
            guard let result else { continue }
            results.append(result)
            map.record(result, stabilized: plan.stabilize)
            do { try map.write() } catch {
                // The map is a convenience; failing to write it must not fail the clip.
            }
            events(.clipFinished(result))
        }
        let wasStopped = stopped
        if !wasStopped {
            events(.progress(overall: 1, clip: nil, message: "完成"))
        }
        let mapFile = FileManager.default.fileExists(atPath: map.url.path) ? map.url : nil
        return StabilizeSummary(results: results, mapFile: mapFile, stopped: wasStopped)
    }

    private func pause(_ reason: String, events: @Sendable (StabilizeEvent) -> Void) async {
        lock.withLock { isPaused = true }
        events(.paused(reason: reason))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proceed: Bool = lock.withLock {
                if stopRequested || resumeArrived {
                    resumeArrived = false
                    isPaused = false
                    return true
                }
                pauseContinuation = continuation
                return false
            }
            if proceed { continuation.resume() }
        }
        if !stopped { events(.resumed) }
    }

    // MARK: One clip

    private func process(_ plan: Plan, index: Int, context: Context) async -> Outcome {
        let job = plan.job
        func finish(_ status: ClipStatus, output: URL? = nil, warnings: [String] = []) -> Outcome {
            var result = ClipResult(job: job, output: output, status: status)
            result.warnings = warnings
            return .finished(result)
        }
        if let reason = plan.skipReason { return finish(.skipped(reason)) }
        if let reason = missingVolume(context) { return .pause(reason) }
        guard FileManager.default.fileExists(atPath: job.source.url.path) else {
            return finish(.failed("原片不见了：\(job.source.relativePath)。可能被移动或删除，找回后可重试。"))
        }
        guard let ffprobe = context.ffprobe else {
            return finish(.failed("找不到 ffprobe，无法检查成片。请重新安装 LightTable。"))
        }

        // A validated final file from an earlier run.
        if FileManager.default.fileExists(atPath: plan.output.path),
           (try? String(contentsOf: plan.recipeFile, encoding: .utf8)) == plan.recipe(settings),
           await durationMatches(plan.output, source: job.source, ffprobe: ffprobe) {
            return finish(.alreadyDone, output: plan.output)
        }

        if plan.stabilize {
            guard case .ready? = context.gyroflow else {
                return finish(.failed(context.gyroflow?.problem ?? "Gyroflow 不可用。"))
            }
        }
        if plan.lut != nil {
            guard context.ffmpeg != nil else { return finish(.failed("找不到 ffmpeg，无法套用 LUT。请重新安装 LightTable。")) }
            if let lut = plan.lut, !FileManager.default.fileExists(atPath: lut.path) {
                return finish(.failed("LUT 文件不见了：\(lut.lastPathComponent)。请重新选择 LUT。"))
            }
        }

        // Reuse a complete staging file left by a run whose LUT pass failed or was stopped.
        var reuseStaging = false
        if plan.stabilize, plan.lut != nil, FileManager.default.fileExists(atPath: plan.staging.path) {
            reuseStaging = (try? String(contentsOf: plan.stagingRecipeFile, encoding: .utf8)) == plan.stagingRecipe(settings)
            if reuseStaging { reuseStaging = await durationMatches(plan.staging, source: job.source, ffprobe: ffprobe) }
            if !reuseStaging { try? FileManager.default.removeItem(at: plan.staging) }
        }

        // Space for this clip: final plus staging at peak.
        let needed = plan.finalBytes + (reuseStaging ? 0 : plan.stagingBytes) + Self.spaceMargin
        if let available = freeSpace(at: settings.outputRoot), available < needed {
            return .pause("输出位置空间不够：这段需要约 \(Self.format(needed))，只剩 \(Self.format(available))。请腾出空间后点「继续」。")
        }

        do {
            try FileManager.default.createDirectory(at: plan.output.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            if let reason = missingVolume(context) { return .pause(reason) }
            return finish(.failed("无法创建输出文件夹：\(error.localizedDescription)。请确认输出位置可写。"))
        }
        cleanTemps(plan, keepStaging: reuseStaging)

        let weights: (gyro: Double, lut: Double) = plan.stabilize && plan.lut != nil ? (0.75, 0.25) : (plan.stabilize ? (1, 0) : (0, 1))

        // 1. Gyroflow
        if plan.stabilize && !reuseStaging, case .ready(let gyroflow, _)? = context.gyroflow {
            let target = plan.lut != nil ? plan.staging : plan.partial
            if plan.lut != nil { try? plan.stagingRecipe(settings).write(to: plan.stagingRecipeFile, atomically: true, encoding: .utf8) }
            let preset = StabilizeCommands.presetValue(maxZoom: settings.maxZoom, readoutTime: settings.readoutTime)
            let arguments = StabilizeCommands.gyroflowArguments(
                source: job.source.url, target: target, staging: plan.lut != nil, codec: settings.codec,
                bitrateMbps: plan.bitrate, preset: preset)
            let child = await runChild(
                executable: gyroflow, arguments: arguments, watch: [target, StabilizeCommands.gyroflowTemp(for: target)],
                plan: plan, index: index, base: 0, weight: weights.gyro, verb: "增稳", context: context,
                parse: { StabilizeCommands.gyroflowProgress($0) })
            try? FileManager.default.removeItem(at: StabilizeCommands.gyroflowTemp(for: target))
            switch child {
            case .finished(let exit, let tail):
                // Gyroflow's exit code means nothing: it returns 0 on failure and logs [ERROR]
                // on success. Only a produced file with the right duration counts.
                let produced = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { $0 > 0 } ?? false
                let complete = produced ? await durationMatches(target, source: job.source, ffprobe: ffprobe) : false
                if !complete {
                    try? FileManager.default.removeItem(at: target)
                    if let reason = missingVolume(context) { return .pause(reason) }
                    let detail = Self.lastLines(tail)
                    return finish(.failed("Gyroflow 没有生成完整的文件（\(exit)）。可能是原片损坏或格式不支持，可以在 Gyroflow 里单独打开这段看看。" + (detail.isEmpty ? "" : "\n详情：\(detail)")))
                }
            case .other(let status):
                cleanTemps(plan, keepStaging: false)
                if case .failed = status, let reason = missingVolume(context) { return .pause(reason) }
                return finish(status)
            }
        }

        // 2. LUT pass
        if let lut = plan.lut, let ffmpeg = context.ffmpeg {
            let input = plan.stabilize ? plan.staging : job.source.url
            let probedInput: ProbedMedia
            let probedSource: ProbedMedia
            do {
                probedInput = try await ProbedMedia.probe(input, ffprobe: ffprobe)
                probedSource = input == job.source.url ? probedInput : try await ProbedMedia.probe(job.source.url, ffprobe: ffprobe)
            } catch {
                if let reason = missingVolume(context) { return .pause(reason) }
                return finish(.failed("读不出视频信息：\(error.localizedDescription)"))
            }
            let source = job.source
            let pass = StabilizeCommands.LUTPass(
                input: input, output: plan.partial, lut: lut, codec: settings.codec,
                tenBit: settings.codec == .hevc && probedSource.tenBit, bitrateMbps: plan.bitrate,
                inputTags: probedInput.tags,
                sourceTags: .init(range: source.colorRange, space: source.colorSpace,
                                  primaries: source.colorPrimaries, transfer: source.colorTransfer),
                height: probedInput.height > 0 ? probedInput.height : source.height,
                audioCodec: probedInput.audioCodec)
            let child = await runChild(
                executable: ffmpeg, arguments: StabilizeCommands.lutArguments(pass), watch: [plan.partial],
                plan: plan, index: index, base: weights.gyro, weight: weights.lut, verb: "调色", context: context,
                parse: { StabilizeCommands.ffmpegProgress($0, duration: source.duration) })
            let keptStaging = plan.stabilize ? "Gyroflow 的增稳结果已保留，重试时只重新调色。" : ""
            switch child {
            case .finished(let exit, let tail):
                // ffmpeg reports failure honestly and may leave a truncated file, so its exit
                // code counts.
                if exit != .exited(0) {
                    try? FileManager.default.removeItem(at: plan.partial)
                    if let reason = missingVolume(context) { return .pause(reason) }
                    let detail = Self.lastLines(tail)
                    return finish(.failed("套用 LUT 失败（\(exit)）。\(keptStaging)" + (detail.isEmpty ? "" : "\n详情：\(detail)")))
                }
            case .other(let status):
                try? FileManager.default.removeItem(at: plan.partial)
                if case .failed = status, let reason = missingVolume(context) { return .pause(reason) }
                return finish(status)
            }
        }

        // 3. Validate, then make it final.
        guard await durationMatches(plan.partial, source: job.source, ffprobe: ffprobe) else {
            try? FileManager.default.removeItem(at: plan.partial)
            if let reason = missingVolume(context) { return .pause(reason) }
            return finish(.failed("成片时长和原片对不上，已丢弃。可以重试这段。"))
        }
        do {
            if FileManager.default.fileExists(atPath: plan.output.path) {
                _ = try FileManager.default.replaceItemAt(plan.output, withItemAt: plan.partial)
            } else {
                try FileManager.default.moveItem(at: plan.partial, to: plan.output)
            }
        } catch {
            return finish(.failed("成片无法改成正式文件名：\(error.localizedDescription)"))
        }
        try? plan.recipe(settings).write(to: plan.recipeFile, atomically: true, encoding: .utf8)
        if plan.stabilize && plan.lut != nil {
            try? FileManager.default.removeItem(at: plan.staging)
            try? FileManager.default.removeItem(at: plan.stagingRecipeFile)
        }

        var warnings: [String] = []
        if let warning = await writeCreationDate(plan, exiftool: context.exiftool) { warnings.append(warning) }
        context.events(.progress(overall: Double(index + 1) / Double(max(context.total, 1)), clip: 1,
                                 message: "\(index + 1)/\(context.total)：\(plan.name) 完成"))
        return finish(.done, output: plan.output, warnings: warnings)
    }

    // MARK: Children

    enum ChildOutcome {
        /// Ended on its own; the caller decides from the exit and the produced file.
        case finished(SupervisedProcess.Exit, String)
        /// Skipped, stopped, stuck, timed out or unkillable: the clip ends with this status.
        case other(ClipStatus)
    }

    private func runChild(executable: URL, arguments: [String], watch: [URL], plan: Plan, index: Int,
                          base: Double, weight: Double, verb: String, context: Context,
                          parse: @escaping @Sendable (String) -> Double?) async -> ChildOutcome {
        let timing = settings.timing
        let stall = timing.stallTimeout ?? StabilizeCommands.stallTimeout(expectedSeconds: plan.expectedSeconds)
        let hard = timing.hardTimeout ?? StabilizeCommands.hardTimeout(expectedSeconds: plan.expectedSeconds)
        let quietAfter = timing.quietAfter ?? min(30, stall / 4)
        var options = SupervisedProcess.Options(stallTimeout: stall, hardTimeout: hard) {
            // Growth of the file being written is progress even when the child prints nothing.
            watch.reduce(Int64(0)) { total, url in
                total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        options.heartbeatInterval = timing.heartbeatInterval
        options.terminationGrace = timing.terminationGrace
        options.killGrace = timing.killGrace
        options.stdoutLimit = 64 << 10

        let process = SupervisedProcess(executable: executable, arguments: arguments, options: options)
        let events = context.events
        let total = Double(max(context.total, 1))
        let name = plan.name
        let label = "\(verb) \(index + 1)/\(context.total)：\(name)"
        process.onLine = { _, line in
            guard let fraction = parse(line) else { return }
            let clip = base + weight * fraction
            events(.progress(overall: (Double(index) + clip) / total, clip: clip, message: label))
        }
        process.onQuiet = { seconds in
            if seconds >= quietAfter { events(.quiet(name: name, seconds: seconds)) }
        }

        let alreadyStopping: Bool = lock.withLock {
            current = process
            currentStallTimeout = stall
            return stopRequested || skipRequested
        }
        defer { lock.withLock { current = nil } }
        if alreadyStopping { return .other(stopped ? .skipped("已停止") : .skipped("已按要求跳过这段。")) }
        do { try process.start() } catch {
            return .other(.failed("无法启动 \(executable.lastPathComponent)：\(error.localizedDescription)"))
        }
        let result = await process.wait()
        let (wasStopped, wasSkipped) = lock.withLock { (stopRequested, skipRequested) }
        switch result.ending {
        case .finished(let exit):
            if wasStopped { return .other(.skipped("已停止")) }
            if wasSkipped { return .other(.skipped("已按要求跳过这段。")) }
            return .finished(exit, result.stderrTail)
        case .stopped:
            return .other(.skipped(wasStopped ? "已停止" : "已按要求跳过这段。"))
        case .stalled:
            return .other(.skipped("\(executable.lastPathComponent) 超过 \(Int(stall)) 秒没有任何进展，判定卡住，已自动跳过。可以稍后单独重试这段。"))
        case .timedOut:
            return .other(.failed("\(executable.lastPathComponent) 运行超过 \(Int(hard / 60)) 分钟仍未完成，已结束。可以单独重试这段。"))
        case .unkillable(let pid):
            return .other(.failed("\(executable.lastPathComponent)（PID \(pid)）结束不掉。请在「活动监视器」中搜索这个 PID 并强制退出。"))
        }
    }

    // MARK: Helpers

    private func durationMatches(_ file: URL, source: ScannedVideo, ffprobe: URL) async -> Bool {
        guard let probed = try? await ProbedMedia.probe(file, ffprobe: ffprobe), let duration = probed.duration else { return false }
        return source.duration > 0 ? abs(duration - source.duration) <= 1 : duration > 0
    }

    /// Writes the zoned capture time onto the result. A failure is a warning: the video is fine,
    /// only its date in Photos may be off.
    private func writeCreationDate(_ plan: Plan, exiftool: URL?) async -> String? {
        guard let date = plan.job.source.creationDate, !date.isEmpty else { return nil }
        guard let exiftool else { return "找不到 exiftool，成片没有写回带时区的拍摄时间。" }
        let arguments = StabilizeCommands.creationDateArguments(date: date, file: plan.output)
        guard let result = try? await ToolRun.run(exiftool, arguments, timeout: 120), result.ending == .finished(.exited(0)) else {
            return "成片的拍摄时间没有写回（exiftool 失败），视频本身没问题。"
        }
        return nil
    }

    private func cleanTemps(_ plan: Plan, keepStaging: Bool) {
        var doomed = [plan.partial, StabilizeCommands.gyroflowTemp(for: plan.partial), StabilizeCommands.gyroflowTemp(for: plan.staging)]
        if !keepStaging { doomed.append(plan.staging) }
        for url in doomed { try? FileManager.default.removeItem(at: url) }
    }

    /// A pause reason when the source or output volume is no longer mounted.
    private func missingVolume(_ context: Context) -> String? {
        if let volume = context.sourceVolume, !FileManager.default.fileExists(atPath: volume.path) {
            return "原片所在的磁盘「\(volume.lastPathComponent)」不见了。请把它接回，然后点「继续」。"
        }
        if let volume = context.outputVolume, !FileManager.default.fileExists(atPath: volume.path) {
            return "输出位置所在的磁盘「\(volume.lastPathComponent)」不见了。请把它接回，然后点「继续」。"
        }
        return nil
    }

    static func volume(of url: URL) -> URL? {
        guard let existing = nearestExisting(url) else { return nil }
        return (try? existing.resourceValues(forKeys: [.volumeURLKey]))?.volume
    }

    static func nearestExisting(_ url: URL) -> URL? {
        var candidate = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { return nil }
            candidate = parent
        }
        return candidate
    }

    func freeSpace(at url: URL) -> Int64? {
        if let probe = settings.freeSpaceProbe { return probe(url) }
        guard let existing = Self.nearestExisting(url),
              let values = try? existing.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values.volumeAvailableCapacity.map(Int64.init)
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func lastLines(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n")
    }
}
