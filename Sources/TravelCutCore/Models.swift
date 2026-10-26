import AVFoundation
import Foundation
import Vision

/// What the user wants to keep. The same names as the shooting-habit categories (minus 静物与微距,
/// plus the travel-only 沿途风景), so video highlights, photo-grouping keywords and the habit
/// report speak one vocabulary.
public enum HighlightTheme: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case people = "人像"
    case street = "街头人文"
    case cultureActivity = "活动与运动"
    case food = "美食"
    case flowers = "花卉植物"
    case animals = "动物"
    case vehicles = "交通工具"
    case night = "夜景与星空"
    case interior = "室内与展馆"
    case city = "城市与建筑"
    case nature = "自然风光"
    case roadScenery = "沿途风景"

    public var id: String { rawValue }

    public static var defaultSelection: Set<HighlightTheme> {
        Set(allCases)
    }

    /// Names used before LightTable unified the vocabulary (TravelCut 0.8.0 and earlier), kept so
    /// checkpoints, caches and saved choices from then still load.
    static let legacyNames: [String: HighlightTheme] = [
        "自然景观": .nature, "城市街景": .city, "地标建筑": .city,
        "人物互动": .people, "当地美食": .food, "活动人文": .cultureActivity,
    ]

    /// Current or legacy name.
    public init?(named name: String) {
        if let theme = HighlightTheme(rawValue: name) ?? Self.legacyNames[name] { self = theme } else { return nil }
    }

    public init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        guard let theme = HighlightTheme(named: name) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown theme \(name)"))
        }
        self = theme
    }

    /// Three short prompts per theme; a frame takes the best of them. CLIP matches one clear
    /// concept better than a long list, and an equal count keeps themes on an even footing.
    var mobileCLIPPrompts: [String] {
        switch self {
        case .people:
            return ["friends or family smiling together on a trip", "a candid photo of people talking and laughing",
                    "a group of people posing for a photo"]
        case .street:
            return ["everyday street life with locals walking by", "a busy local market with street vendors",
                    "people in a narrow old town street"]
        case .cultureActivity:
            return ["a concert or a stage performance", "a festival parade or a light show",
                    "people playing a sport or a fun activity"]
        case .food:
            return ["a plate of local food on a restaurant table", "street food at a market stall",
                    "a dessert or a cup of coffee in a cafe"]
        case .flowers:
            return ["a close-up photo of a flower", "a field of blooming flowers or cherry blossoms",
                    "green leaves, a cactus or autumn foliage"]
        case .animals:
            return ["a wild animal in nature", "a bird", "a pet dog or cat, or farm animals"]
        case .vehicles:
            return ["a train or a tram", "a boat or a ferry on the water", "an airplane, a cable car or a classic car"]
        case .night:
            return ["a city at night with bright lights", "a starry night sky or the milky way",
                    "the northern lights or fireworks in the night sky"]
        case .interior:
            return ["the interior of a museum or an art gallery", "the inside of a church or a palace hall",
                    "a beautiful hotel room interior"]
        case .city:
            return ["a famous landmark or historic building", "an old town square with beautiful architecture",
                    "a city skyline"]
        case .nature:
            return ["a landscape with mountains and lakes", "a coastline with the sea and beach",
                    "a forest, waterfall or snowy landscape at sunrise or sunset"]
        case .roadScenery:
            return ["scenery filmed through a car or train window", "a road trip view of the highway ahead",
                    "the view from a boat during a journey"]
        }
    }

    var qwenGuidance: String {
        switch self {
        case .people:
            return "人像：同行者的表情、对话、动作、合影过程和真实情绪"
        case .street:
            return "街头人文：街道、市场、店铺里的当地人和日常生活场景"
        case .cultureActivity:
            return "活动与运动：表演、演唱会、节庆游行、灯光秀、游乐、比赛和运动体验"
        case .food:
            return "美食：餐厅、咖啡馆、市场、菜品、甜品和制作过程"
        case .flowers:
            return "花卉植物：花朵特写、花海、樱花、红叶、植物园和有特色的植物"
        case .animals:
            return "动物：旅途中遇到的野生动物、牧场动物、鸟类和宠物互动"
        case .vehicles:
            return "交通工具：以火车、电车、船、缆车、飞机或特色车辆为主体的画面"
        case .night:
            return "夜景与星空：城市夜景和灯光、星空、银河、极光和烟花"
        case .interior:
            return "室内与展馆：博物馆、美术馆、教堂、宫殿内部和有特色的酒店室内"
        case .city:
            return "城市与建筑：名胜、地标、历史建筑、老城广场和城市天际线"
        case .nature:
            return "自然风光：山川、海岸、湖泊、森林、瀑布、雪景、日出日落"
        case .roadScenery:
            return "沿途风景：公路、步行途中、车窗、火车、船上看到的景色和旅途氛围；只要清晰稳定并能记录路线，即使常见也有保留价值"
        }
    }
}

