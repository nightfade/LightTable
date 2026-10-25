import Foundation
import LightTableKit

/// Pure construction of every Gyroflow, ffmpeg and exiftool command line, plus the small
/// decisions around them (names, colour tags, sizes, timeouts). Kept free of I/O so the self-test
/// can check them against what `batch_gyroflow.py` produced.
enum StabilizeCommands {
    // MARK: Output names

    /// Delivery codec chosen in 高级. Only VideoToolbox encoders: the LGPL ffmpeg build has no
    /// libx264/libx265.
    static func outputExtension(for codec: StabilizeCodec) -> String {
        switch codec {
        case .hevc, .h264: "mp4"
        }
    }

    /// `<outputRoot>/<same subfolders>/<same stem>.<codec extension>`. The design keeps the
    /// original file name; the output folder already says these are results.
    static func outputURL(for relativePath: String, outputRoot: URL, codec: StabilizeCodec) -> URL {
        let relative = relativePath as NSString
        let folder = relative.deletingLastPathComponent
        let stem = (relative.lastPathComponent as NSString).deletingPathExtension
        var url = outputRoot
        if !folder.isEmpty { url = url.appendingPathComponent(folder, isDirectory: true) }
        return url.appendingPathComponent(stem).appendingPathExtension(outputExtension(for: codec))
    }

    /// Two sources that differ only by extension (`C0001.MP4`, `C0001.MOV`) would map to the same
    /// output; the later one gets the original extension in its name instead of overwriting.
    static func uniqueOutputs(for relativePaths: [String], outputRoot: URL, codec: StabilizeCodec) -> [URL] {
        var taken: Set<String> = []
        return relativePaths.map { path in
            var url = outputURL(for: path, outputRoot: outputRoot, codec: codec)
            if taken.contains(url.path.lowercased()) {
                let ext = (path as NSString).pathExtension
                url = url.deletingPathExtension()
                let stem = url.lastPathComponent + "_" + ext
                url = url.deletingLastPathComponent().appendingPathComponent(stem)
                    .appendingPathExtension(outputExtension(for: codec))
            }
            taken.insert(url.path.lowercased())
            return url
        }
    }

