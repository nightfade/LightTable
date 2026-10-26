import CoreGraphics
import Foundation
import ImageIO
import LightTableKit
import TravelCutCore

/// Subject categories and how a photo gets one: keywords → folder names → MobileCLIP → camera
/// scene mode and faces, the first that answers wins (photo-habits order).
public enum HabitCategories {
    /// (name, keyword and folder aliases, MobileCLIP prompts). Aliases ignore case; English ones
    /// match whole words, Chinese ones substrings, so single characters that occur in unrelated
    /// words (花 in 烟花, 车 in 车站) are avoided. A photo matching several takes the earlier one:
    /// people first, then specific subjects (food, flowers, animals, vehicles), then scenes from
    /// specific to general (night before city, interiors before city, city before nature), so a
    /// flower field is 花卉植物 and a city at night is 夜景与星空.
    static let table: [(String, [String], [String])] = [
        ("人像", ["人像", "肖像", "写真", "合影", "孩子", "宝宝", "家人",
                "portrait", "portraits", "people", "family", "kids", "baby"],
         ["a portrait photo of a person", "a close-up photo of a person's face", "a photo of a child",
          "a photo of a family posing together", "a photo of a kid playing"]),
        ("街头人文", ["街拍", "街头", "扫街", "人文", "street", "streets", "candid"],
         ["a candid street photograph of strangers", "people walking in a crowd on a city sidewalk",
          "a photo of a street vendor", "a photo of a crowded market"]),
        ("活动与运动", ["演出", "演唱会", "音乐会", "比赛", "运动", "体育", "节庆", "庆典", "婚礼", "舞台",
                   "concert", "concerts", "sports", "sport", "festival", "wedding", "performance", "stage"],
         ["a photo of a concert or a stage performance", "a photo of people playing a sport",
          "a photo of a festival parade", "a photo of a wedding ceremony", "a photo of athletes in a race"]),
        ("美食", ["美食", "食物", "菜品", "甜品", "饮品", "咖啡", "food", "dish", "dishes", "meal", "dessert", "coffee"],
         ["a photo of food on a plate", "a photo of a meal on a restaurant table", "a photo of a dessert",
          "a photo of a cup of coffee", "a photo of street food"]),
        ("花卉植物", ["花卉", "鲜花", "植物", "樱花", "赏花", "红叶", "flower", "flowers", "plant", "plants", "botanical"],
         ["a close-up photo of a flower", "a macro photo of a blooming flower", "a photo of a field of flowers",
          "a photo of cherry blossoms", "a close-up photo of a green leaf", "a photo of a cactus or a potted plant",
          "a photo of autumn leaves"]),
        ("动物", ["动物", "鸟类", "宠物", "猫咪", "狗狗", "野生", "动物园", "animal", "animals", "wildlife",
                "bird", "birds", "pet", "pets", "cat", "cats", "dog", "dogs", "zoo"],
         ["a close-up photo of a dog", "a close-up photo of a cat", "a photo of a bird",
          "a wildlife photo of an animal", "a photo of animals at a zoo"]),
        ("交通工具", ["交通工具", "汽车", "火车", "列车", "高铁", "飞机", "航班", "轮船", "游船", "游艇", "地铁", "缆车",
                  "car", "cars", "train", "trains", "plane", "airplane", "aircraft", "ship", "boat", "boats",
                  "subway", "tram", "vehicle", "vehicles"],
         ["a photo of a car", "a photo of a train at a station", "a photo of an airplane",
          "a photo of a boat on the water", "a photo of a tram or a subway train", "a view from an airplane window"]),
        ("夜景与星空", ["夜景", "夜拍", "星空", "银河", "极光", "烟花", "night", "nightscape", "stars",
                   "milky way", "aurora", "astro", "astrophotography", "fireworks"],
         ["a photo of a city at night with lights", "a photo of the starry night sky", "a photo of the milky way",
          "a photo of the northern lights", "a photo of fireworks in the night sky"]),
        ("室内与展馆", ["室内", "博物馆", "美术馆", "展览", "展馆", "酒店", "民宿", "interior", "interiors",
                   "indoor", "museum", "gallery", "exhibition", "hotel"],
         ["a photo of the interior of a museum", "a photo of artworks in a gallery", "a photo of the inside of a church",
          "a photo of a hotel room", "a photo of a cozy living room interior"]),
        ("城市与建筑", ["建筑", "城市", "街景", "architecture", "cityscape", "urban", "buildings", "city"],
         ["a photo of a building facade", "architecture photography", "a photo of a city skyline",
          "a photo of a city street lined with buildings", "a photo of a famous landmark", "a photo of an old town square"]),
        ("自然风光", ["风景", "风光", "自然", "雪山", "海边", "海滩", "湖泊", "峡湾", "日落", "日出",
                  "landscape", "landscapes", "scenery", "nature", "mountain", "mountains", "beach", "lake",
                  "sunset", "sunrise", "fjord"],
         ["a landscape photo of mountains", "a photo of the sea and the coastline", "a photo of a forest",
          "a scenic view of nature under the sky", "a photo of a lake at sunset",
          "a wide view of open countryside with hills and fields", "a photo inside a cave or a canyon",
          "a photo of a snowy landscape"]),
        ("静物与微距", ["静物", "微距", "产品", "物件", "still life", "macro", "product", "products"],
         ["a still life arrangement of man-made objects on a table", "a product photo of a gadget on a plain background",
          "a photo of a toy or a household object", "a photo of a musical instrument", "a photo of sports equipment like a ball"]),
        ("其他", [], ["a photo of a document or a screen", "a blurry out of focus photo",
                     "a screenshot of a phone", "a photo of a receipt or a ticket"]),
    ]
    /// The subject categories the report filter offers: every category except 其他.
    public static let subjects = table.map(\.0).filter { $0 != "其他" }
    /// Camera scene modes LightTable maps to a category when nothing else answers, in order.
    /// Portrait comes first so "Night Portrait" is a portrait.
    static let sceneRules: [(needles: [String], category: String)] = [
        (["portrait"], "人像"),
        (["night", "fireworks", "star"], "夜景与星空"),
        (["sport", "action"], "活动与运动"),
        (["food", "gourmet"], "美食"),
        (["macro", "close"], "静物与微距"),
        (["landscape", "scenery", "beach", "snow", "sunset"], "自然风光"),
    ]
    /// Every category in report order, including 其他 and 未分类.
    public static let all = table.map(\.0) + ["未分类"]

