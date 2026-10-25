import Foundation
import LightTableKit

// Public surface the App and CLI build against. Keep these names and shapes stable.

public enum ContentMode: String, Sendable, CaseIterable {
    /// MobileCLIP when its model is installed or can be downloaded, else metadata only.
    case auto
    /// Must look at the images.
    case clip
    /// Keywords, folder names, scene mode and faces only. Used for parity with photo-habits.
    case meta
}

public struct HabitsOptions: Sendable {
    public var root: URL
    /// The HTML report, normally `<root>/LightTable 拍摄习惯.html`.
    public var outputHTML: URL
    public var excludeDirs: [String] = []
    public var includeExports = false
    public var includePhones = false
    public var content: ContentMode = .auto
    /// Where EXIF rows, MobileCLIP results and `stats.json` are kept. nil: `<root>/.lighttable-cache`,
    /// or a folder under `~/Library/Caches/LightTable` when the root is read-only.
    public var cacheDirectory: URL? = nil

    public init(root: URL, outputHTML: URL) {
        self.root = root
        self.outputHTML = outputHTML
    }
}

public struct HabitsSummary: Sendable {
    public let htmlFile: URL
    /// Photos after dedup and filters, i.e. what the statistics cover.
    public let photoCount: Int
    public let scannedFiles: Int
    public let categoryCounts: [String: Int]
    /// Every number in the report, machine-readable; used for the parity test with photo-habits.
    public var statsFile: URL? = nil
    /// Whether MobileCLIP looked at any image this run (false in `.meta`, or when the model is missing).
    public var clipUsed = false
}