    /// Hidden temp names next to the final file. Hidden so the scanner and Finder ignore them,
    /// next to it so the final rename never crosses volumes.
    static func partialURL(for output: URL) -> URL {
        output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).lighttable-partial.\(output.pathExtension)")
    }

    static func stagingURL(for output: URL) -> URL {
        output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.deletingPathExtension().lastPathComponent).lighttable-staging.mov")
    }

    /// Gyroflow renders to `<output_path>.tmp` and renames it when done.
    static func gyroflowTemp(for target: URL) -> URL {
        target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".tmp")
    }

    // MARK: Gyroflow

    /// The single value for `--preset`, or nil. Gyroflow rejects a repeated `--preset`
    /// ("duplicate values provided"), so everything goes into one JSON object. Key names must
    /// match the project schema exactly; Gyroflow ignores unknown keys without a word
    /// (`adaptive_zoom_window` works, `adaptive_zoom` does nothing). Any new key must be checked
    /// by exporting a project with `--export-project 1` and reading it back.
    static func presetValue(maxZoom: Double?, zoomWindow: Double? = nil, readoutTime: Double?,
                            readoutDirection: String? = nil, base: [String: Any]? = nil) -> String? {
        var overrides: [String: Any] = [:]
        if let maxZoom { overrides["max_zoom"] = maxZoom }
        if let zoomWindow { overrides["adaptive_zoom_window"] = zoomWindow }
        if let readoutTime { overrides["frame_readout_time"] = readoutTime }
        if let readoutDirection { overrides["frame_readout_direction"] = readoutDirection }
        guard !overrides.isEmpty else { return nil }
        var data = base ?? [:]
        if data["version"] == nil { data["version"] = 2 }
        var stabilization = data["stabilization"] as? [String: Any] ?? [:]
        stabilization.merge(overrides) { _, new in new }
        data["stabilization"] = stabilization
        return json(data)
    }

    /// Gyroflow's `--out-params`. The output path is always explicit: otherwise Gyroflow picks
    /// the extension from the codec and a `.MOV` source silently becomes `.mp4` somewhere else.
    /// When a LUT follows, Gyroflow stages ProRes (visually lossless) and ffmpeg does the only
    /// lossy delivery encode.
    static func gyroflowArguments(source: URL, target: URL, staging: Bool, codec: StabilizeCodec,
                                  bitrateMbps: Double, preset: String?) -> [String] {
        var parameters: [String: Any] = ["use_gpu": true, "audio": true, "output_path": target.path]
        if staging {
            parameters["codec"] = "ProRes"
        } else {
            parameters["codec"] = gyroflowCodecName(codec)
            // Without an explicit bitrate Gyroflow scales by resolution (≈28 Mbps at 1080p60),
            // which is too low for delivery.
            parameters["bitrate"] = Int(bitrateMbps.rounded())
        }
        var arguments = [source.path, "--out-params", json(parameters), "--stdout-progress", "--overwrite"]
        if let preset { arguments += ["--preset", preset] }
        return arguments
    }

    static func gyroflowCodecName(_ codec: StabilizeCodec) -> String {
        switch codec {
        case .hevc: "H.265/HEVC"
        case .h264: "H.264/AVC"
        }
    }

    // MARK: Colour

    /// The colour fields ffprobe reports for a video stream. "unknown" and friends are dropped.
    struct ColorTags: Equatable, Sendable {
        var range: String?
        var space: String?
        var primaries: String?
        var transfer: String?

        init(range: String? = nil, space: String? = nil, primaries: String? = nil, transfer: String? = nil) {
            self.range = Self.clean(range)
            self.space = Self.clean(space)
            self.primaries = Self.clean(primaries)
            self.transfer = Self.clean(transfer)
        }

        static func clean(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty,
                  !["unknown", "unspecified", "reserved"].contains(value.lowercased()) else { return nil }
            return value
        }

        /// Output flags that reproduce these tags.
        var outputFlags: [String] {
            var flags: [String] = []
            if let range { flags += ["-color_range", range] }
            if let space { flags += ["-colorspace", space] }
            if let primaries { flags += ["-color_primaries", primaries] }
            if let transfer { flags += ["-color_trc", transfer] }
            return flags
        }

        static let rec709 = ColorTags(range: "tv", space: "bt709", primaries: "bt709", transfer: "bt709")
    }

    /// How to read the LUT input's pixels as RGB. `lut3d` works on RGB, so a wrong range or matrix
    /// feeds the LUT a different signal than the camera recorded. The input's own tags win
    /// (Gyroflow's ProRes staging converts a full-range source to limited and tags it so, verified
    /// on C0835); gaps are filled from the original, then from convention (limited range;
    /// BT.709 matrix for HD and up, BT.601 below).
    static func inputInterpretation(input: ColorTags, source: ColorTags, height: Int) -> String {
        let range = normalizedRange(input.range ?? source.range) ?? "tv"
        let space = input.space ?? source.space ?? (height >= 720 ? "bt709" : "smpte170m")
        return "setparams=range=\(range == "pc" ? "full" : "limited"):colorspace=\(space)"
    }

    static func normalizedRange(_ range: String?) -> String? {
        switch range?.lowercased() {
        case "pc", "jpeg", "full": "pc"
        case "tv", "mpeg", "limited": "tv"
        default: nil
        }
    }

    // MARK: ffmpeg LUT pass

    struct LUTPass {
        var input: URL
        var output: URL
        var lut: URL
        var codec: StabilizeCodec
        var tenBit: Bool
        var bitrateMbps: Double
        var inputTags: ColorTags
        var sourceTags: ColorTags
        var height: Int
        /// Audio codec of the input, nil when it has no audio.
        var audioCodec: String?
    }

    /// Codecs an MP4 can carry as they are; anything else (camera PCM) becomes AAC, as Gyroflow does.
    static let mp4AudioCodecs: Set<String> = ["aac", "alac", "mp3", "ac3", "eac3", "opus"]

    /// `format=yuv444p16le` before `lut3d` keeps gradients from banding (verified in
    /// batch-gyroflow). After the LUT the picture is Rec.709, so it is converted with the BT.709
    /// matrix into limited range and tagged that way, whatever the source was tagged.
    static func lutFilter(pass: LUTPass) -> String {
        let outFormat = pass.tenBit ? "p010le" : "yuv420p"
        return [
            inputInterpretation(input: pass.inputTags, source: pass.sourceTags, height: pass.height),
            lutChain(pass.lut),
            "scale=out_color_matrix=bt709:out_range=tv",
            "format=\(outFormat)",
            "setparams=range=limited:colorspace=bt709:color_primaries=bt709:color_trc=bt709",
        ].joined(separator: ",")
    }

    /// The part shared with the preview: same precision, same LUT filter.
    static func lutChain(_ lut: URL) -> String {
        "format=yuv444p16le,lut3d=file=\(escapeFilterPath(lut.path))"
    }

    static func lutArguments(_ pass: LUTPass) -> [String] {
        var arguments = [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-nostats", "-progress", "pipe:1", "-y",
            "-i", pass.input.path,
            "-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0",
            "-vf", lutFilter(pass: pass),
        ]
        arguments += videoEncoderArguments(codec: pass.codec, tenBit: pass.tenBit, bitrateMbps: pass.bitrateMbps)
        arguments += ColorTags.rec709.outputFlags
        if let audio = pass.audioCodec {
            arguments += mp4AudioCodecs.contains(audio.lowercased()) ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "256k"]
        }
        arguments += ["-f", "mp4", pass.output.path]
        return arguments
    }

    /// VideoToolbox only. 10-bit sources keep 10 bits (HEVC Main10); H.264 has no 10-bit
    /// VideoToolbox profile, so it is always 8-bit.
    static func videoEncoderArguments(codec: StabilizeCodec, tenBit: Bool, bitrateMbps: Double) -> [String] {
        let bitrate = ["-b:v", "\(Int(bitrateMbps.rounded()))M"]
        switch codec {
        case .hevc:
            return ["-c:v", "hevc_videotoolbox", "-profile:v", tenBit ? "main10" : "main",
                    "-pix_fmt", tenBit ? "p010le" : "yuv420p", "-tag:v", "hvc1"] + bitrate
        case .h264:
            return ["-c:v", "h264_videotoolbox", "-profile:v", "high", "-pix_fmt", "yuv420p"] + bitrate
        }
    }

    /// Whether to keep 10 bits: from the pixel format, or the raw sample depth when the format
    /// name does not say.
    static func isTenBit(pixelFormat: String?, bitsPerRawSample: String?) -> Bool {
        if let bits = Int(bitsPerRawSample ?? ""), bits > 8 { return true }
        guard let format = pixelFormat?.lowercased() else { return false }
        return ["10", "12", "16", "p010", "p210", "p410"].contains { format.contains($0) }
    }

    /// ffmpeg filter arguments treat `\ : ' [ ] ,` specially.
    static func escapeFilterPath(_ path: String) -> String {
        var text = path
        for character in ["\\", ":", "'", "[", "]", ","] {
            text = text.replacingOccurrences(of: character, with: "\\" + character)
        }
        return text
    }

    // MARK: exiftool

    /// Gyroflow keeps only the UTC creation time; the zoned capture time goes back on the result
    /// so Photos and the highlight step put the clip on the right day.
    static func creationDateArguments(date: String, file: URL) -> [String] {
        ["-q", "-m", "-overwrite_original", "-api", "LargeFileSupport=1",
         "-QuickTime:CreationDate=\(date)", "-Keys:CreationDate=\(date)", file.path]
    }

    // MARK: Progress

    /// `[41738b21] Rendering progress: 12/84 frames (14.3%) ETA 20.1s`
    static func gyroflowProgress(_ line: String) -> Double? {
        guard let range = line.range(of: "Rendering progress: ") else { return nil }
        let rest = line[range.upperBound...]
        let numbers = rest.split(separator: " ").first?.split(separator: "/") ?? []
        guard numbers.count == 2, let done = Double(numbers[0]), let total = Double(numbers[1]), total > 0 else { return nil }
        return min(1, done / total)
    }

    /// `out_time_us=1234567` from `-progress pipe:1`.
    static func ffmpegProgress(_ line: String, duration: Double) -> Double? {
        guard duration > 0, line.hasPrefix("out_time_us="),
              let micro = Double(line.dropFirst("out_time_us=".count)) else { return nil }
        return min(1, max(0, micro / 1_000_000 / duration))
    }

    // MARK: Sizes and time

    static let reference4K = 3840.0 * 2160.0

    /// Pixels relative to UHD, never below a 720p floor so tiny clips still get sane numbers.
    static func pixelRatio(width: Int, height: Int) -> Double {
        max(Double(width * height), 1280 * 720) / reference4K
    }

    /// Delivery bitrate when the user left it empty: 100 Mbps at UHD 30p (batch-gyroflow's
    /// default), scaled by pixels and frame rate, at least 10 Mbps.
    static func defaultBitrate(width: Int, height: Int, frameRate: Double) -> Double {
        max(10, (100 * pixelRatio(width: width, height: height) * max(1, frameRate / 30)).rounded())
    }

    static func finalBytes(duration: Double, bitrateMbps: Double) -> Int64 {
        Int64(duration * bitrateMbps * 1_000_000 / 8 * 1.05)
    }

    /// ProRes 422 staging: about 5 GB per minute at UHD 25p.
    static func stagingBytes(duration: Double, width: Int, height: Int, frameRate: Double) -> Int64 {
        Int64(5e9 / 60 * duration * pixelRatio(width: width, height: height) * max(1, frameRate / 25))
    }

    /// Seconds of rendering expected per second of footage at UHD: Gyroflow on the GPU and the
    /// LUT pass are each roughly real time; doubled to stay on the safe side.
    static func expectedSeconds(duration: Double, width: Int, height: Int, frameRate: Double,
                                stabilize: Bool, lut: Bool) -> Double {
        let scale = duration * pixelRatio(width: width, height: height) * max(1, frameRate / 30)
        return scale * ((stabilize ? 2.0 : 0) + (lut ? 1.5 : 0))
    }

    /// How long a child may go without output or file growth before it counts as stuck. Gyroflow
    /// spends a while loading lens profiles and syncing before the first frame, so this is
    /// generous: at least two minutes, or four times the expected render.
    static func stallTimeout(expectedSeconds: Double) -> TimeInterval {
        max(120, 4 * expectedSeconds)
    }

    /// Absolute ceiling, for a child that keeps printing but never finishes.
    static func hardTimeout(expectedSeconds: Double) -> TimeInterval {
        max(1800, 30 * expectedSeconds)
    }

    // MARK: Helpers

    static func json(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
