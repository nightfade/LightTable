import Foundation
import LightTableKit

// Public surface the App and CLI build against. Implementation lives in the other files of
// this module; keep these names and shapes stable.

public enum GyroflowStatus: Equatable, Sendable {
    case ready(executable: URL, version: String)
    case missing
    /// Mac App Store build: sandboxed, its CLI cannot be driven by other programs.
    case appStore(app: URL)
    case broken(app: URL, detail: String)
}

public struct StabilizeJob: Sendable, Identifiable {
    public var id: String { source.relativePath }
    public let source: ScannedVideo
    /// Profile after the user's per-camera override; decides output colour tags.
    public let profile: ColorProfile
    public let stabilize: Bool
    /// nil: no grading.
    public let lut: URL?

    public init(source: ScannedVideo, profile: ColorProfile, stabilize: Bool, lut: URL?) {
        self.source = source
        self.profile = profile
        self.stabilize = stabilize
        self.lut = lut
    }
}

public struct StabilizeSettings: Sendable {
    /// Folder the sources were scanned from; output mirrors paths relative to it.
    public var sourceRoot: URL
    /// `<output>/LightTable 增稳`.
    public var outputRoot: URL
    /// Cap on the stabilisation crop as a zoom percentage (117.6 ≈ 15 % crop). nil: Gyroflow default.
    public var maxZoom: Double?
    /// Target bitrate in Mbps; nil scales with resolution.
    public var bitrateMbps: Double?
    /// Rolling-shutter readout time in ms; nil leaves correction off.
    public var readoutTime: Double?
    public var gyroflow: URL?
    /// Clips run one at a time; Gyroflow already saturates the GPU. Kept for the 高级 page.
    public var jobs: Int = 1
    public var codec: StabilizeCodec = .hevc
    /// Stall and stop timings; the defaults scale with each clip, tests shorten them.
    public var timing = StabilizeTiming()
    /// Tool overrides, mainly for tests. nil: `Tools.find`.
    public var ffmpeg: URL?
    public var ffprobe: URL?
    public var exiftool: URL?
    /// Free bytes on the volume holding a URL. nil: ask the file system. Tests inject a fake.
    public var freeSpaceProbe: (@Sendable (URL) -> Int64?)?

    public init(sourceRoot: URL, outputRoot: URL) {
        self.sourceRoot = sourceRoot
        self.outputRoot = outputRoot
    }
}

/// Delivery codec. VideoToolbox only, so the bundled LGPL ffmpeg suffices.
public enum StabilizeCodec: String, Sendable, CaseIterable {
    case hevc, h264
}

public struct StabilizeTiming: Sendable {
    /// Seconds without output or file growth before a child counts as stuck. nil: scaled by clip
    /// duration and resolution (at least two minutes).
    public var stallTimeout: TimeInterval?
    /// Total time allowed per child. nil: scaled by clip.
    public var hardTimeout: TimeInterval?
    /// Quiet time before `.quiet` events start. nil: a quarter of the stall timeout, at most 30 s.
    public var quietAfter: TimeInterval?
    public var heartbeatInterval: TimeInterval = 1
    public var terminationGrace: TimeInterval = 5
    public var killGrace: TimeInterval = 3
    /// Time allowed for `gyroflow --version` and other short probes.
    public var probeTimeout: TimeInterval = 60

    public init() {}
}

public enum ClipStatus: Equatable, Sendable {
    case done
    /// A complete output already existed from an earlier run.
    case alreadyDone
    case skipped(String)
    case failed(String)
}

public struct ClipResult: Sendable {
    public let job: StabilizeJob
    public let output: URL?
    public let status: ClipStatus
    /// Problems that did not fail the clip, e.g. the creation date could not be written back.
    public var warnings: [String] = []
}

public enum StabilizeEvent: Sendable {
    case clipStarted(index: Int, total: Int, name: String)
    /// overall: whole batch 0…1; clip: current clip 0…1 when known.
    case progress(overall: Double, clip: Double?, message: String)
    /// The current child has made no progress for `seconds`; UI offers 跳过这段 / 再等等.
    case quiet(name: String, seconds: TimeInterval)
    case clipFinished(ClipResult)
    /// Source or output volume vanished, or space ran out; the batch waits for `resume()`.
    case paused(reason: String)
    case resumed
}

public struct StabilizeSummary: Sendable {
    public let results: [ClipResult]
    /// `LightTable 增稳/对照表.json`: original ↔ output, model, gamma, zoned capture date.
    public let mapFile: URL?
    public let stopped: Bool

    public var outputsByOriginal: [URL: URL] {
        Dictionary(uniqueKeysWithValues: results.compactMap { result in result.output.map { (result.job.source.url, $0) } })
    }
}

public struct StabilizeEstimate: Sendable {
    public let seconds: TimeInterval
    public let finalBytes: Int64
    /// Largest extra space needed at any moment (output + ProRes staging of the clips in flight).
    public let peakBytes: Int64
    public let availableBytes: Int64?
}
