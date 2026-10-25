import Foundation
import LightTableKit

/// Short ffprobe/ffmpeg/exiftool calls the engine and the preview need, run through
/// `SupervisedProcess` without blocking a cooperative thread.
enum ToolRun {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs to completion with a hard timeout and returns the result; throws only when the
    /// process cannot start.
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> SupervisedProcess.Result {
        let process = SupervisedProcess(executable: executable, arguments: arguments,
                                        options: .init(hardTimeout: timeout))
        try process.start()
        return await process.wait()
    }

    /// stdout of a run that must exit 0.
    static func output(_ executable: URL, _ arguments: [String], timeout: TimeInterval) async throws -> String {
        let result = try await run(executable, arguments, timeout: timeout)
        guard result.ending == .finished(.exited(0)) else {
            let status = result.exit?.description ?? "超时或被停止"
            throw ToolError.failed(executable.lastPathComponent, status, result.stderrTail)
        }
        return result.stdout
    }
}

/// What the engine needs to know about a file beyond `ScannedVideo`: bit depth, audio codec and
/// colour tags of the actual ffmpeg input (which may be Gyroflow's staging file).
struct ProbedMedia: Sendable {
    var duration: Double?
    var pixelFormat: String?
    var bitsPerRawSample: String?
    var height: Int
    var audioCodec: String?
    var tags: StabilizeCommands.ColorTags
    var hasAudio: Bool { audioCodec != nil }

    var tenBit: Bool { StabilizeCommands.isTenBit(pixelFormat: pixelFormat, bitsPerRawSample: bitsPerRawSample) }

    static func probe(_ url: URL, ffprobe: URL, timeout: TimeInterval = 60) async throws -> ProbedMedia {
        let text = try await ToolRun.output(ffprobe, [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path,
        ], timeout: timeout)
        return try parse(text)
    }

    static func parse(_ text: String) throws -> ProbedMedia {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw ToolRun.Failure(message: "ffprobe 输出无法解析")
        }
        let streams = json["streams"] as? [[String: Any]] ?? []
        let format = json["format"] as? [String: Any] ?? [:]
        let video = streams.first { $0["codec_type"] as? String == "video" }
        let audio = streams.first { $0["codec_type"] as? String == "audio" }
        return ProbedMedia(
            duration: Double(format["duration"] as? String ?? "") ?? Double(video?["duration"] as? String ?? ""),
            pixelFormat: video?["pix_fmt"] as? String,
            bitsPerRawSample: video?["bits_per_raw_sample"] as? String,
            height: video?["height"] as? Int ?? 0,
            audioCodec: audio?["codec_name"] as? String,
            tags: .init(range: video?["color_range"] as? String, space: video?["color_space"] as? String,
                        primaries: video?["color_primaries"] as? String, transfer: video?["color_transfer"] as? String)
        )
    }
}
