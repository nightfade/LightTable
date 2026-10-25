import Foundation
import Habits
import LightTableKit
import Stabilize
import TravelCutCore

// Command-line entry for debugging and scripted runs. The App is the product; every command here
// calls the same engines with the same defaults.

let usage = """
用法：lighttable-cli <命令> [选项]

  scan <文件夹>                         列出视频（机型、画面类型、能否增稳）和照片数量
  gyroflow                              检查 Gyroflow 是否可用
  tools                                 列出实际使用的 ffmpeg、ffprobe、exiftool 和 Gyroflow
  stabilize <文件夹> [--lut 文件.cube（只套 Log 画面）] [--lut-for 画面=文件.cube ...] [--no-stabilize]
            [--output 文件夹] [--max-zoom 117.6] [--readout-time 15.6] [--dry-run]
                                        增稳调色，结果在 <输出>/LightTable 增稳/
  highlights <文件夹> [--output 文件夹] [--themes 自然景观,人物互动] [--fast-only] [--after-stabilize]
                                        挑视频高光；--after-stabilize 用 LightTable 增稳/ 里的成片代替原片
  photos <文件夹> [--fast-only] [--dry-run] [--stars] [--online-places] [--themes ...]
                                        照片分组（写进照片元数据）
  habits <文件夹> [--content auto|clip|meta] [--include-exports] [--include-phones]
         [--exclude-dir 名字 ...] [--output 文件.html]
                                        拍摄习惯报告

画面名称：\(ColorProfile.allCases.map(\.rawValue).joined(separator: "、"))
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("错误：\(message)\n".utf8))
    exit(1)
}

func say(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

struct Arguments {
    var positional: [String] = []
    var options: [String: [String]] = [:]
    var flags: Set<String> = []

    /// `valued` options take a value; `flags` are the switches this command knows. Anything else
    /// stops with an error, so a typo like `--dryrun` cannot start a real run.
    init(_ raw: ArraySlice<String>, valued: Set<String>, flags known: Set<String> = []) {
        var iterator = raw.makeIterator()
        while let argument = iterator.next() {
            if argument.hasPrefix("--") {
                if argument.contains("=") { fail("请写成「\(argument.replacingOccurrences(of: "=", with: " "))」，选项和值之间用空格") }
                guard valued.contains(argument) || known.contains(argument) else { fail("不认识的选项 \(argument)\n\n\(usage)") }
                if valued.contains(argument) {
                    guard let value = iterator.next() else { fail("\(argument) 缺少值") }
                    options[argument, default: []].append(value)
                } else {
                    flags.insert(argument)
                }
            } else {
                positional.append(argument)
            }
        }
    }

    func value(_ name: String) -> String? { options[name]?.last }

    func folder() -> URL {
        guard let path = positional.first else { fail("缺少文件夹\n\n\(usage)") }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}

func themes(_ text: String?) -> Set<HighlightTheme> {
    guard let text else { return HighlightTheme.defaultSelection }
    let names = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    let themes = Set(names.compactMap(HighlightTheme.init(rawValue:)))
    guard !themes.isEmpty, themes.count == names.count else {
        fail("未知标签；可用：\(HighlightTheme.allCases.map(\.rawValue).joined(separator: ","))")
    }
    return themes
}

func scanFolder(_ folder: URL) async -> ScanResult {
    do {
        return try await MediaScanner.scan(folder) { done, total in
            if done == total || done % 20 == 0 { say("扫描视频 \(done)/\(total)") }
        }
    } catch {
        fail(error.localizedDescription)
    }
}

let command = CommandLine.arguments.dropFirst().first ?? "--help"
let rest = CommandLine.arguments.dropFirst(2)

switch command {
case "scan":
    let arguments = Arguments(rest, valued: [])
    let scan = await scanFolder(arguments.folder())
    for video in scan.videos {
        print([video.relativePath, video.cameraModel ?? "-", video.detectedProfile.displayName,
               video.gyroFormat.map { "陀螺仪 \($0)" } ?? "无陀螺仪",
               "\(video.width)x\(video.height)", String(format: "%.2ffps %.1fs", video.frameRate, video.duration),
               video.creationDate ?? "-"].joined(separator: "\t"))
    }
    print("视频 \(scan.videos.count)（可增稳 \(scan.stabilizableCount)），照片 \(scan.photos.count)，读不出 \(scan.unreadable.count)")

case "tools":
    for tool in Tool.allCases { print("\(tool.rawValue)\t\(Tools.find(tool)?.path ?? "未找到")") }
    switch Gyroflow.check() {
    case .ready(let executable, let version): print("gyroflow\t\(executable.path)（\(version)）")
    default: print("gyroflow\t不可用")
    }

case "gyroflow":
    switch Gyroflow.check() {
    case .ready(let executable, let version): print("可用：\(version)（\(executable.path)）")
    case .missing: fail("没有安装 Gyroflow。请从 https://gyroflow.xyz/download 下载，拖进「应用程序」。")
    case .appStore(let app): fail("\(app.path) 是 App Store 版，不能被调用。请换成官网版。")
    case .broken(let app, let detail): fail("\(app.path) 无法运行：\(detail)")
    }

case "stabilize":
    let arguments = Arguments(rest, valued: ["--lut", "--lut-for", "--output", "--max-zoom", "--readout-time"],
                              flags: ["--no-stabilize", "--dry-run"])
    let folder = arguments.folder()
    let output = arguments.value("--output").map { URL(fileURLWithPath: $0).standardizedFileURL } ?? folder
    var luts: [ColorProfile: URL] = [:]
    for item in arguments.options["--lut-for"] ?? [] {
        let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, let profile = ColorProfile(rawValue: parts[0]) else { fail("--lut-for 格式是 画面=文件.cube，如 sLog2=look.cube") }
        luts[profile] = URL(fileURLWithPath: parts[1])
    }
    let defaultLUT = arguments.value("--lut").map { URL(fileURLWithPath: $0) }
    let scan = await scanFolder(folder)
    let status = Gyroflow.check()
    var gyroflow: URL?
    if case .ready(let executable, _) = status { gyroflow = executable }
    let wantStabilize = !arguments.flags.contains("--no-stabilize")
    let jobs = scan.videos.compactMap { video -> StabilizeJob? in
        let lut = luts[video.detectedProfile] ?? (video.detectedProfile.isLog ? defaultLUT : nil)
        let stabilize = wantStabilize && video.canStabilize && gyroflow != nil
        guard stabilize || lut != nil else { return nil }
        return StabilizeJob(source: video, profile: video.detectedProfile, stabilize: stabilize, lut: lut)
    }
    if wantStabilize && gyroflow == nil && scan.stabilizableCount > 0 { say("提示：Gyroflow 不可用，只做调色") }
    guard !jobs.isEmpty else { fail("没有需要增稳或调色的视频") }
    var settings = StabilizeSettings(sourceRoot: folder, outputRoot: output.appendingPathComponent("LightTable 增稳", isDirectory: true))
    settings.gyroflow = gyroflow
    settings.maxZoom = arguments.value("--max-zoom").flatMap(Double.init)
    settings.readoutTime = arguments.value("--readout-time").flatMap(Double.init)
    let engine = StabilizeEngine(settings: settings)
    let estimate = engine.estimate(jobs)
    say(String(format: "%d 段，预计 %.0f 分钟，成片约 %.1f GB，峰值需要 %.1f GB 空间", jobs.count,
               estimate.seconds / 60, Double(estimate.finalBytes) / 1e9, Double(estimate.peakBytes) / 1e9))
    if arguments.flags.contains("--dry-run") {
        for job in jobs { print("\(job.source.relativePath)\t增稳:\(job.stabilize ? "是" : "否")\tLUT:\(job.lut?.lastPathComponent ?? "-")") }
        exit(0)
    }
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler { say("正在停止…"); engine.stop() }
    interrupt.resume()
    let summary = await engine.run(jobs) { event in
        switch event {
        case .clipStarted(let index, let total, let name): say("[\(index + 1)/\(total)] \(name)")
        case .quiet(let name, let seconds) where Int(seconds) % 30 == 0: say("  \(name) 已经 \(Int(seconds)) 秒没有进展")
        case .clipFinished(let result):
            say("  → \(result.output?.path ?? "-")：\(result.status)" + (result.warnings.isEmpty ? "" : " ⚠︎ \(result.warnings.joined(separator: "；"))"))
        case .paused(let reason): say("已暂停：\(reason)。解决后按回车继续"); _ = readLine(); engine.resume()
        default: break
        }
    }
    let failed = summary.results.filter { if case .failed = $0.status { return true } else { return false } }.count
    print("完成 \(summary.results.count - failed)/\(summary.results.count)；对照表：\(summary.mapFile?.path ?? "-")")
    exit(failed > 0 || summary.stopped ? 1 : 0)

case "highlights":
    let arguments = Arguments(rest, valued: ["--output", "--themes"], flags: ["--fast-only", "--after-stabilize"])
    let folder = arguments.folder()
    let output = arguments.value("--output").map { URL(fileURLWithPath: $0).standardizedFileURL }
        ?? folder.appendingPathComponent("LightTable 高光", isDirectory: true)
    let scan = await scanFolder(folder)
    // Same hand-over as the App: stabilised outputs replace their originals, dates come from the
    // originals (Gyroflow keeps only UTC), and selection.json records the original.
    let stabilized = arguments.flags.contains("--after-stabilize")
        ? StabilizedOutputs.load(outputRoot: folder.appendingPathComponent("LightTable 增稳", isDirectory: true)) : [:]
    if arguments.flags.contains("--after-stabilize") { say("使用增稳后的视频 \(stabilized.count) 段") }
    var files: [URL] = []
    var dates: [String: String] = [:]
    var originals: [String: String] = [:]
    for video in scan.videos {
        let file = stabilized[video.url.standardizedFileURL] ?? video.url
        files.append(file)
        if let date = video.creationDate { dates[file.standardizedFileURL.path] = date }
        if file != video.url { originals[file.standardizedFileURL.path] = video.url.path }
    }
    let configuration = JobConfiguration(inputFolder: folder, outputFolder: output,
                                         useDeepAnalysis: !arguments.flags.contains("--fast-only"),
                                         selectedThemes: themes(arguments.value("--themes")),
                                         inputFiles: files, captureDates: dates, originalSources: originals)
    do {
        let summary = try await HighlightEngine().run(configuration: configuration) { update in
            say("[\(Int(update.fraction * 100))%] \(update.message)")
        }
        print("从 \(summary.inputVideoCount) 个视频中导出 \(summary.selectedClipCount) 段高光：\(summary.outputFolder.path)")
    } catch {
        fail(error.localizedDescription)
    }

case "photos":
    let arguments = Arguments(rest, valued: ["--themes"],
                              flags: ["--fast-only", "--dry-run", "--stars", "--online-places", "--export-features", "--debug-log"])
    let configuration = PhotoCullConfiguration(
        inputFolder: arguments.folder(), selectedThemes: themes(arguments.value("--themes")),
        useQwen: !arguments.flags.contains("--fast-only"), writeRatings: !arguments.flags.contains("--dry-run"),
        writeStars: arguments.flags.contains("--stars"), exportFeatures: arguments.flags.contains("--export-features"),
        debugLog: arguments.flags.contains("--debug-log"), onlinePlaces: arguments.flags.contains("--online-places"))
    do {
        let summary = try await PhotoCullEngine().run(configuration: configuration) { update in
            say("[\(Int(update.fraction * 100))%] \(update.message)")
        }
        print("\(summary.photoCount) 张照片分成 \(summary.groupCount) 组；报告：\(summary.reportFile.path)")
    } catch {
        fail(error.localizedDescription)
    }

case "habits":
    let arguments = Arguments(rest, valued: ["--content", "--exclude-dir", "--output"],
                              flags: ["--include-exports", "--include-phones"])
    let folder = arguments.folder()
    var options = HabitsOptions(root: folder, outputHTML: arguments.value("--output").map { URL(fileURLWithPath: $0) }
        ?? folder.appendingPathComponent("LightTable 拍摄习惯.html"))
    options.excludeDirs = arguments.options["--exclude-dir"] ?? []
    options.includeExports = arguments.flags.contains("--include-exports")
    options.includePhones = arguments.flags.contains("--include-phones")
    if let mode = arguments.value("--content") {
        guard let content = ContentMode(rawValue: mode) else { fail("--content 只能是 auto、clip 或 meta") }
        options.content = content
    }
    do {
        let summary = try await HabitsEngine().run(options) { message, fraction in
            say("[\(Int(fraction * 100))%] \(message)")
        }
        print("统计 \(summary.photoCount) 张照片（扫描 \(summary.scannedFiles) 个文件）：\(summary.htmlFile.path)")
    } catch {
        fail(error.localizedDescription)
    }

case "--help", "-h", "help":
    print(usage)

default:
    fail("未知命令 \(command)\n\n\(usage)")
}
