import AppKit
import Habits
import LightTableKit
import Stabilize
import SwiftUI
import TravelCutCore

/// What LightTable can do with a folder, in the order the pipeline runs them.
/// Habits must run before photo grouping, which writes theme keywords habits would read.
enum TaskKind: String, CaseIterable, Identifiable {
    case stabilize, highlights, habits, photos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stabilize: "增稳调色"
        case .highlights: "挑视频高光"
        case .habits: "看拍摄习惯"
        case .photos: "照片分组"
        }
    }

    var systemImage: String {
        switch self {
        case .stabilize: "camera.metering.center.weighted"
        case .highlights: "sparkles.rectangle.stack"
        case .habits: "chart.bar.xaxis"
        case .photos: "square.stack.3d.up"
        }
    }

    var summary: String {
        switch self {
        case .stabilize: "用相机记录的陀螺仪数据让画面更稳，并给灰片套上色调"
        case .highlights: "挑出值得保留的片段，按天分好文件夹，直接拖进剪映"
        case .habits: "统计常用的焦段、光圈、拍摄时间，生成一页报告"
        case .photos: "把连拍和相似照片分组、写上地点和主题，在 Bridge 里一组一组看"
        }
    }
}

enum LUTChoice: Equatable {
    /// Must be decided before starting (log footage).
    case undecided
    case none
    case lut(URL)

    var url: URL? {
        if case .lut(let url) = self { return url }
        return nil
    }
}

struct ProfileGroup: Identifiable {
    var id: ColorProfile { profile }
    let profile: ColorProfile
    let videos: [ScannedVideo]
    var choice: LUTChoice
    /// Camera models in this group, for the 未识别 row where the user assigns a profile.
    var models: [String] { Array(Set(videos.map { $0.cameraModel ?? "未知相机" })).sorted() }
}

struct TaskReport: Identifiable {
    enum Status { case success, partial, failed, skipped, stopped }
    var id: TaskKind { kind }
    let kind: TaskKind
    let status: Status
    let lines: [String]
    var openURL: URL?
    var openLabel: String?
}

@MainActor
final class AppModel: ObservableObject {
    enum Stage: Equatable {
        case home
        case scanning
        case plan
        case running
        case finished
    }

    @Published var stage: Stage = .home
    @Published var folder: URL?
    @Published var scan: ScanResult?
    @Published var scanProgress: (done: Int, total: Int) = (0, 0)
    @Published var errorMessage: String?

    // Plan
    @Published var selected: Set<TaskKind> = []
    @Published var stabilizeOn = true
    @Published var gradeOn = true
    @Published var groups: [ProfileGroup] = []
    @Published var themes: Set<HighlightTheme> = Preferences.themes {
        didSet { Preferences.themes = themes }
    }
    @Published var maxZoom: Double? = Preferences.double("maxZoom") {
        didSet { Preferences.setDouble(maxZoom, "maxZoom") }
    }
    @Published var readoutTime: Double? = Preferences.double("readoutTime") {
        didSet { Preferences.setDouble(readoutTime, "readoutTime") }
    }
    @Published var photoUseQwen = false
    @Published var photoWriteStars = Preferences.bool("photoWriteStars") {
        didSet { Preferences.setBool(photoWriteStars, "photoWriteStars") }
    }
    @Published var photoOnlinePlaces = Preferences.bool("photoOnlinePlaces") {
        didSet { Preferences.setBool(photoOnlinePlaces, "photoOnlinePlaces") }
    }
    @Published var photoDryRun = false
    @Published var gyroflow: GyroflowStatus = .missing
    @Published var lutPickerGroup: ColorProfile?

    // Running
    @Published var overallProgress = 0.0
    @Published var currentTask: TaskKind?
    @Published var detail = ""
    @Published var quiet: (name: String, seconds: Int)?
    @Published var pausedReason: String?
    @Published var stopping = false
    @Published var reports: [TaskReport] = []
    @Published var leftovers: [ProcessRegistry.Entry] = []

