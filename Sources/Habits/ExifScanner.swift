import Darwin
import Foundation
import LightTableKit

/// Finds photos and `.xmp` sidecars and reads their EXIF with exiftool, using the same file
/// rules, tags and arguments as photo-habits so the statistics come out the same.
enum ExifScanner {
    static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "rw2",
        "orf", "ori", "pef", "srw", "x3f", "3fr", "iiq", "rwl", "erf", "mef", "mos",
    ]
    static let renderedExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "hif", "tif", "tiff"]
    static var imageExtensions: Set<String> { rawExtensions.union(renderedExtensions) }

    /// Numeric tags carry `#` so exiftool prints raw numbers instead of "1/250" or "50.0 mm".
    static let tags = [
        "-Make", "-Model", "-LensModel", "-LensID", "-Lens",
        "-FocalLength#", "-FocalLengthIn35mmFormat#", "-FocalLength35efl#", "-ScaleFactor35efl#",
        "-FNumber#", "-MaxApertureValue#", "-ExposureTime#", "-ISO#",
        "-ExposureProgram", "-ExposureCompensation#", "-MeteringMode", "-Flash#",
        "-WhiteBalance", "-DateTimeOriginal", "-SubSecTimeOriginal",
        "-ImageWidth#", "-ImageHeight#", "-Orientation#",
        "-Software", "-CreatorTool", "-Rating#", "-Label",
        "-Subject", "-HierarchicalSubject", "-Keywords", "-PersonInImage", "-RegionType",
        "-SceneCaptureType", "-SceneMode", "-FacesDetected",
    ]
    static let sidecarTags = ["-Rating#", "-Label", "-Subject", "-HierarchicalSubject", "-PersonInImage", "-RegionType"]
    static let batchSize = 400

    struct Listing {
        var images: [String] = []
        var sidecars: [String] = []
    }

    /// Walks `root` in the same order as Python's `os.walk` (directory entries in `readdir` order,
    /// a folder's files before its subfolders). Ties in "most used" rankings are broken by that
    /// order, so matching it keeps the report identical to photo-habits.
    ///
    /// Skips hidden folders, folders whose name contains an excluded string, AppleDouble `._`
    /// files, and LightTable's own output folders.
    static func walk(_ root: String, excludeDirs: [String]) -> Listing {
        var listing = Listing()
        let excluded = excludeDirs.map { $0.lowercased() }
        func visit(_ dir: String) {
            guard let handle = opendir(dir) else { return }
            var subdirs: [String] = []
            while let entry = readdir(handle) {
                let name = withUnsafePointer(to: entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                let path = dir + "/" + name
                var isDir = false
                var isLink = false
                switch Int32(entry.pointee.d_type) {
                case DT_DIR: isDir = true
                case DT_REG: break
                default:
                    var info = stat()
                    if lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { isLink = true }
                    if stat(path, &info) == 0 { isDir = (info.st_mode & S_IFMT) == S_IFDIR }
                }
                if isDir {
                    // os.walk lists symlinked folders but does not descend into them.
                    if !isLink { subdirs.append(name) }
                    continue
                }
                if name.hasPrefix("._") { continue }
                let ext = name.contains(".") ? String(name[name.index(after: name.lastIndex(of: ".")!)...]).lowercased() : ""
                if imageExtensions.contains(ext) { listing.images.append(path) } else if ext == "xmp" { listing.sidecars.append(path) }
            }
            closedir(handle)
            for name in subdirs {
                if name.hasPrefix(".") || excluded.contains(where: { name.lowercased().contains($0) }) { continue }
                if MediaScanner.excludedFolderNames.contains(name) { continue }
                visit(dir + "/" + name)
            }
        }
        visit(root)
        return listing
    }

    /// Runs exiftool over `paths` in batches, several at once, returning rows in input order.
    /// A batch whose output does not parse is dropped, as photo-habits does.
    static func read(_ paths: [String], tags: [String], exiftool: URL,
                     progress: @escaping @Sendable (Int) -> Void) async throws -> [ExifValue] {
        guard !paths.isEmpty else { return [] }
        let batches = stride(from: 0, to: paths.count, by: batchSize).map { Array(paths[$0..<min($0 + batchSize, paths.count)]) }
        var results = [[ExifValue]](repeating: [], count: batches.count)
        let done = DoneCounter()
        try await withThrowingTaskGroup(of: (Int, [ExifValue]).self) { group in
            var next = 0
            func add() {
                guard next < batches.count else { return }
                let index = next
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    let rows = try await runBatch(batches[index], tags: tags, exiftool: exiftool)
                    progress(done.add(batches[index].count))
                    return (index, rows)
                }
            }
            for _ in 0..<4 { add() }
            while let (index, rows) = try await group.next() {
                results[index] = rows
                add()
            }
        }
        return results.flatMap { $0 }
    }

    static func runBatch(_ paths: [String], tags: [String], exiftool: URL) async throws -> [ExifValue] {
        let argfile = FileManager.default.temporaryDirectory.appendingPathComponent("lighttable-habits-\(UUID().uuidString).args")
        try paths.joined(separator: "\n").write(to: argfile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: argfile) }
        let arguments = ["-charset", "filename=utf8", "-j", "-q", "-q", "-api", "largefilesupport=1"] + tags + ["-@", argfile.path]
        let stdout = try await runExiftool(exiftool, arguments)
        let text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return [] }
        guard case .array(let rows)? = try? ExifJSONParser.parse(Data(text.utf8)) else { return [] }
        return rows
    }

    /// exiftool as a supervised child, stopped when the task is cancelled.
    static func runExiftool(_ exiftool: URL, _ arguments: [String], stdoutLimit: Int = 64 << 20) async throws -> String {
        var options = SupervisedProcess.Options(hardTimeout: 1800)
        options.stdoutLimit = stdoutLimit
        let process = SupervisedProcess(executable: exiftool, arguments: arguments, options: options)
        try process.start()
        let result = await withTaskCancellationHandler {
            await process.wait()
        } onCancel: {
            process.stop()
        }
        try Task.checkCancellation()
        // exiftool exits 1 when some files had errors yet still prints the others; keep what it printed.
        return result.stdout
    }
}

