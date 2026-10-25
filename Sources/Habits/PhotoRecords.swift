import Foundation

/// Capture time as written in EXIF, without a time zone, like Python's naive `datetime`.
/// Statistics count local wall-clock hours and days, so no zone conversion is wanted.
struct LocalTime: Comparable, Hashable, Sendable {
    let year, month, day, hour, minute, second: Int

    /// Days since 1970-01-01 (proleptic Gregorian), for differences and weekdays.
    var dayNumber: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }
    var seconds: Int { dayNumber * 86400 + hour * 3600 + minute * 60 + second }
    /// Monday = 0, as Python's `weekday()`.
    var weekday: Int { ((dayNumber % 7) + 7 + 3) % 7 }
    var date: String { String(format: "%04d-%02d-%02d", year, month, day) }
    var yearMonth: String { String(format: "%04d-%02d", year, month) }
    var iso: String { String(format: "%04d-%02d-%02dT%02d:%02d:%02d", year, month, day, hour, minute, second) }
    var display: String { String(format: "%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, second) }

    static func < (a: LocalTime, b: LocalTime) -> Bool { a.seconds < b.seconds }

    /// Python's `strptime(s[:19], "%Y:%m:%d %H:%M:%S")`, then `"%Y:%m:%d %H:%M"`. strptime accepts
    /// one-digit fields and any run of whitespace where the format has a space.
    static func parse(_ text: String) -> LocalTime? {
        let s = String(text.prefix(19))
        for withSeconds in [true, false] {
            if let t = match(s, withSeconds: withSeconds) { return t }
        }
        return nil
    }

    private static let patterns: [Bool: NSRegularExpression] = {
        let date = #"^(\d\d\d\d):(1[0-2]|0[1-9]|[1-9]):(3[01]|[12]\d|0[1-9]|[1-9]| [1-9])\s+(2[0-3]|[0-1]\d|\d):([0-5]\d|\d)"#
        return [
            true: try! NSRegularExpression(pattern: date + #":(6[0-1]|[0-5]\d|\d)$"#, options: [.caseInsensitive]),
            false: try! NSRegularExpression(pattern: date + "$", options: [.caseInsensitive]),
        ]
    }()

    private static func match(_ s: String, withSeconds: Bool) -> LocalTime? {
        let ns = s as NSString
        guard let m = patterns[withSeconds]!.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func field(_ i: Int) -> Int { Int(ns.substring(with: m.range(at: i)).trimmingCharacters(in: .whitespaces)) ?? 0 }
        let t = LocalTime(year: field(1), month: field(2), day: field(3), hour: field(4), minute: field(5),
                          second: withSeconds ? field(6) : 0)
        // datetime() rejects year 0, day 31 in short months, Feb 29 outside leap years and second 60/61.
        let leap = t.year % 4 == 0 && (t.year % 100 != 0 || t.year % 400 == 0)
        let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard t.year >= 1, t.day <= monthDays[t.month - 1], t.second < 60 else { return nil }
        return t
    }
}

/// One photo after parsing, the same fields as photo-habits' record dict.
struct PhotoRecord: Sendable {
    var path: String
    var ext: String
    var raw: Bool
    var body: String
    var make: String
    var phone: Bool
    var lens: String
    var time: LocalTime?
    var focal: Double?
    var eqFocal: Double?
    var crop: Double?
    var fnum: Double?
    var eqFnum: Double?
    var maxAp: Double?
    var shutter: Double?
    var iso: Double?
    var program: String
    var ev: Double?
    var metering: String
    var wb: String
    var flash: Bool?
    var portrait: Bool?
    var rating: Double?
    var label: String
    var export: Bool
    var orient: Double?
    var keywords: [String]
    var faces: Int
    var scene: String
    var category: String?
    var categorySource = ""
    var categoryConfidence: Double?

    var rated: Bool { (rating ?? 0) >= 1 && rating != nil }
}

/// Python truthiness for optional numbers: None and 0 are false.
@inline(__always) func truthy(_ v: Double?) -> Bool { v != nil && v != 0 }
@inline(__always) func or(_ a: Double?, _ b: @autoclosure () -> Double?) -> Double? { truthy(a) ? a : b() }

enum Records {
    static let phoneMakes = ["apple", "google", "samsung", "xiaomi", "huawei", "honor", "oppo",
                             "vivo", "oneplus", "realme", "motorola", "nothing"]
    static let editorPattern = try! NSRegularExpression(
        pattern: "lightroom|photoshop|camera raw|capture one|luminar|snapseed|vsco|darktable|"
            + "dxo|affinity|gimp|pixelmator|acdsee|on1|meitu|美图|醒图|picsart",
        options: [.caseInsensitive])
    static let junkLens: Set<String> = ["", "----", "unknown", "0", "n/a", "none", "unknown lens"]
    /// Keywords the photo-grouping feature writes. Counting them would make the habit report
    /// classify by LightTable's own guess instead of the user's tags.
    static let ownKeywordPrefix = "TravelCut|"

    // MARK: Field access

    struct Row {
        let pairs: [(String, ExifValue)]
        init(_ value: ExifValue) {
            if case .object(let p) = value { pairs = p } else { pairs = [] }
        }
        subscript(_ key: String) -> ExifValue? { pairs.first { $0.0 == key }?.1 }
        /// `d.get(key + "#", d.get(key))`
        func numeric(_ key: String) -> ExifValue? { self[key + "#"] ?? self[key] }
    }

    /// Python `num()`: numbers as is; strings lose "f/", "mm" and every "s", then "a/b" or the
    /// first word parses as a float.
    static func num(_ v: ExifValue?) -> Double? {
        guard let v else { return nil }
        switch v {
        case .null: return nil
        case .number(let lexeme): return Double(lexeme)
        case .bool(let b): return b ? 1 : 0
        case .string(let s) where s.isEmpty: return nil
        default: break
        }
        var s = v.pythonString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        s = s.replacingOccurrences(of: "f/", with: "").replacingOccurrences(of: "mm", with: "")
            .replacingOccurrences(of: "s", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = s.firstIndex(of: "/") {
            guard let a = pythonFloat(String(s[..<slash])), let b = pythonFloat(String(s[s.index(after: slash)...])), b != 0
            else { return nil }
            return a / b
        }
        guard let first = s.split(whereSeparator: { $0.isWhitespace }).first else { return nil }
        return pythonFloat(String(first))
    }

    /// `float(str)`: optional surrounding whitespace, decimal or inf/nan; no hex.
    static func pythonFloat(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.lowercased().contains("x") else { return nil }
        return Double(t)
    }

    static func text(_ v: ExifValue?) -> String {
        guard let v, v != .null else { return "" }
        return v.pythonString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keyword-like tags may be a string or a list; hierarchical keywords split on `|`.
    /// Values from the photo-grouping feature (`TravelCut|…`) are left out when `ignoreOwn`.
    static func textList(_ v: ExifValue?, ignoreOwn: Bool = false) -> [String] {
        let items: [ExifValue]
        switch v {
        case .array(let list)?: items = list
        case nil, .null?, .string("")?: items = []
        case let single?: items = [single]
        }
        var out: [String] = []
        for item in items {
            let s = item.pythonString
            if ignoreOwn, s.hasPrefix(ownKeywordPrefix) { continue }
            out += s.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        return out
    }

    /// Subject + HierarchicalSubject + Keywords. Photo grouping writes `TravelCut|主题|风景` into
    /// HierarchicalSubject and its leaf `风景` into Subject, so both are dropped: the leaf only when
    /// the same file carries the matching `TravelCut|` path.
    static func keywords(_ d: Row) -> [String] {
        var ownLeaves = Set<String>()
        for item in textListRaw(d["HierarchicalSubject"]) where item.hasPrefix(ownKeywordPrefix) {
            if let leaf = item.split(separator: "|").last?.trimmingCharacters(in: .whitespacesAndNewlines) { ownLeaves.insert(leaf) }
        }
        let flat = (textList(d["Subject"], ignoreOwn: true) + [])
            .filter { !ownLeaves.contains($0) }
        let hier = textList(d["HierarchicalSubject"], ignoreOwn: true)
        let other = textList(d["Keywords"], ignoreOwn: true).filter { !ownLeaves.contains($0) }
        return flat + hier + other
    }

    private static func textListRaw(_ v: ExifValue?) -> [String] {
        switch v {
        case .array(let list)?: list.map(\.pythonString)
        case nil, .null?, .string("")?: []
        case let single?: [single.pythonString]
        }
    }

    /// Camera face count, Lightroom face regions or tagged people, whichever is largest.
    static func faces(_ d: Row) -> Int {
        let digits = text(d["FacesDetected"]).split(whereSeparator: { !$0.isASCII || !$0.isNumber }).compactMap { Int($0) }
        var n = digits.max() ?? 0
        n = max(n, textList(d["RegionType"]).filter { $0.lowercased() == "face" }.count)
        return max(n, textList(d["PersonInImage"]).count)
    }

    static func bodyName(make rawMake: String, model rawModel: String) -> String {
        let make = rawMake.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty { return make.isEmpty ? "(未知机身)" : make }
        let first = make.split(whereSeparator: { $0.isWhitespace }).first.map { $0.lowercased() } ?? ""
        if !first.isEmpty, model.lowercased().hasPrefix(first) { return model }
        let short = ["nikon corporation": "Nikon", "olympus imaging corp.": "Olympus",
                     "olympus corporation": "Olympus", "om digital solutions": "OM System",
                     "ricoh imaging company, ltd.": "Ricoh", "fujifilm": "Fujifilm",
                     "panasonic": "Panasonic", "sony": "Sony", "canon": "Canon"]
        return "\(short[make.lowercased()] ?? make) \(model)".trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func lensName(_ d: Row, body: String) -> String {
        for key in ["LensModel", "LensID", "Lens"] {
            let v = text(d[key])
            if !junkLens.contains(v.lowercased()), !v.lowercased().hasPrefix("unknown") { return v }
        }
        return "\(body) 内置/未知镜头"
    }

    /// Python `os.path.splitext`: the extension starts at the last dot unless only dots precede it.
    static func splitext(_ name: String) -> (String, String) {
        guard let dot = name.lastIndex(of: "."), name[..<dot].contains(where: { $0 != "." }) else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    /// (lowercased folder, lowercased stem). `IMG_1.RW2.xmp` and `IMG_1.xmp` both map to `IMG_1`.
    static func stemKey(_ path: String) -> String {
        let slash = path.lastIndex(of: "/")
        let dir = slash.map { String(path[..<$0]) } ?? ""
        let file = slash.map { String(path[path.index(after: $0)...]) } ?? path
        var (stem, ext) = splitext(file.lowercased())
        if ext == ".xmp" {
            let (inner, ext2) = splitext(stem)
            if ExifScanner.imageExtensions.contains(String(ext2.dropFirst())) { stem = inner }
        }
        return dir.lowercased() + "\u{0}" + stem
    }

    static func stemOnly(_ key: String) -> String { String(key[key.index(after: key.firstIndex(of: "\u{0}")!)...]) }

    // MARK: Build

    struct Result {
        var all: [PhotoRecord]
        var habit: [PhotoRecord]
        /// Insertion-ordered counts, e.g. 文件总数, 软件导出件，跳过.
        var stats: [(String, Int)]
    }

    /// photo-habits `build_records`: filters, sidecar ratings, dedup.
    static func build(images: [ExifValue], sidecars: [ExifValue], includeExports: Bool, includePhones: Bool) -> Result {
        var ratings: [String: (Double?, String, [String], Int)] = [:]
        for value in sidecars {
            let d = Row(value)
            ratings[stemKey(text(d["SourceFile"]))] = (num(d.numeric("Rating")), text(d["Label"]), keywords(d), faces(d))
        }

        var stats: [(String, Int)] = []
        func count(_ key: String) {
            if let i = stats.firstIndex(where: { $0.0 == key }) { stats[i].1 += 1 } else { stats.append((key, 1)) }
        }
        var order: [String] = []
        var candidates: [String: PhotoRecord] = [:]
        for value in images {
            let d = Row(value)
            count("文件总数")
            let path = d["SourceFile"]?.pythonString ?? ""
            let ext = (path.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? "").lowercased()
            let make = text(d["Make"]), model = text(d["Model"])
            if model.isEmpty { count("无相机信息（截图、扫描件等），跳过"); continue }
            let software = text(d["Software"]) + " " + text(d["CreatorTool"])
            let isExport = ExifScanner.renderedExtensions.contains(ext)
                && editorPattern.firstMatch(in: software, range: NSRange(software.startIndex..., in: software)) != nil
            if isExport && !includeExports { count("软件导出件，跳过"); continue }

            let body = bodyName(make: make, model: model)
            let t = LocalTime.parse(text(d["DateTimeOriginal"]))
            let sk = stemKey(path)
            let side = ratings[sk] ?? (nil, "", [], 0)
            var rating = num(d.numeric("Rating"))
            if let sr = side.0 { rating = rating.map { max($0, sr) } ?? sr }

            let focal = num(d.numeric("FocalLength"))
            var eq = or(num(d.numeric("FocalLengthIn35mmFormat")), num(d.numeric("FocalLength35efl")))
            var scale = num(d.numeric("ScaleFactor35efl"))
            if !truthy(eq), truthy(focal), truthy(scale) { eq = focal! * scale! }
            // As exiftool does: without sensor-size information assume full frame.
            if !truthy(eq), truthy(focal) { eq = focal; scale = or(scale, 1.0) }
            if !truthy(scale), truthy(focal), truthy(eq) { scale = eq! / focal! }
            let fnum = num(d.numeric("FNumber"))
            let w = num(d.numeric("ImageWidth")), h = num(d.numeric("ImageHeight"))
            let orient = num(d.numeric("Orientation"))
            var portrait: Bool?
            if truthy(w), truthy(h) { portrait = (h! > w!) != [5, 6, 7, 8].contains(orient ?? -1) }
            let flash = num(d.numeric("Flash"))

            let rec = PhotoRecord(
                path: path, ext: ext, raw: ExifScanner.rawExtensions.contains(ext), body: body, make: make,
                phone: phoneMakes.contains(where: { make.lowercased().hasPrefix($0) }) || model.lowercased().contains("iphone"),
                lens: lensName(d, body: body), time: t,
                focal: focal, eqFocal: eq, crop: scale,
                fnum: fnum, eqFnum: truthy(fnum) && truthy(scale) ? fnum! * scale! : fnum,
                maxAp: num(d.numeric("MaxApertureValue")),
                shutter: num(d.numeric("ExposureTime")), iso: num(d.numeric("ISO")),
                program: text(d["ExposureProgram"]), ev: num(d.numeric("ExposureCompensation")),
                metering: text(d["MeteringMode"]), wb: text(d["WhiteBalance"]),
                flash: flash.map { (Int(exactly: $0.rounded(.towardZero)) ?? 0) & 1 == 1 },
                portrait: portrait, rating: rating,
                label: text(d["Label"]).isEmpty ? side.1 : text(d["Label"]), export: isExport,
                orient: orient, keywords: keywords(d) + side.2,
                faces: max(faces(d), side.3),
                scene: "\(text(d["SceneCaptureType"])) \(text(d["SceneMode"]))".trimmingCharacters(in: .whitespacesAndNewlines),
                category: nil)
            let key = t.map { [body, $0.iso, text(d["SubSecTimeOriginal"]), stemOnly(sk)].joined(separator: "\u{1}") }
                ?? "nodate\u{1}" + sk
            guard var old = candidates[key] else {
                candidates[key] = rec
                order.append(key)
                continue
            }
            count("重复（RAW+JPEG 或备份），合并")
            var keep = rec, drop = old
            if !(rec.raw && !old.raw) { keep = old; drop = rec }
            if let dr = drop.rating { keep.rating = keep.rating.map { max($0, dr) } ?? dr }
            keep.keywords += drop.keywords.filter { !keep.keywords.contains($0) }
            keep.faces = max(keep.faces, drop.faces)
            old = keep
            candidates[key] = old
        }
        let all = order.map { candidates[$0]! }
        return Result(all: all, habit: includePhones ? all : all.filter { !$0.phone }, stats: stats)
    }
}
