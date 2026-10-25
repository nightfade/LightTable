import CryptoKit
import Foundation
import LightTableKit

/// Frames for the per-group LUT picker: one frame per clip, graded once per LUT.
///
/// The frame is turned into 16-bit RGB with the same input interpretation and the same
/// `format=yuv444p16le` step the render uses before `lut3d`, so applying a LUT to it matches the
/// delivered file to within a few 8-bit levels (the rest is the delivery's 4:2:0 chroma).
public enum LUTPreview {
    public static let frameWidth = 640

    /// Temp cache, shared by every preview in this run.
    static var cacheFolder: URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LightTable-LUTPreview", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Every `.cube` under `folder`, subfolders included, in Finder order.
    public static func listLUTs(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var luts: [URL] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "cube" {
            luts.append(url)
        }
        return luts.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// A ~640 px wide 16-bit PNG of the frame at `seconds`, cached by file, mtime and position.
    public static func extractFrame(from video: URL, at seconds: Double) async throws -> URL {
        guard let ffmpeg = Tools.find(.ffmpeg), let ffprobe = Tools.find(.ffprobe) else { throw ToolError.missing("ffmpeg") }
        let stamp = modification(of: video)
        let output = cacheFolder.appendingPathComponent("frame-\(key(video.path, stamp, String(format: "%.3f", seconds), frameWidth)).png")
        if FileManager.default.fileExists(atPath: output.path) { return output }

        let probed = try await ProbedMedia.probe(video, ffprobe: ffprobe)
        let duration = probed.duration ?? 0
        let position = duration > 0 ? min(max(0, seconds), max(duration - 0.1, 0)) : max(0, seconds)
        let interpret = StabilizeCommands.inputInterpretation(input: probed.tags, source: .init(), height: probed.height)
        let partial = output.deletingLastPathComponent().appendingPathComponent(".\(output.lastPathComponent)")
        _ = try await ToolRun.output(ffmpeg, [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
            "-ss", String(format: "%.3f", position), "-i", video.path, "-frames:v", "1",
            "-vf", "\(interpret),scale=\(frameWidth):-2:flags=lanczos,format=yuv444p16le,format=rgb48be",
            "-f", "image2", "-c:v", "png", partial.path,
        ], timeout: 120)
        try moveIntoPlace(partial, output)
        return output
    }

    /// `frame` with `lut` applied, as an 8-bit PNG; cached by frame, LUT path and LUT mtime so an
    /// edited LUT is graded again.
    public static func grade(frame: URL, lut: URL) async throws -> URL {
        guard let ffmpeg = Tools.find(.ffmpeg) else { throw ToolError.missing("ffmpeg") }
        let output = cacheFolder.appendingPathComponent("graded-\(key(frame.lastPathComponent, lut.path, modification(of: lut))).png")
        if FileManager.default.fileExists(atPath: output.path) { return output }
        let partial = output.deletingLastPathComponent().appendingPathComponent(".\(output.lastPathComponent)")
        _ = try await ToolRun.output(ffmpeg, [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
            "-i", frame.path, "-vf", "\(StabilizeCommands.lutChain(lut)),format=rgb24",
            "-f", "image2", "-c:v", "png", partial.path,
        ], timeout: 120)
        try moveIntoPlace(partial, output)
        return output
    }

    private static func moveIntoPlace(_ partial: URL, _ output: URL) throws {
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: partial, to: output)
    }

    private static func modification(of url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return String(date?.timeIntervalSince1970 ?? 0)
    }

    static func key(_ parts: CustomStringConvertible...) -> String {
        let digest = SHA256.hash(data: Data(parts.map(\.description).joined(separator: "\u{0}").utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}