public struct JobConfiguration: Sendable {
    public let inputFolder: URL
    public let outputFolder: URL
    public let useDeepAnalysis: Bool
    public let deepCandidateFraction: Double
    public let deepFrameCount: Int
    public let selectedThemes: Set<HighlightTheme>
    /// Exact videos to analyse. LightTable passes stabilised outputs plus untouched originals;
    /// nil keeps TravelCut's behaviour of scanning `inputFolder`.
    public let inputFiles: [URL]?
    /// Path → creation time with the camera's UTC offset (`2025:10:26 14:10:41-08:00` or ISO 8601),
    /// read by LightTable from Sony XML or the original clip. Decides the day folder.
    public let captureDates: [String: String]
    /// Stabilised file path → original clip path, recorded in selection.json.
    public let originalSources: [String: String]

    public init(
        inputFolder: URL,
        outputFolder: URL,
        useDeepAnalysis: Bool = true,
        deepCandidateFraction: Double = 0.40,
        deepFrameCount: Int = 10,
        selectedThemes: Set<HighlightTheme> = HighlightTheme.defaultSelection,
        inputFiles: [URL]? = nil,
        captureDates: [String: String] = [:],
        originalSources: [String: String] = [:]
    ) {
        self.inputFiles = inputFiles.map { files in
            files.map(\.standardizedFileURL).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        self.captureDates = captureDates
        self.originalSources = originalSources
        self.inputFolder = inputFolder
        self.outputFolder = outputFolder
        self.useDeepAnalysis = useDeepAnalysis
        self.deepCandidateFraction = min(1, max(0.05, deepCandidateFraction))
        self.deepFrameCount = min(16, max(6, deepFrameCount))
        self.selectedThemes = selectedThemes
    }
}

extension JobConfiguration {
    func sourceURLs() throws -> [URL] {
        if let inputFiles { return inputFiles }
        return try MediaDiscovery.discoverVideos(in: inputFolder, excludingFolders: [outputFolder])
    }
}

public struct ProgressUpdate: Sendable {
    public let fraction: Double
    public let message: String

    public init(fraction: Double, message: String) {
        self.fraction = fraction
        self.message = message
    }
}

public struct JobSummary: Sendable {
    public let outputFolder: URL
    public let reportFile: URL
    public let exportedFiles: [URL]
    public let inputVideoCount: Int
    public let analyzedCandidateCount: Int
    public let selectedClipCount: Int
    public let totalOutputDuration: TimeInterval
    public let advancedModelUsed: String?
}

public struct MediaMetadataRecord: Codable, Hashable, Sendable {
    public let identifier: String?
    public let keySpace: String?
    public let key: String?
    public let value: String?

    public init(identifier: String?, keySpace: String?, key: String?, value: String?) {
        self.identifier = identifier
        self.keySpace = keySpace
        self.key = key
        self.value = value
    }
}

public struct SourceVideo: Codable, Hashable, Sendable {
    public let url: URL
    public let duration: TimeInterval
    public let createdAt: Date
    public let modifiedAt: Date
    public let hasAudio: Bool
    public let width: Int
    public let height: Int
    public let nominalFrameRate: Double
    public let codec: String
    public let isHDR: Bool
    public let fileSize: Int64
    public let metadata: [MediaMetadataRecord]

    public init(
        url: URL,
        duration: TimeInterval,
        createdAt: Date,
        modifiedAt: Date? = nil,
        hasAudio: Bool,
        width: Int = 0,
        height: Int = 0,
        nominalFrameRate: Double = 0,
        codec: String = "unknown",
        isHDR: Bool = false,
        fileSize: Int64 = 0,
        metadata: [MediaMetadataRecord] = []
    ) {
        self.url = url
        self.duration = duration
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
        self.hasAudio = hasAudio
        self.width = width
        self.height = height
        self.nominalFrameRate = nominalFrameRate
        self.codec = codec
        self.isHDR = isHDR
        self.fileSize = fileSize
        self.metadata = metadata
    }
}

public struct CandidatePlan: Equatable, Hashable, Sendable {
    public let sourceIndex: Int
    public let start: TimeInterval
    public let duration: TimeInterval

