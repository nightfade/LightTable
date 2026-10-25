import CoreGraphics
import Foundation
import LightTableKit
import TravelCutCore

public enum HabitsError: LocalizedError {
    case noPhotos
    case clipUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .noPhotos: "没有找到带相机信息的照片。截图、扫描件和软件导出的图片不计入。"
        case .clipUnavailable(let reason): "看图分类不可用：\(reason)"
        }
    }
}

/// Shooting-habit statistics for a folder of photos, rewritten from photo-habits. Reads EXIF with
/// exiftool, classifies subjects, and writes a self-contained HTML report plus `stats.json`.
public final class HabitsEngine: @unchecked Sendable {
    public init() {}

    public func run(_ options: HabitsOptions, progress: @escaping @Sendable (String, Double) -> Void) async throws -> HabitsSummary {
        let root = Self.normalizedRoot(options.root)
        guard let exiftool = Tools.find(.exiftool) else { throw ToolError.missing("exiftool") }
        let cacheDir = Self.cacheDirectory(options, root: root)

        progress("查找照片", 0)
        let listing = ExifScanner.walk(root, excludeDirs: options.excludeDirs)
        try Task.checkCancellation()

        let (images, sidecars) = try await readExif(listing, exiftool: exiftool, cacheDir: cacheDir, progress: progress)
        let built = Records.build(images: images, sidecars: sidecars,
                                  includeExports: options.includeExports, includePhones: options.includePhones)
        guard !built.all.isEmpty else { throw HabitsError.noPhotos }

        var habit = built.habit
        let clipUsed = try await classify(&habit, root: root, mode: options.content, exiftool: exiftool,
                                          cacheDir: cacheDir, progress: progress)
        try Task.checkCancellation()
        // `all` carries categories too, so stats.json lists them per photo like photos.csv.
        let categories = Dictionary(habit.map { ($0.path, ($0.category, $0.categorySource, $0.categoryConfidence)) },
                                    uniquingKeysWith: { a, _ in a })
        let all = built.all.map { r -> PhotoRecord in
            var r = r
            if let c = categories[r.path] { (r.category, r.categorySource, r.categoryConfidence) = c }
            return r
        }

        progress("生成报告", 0.96)
        let builder = ReportBuilder(all: all, habit: habit, stats: built.stats,
                                    includePhones: options.includePhones, clipUsed: clipUsed)
        let views = builder.views(root: root)
        let generated = Self.timestamp()
        let html = HTMLReport.render(title: "拍摄习惯", subtitle: Self.subtitle(root: root, habit: habit),
                                     generated: generated, cards: Self.cards(all: all, habit: habit, scanned: listing.images.count),
                                     views: views)
        try FileManager.default.createDirectory(at: options.outputHTML.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(html.utf8).write(to: options.outputHTML, options: .atomic)

        var counts: [String: Int] = [:]
        for r in habit { counts[r.category ?? "未分类", default: 0] += 1 }
        let statsFile = cacheDir.appendingPathComponent("stats.json")
        try writeStats(to: statsFile, root: root, generated: generated, options: options, clipUsed: clipUsed,
                       scanned: listing.images.count, all: all, habit: habit, counts: counts, views: views)
        progress("完成", 1)

        var summary = HabitsSummary(htmlFile: options.outputHTML, photoCount: habit.count,
                                    scannedFiles: listing.images.count, categoryCounts: counts)
        summary.statsFile = statsFile
        summary.clipUsed = clipUsed
        return summary
    }

    // MARK: EXIF

    private func readExif(_ listing: ExifScanner.Listing, exiftool: URL, cacheDir: URL,
                          progress: @escaping @Sendable (String, Double) -> Void) async throws -> ([ExifValue], [ExifValue]) {
        let cacheURL = cacheDir.appendingPathComponent("exif.json")
        var cache = ExifCache.load(cacheURL)

        func refresh(_ paths: [String], _ entries: inout [String: ExifCache.Entry], tags: [String],
                     share: ClosedRange<Double>) async throws -> [ExifValue] {
            var stamps: [String: (Double, Int64)] = [:]
            var stale: [String] = []
            for path in paths {
                guard let stamp = ExifCache.fileStamp(path) else { continue }
                stamps[path] = stamp
                if let entry = entries[path], entry.mtime == stamp.0, entry.size == stamp.1 { continue }
                stale.append(path)
            }
            let total = stale.count
            if total > 0 {
                let rows = try await ExifScanner.read(stale, tags: tags, exiftool: exiftool) { done in
                    progress("读取照片信息 \(done)/\(total)", share.lowerBound + (share.upperBound - share.lowerBound) * Double(done) / Double(total))
                }
                for row in rows {
                    let r = Records.Row(row)
                    guard let path = r["SourceFile"]?.pythonString, let stamp = stamps[path] else { continue }
                    entries[path] = ExifCache.Entry(mtime: stamp.0, size: stamp.1, row: row)
                }
                // Files that produced no row this time must not keep an old one.
                for path in stale where entries[path]?.mtime != stamps[path]?.0 || entries[path]?.size != stamps[path]?.1 {
                    entries[path] = nil
                }
            }
            let present = Set(paths)
            entries = entries.filter { present.contains($0.key) }
            return paths.compactMap { entries[$0]?.row }
        }

        let images = try await refresh(listing.images, &cache.images, tags: ExifScanner.tags, share: 0.03...0.5)
        let sidecars = try await refresh(listing.sidecars, &cache.sidecars, tags: ExifScanner.sidecarTags, share: 0.5...0.55)
        cache.save(cacheURL)
        return (images, sidecars)
    }

    // MARK: Classification

    private func classify(_ habit: inout [PhotoRecord], root: String, mode: ContentMode, exiftool: URL,
                          cacheDir: URL, progress: @escaping @Sendable (String, Double) -> Void) async throws -> Bool {
        var rest: [Int] = []
        for i in habit.indices {
            if let (category, source) = HabitCategories.byTags(habit[i], root: root) {
                habit[i].category = category
                habit[i].categorySource = source
            } else {
                rest.append(i)
            }
        }
        var used = false
        if mode != .meta, !rest.isEmpty {
            used = try await classifyByClip(&habit, indices: rest, required: mode == .clip, exiftool: exiftool,
                                            cacheDir: cacheDir, progress: progress)
        }
        for i in rest where habit[i].category == nil {
            (habit[i].category, habit[i].categorySource) = HabitCategories.byCamera(habit[i])
        }
        return used
    }

    private func classifyByClip(_ habit: inout [PhotoRecord], indices: [Int], required: Bool, exiftool: URL,
                                cacheDir: URL, progress: @escaping @Sendable (String, Double) -> Void) async throws -> Bool {
        let cacheURL = cacheDir.appendingPathComponent("content.json")
        var cache = ContentCache.load(cacheURL)
        var probs: [Int: [String: Double]] = [:]
        var todo: [Int] = []
        for i in indices {
            let path = habit[i].path
            let mtime = ContentCache.mtime(path)
            if let hit = cache.photos[path], mtime == nil || hit.mtime == mtime {
                probs[i] = hit.probs
            } else if mtime != nil {
                todo.append(i)
            }
        }

        if !todo.isEmpty {
            do {
                if !MobileCLIPEncoder.isInstalled {
                    progress("下载看图模型", 0.55)
                    try await MobileCLIPEncoder.install { fraction in progress("下载看图模型", 0.55 + 0.1 * fraction) }
                }
                let classifier = try ClipClassifier()
                let total = todo.count
                for start in stride(from: 0, to: total, by: ClipClassifier.batch) {
                    try Task.checkCancellation()
                    let chunk = Array(todo[start..<min(start + ClipClassifier.batch, total)])
                    let images = await ClipClassifier.loadImages(chunk.map { habit[$0] }, exiftool: exiftool)
                    for (i, image) in zip(chunk, images) {
                        guard let image, let p = try? classifier.probabilities(image) else { continue }
                        probs[i] = p
                        if let mtime = ContentCache.mtime(habit[i].path) { cache.photos[habit[i].path] = (mtime, p) }
                    }
                    let done = min(start + ClipClassifier.batch, total)
                    progress("看图分类 \(done)/\(total)", 0.65 + 0.3 * Double(done) / Double(total))
                    // Keep progress if the run is stopped part way.
                    if (done / ClipClassifier.batch) % 50 == 0 || done == total { cache.save(cacheURL) }
                }
            } catch is CancellationError {
                cache.save(cacheURL)
                throw CancellationError()
            } catch {
                cache.save(cacheURL)
                if required { throw HabitsError.clipUnavailable(error.localizedDescription) }
            }
        }

        var used = false
        for i in indices {
            guard let p = probs[i] else { continue }
            var best = HabitCategories.table[0].0
            for (name, _, _) in HabitCategories.table where (p[name] ?? 0) > (p[best] ?? 0) { best = name }
            let confidence = p[best] ?? 0
            habit[i].category = confidence >= HabitCategories.clipMinimumProbability ? best : "其他"
            habit[i].categorySource = "MobileCLIP 看图"
            habit[i].categoryConfidence = confidence
            used = true
        }
        return used
    }

    // MARK: Output

    private func writeStats(to url: URL, root: String, generated: String, options: HabitsOptions, clipUsed: Bool,
                            scanned: Int, all: [PhotoRecord], habit: [PhotoRecord], counts: [String: Int],
                            views: [ReportView]) throws {
        func n(_ v: Double?) -> Any { v.map { $0 as Any } ?? NSNull() }
        func b(_ v: Bool?) -> Any { v.map { $0 as Any } ?? NSNull() }
        let photos: [[String: Any]] = all.sorted { a, b in
            let ta = a.time?.seconds ?? Int.min, tb = b.time?.seconds ?? Int.min
            return ta != tb ? ta < tb : pyLess(a.path, b.path)
        }.map { r in
            ["path": r.path, "body": r.body, "lens": r.lens, "time": r.time?.display ?? "",
             "focal": n(r.focal), "eq_focal": n(r.eqFocal), "crop": n(r.crop), "fnum": n(r.fnum), "eq_fnum": n(r.eqFnum),
             "max_ap": n(r.maxAp), "shutter": n(r.shutter), "iso": n(r.iso), "program": r.program, "ev": n(r.ev),
             "metering": r.metering, "wb": r.wb, "flash": b(r.flash), "portrait": b(r.portrait), "rating": n(r.rating),
             "label": r.label, "category": r.category ?? "", "category_src": r.categorySource,
             "category_conf": n(r.categoryConfidence), "raw": r.raw, "phone": r.phone, "export": r.export]
        }
        let viewData = try JSONSerialization.jsonObject(with: JSONEncoder().encode(views))
        let json: [String: Any] = [
            "version": 1,
            "generatedAt": generated,
            "root": root,
            "content": options.content.rawValue,
            "clipUsed": clipUsed,
            "clipModel": ClipClassifier.modelName,
            "clipMinimumProbability": HabitCategories.clipMinimumProbability,
            "scannedFiles": scanned,
            "dedupedPhotos": all.count,
            "habitPhotos": habit.count,
            "categoryCounts": counts,
            "views": viewData,
            "photos": photos,
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    static func normalizedRoot(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// `<root>/.lighttable-cache`, or a per-folder cache under ~/Library/Caches when the root
    /// cannot be written (a locked card, a read-only share).
    static func cacheDirectory(_ options: HabitsOptions, root: String) -> URL {
        let manager = FileManager.default
        let preferred = options.cacheDirectory ?? URL(fileURLWithPath: root).appendingPathComponent(".lighttable-cache", isDirectory: true)
        if (try? manager.createDirectory(at: preferred, withIntermediateDirectories: true)) != nil,
           manager.isWritableFile(atPath: preferred.path) {
            return preferred
        }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in root.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let fallback = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LightTable/Habits/\(String(hash, radix: 16))", isDirectory: true)
        try? manager.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }

    static func subtitle(root: String, habit: [PhotoRecord]) -> String {
        let name = (root as NSString).lastPathComponent
        let times = habit.compactMap(\.time)
        guard let lo = times.min(), let hi = times.max() else { return "文件夹：\(name)" }
        return "文件夹：\(name) · \(lo.date) 至 \(hi.date)"
    }

    static func cards(all: [PhotoRecord], habit: [PhotoRecord], scanned: Int) -> [HTMLReport.Card] {
        var cards = [HTMLReport.Card(label: "统计的照片", value: "\(habit.count) 张",
                                     detail: "扫描 \(scanned) 个文件，去重后 \(all.count) 张")]
        let days = Set(habit.compactMap { $0.time?.date }).count
        cards.append(.init(label: "拍摄天数", value: "\(days) 天",
                           detail: days > 0 ? "平均每天 \(Fmt.pyRound(Double(habit.count) / Double(days))) 张" : ""))
        if let body = OrderedCounter(habit.map(\.body)).mostCommon(1).first {
            cards.append(.init(label: "最常用机身", value: body.0, detail: Fmt.pct(body.1, habit.count)))
        }
        if let lens = OrderedCounter(habit.map(\.lens)).mostCommon(1).first {
            cards.append(.init(label: "最常用镜头", value: lens.0, detail: Fmt.pct(lens.1, habit.count)))
        }
        let subjects = habit.compactMap(\.category).filter { HabitCategories.subjects.contains($0) }
        if let top = OrderedCounter(subjects).mostCommon(1).first {
            cards.append(.init(label: "拍得最多的题材", value: top.0, detail: Fmt.pct(top.1, habit.count)))
        }
        return cards
    }
}

/// Exposed for the self-test and for tuning: MobileCLIP probabilities per category for image files.
public enum HabitsClip {
    public static var isModelInstalled: Bool { MobileCLIPEncoder.isInstalled }

    /// Category → probability for each file (nil where the image could not be read).
    public static func probabilities(for files: [URL]) async throws -> [[String: Double]?] {
        let classifier = try ClipClassifier()
        var out: [[String: Double]?] = []
        for file in files {
            let raw = ExifScanner.rawExtensions.contains(file.pathExtension.lowercased())
            let image: CGImage? = raw
                ? await ClipClassifier.loadImages([Self.stub(file)], exiftool: Tools.find(.exiftool)).first ?? nil
                : ClipClassifier.thumbnail(url: file)
            out.append(try image.map { try classifier.probabilities($0) })
        }
        return out
    }

    /// The category the report would assign from these probabilities.
    public static func category(for probabilities: [String: Double]) -> String {
        var best = HabitCategories.table[0].0
        for (name, _, _) in HabitCategories.table where (probabilities[name] ?? 0) > (probabilities[best] ?? 0) { best = name }
        return (probabilities[best] ?? 0) >= HabitCategories.clipMinimumProbability ? best : "其他"
    }

    private static func stub(_ file: URL) -> PhotoRecord {
        PhotoRecord(path: file.path, ext: file.pathExtension.lowercased(), raw: true, body: "", make: "", phone: false,
                    lens: "", time: nil, focal: nil, eqFocal: nil, crop: nil, fnum: nil, eqFnum: nil, maxAp: nil,
                    shutter: nil, iso: nil, program: "", ev: nil, metering: "", wb: "", flash: nil, portrait: nil,
                    rating: nil, label: "", export: false, orient: nil, keywords: [], faces: 0, scene: "", category: nil)
    }
}
