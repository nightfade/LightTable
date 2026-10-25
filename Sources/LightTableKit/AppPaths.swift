import Foundation

/// Where LightTable keeps models, downloaded data and run state.
public enum AppPaths {
    public static let folderName = "LightTable"
    /// TravelCut kept the same model files here; reused instead of downloading 3 GB again.
    static let legacyFolderName = "TravelCut"

    /// `~/Library/Application Support/LightTable`; nil only if the system cannot provide Application Support.
    public static var applicationSupport: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// Subfolder of Application Support, e.g. `Models` or `Geo`. Contents from TravelCut are
    /// brought over the first time the folder is asked for.
    public static func supportFolder(_ name: String) -> URL? {
        guard let root = applicationSupport else { return nil }
        let folder = root.appendingPathComponent(name, isDirectory: true)
        adoptLegacy(name, into: folder)
        return folder
    }

    /// Copies TravelCut's folder of the same name when LightTable has none yet. On APFS
    /// `copyItem` clones, so multi-gigabyte models take no extra space or time. TravelCut keeps
    /// its own copy and still works.
    static func adoptLegacy(_ name: String, into folder: URL) {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: folder.path),
              let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }
        let legacy = base.appendingPathComponent(legacyFolderName, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        guard manager.fileExists(atPath: legacy.path) else { return }
        try? manager.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? manager.copyItem(at: legacy, to: folder)
    }
}