    public var end: TimeInterval { start + duration }

    public init(sourceIndex: Int, start: TimeInterval, duration: TimeInterval) {
        self.sourceIndex = sourceIndex
        self.start = start
        self.duration = duration
    }
}

public struct DeepAnalysisResult: Codable, Sendable {
    public let keep: Bool
    public let highlightScore: Double
    public let qualityScore: Double
    public let completenessScore: Double
    public let label: String
    public let reason: String
    public let suggestedStart: TimeInterval?
    public let suggestedEnd: TimeInterval?
    /// The selected content type the clip fits best; nil in checkpoints from older versions.
    public let theme: HighlightTheme?

    public init(
        keep: Bool,
        highlightScore: Double,
        qualityScore: Double,
        completenessScore: Double,
        label: String,
        reason: String,
        suggestedStart: TimeInterval? = nil,
        suggestedEnd: TimeInterval? = nil,
        theme: HighlightTheme? = nil
    ) {
        self.keep = keep
        self.highlightScore = min(1, max(0, highlightScore))
        self.qualityScore = min(1, max(0, qualityScore))
        self.completenessScore = min(1, max(0, completenessScore))
        self.label = label
        self.reason = reason
        self.suggestedStart = suggestedStart
        self.suggestedEnd = suggestedEnd
        self.theme = theme
    }
}

struct AudioEvent: Sendable {
    let start: TimeInterval
    let duration: TimeInterval
    let identifier: String
    let confidence: Double

    var end: TimeInterval { start + duration }
}

struct AudioSummary: Sendable {
    let score: Double
    let labels: [String]

    static let unavailable = AudioSummary(score: 0.5, labels: [])
}

public final class HighlightCandidate: @unchecked Sendable {
    public let source: SourceVideo
    public let sourceIndex: Int
    public let start: TimeInterval
    public let duration: TimeInterval
    public let score: Double
    public let aestheticScore: Double
    public let technicalScore: Double
    public let brightness: Double
    public let faceCount: Int
    public let faceQuality: Double
    public let isUtilityImage: Bool
    public let labels: [String]
    public let semanticScore: Double
    public let semanticLabel: String
    /// Content type used to name and sort the exported clip.
    public let theme: HighlightTheme?
    public let audioScore: Double
    public let audioLabels: [String]
    public let deepAnalysis: DeepAnalysisResult?
    let featurePrint: VNFeaturePrintObservation?
    let semanticEmbedding: [Float]?

    public var end: TimeInterval { start + duration }

    init(
        source: SourceVideo,
        sourceIndex: Int,
        start: TimeInterval,
        duration: TimeInterval,
        score: Double,
        aestheticScore: Double,
        technicalScore: Double,
        brightness: Double,
        faceCount: Int,
        faceQuality: Double,
        isUtilityImage: Bool,
        labels: [String],
        semanticScore: Double,
        semanticLabel: String,
        theme: HighlightTheme? = nil,
        audioScore: Double = 0.5,
        audioLabels: [String] = [],
        deepAnalysis: DeepAnalysisResult? = nil,
        featurePrint: VNFeaturePrintObservation?,
        semanticEmbedding: [Float]?
    ) {
        self.source = source
        self.sourceIndex = sourceIndex
        self.start = start
        self.duration = duration
        self.score = score
        self.aestheticScore = aestheticScore
        self.technicalScore = technicalScore
        self.brightness = brightness
        self.faceCount = faceCount
        self.faceQuality = faceQuality
        self.isUtilityImage = isUtilityImage
        self.labels = labels
        self.semanticScore = semanticScore
        self.semanticLabel = semanticLabel
        self.theme = theme
        self.audioScore = audioScore
        self.audioLabels = audioLabels
        self.deepAnalysis = deepAnalysis
        self.featurePrint = featurePrint
        self.semanticEmbedding = semanticEmbedding
    }

