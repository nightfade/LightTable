import Foundation

enum TravelCutResources {
    static let bundle: Bundle? = {
        // SwiftPM names the bundle after the package; it was TravelCut_… before the move.
        let bundleName = "LightTable_TravelCutCore.bundle"
        let executableFolder = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
            executableFolder.appendingPathComponent(bundleName),
            // lighttable-cli inside the app lives in Contents/Helpers.
            executableFolder.deletingLastPathComponent().appendingPathComponent("Resources/\(bundleName)"),
        ].compactMap { $0 }

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }()
}