private final class DoneCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add(_ n: Int) -> Int { lock.withLock { value += n; return value } }
}

/// Raw exiftool rows kept between runs so regenerating the report only reads new or changed files.
struct ExifCache {
    static let version = 1
    struct Entry {
        var mtime: Double
        var size: Int64
        var row: ExifValue
    }
    var images: [String: Entry] = [:]
    var sidecars: [String: Entry] = [:]

    static func load(_ url: URL) -> ExifCache {
        guard let data = try? Data(contentsOf: url), case .object(let top)? = try? ExifJSONParser.parse(data),
              top.first(where: { $0.0 == "version" })?.1 == .number("\(version)")
        else { return ExifCache() }
        func entries(_ key: String) -> [String: Entry] {
            guard case .object(let files)? = top.first(where: { $0.0 == key })?.1 else { return [:] }
            var out: [String: Entry] = [:]
            for (path, value) in files {
                guard case .array(let parts) = value, parts.count == 3,
                      case .number(let m) = parts[0], case .number(let s) = parts[1],
                      let mtime = Double(m), let size = Int64(s) else { continue }
                out[path] = Entry(mtime: mtime, size: size, row: parts[2])
            }
            return out
        }
        return ExifCache(images: entries("images"), sidecars: entries("sidecars"))
    }

    func save(_ url: URL) {
        var out = "{\"version\":\(Self.version)"
        for (key, entries) in [("images", images), ("sidecars", sidecars)] {
            out += ",\"\(key)\":{"
            for (i, (path, entry)) in entries.sorted(by: { $0.key < $1.key }).enumerated() {
                if i > 0 { out += ",\n" }
                ExifJSONWriter.writeString(path, into: &out)
                out += ":[\(entry.mtime),\(entry.size),"
                ExifJSONWriter.write(entry.row, into: &out)
                out += "]"
            }
            out += "}"
        }
        out += "}"
        try? Data(out.utf8).write(to: url, options: .atomic)
    }

    static func fileStamp(_ path: String) -> (Double, Int64)? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return (Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9, Int64(info.st_size))
    }
}
