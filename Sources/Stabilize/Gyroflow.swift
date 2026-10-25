import Darwin
import Foundation
import LightTableKit

/// Finding a Gyroflow LightTable can drive. Gyroflow is not bundled; the user installs the
/// official build and LightTable checks it before every stabilisation run.
public enum Gyroflow {
    /// Places the official build lands in, in the order they are tried.
    static var standardLocations: [URL] {
        [URL(fileURLWithPath: "/Applications/Gyroflow.app"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Gyroflow.app")]
    }

    public static func check(override: URL? = nil) -> GyroflowStatus {
        check(override: override, timeout: 60)
    }

    /// `override` may be a `.app` or the executable itself.
    ///
    /// The Mac App Store build is sandboxed: its CLI aborts in `_libsecinit_appsandbox` before
    /// `main()` (SIGTRAP, exit 133) and could only read files picked in a dialog anyway. It is
    /// recognised by `Contents/_MASReceipt`, or by the SIGTRAP when the receipt is missing.
    static func check(override: URL?, timeout: TimeInterval) -> GyroflowStatus {
        let candidates = override.map { [$0] } ?? standardLocations
        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return .missing
        }
        let (app, executable) = resolve(found)
        if let app, FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/_MASReceipt").path) {
            return .appStore(app: app)
        }
        let reported = app ?? executable
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return .broken(app: reported, detail: "找不到可运行的 gyroflow 程序：\(executable.path)")
        }
        let result: SupervisedProcess.Result
        do {
            result = try SupervisedProcess.runToCompletion(executable: executable, arguments: ["--version"], timeout: timeout)
        } catch {
            return .broken(app: reported, detail: error.localizedDescription)
        }
        return interpret(result, app: app, executable: executable)
    }

    static func interpret(_ result: SupervisedProcess.Result, app: URL?, executable: URL) -> GyroflowStatus {
        let reported = app ?? executable
        switch result.ending {
        case .finished(.signaled(SIGTRAP)), .finished(.exited(133)):
            return .appStore(app: reported)
        case .finished(.exited(0)):
            let text = result.stdout + "\n" + result.stderrTail
            if let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("Gyroflow v") }) {
                return .ready(executable: executable, version: String(line.dropFirst("Gyroflow ".count)).trimmingCharacters(in: .whitespaces))
            }
            if text.contains("Gyroflow") { return .ready(executable: executable, version: "unknown") }
            return .broken(app: reported, detail: "gyroflow --version 没有输出版本号")
        case .finished(let exit):
            return .broken(app: reported, detail: "gyroflow --version 失败（\(exit)）" + tail(result))
        case .timedOut, .stalled, .stopped:
            return .broken(app: reported, detail: "gyroflow --version 长时间没有响应，已结束")
        case .unkillable(let pid):
            return .broken(app: reported, detail: "gyroflow --version 卡住且结束不掉（PID \(pid)），请在活动监视器中结束")
        }
    }

    /// (`.app` if any, executable inside it).
    static func resolve(_ url: URL) -> (URL?, URL) {
        guard url.pathExtension == "app" else { return (nil, url) }
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        let name = info?["CFBundleExecutable"] as? String ?? "gyroflow"
        return (url, url.appendingPathComponent("Contents/MacOS/\(name)"))
    }

    private static func tail(_ result: SupervisedProcess.Result) -> String {
        let text = result.stderrTail.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " ")
        return text.isEmpty ? "" : "：\(text)"
    }
}

extension GyroflowStatus {
    /// What to tell the user when stabilisation cannot run, nil when ready.
    public var problem: String? {
        switch self {
        case .ready: nil
        case .missing: "没有找到 Gyroflow。请从 gyroflow.xyz 下载官网版，拖进「应用程序」后再试。"
        case .appStore: "装的是 App Store 版 Gyroflow，它不允许别的程序调用。请删掉它，改装 gyroflow.xyz 的官网版。"
        case .broken(_, let detail): "Gyroflow 无法运行：\(detail)。可以重新安装官网版后再试。"
        }
    }
}
