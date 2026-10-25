import Foundation

public enum StabilizedOutputs {
    /// Original clip → finished output, from `<outputRoot>/对照表.json`. Only entries whose output
    /// still exists count, so a deleted result falls back to the original.
    public static func load(outputRoot: URL) -> [URL: URL] {
        var result: [URL: URL] = [:]
        for entry in StabilizeMap(outputRoot: outputRoot).entries where entry.status == "done" || entry.status == "alreadyDone" {
            guard let output = entry.output, FileManager.default.fileExists(atPath: output) else { continue }
            result[URL(fileURLWithPath: entry.original).standardizedFileURL] = URL(fileURLWithPath: output)
        }
        return result
    }
}
