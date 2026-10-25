import Foundation

/// External command-line tools LightTable drives.
public enum Tool: String, CaseIterable, Sendable {
    case ffmpeg, ffprobe, exiftool

    /// Folder inside `Contents/Helpers/` the release build copies the tool into.
    var helperFolder: String {
        switch self {
        case .ffmpeg, .ffprobe: "ffmpeg"
        case .exiftool: "exiftool"
        }
    }
}

public enum Tools {
    /// Bundled copy first, then Homebrew and the system path. Development builds run from
    /// `.build` and have no bundle, so they fall through to Homebrew.
    public static func find(_ tool: Tool) -> URL? {
        if let override = ProcessInfo.processInfo.environment["LIGHTTABLE_\(tool.rawValue.uppercased())"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/\(tool.helperFolder)/\(tool.rawValue)")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in ["/opt/homebrew/bin", "/usr/local/bin"] + path + ["/usr/bin"] {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(tool.rawValue)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Runs a short command to completion and returns stdout. For quick probes only; long jobs
    /// go through `SupervisedProcess`.
    @discardableResult
    public static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 120) throws -> String {
        let result = try SupervisedProcess.runToCompletion(executable: executable, arguments: arguments, timeout: timeout)
        guard result.exit == .exited(0) else {
            throw ToolError.failed(executable.lastPathComponent, result.exit?.description ?? "超时或被停止", result.stderrTail)
        }
        return result.stdout
    }
}

public enum ToolError: LocalizedError, Equatable {
    case missing(String)
    case failed(String, String, String)

    public var errorDescription: String? {
        switch self {
        case .missing(let name): "找不到 \(name)"
        case .failed(let name, let status, let detail):
            "\(name) 运行失败（\(status)）" + (detail.isEmpty ? "" : "：\(detail)")
        }
    }
}
