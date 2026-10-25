import Foundation

/// What the footage was shot as, which decides which LUTs make sense for it.
public enum ColorProfile: String, Codable, CaseIterable, Sendable, Identifiable {
    case sLog2, sLog3, vLog, hlg, pq, rec709, unknown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sLog2: "S-Log2"
        case .sLog3: "S-Log3"
        case .vLog: "V-Log"
        case .hlg: "HLG"
        case .pq: "HDR（PQ）"
        case .rec709: "普通画面（709）"
        case .unknown: "未识别"
        }
    }

    /// Log footage looks washed out until graded, so it needs a LUT.
    public var isLog: Bool { self == .sLog2 || self == .sLog3 || self == .vLog }
}

public struct ScannedVideo: Codable, Equatable, Sendable, Identifiable {
    public var id: String { relativePath }
    public let url: URL
    public let relativePath: String
    public let duration: Double
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let codec: String
    /// Timed-metadata track Gyroflow can stabilise from: `rtmd` (Sony), `gpmd` (GoPro), `camm`.
    public let gyroFormat: String?
    public let cameraModel: String?
    /// Detected profile before any per-camera override from the user.
    public let detectedProfile: ColorProfile
    /// Creation time with the camera's UTC offset, e.g. `2025:10:26 14:10:41-08:00`.
    /// Gyroflow keeps only the UTC time, so this is written back onto its output.
    public let creationDate: String?
    public let colorRange: String?
    public let colorSpace: String?
    public let colorPrimaries: String?
    public let colorTransfer: String?
    public let size: Int64

    public var canStabilize: Bool { gyroFormat != nil }
}

public struct ScanResult: Sendable {
    public let root: URL
    public let videos: [ScannedVideo]
    public let photos: [URL]
    /// Videos ffprobe could not read; listed so the user sees they were skipped.
    public let unreadable: [URL]

    public var stabilizableCount: Int { videos.filter(\.canStabilize).count }
}