    /// Below this top probability MobileCLIP's answer is not trusted and the photo goes to 其他.
    /// photo-habits used 0.40 for open_clip ViT-B-32 with 6 categories. Re-measured for
    /// MobileCLIP-S2 with the 12 categories on 56 macOS sample pictures (animals, flowers, plants,
    /// objects, instruments, balls, wallpapers): clear subjects score 0.85–1.0; the wrong top
    /// answers (Earth and a sand dollar read as 人像) sit at 0.31–0.39, below 0.45. Generic
    /// close-up prompts in 静物与微距 pulled every flower in, so its prompts describe man-made
    /// objects only. No people, street, food or travel photos were in the sample; re-check on a
    /// real folder with `LIGHTTABLE_HABITS_TUNE` (see HabitsTests).
    public static let clipMinimumProbability = 0.45

    /// Categories whose aliases occur in `s`.
    static func aliasHits(_ s: String) -> [String] {
        let lower = Array(s.lowercased().unicodeScalars)
        var hits: [String] = []
        for (name, aliases, _) in table {
            for alias in aliases where matches(alias, in: lower) {
                hits.append(name)
                break
            }
        }
        return hits
    }

    /// Chinese aliases: substring. ASCII aliases: not preceded or followed by a letter a–z,
    /// so "cat" does not match "location" but does match "cat_2024".
    static func matches(_ alias: String, in text: [Unicode.Scalar]) -> Bool {
        let a = Array(alias.unicodeScalars)
        guard !a.isEmpty, a.count <= text.count else { return false }
        let ascii = alias.unicodeScalars.allSatisfy(\.isASCII)
        func letter(_ c: Unicode.Scalar) -> Bool { ("a"..."z").contains(c) }
        for start in 0...(text.count - a.count) where text[start..<start + a.count].elementsEqual(a) {
            if !ascii { return true }
            if start > 0, letter(text[start - 1]) { continue }
            if start + a.count < text.count, letter(text[start + a.count]) { continue }
            return true
        }
        return false
    }

    static func firstInOrder(_ names: some Sequence<String>) -> String? {
        let set = Set(names)
        return all.first { set.contains($0) }
    }

    /// The user's own signals: keywords first, then the folders below the scanned root,
    /// deepest first. The root's own name does not count.
    static func byTags(_ record: PhotoRecord, root: String) -> (String, String)? {
        if let hit = firstInOrder(record.keywords.flatMap(aliasHits)) { return (hit, "关键词") }
        var dir = (record.path as NSString).deletingLastPathComponent
        if dir.hasPrefix(root) { dir = String(dir.dropFirst(root.count)) }
        for part in dir.split(separator: "/", omittingEmptySubsequences: false).reversed() {
            if let hit = firstInOrder(aliasHits(String(part))) { return (hit, "目录名") }
        }
        return nil
    }

    /// Fallback without image analysis: scene mode, then detected faces (street photos have faces
    /// too, so without looking at the image they can only count as portraits).
    static func byCamera(_ record: PhotoRecord) -> (String, String) {
        let scene = record.scene.lowercased()
        for rule in sceneRules where rule.needles.contains(where: scene.contains) {
            return (rule.category, "相机场景模式")
        }
        if record.faces > 0 { return ("人像", "人脸检测") }
        return ("未分类", "")
    }
}

/// MobileCLIP zero-shot classification with a per-photo cache, so re-generating the report never
/// looks at the same unchanged image twice.
final class ClipClassifier: @unchecked Sendable {
    static let modelName = "MobileCLIP-S2"
    static let batch = 16