    private(set) var outputRoot: URL?
    private var pipeline: Task<Void, Never>?
    private var stabilizeEngine: StabilizeEngine?
    private var activity: NSObjectProtocol?
    private(set) var log: RunLog?

    init() {
        leftovers = ProcessRegistry.shared.leftovers()
    }

    var isRunning: Bool { stage == .running }

    // MARK: Folder and scan

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择这次拍的素材文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        guard !isRunning else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            errorMessage = "请拖入一个文件夹，而不是单个文件。"
            return
        }
        folder = url
        errorMessage = nil
        reports = []
        stage = .scanning
        scanProgress = (0, 0)
        Task {
            do {
                let result = try await MediaScanner.scan(url) { done, total in
                    Task { @MainActor in self.scanProgress = (done, total) }
                }
                applyScan(result)
            } catch {
                errorMessage = Self.explain(error)
                stage = .home
            }
        }
    }

    func backToHome() {
        guard !isRunning else { return }
        stage = .home
        scan = nil
        reports = []
    }

    private func applyScan(_ result: ScanResult) {
        scan = result
        guard !result.videos.isEmpty || !result.photos.isEmpty else {
            errorMessage = "这个文件夹里没有找到视频或照片。"
            stage = .home
            return
        }
        stabilizeOn = result.stabilizableCount > 0
        rebuildGroups()
        gradeOn = groups.contains { $0.profile.isLog }
        selected = []
        if result.stabilizableCount > 0 || groups.contains(where: { $0.profile.isLog }) { selected.insert(.stabilize) }
        if !result.videos.isEmpty { selected.insert(.highlights) }
        if !result.photos.isEmpty { selected.insert(.photos) }
        refreshGyroflow()
        stage = .plan
    }

    /// Profile after the user's per-camera assignment for footage detection could not place.
    func effectiveProfile(_ video: ScannedVideo) -> ColorProfile {
        guard video.detectedProfile == .unknown, let model = video.cameraModel,
              let assigned = Preferences.cameraProfiles[model] else { return video.detectedProfile }
        return assigned
    }

    func rebuildGroups() {
        guard let scan else { groups = []; return }
        let previous = Dictionary(uniqueKeysWithValues: groups.map { ($0.profile, $0.choice) })
        let byProfile = Dictionary(grouping: scan.videos, by: effectiveProfile)
        groups = ColorProfile.allCases.compactMap { profile in
            guard let videos = byProfile[profile] else { return nil }
            let choice = previous[profile] ?? (profile.isLog ? .undecided : .none)
            return ProfileGroup(profile: profile, videos: videos, choice: choice)
        }
    }

    func assign(model: String, to profile: ColorProfile) {
        var profiles = Preferences.cameraProfiles
        profiles[model] = profile
        Preferences.cameraProfiles = profiles
        rebuildGroups()
    }

    func setChoice(_ choice: LUTChoice, for profile: ColorProfile) {
        guard let index = groups.firstIndex(where: { $0.profile == profile }) else { return }
        groups[index].choice = choice
    }

    func refreshGyroflow() {
        gyroflow = Gyroflow.check()
    }

    var gyroflowReady: Bool {
        if case .ready = gyroflow { return true }
        return false
    }

    /// Jobs for the stabilise/grade step from the current choices.
    var stabilizeJobs: [StabilizeJob] {
        guard let scan else { return [] }
        let luts = Dictionary(uniqueKeysWithValues: groups.map { ($0.profile, $0.choice.url) })
        return scan.videos.compactMap { video in
            let profile = effectiveProfile(video)
            let stabilize = stabilizeOn && video.canStabilize && gyroflowReady
            let lut = gradeOn ? (luts[profile] ?? nil) : nil
            guard stabilize || lut != nil else { return nil }
            return StabilizeJob(source: video, profile: profile, stabilize: stabilize, lut: lut)
        }
    }

    /// Why 开始 is disabled, in words; nil when ready.
    var blocker: String? {
        if selected.isEmpty { return "至少勾选一项" }
        if selected.contains(.stabilize) {
            if gradeOn, let group = groups.first(where: { $0.choice == .undecided }) {
                return "请给「\(group.profile.displayName)」选一个色调，或选「不调色」"
            }
            if stabilizeJobs.isEmpty {
                return stabilizeOn && !gyroflowReady && (scan?.stabilizableCount ?? 0) > 0
                    ? "增稳需要先安装 Gyroflow" : "没有需要增稳或调色的视频，可以取消勾选这一项"
            }
        }
        if selected.contains(.highlights), themes.isEmpty { return "挑高光至少要选一种想保留的内容" }
        return nil
    }

    var downloadNote: String? {
        var gb = 0.0
        if selected.contains(.highlights) || (selected.contains(.photos) && photoUseQwen) {
            if !ModelStatus.qwenInstalled { gb += ModelStatus.qwenDownloadGB }
        }
        if !selected.isDisjoint(with: [.highlights, .photos, .habits]), !ModelStatus.mobileCLIPInstalled {
            gb += ModelStatus.mobileCLIPDownloadGB
        }
        guard gb > 0 else { return nil }
        return String(format: "第一次使用要下载约 %.1f GB 的本地模型，之后可以离线使用。", gb)
    }

    // MARK: Run

    func start() {
        guard let folder, let scan, blocker == nil, !isRunning else { return }
        guard let output = resolveOutputRoot(for: folder) else { return }
        outputRoot = output
        let log = RunLog(folder: output.appendingPathComponent("LightTable 日志", isDirectory: true))
        self.log = log
        log.write("开始：\(folder.path)")
        log.write("任务：\(TaskKind.allCases.filter(selected.contains).map(\.title).joined(separator: "、"))")
        log.write("素材：视频 \(scan.videos.count)（可增稳 \(scan.stabilizableCount)），照片 \(scan.photos.count)")

        let plan = TaskKind.allCases.filter(selected.contains)
        reports = []
        overallProgress = 0
        stopping = false
        quiet = nil
        pausedReason = nil
        stage = .running
        beginActivity()
        let jobs = stabilizeJobs
        for group in groups where gradeOn { Preferences.setLastLUT(group.choice.url, for: group.profile) }

        pipeline = Task {
            var stabilized: [URL: URL] = [:]
            for (index, kind) in plan.enumerated() {
                if Task.isCancelled { break }
                currentTask = kind
                detail = "准备中…"
                let report: TaskReport
                let progress: @MainActor (Double, String) -> Void = { [weak self] fraction, message in
                    guard let self else { return }
                    self.overallProgress = (Double(index) + min(1, max(0, fraction))) / Double(plan.count)
                    self.detail = message
                }
                switch kind {
                case .stabilize:
                    let result = await runStabilize(jobs: jobs, root: folder, output: output, progress: progress)
                    stabilized = result.outputs
                    report = result.report
                case .highlights:
                    report = await runHighlights(scan: scan, stabilized: stabilized, output: output, progress: progress)
                case .habits:
                    report = await runHabits(root: folder, output: output, progress: progress)
                case .photos:
                    report = await runPhotos(root: folder, progress: progress)
                }
                reports.append(report)
                log.write("\(kind.title)：\(report.lines.joined(separator: "；"))")
            }
            finish()
        }
    }

    func stop() {
        guard isRunning else { return }
        stopping = true
        detail = "正在停止…"
        stabilizeEngine?.stop()
        pipeline?.cancel()
    }

    func skipCurrentClip() {
        quiet = nil
        stabilizeEngine?.skipCurrent()
    }

    func waitLonger() {
        quiet = nil
        stabilizeEngine?.waitLonger()
    }

    func resume() {
        pausedReason = nil
        stabilizeEngine?.resume()
    }

    private func finish() {
        endActivity()
        log?.write("结束")
        currentTask = nil
        quiet = nil
        pausedReason = nil
        stabilizeEngine = nil
        overallProgress = 1
        stage = .finished
        stopping = false
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    /// Output goes next to the footage unless that folder is read-only or on a memory card.
    private func resolveOutputRoot(for folder: URL) -> URL? {
        let values = try? folder.resourceValues(forKeys: [.volumeIsRemovableKey, .volumeIsReadOnlyKey, .volumeIsEjectableKey])
        let removable = values?.volumeIsRemovable == true && values?.volumeIsEjectable == true
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent("DCIM").path)
            || FileManager.default.fileExists(atPath: Self.volumeRoot(of: folder).appendingPathComponent("DCIM").path)
        let writable = FileManager.default.isWritableFile(atPath: folder.path) && values?.volumeIsReadOnly != true
        if writable && !removable { return folder }
        let alert = NSAlert()
        alert.messageText = removable ? "素材在存储卡上" : "这个文件夹不能写入"
        alert.informativeText = removable
            ? "结果文件很大，不建议写回存储卡。请选一个电脑上的文件夹存放结果。照片分组仍会直接写进照片。"
            : "请选一个可以写入的文件夹存放结果。"
        alert.addButton(withTitle: "选择文件夹…")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let panel = NSOpenPanel()
        panel.title = "选择存放结果的文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    private static func volumeRoot(of url: URL) -> URL {
        (try? url.resourceValues(forKeys: [.volumeURLKey]).volume) ?? URL(fileURLWithPath: "/")
    }

    // MARK: Steps

    private func runStabilize(jobs: [StabilizeJob], root: URL, output: URL,
                              progress: @escaping @MainActor (Double, String) -> Void) async -> (outputs: [URL: URL], report: TaskReport) {
        var settings = StabilizeSettings(sourceRoot: root, outputRoot: output.appendingPathComponent("LightTable 增稳", isDirectory: true))
        settings.maxZoom = maxZoom
        settings.readoutTime = readoutTime
        if case .ready(let executable, _) = gyroflow { settings.gyroflow = executable }
        let engine = StabilizeEngine(settings: settings)
        stabilizeEngine = engine
        let log = self.log
        let summary = await engine.run(jobs) { event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch event {
                case .clipStarted(let index, let total, let name):
                    self.quiet = nil
                    self.detail = "增稳调色 \(index + 1)/\(total)：\(name)"
                    log?.write("开始 \(name)")
                case .progress(let overall, _, let message):
                    progress(overall, message)
                case .quiet(let name, let seconds):
                    if seconds >= 30 { self.quiet = (name, Int(seconds)) }
                case .clipFinished(let result):
                    self.quiet = nil
                    log?.write("\(result.job.source.relativePath)：\(Self.describe(result.status))"
                        + (result.warnings.isEmpty ? "" : "（\(result.warnings.joined(separator: "；"))）"))
                case .paused(let reason):
                    self.pausedReason = reason
                    log?.write("暂停：\(reason)")
                case .resumed:
                    self.pausedReason = nil
                }
            }
        }
        stabilizeEngine = nil
        let done = summary.results.filter { $0.status == .done || $0.status == .alreadyDone }
        let failed = summary.results.filter { if case .failed = $0.status { return true } else { return false } }
        let skipped = summary.results.filter { if case .skipped = $0.status { return true } else { return false } }
        var lines = ["完成 \(done.count) 段"]
        if !skipped.isEmpty { lines.append("跳过 \(skipped.count) 段") }
        for result in failed.prefix(5) { lines.append("\(result.job.source.relativePath)：\(Self.describe(result.status))") }
        if failed.count > 5 { lines.append("另有 \(failed.count - 5) 段失败，详见日志") }
        let status: TaskReport.Status = summary.stopped ? .stopped : failed.isEmpty ? .success : done.isEmpty ? .failed : .partial
        return (summary.outputsByOriginal,
                TaskReport(kind: .stabilize, status: status, lines: lines,
                           openURL: settings.outputRoot, openLabel: "打开增稳后的视频"))
    }

    private func runHighlights(scan: ScanResult, stabilized: [URL: URL], output: URL,
                               progress: @escaping @MainActor (Double, String) -> Void) async -> TaskReport {
        var files: [URL] = []
        var dates: [String: String] = [:]
        var originals: [String: String] = [:]
        for video in scan.videos {
            let file = stabilized[video.url] ?? video.url
            files.append(file)
            if let date = video.creationDate { dates[file.standardizedFileURL.path] = date }
            if file != video.url { originals[file.standardizedFileURL.path] = video.url.path }
        }
        let configuration = Self.highlightConfiguration(output: output, files: files, dates: dates,
                                                         originals: originals, themes: themes, input: scan.root)
        do {
            let summary = try await Task.detached(priority: .userInitiated) {
                try await HighlightEngine().run(configuration: configuration) { update in
                    Task { @MainActor in progress(update.fraction, update.message) }
                }
            }.value
            return TaskReport(kind: .highlights, status: .success,
                              lines: ["从 \(summary.inputVideoCount) 段视频中挑出 \(summary.selectedClipCount) 段高光"],
                              openURL: summary.outputFolder, openLabel: "打开高光片段")
        } catch is CancellationError {
            return TaskReport(kind: .highlights, status: .stopped, lines: ["已停止，下次用同样的设置开始会接着做"])
        } catch {
            if Task.isCancelled { return TaskReport(kind: .highlights, status: .stopped, lines: ["已停止"]) }
            return TaskReport(kind: .highlights, status: .failed, lines: [Self.explain(error)])
        }
    }

    /// Reuses `LightTable 高光` when it holds a checkpoint for this exact job, otherwise the
    /// first unused `LightTable 高光 N`.
    nonisolated static func highlightConfiguration(output: URL, files: [URL], dates: [String: String],
                                                   originals: [String: String], themes: Set<HighlightTheme>,
                                                   input: URL) -> JobConfiguration {
        func make(_ folder: URL) -> JobConfiguration {
            JobConfiguration(inputFolder: input, outputFolder: folder, selectedThemes: themes,
                             inputFiles: files, captureDates: dates, originalSources: originals)
        }
        for index in 1...999 {
            let name = index == 1 ? "LightTable 高光" : "LightTable 高光 \(index)"
            let folder = output.appendingPathComponent(name, isDirectory: true)
            let configuration = make(folder)
            if !FileManager.default.fileExists(atPath: folder.path) || HighlightRecovery.canResume(configuration) {
                return configuration
            }
            if !HighlightRecovery.isUsed(folder),
               (try? FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty) == true {
                return configuration
            }
        }
        return make(output.appendingPathComponent("LightTable 高光 \(UUID().uuidString.prefix(6))", isDirectory: true))
    }

    private func runHabits(root: URL, output: URL, progress: @escaping @MainActor (Double, String) -> Void) async -> TaskReport {
        let options = HabitsOptions(root: root, outputHTML: output.appendingPathComponent("LightTable 拍摄习惯.html"))
        do {
            let summary = try await Task.detached(priority: .userInitiated) {
                try await HabitsEngine().run(options) { message, fraction in
                    Task { @MainActor in progress(fraction, message) }
                }
            }.value
            NSWorkspace.shared.open(summary.htmlFile)
            return TaskReport(kind: .habits, status: .success,
                              lines: ["统计了 \(summary.photoCount) 张照片，报告已在浏览器打开"],
                              openURL: summary.htmlFile, openLabel: "再次打开报告")
        } catch is CancellationError {
            return TaskReport(kind: .habits, status: .stopped, lines: ["已停止"])
        } catch {
            return TaskReport(kind: .habits, status: .failed, lines: [Self.explain(error)])
        }
    }

    private func runPhotos(root: URL, progress: @escaping @MainActor (Double, String) -> Void) async -> TaskReport {
        guard FileManager.default.isWritableFile(atPath: root.path) else {
            return TaskReport(kind: .photos, status: .skipped, lines: ["照片所在的文件夹不能写入，没有分组。请先把照片拷到电脑上。"])
        }
        let configuration = PhotoCullConfiguration(
            inputFolder: root, selectedThemes: HighlightTheme.defaultSelection, useQwen: photoUseQwen,
            writeRatings: !photoDryRun, writeStars: photoWriteStars, exportFeatures: false, debugLog: false,
            onlinePlaces: photoOnlinePlaces)
        do {
            let summary = try await Task.detached(priority: .userInitiated) {
                try await PhotoCullEngine().run(configuration: configuration) { update in
                    Task { @MainActor in progress(update.fraction, update.message) }
                }
            }.value
            var lines = ["\(summary.photoCount) 张照片分成 \(summary.groupCount) 组"]
            if summary.rejectedCount > 0 && !configuration.writeStars { lines.append("\(summary.rejectedCount) 张可能是废片（只加了关键字）") }
            if summary.skippedUserMarked > 0 { lines.append("已有你的星级或标签而跳过 \(summary.skippedUserMarked) 张") }
            if summary.onlinePlaceFailures > 0 { lines.append("在线地点查询失败 \(summary.onlinePlaceFailures) 处，这些照片用离线城市名") }
            if summary.visionFailures > 0 { lines.append("\(summary.visionFailures) 张照片的画面分析失败") }
            if summary.notWritable > 0 { lines.append("\(summary.notWritable) 张的格式不能写入") }
            lines.append(summary.wroteRatings
                ? "在 Bridge 里按创建日期排序，一组一组看；用关键字面板按组、主题、地点筛选"
                : "试运行：没有写入照片，结果见「\(PhotoCullEngine.reportName)」")
            return TaskReport(kind: .photos, status: .success, lines: lines, openURL: root, openLabel: "打开照片文件夹")
        } catch is CancellationError {
            return TaskReport(kind: .photos, status: .stopped, lines: ["已停止"])
        } catch {
            return TaskReport(kind: .photos, status: .failed, lines: [Self.explain(error)])
        }
    }

    // MARK: Leftovers, diagnostics, helpers

    func endLeftovers() {
        let stuck = leftovers.filter { !ProcessRegistry.shared.terminate($0) }
        leftovers = []
        if !stuck.isEmpty {
            errorMessage = "有 \(stuck.count) 个进程无法结束（PID \(stuck.map { String($0.pid) }.joined(separator: "、"))），可以在「活动监视器」里强制退出。"
        }
    }

    func exportDiagnostics() {
        guard let logFolder = log?.folder else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "LightTable 诊断信息.zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        if let scan {
            let lines = scan.videos.map { video in
                "\(video.relativePath)\t\(video.cameraModel ?? "-")\t\(video.detectedProfile.rawValue)\t陀螺仪:\(video.gyroFormat ?? "无")\t\(video.width)x\(video.height)\t\(String(format: "%.2f", video.duration))s"
            }
            try? lines.joined(separator: "\n").write(to: logFolder.appendingPathComponent("素材清单.txt"), atomically: true, encoding: .utf8)
        }
        try? FileManager.default.removeItem(at: destination)
        _ = try? Tools.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--keepParent", logFolder.path, destination.path])
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }

    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "LightTable 正在处理素材")
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    nonisolated static func describe(_ status: ClipStatus) -> String {
        switch status {
        case .done: "完成"
        case .alreadyDone: "上次已完成"
        case .skipped(let reason): "跳过：\(reason)"
        case .failed(let reason): "失败：\(reason)"
        }
    }

    nonisolated static func explain(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// Plain-text log of one run, in `<output>/LightTable 日志/`.
final class RunLog: @unchecked Sendable {
    let folder: URL
    let file: URL
    private let lock = NSLock()
    private let formatter: DateFormatter

    init(folder: URL) {
        self.folder = folder
        formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        file = folder.appendingPathComponent("运行记录 \(formatter.string(from: Date())).txt")
        formatter.dateFormat = "HH:mm:ss"
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: nil)
    }

    func write(_ line: String) {
        lock.withLock {
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(Data("[\(formatter.string(from: Date()))] \(line)\n".utf8))
        }
    }
}