public enum MediaScanner {
    public static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mts", "m2ts", "avi", "mxf", "insv", "360"]
    public static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "tif", "tiff", "png", "dng",
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "rw2", "orf", "pef", "srw", "x3f", "3fr", "iiq", "rwl",
    ]
    static let gyroTags: Set<String> = ["rtmd", "gpmd", "camm"]
    /// LightTable's and the old tools' output folders; scanning them would process results again.
    public static let excludedFolderNames: Set<String> = [
        "LightTable 增稳", "LightTable 高光", "LightTable 日志", "TravelCut 高光片段", "gyroflow_stabilized", "_runs",
    ]
    /// Brands whose cameras can record log without a marker we know how to read. Their unmarked
    /// footage is "未识别" instead of being assumed to be normal 709.
    static let logCapableBrands = ["panasonic", "fujifilm", "canon", "nikon", "dji", "blackmagic", "sony", "z cam",
                                   "zv-", "ilce-", "ilme-", "dc-", "x-t", "x-h", "x-s", "eos"]

    /// Lists media files under `root`, skipping hidden folders and LightTable's own output.
    public static func listFiles(in root: URL) -> (videos: [URL], photos: [URL]) {
        var videos: [URL] = []
        var photos: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return ([], []) }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if excludedFolderNames.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true, !url.lastPathComponent.hasPrefix("._") else { continue }
            let ext = url.pathExtension.lowercased()
            if videoExtensions.contains(ext) { videos.append(url) } else if photoExtensions.contains(ext) { photos.append(url) }
        }
        let byPath: (URL, URL) -> Bool = { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return (videos.sorted(by: byPath), photos.sorted(by: byPath))
    }

    /// Probes every video. `progress` gets (done, total).
    public static func scan(_ root: URL, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> ScanResult {
        let (videoURLs, photos) = listFiles(in: root)
        guard !videoURLs.isEmpty else { return ScanResult(root: root, videos: [], photos: photos, unreadable: []) }
        guard let ffprobe = Tools.find(.ffprobe) else { throw ToolError.missing("ffprobe") }
        let metadata = Tools.find(.exiftool).map { exiftoolMetadata(for: videoURLs, exiftool: $0) } ?? [:]

        let counter = Counter()
        var probed: [Int: ScannedVideo] = [:]
        var unreadable: [URL] = []
        try await withThrowingTaskGroup(of: (Int, ScannedVideo?).self) { group in
            var next = 0
            func add() {
                guard next < videoURLs.count else { return }
                let index = next
                next += 1
                group.addTask {
                    let video = try? probe(videoURLs[index], root: root, ffprobe: ffprobe, metadata: metadata[videoURLs[index].path])
                    progress?(counter.increment(), videoURLs.count)
                    return (index, video)
                }
            }
            for _ in 0..<4 { add() }
            while let (index, video) = try await group.next() {
                if let video { probed[index] = video } else { unreadable.append(videoURLs[index]) }
                add()
            }
        }
        let videos = probed.sorted { $0.key < $1.key }.map(\.value)
        return ScanResult(root: root, videos: videos, photos: photos, unreadable: unreadable)
    }

    struct CameraMetadata {
        var model: String?
        var make: String?
        var gamma: String?
        var creationDate: String?
    }

    static func probe(_ url: URL, root: URL, ffprobe: URL, metadata: CameraMetadata?) throws -> ScannedVideo {
        let output = try Tools.run(ffprobe, [
            "-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path,
        ], timeout: 60)
        guard let json = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]],
              let video = streams.first(where: { $0["codec_type"] as? String == "video" })
        else { throw ToolError.failed("ffprobe", "没有视频轨", url.lastPathComponent) }
        let format = json["format"] as? [String: Any] ?? [:]

        let gyro = streams.lazy.compactMap { stream -> String? in
            let tag = (stream["codec_tag_string"] as? String ?? "").lowercased()
            if gyroTags.contains(tag) { return tag }
            let handler = ((stream["tags"] as? [String: Any])?["handler_name"] as? String ?? "").lowercased()
            return handler.contains("gopro met") ? "gpmd" : nil
        }.first

        let transfer = video["color_transfer"] as? String
        let profile = classify(gamma: metadata?.gamma, transfer: transfer,
                               brand: metadata?.make ?? metadata?.model ?? (format["tags"] as? [String: Any])?["com.apple.quicktime.make"] as? String)
        let size = Int64(format["size"] as? String ?? "") ?? ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0)
        return ScannedVideo(
            url: url,
            relativePath: relativePath(of: url, in: root),
            duration: Double(format["duration"] as? String ?? video["duration"] as? String ?? "") ?? 0,
            width: video["width"] as? Int ?? 0,
            height: video["height"] as? Int ?? 0,
            frameRate: rational(video["avg_frame_rate"] as? String) ?? rational(video["r_frame_rate"] as? String) ?? 0,
            codec: video["codec_name"] as? String ?? "",
            gyroFormat: gyro,
            cameraModel: metadata?.model,
            detectedProfile: profile,
            creationDate: metadata?.creationDate,
            colorRange: video["color_range"] as? String,
            colorSpace: video["color_space"] as? String,
            colorPrimaries: video["color_primaries"] as? String,
            colorTransfer: transfer,
            size: size
        )
    }

    /// Sony writes the capture gamma into its XML; HLG and PQ are tagged on the stream itself.
    public static func classify(gamma: String?, transfer: String?, brand: String?) -> ColorProfile {
        if let gamma = gamma?.lowercased() {
            if gamma.contains("s-log3") || gamma.contains("slog3") { return .sLog3 }
            if gamma.contains("s-log2") || gamma.contains("slog2") { return .sLog2 }
            if gamma.contains("v-log") || gamma.contains("vlog") { return .vLog }
            if gamma.contains("hlg") { return .hlg }
            return .rec709
        }
        switch transfer {
        case "arib-std-b67": return .hlg
        case "smpte2084": return .pq
        default: break
        }
        if let brand = brand?.lowercased(), logCapableBrands.contains(where: { brand.contains($0) }) {
            // A Sony or ZV clip without its XML could be anything; let the user decide.
            let sony = ["sony", "zv-", "ilce-", "ilme-"].contains { brand.contains($0) }
            return transfer == "bt709" && !sony ? .rec709 : .unknown
        }
        return .rec709
    }

    /// One exiftool call for all videos: camera model, capture gamma and zoned creation date.
    static func exiftoolMetadata(for videos: [URL], exiftool: URL) -> [String: CameraMetadata] {
        var result: [String: CameraMetadata] = [:]
        for batch in stride(from: 0, to: videos.count, by: 200).map({ Array(videos[$0..<min($0 + 200, videos.count)]) }) {
            let arguments = ["-j", "-q", "-q", "-n", "-api", "LargeFileSupport=1",
                             "-XML:DeviceModelName", "-XML:DeviceManufacturer", "-XML:CreationDateValue",
                             "-XML:AcquisitionRecordGroupItemName", "-XML:AcquisitionRecordGroupItemValue",
                             "-QuickTime:Model", "-QuickTime:Make", "-QuickTime:CreationDate",
                             "-Keys:CreationDate", "-UserData:Make", "-UserData:Model"]
                + batch.map(\.path)
            guard let output = try? Tools.run(exiftool, arguments, timeout: 600),
                  let rows = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]]
            else { continue }
            for row in rows {
                guard let path = row["SourceFile"] as? String else { continue }
                result[path] = parseMetadata(row)
            }
        }
        return result
    }

    static func parseMetadata(_ row: [String: Any]) -> CameraMetadata {
        func string(_ key: String) -> String? {
            switch row[key] {
            case let value as String: value.isEmpty ? nil : value
            case let value as NSNumber: value.stringValue
            default: nil
            }
        }
        func list(_ key: String) -> [String] {
            switch row[key] {
            case let values as [Any]: values.map { "\($0)" }
            case let value?: ["\(value)"]
            default: []
            }
        }
        var gamma: String?
        let names = list("AcquisitionRecordGroupItemName")
        let values = list("AcquisitionRecordGroupItemValue")
        for (name, value) in zip(names, values) where name == "CaptureGammaEquation" { gamma = value }
        return CameraMetadata(
            model: string("DeviceModelName") ?? string("Model"),
            make: string("DeviceManufacturer") ?? string("Make"),
            gamma: gamma,
            creationDate: string("CreationDateValue") ?? string("CreationDate")
        )
    }

    public static func relativePath(of url: URL, in root: URL) -> String {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base) else { return url.lastPathComponent }
        return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func rational(_ text: String?) -> Double? {
        guard let parts = text?.split(separator: "/"), parts.count == 2,
              let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator != 0
        else { return nil }
        return numerator / denominator
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