    private let encoder: MobileCLIPEncoder
    /// One mean prompt embedding per category, in `HabitCategories.table` order.
    private let textEmbeddings: [[Float]]

    init() throws {
        let encoder = try MobileCLIPEncoder()
        self.encoder = encoder
        textEmbeddings = try HabitCategories.table.map { _, _, prompts in
            let vectors = try prompts.map { try encoder.textEmbedding($0) }
            var mean = [Float](repeating: 0, count: vectors[0].count)
            for v in vectors { for i in mean.indices { mean[i] += v[i] } }
            let norm = sqrt(mean.reduce(0) { $0 + $1 * $1 })
            return mean.map { $0 / norm }
        }
    }

    /// Changes whenever the model or prompts change, invalidating cached probabilities.
    static var signature: String {
        let text = modelName + "|" + HabitCategories.table.map { $0.0 + ":" + $0.2.joined(separator: ";") }.joined(separator: "|")
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    /// softmax(100 · cosine) over the seven categories, like open_clip's zero-shot recipe.
    func probabilities(_ image: CGImage) throws -> [String: Double] {
        let e = try encoder.imageEmbedding(image)
        let logits = textEmbeddings.map { t in 100 * Double(zip(e, t).reduce(Float(0)) { $0 + $1.0 * $1.1 }) }
        let top = logits.max() ?? 0
        let exps = logits.map { exp($0 - top) }
        let sum = exps.reduce(0, +)
        var out: [String: Double] = [:]
        for (i, entry) in HabitCategories.table.enumerated() { out[entry.0] = (exps[i] / sum * 10000).rounded() / 10000 }
        return out
    }

    /// Small enough for CLIP's 256 px input, read without decoding the full image. RAW files use
    /// their embedded camera preview, never a full RAW decode.
    static func loadImages(_ records: [PhotoRecord], exiftool: URL?) async -> [CGImage?] {
        var out = [CGImage?](repeating: nil, count: records.count)
        var need: [Int] = []
        for (i, r) in records.enumerated() {
            if r.raw { need.append(i); continue }
            if let image = thumbnail(url: URL(fileURLWithPath: r.path)) { out[i] = image } else { need.append(i) }
        }
        guard !need.isEmpty, let exiftool else { return out }
        let arguments = ["-charset", "filename=utf8", "-j", "-b", "-PreviewImage", "-JpgFromRaw", "-OtherImage", "-ThumbnailImage"]
            + need.map { records[$0].path }
        guard let stdout = try? await ExifScanner.runExiftool(exiftool, arguments, stdoutLimit: 512 << 20),
              case .array(let rows)? = try? ExifJSONParser.parse(Data(stdout.utf8)) else { return out }
        var byPath: [String: Records.Row] = [:]
        for row in rows { let r = Records.Row(row); byPath[r["SourceFile"]?.pythonString ?? ""] = r }
        for i in need {
            guard let row = byPath[records[i].path] else { continue }
            let blobs = row.pairs.compactMap { $0.1.stringValue }.filter { $0.hasPrefix("base64:") }
            guard let largest = blobs.max(by: { $0.count < $1.count }),
                  let data = Data(base64Encoded: String(largest.dropFirst(7)), options: .ignoreUnknownCharacters),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 512,
                  ] as CFDictionary)
            else { continue }
            out[i] = rotate(image, orientation: Int(records[i].orient ?? 1))
        }
        return out
    }

    static func thumbnail(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ] as CFDictionary)
    }

    /// Embedded previews are stored unrotated; apply the RAW's EXIF orientation (3, 6, 8 only).
    static func rotate(_ image: CGImage, orientation: Int) -> CGImage {
        guard [3, 6, 8].contains(orientation) else { return image }
        let swap = orientation != 3
        let w = swap ? image.height : image.width, h = swap ? image.width : image.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        let angle: CGFloat = orientation == 3 ? .pi : orientation == 6 ? -.pi / 2 : .pi / 2
        context.rotate(by: angle)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return context.makeImage() ?? image
    }
}

/// `<cache>/content.json`: MobileCLIP probabilities per photo path, valid while the file's
/// modification time is unchanged and the model and prompts are the same.
struct ContentCache {
    var signature = ClipClassifier.signature
    var photos: [String: (mtime: Int, probs: [String: Double])] = [:]

    static func load(_ url: URL) -> ContentCache {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["signature"] as? String == ClipClassifier.signature,
              let photos = json["photos"] as? [String: [String: Any]]
        else { return ContentCache() }
        var cache = ContentCache()
        for (path, entry) in photos {
            guard let mtime = entry["mtime"] as? Int, let probs = entry["probs"] as? [String: Double] else { continue }
            cache.photos[path] = (mtime, probs)
        }
        return cache
    }

    func save(_ url: URL) {
        let json: [String: Any] = [
            "signature": signature,
            "photos": photos.mapValues { ["mtime": $0.mtime, "probs": $0.probs] as [String: Any] },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func mtime(_ path: String) -> Int? {
        ExifCache.fileStamp(path).map { Int($0.0.rounded()) }
    }
}
