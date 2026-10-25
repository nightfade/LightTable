import Foundation

/// Whether the downloadable models are already on this Mac, so the UI can say before starting
/// how much has to be downloaded.
public enum ModelStatus {
    /// Qwen3-VL-4B, about 2.95 GB: deep highlight judgement and optional photo labels.
    public static var qwenInstalled: Bool { isInstalled(ModelInstaller.qwen) }
    /// MobileCLIP-S2, about 199 MB: highlight pre-filter, photo themes, habit categories.
    public static var mobileCLIPInstalled: Bool { isInstalled(ModelInstaller.mobileCLIP) }

    public static let qwenDownloadGB = 2.95
    public static let mobileCLIPDownloadGB = 0.2

    static func isInstalled(_ set: ModelInstaller.ModelSet) -> Bool {
        guard let directory = ModelInstaller.installedDirectory(for: set) else { return false }
        return set.files.allSatisfy { file in
            let size = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file.name).path)[.size] as? Int64) ?? nil
            return size == file.size
        }
    }
}
