import Foundation
import LightTableKit
import TravelCutCore

/// Choices LightTable remembers between runs. Stored in UserDefaults under `LightTable.*`.
struct Preferences {
    private static let defaults = UserDefaults.standard

    /// Folder of `.cube` files, chosen the first time grading is needed.
    static var lutFolder: URL? {
        get { defaults.string(forKey: "LightTable.lutFolder").map { URL(fileURLWithPath: $0) } }
        set { defaults.set(newValue?.path, forKey: "LightTable.lutFolder") }
    }

    /// LUT used last time for each profile; shown as「上次用的」, never applied automatically.
    static func lastLUT(for profile: ColorProfile) -> URL? {
        defaults.string(forKey: "LightTable.lastLUT.\(profile.rawValue)").map { URL(fileURLWithPath: $0) }
    }

    static func setLastLUT(_ lut: URL?, for profile: ColorProfile) {
        defaults.set(lut?.path, forKey: "LightTable.lastLUT.\(profile.rawValue)")
    }

    /// Camera model → profile the user assigned when detection could not tell (e.g. V-Log).
    static var cameraProfiles: [String: ColorProfile] {
        get {
            let raw = defaults.dictionary(forKey: "LightTable.cameraProfiles") as? [String: String] ?? [:]
            return raw.compactMapValues(ColorProfile.init(rawValue:))
        }
        set { defaults.set(newValue.mapValues(\.rawValue), forKey: "LightTable.cameraProfiles") }
    }

    static var themes: Set<HighlightTheme> {
        get {
            guard let saved = defaults.stringArray(forKey: "LightTable.themes") else { return HighlightTheme.defaultSelection }
            let themes = Set(saved.compactMap(HighlightTheme.init(rawValue:)))
            return themes.isEmpty ? HighlightTheme.defaultSelection : themes
        }
        set { defaults.set(HighlightTheme.allCases.filter(newValue.contains).map(\.rawValue), forKey: "LightTable.themes") }
    }

    static func bool(_ key: String, default value: Bool = false) -> Bool {
        defaults.object(forKey: "LightTable.\(key)") as? Bool ?? value
    }

    static func setBool(_ value: Bool, _ key: String) {
        defaults.set(value, forKey: "LightTable.\(key)")
    }

    static func double(_ key: String) -> Double? {
        defaults.object(forKey: "LightTable.\(key)") as? Double
    }

    static func setDouble(_ value: Double?, _ key: String) {
        defaults.set(value, forKey: "LightTable.\(key)")
    }
}
