import Foundation
import LightTableKit

/// `LightTable 增稳/对照表.json`. Gyroflow drops the camera model, capture gamma and time zone, so
/// this file is where the highlight step and the user find which original a result came from.
/// Rewritten after every clip, so a crash leaves it current; entries from earlier runs are kept.
struct StabilizeMap {
    struct Entry: Codable, Equatable {
        var original: String
        var output: String?
        var cameraModel: String?
        var detectedProfile: String
        var usedProfile: String
        var stabilized: Bool
        var lut: String?
        var creationDate: String?
        /// done / alreadyDone / skipped / failed
        var status: String
        var detail: String?
        var updatedAt: String
    }

    struct File: Codable {
        var version = 1
        var entries: [Entry]
    }

    let url: URL
    private(set) var entries: [Entry]

    init(outputRoot: URL) {
        url = outputRoot.appendingPathComponent("对照表.json")
        entries = (try? JSONDecoder().decode(File.self, from: Data(contentsOf: url)))?.entries ?? []
    }

    mutating func record(_ result: ClipResult, stabilized: Bool) {
        let job = result.job
        let (status, detail): (String, String?) = switch result.status {
        case .done: ("done", nil)
        case .alreadyDone: ("alreadyDone", nil)
        case .skipped(let why): ("skipped", why)
        case .failed(let why): ("failed", why)
        }
        let entry = Entry(
            original: job.source.url.path,
            output: result.output?.path,
            cameraModel: job.source.cameraModel,
            detectedProfile: job.source.detectedProfile.rawValue,
            usedProfile: job.profile.rawValue,
            stabilized: stabilized,
            lut: job.lut?.path,
            creationDate: job.source.creationDate,
            status: status,
            detail: detail,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
        if let index = entries.firstIndex(where: { $0.original == entry.original }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    func write() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(File(entries: entries)).write(to: url, options: .atomic)
    }
}