    func applying(
        _ result: DeepAnalysisResult,
        start: TimeInterval,
        duration: TimeInterval
    ) -> HighlightCandidate {
        let combinedScore = 0.35 * score
            + 0.35 * result.highlightScore
            + 0.15 * result.qualityScore
            + 0.15 * result.completenessScore
        return HighlightCandidate(
            source: source,
            sourceIndex: sourceIndex,
            start: start,
            duration: duration,
            score: combinedScore,
            aestheticScore: aestheticScore,
            technicalScore: technicalScore,
            brightness: brightness,
            faceCount: faceCount,
            faceQuality: faceQuality,
            isUtilityImage: isUtilityImage,
            labels: labels,
            semanticScore: semanticScore,
            semanticLabel: result.label,
            theme: result.theme ?? theme,
            audioScore: audioScore,
            audioLabels: audioLabels,
            deepAnalysis: result,
            featurePrint: featurePrint,
            semanticEmbedding: semanticEmbedding
        )
    }

    func applying(_ audio: AudioSummary) -> HighlightCandidate {
        HighlightCandidate(
            source: source,
            sourceIndex: sourceIndex,
            start: start,
            duration: duration,
            score: score * 0.88 + audio.score * 0.12,
            aestheticScore: aestheticScore,
            technicalScore: technicalScore,
            brightness: brightness,
            faceCount: faceCount,
            faceQuality: faceQuality,
            isUtilityImage: isUtilityImage,
            labels: labels,
            semanticScore: semanticScore,
            semanticLabel: semanticLabel,
            theme: theme,
            audioScore: audio.score,
            audioLabels: audio.labels,
            deepAnalysis: deepAnalysis,
            featurePrint: featurePrint,
            semanticEmbedding: semanticEmbedding
        )
    }
}

struct ExportedClip: Codable, Sendable {
    let outputFile: String
    let sourceFile: String
    let sourceCreatedAt: Date
    let sourceModifiedAt: Date
    let startSeconds: Double
    let durationSeconds: Double
    let score: Double
    let semanticLabel: String
    let reason: String?
    /// Added in 0.4.0; absent in older checkpoints.
    let theme: String?
    let clipStartedAt: Date?
    let dayFolder: String?
    let width: Int
    let height: Int
    let nominalFrameRate: Double
    let codec: String
    let hdr: Bool
    let hasAudio: Bool
    let audioLabels: [String]
    let sourceMetadata: [MediaMetadataRecord]
    /// The camera original when `sourceFile` is a stabilised copy. Absent before LightTable.
    var originalSourceFile: String? = nil
}

struct SelectionReport: Codable, Sendable {
    let generatedAt: Date
    let inputFolder: String
    let outputFolder: String
    let analyzedVideos: Int
    let analyzedCandidates: Int
    let advancedModel: String?
    let selectedThemes: [String]
    let totalOutputDurationSeconds: Double
    let exportedClips: [ExportedClip]
}

public enum TravelCutError: LocalizedError {
    case noVideos
    case noUsableVideos
    case noCandidates
    case noHighlights
    case cannotCreateExporter
    case outputAlreadyExists(String)
    case exportFailed(String)
    case modelUnavailable(String)
    case modelResponseInvalid
    case invalidArguments(String)
    case insufficientOutputSpace(requiredGB: Double, availableGB: Double)

    public var errorDescription: String? {
        switch self {
        case .noVideos: return "所选文件夹中没有找到支持的视频。"
        case .noUsableVideos: return "没有可读取的视频。"
        case .noCandidates: return "没有生成可分析的候选事件。"
        case .noHighlights: return "这批素材中没有找到达到保留标准的高光片段。"
        case .cannotCreateExporter: return "无法创建保持原始规格的导出器。"
        case .outputAlreadyExists(let path): return "输出文件已存在：\(path)"
        case .exportFailed(let reason): return "导出失败：\(reason)"
        case .modelUnavailable(let reason): return "本地模型不可用：\(reason)"
        case .modelResponseInvalid: return "Qwen3-VL 返回了无法解析的分析结果。"
        case .invalidArguments(let reason): return reason
        case .insufficientOutputSpace(let required, let available):
            return String(
                format: "输出磁盘空间不足：预计还需要 %.1f GB（含安全余量），当前约有 %.1f GB。筛选结果已保存；清理空间后再次运行会直接继续导出。",
                required,
                available
            )
        }
    }
}
