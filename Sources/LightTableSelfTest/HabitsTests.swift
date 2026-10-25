import CoreGraphics
import Foundation
import ImageIO
import LightTableKit
import UniformTypeIdentifiers
@testable import Habits

// Habits module checks. Unit cases build exiftool-shaped rows by hand; the parity case builds a
// synthetic photo folder with exiftool and compares every table, every number-carrying sentence
// and every per-photo field against photo-habits (`reference/photo_habits.py --content meta`).

func runHabitsTests() async {
    if let list = ProcessInfo.processInfo.environment["LIGHTTABLE_HABITS_TUNE"] {
        await runHabitsTuning(list)
        return
    }
    print("habits: parsing and rules")
    testValueParsing()
    testTimeParsing()
    testAliasMatching()
    testKeywordsIgnoreOwn()
    testDedupAndFilters()
    testFormatting()

    guard let exiftool = Tools.find(.exiftool) else {
        print("habits: exiftool missing, skipping fixture, parity and HTML tests")
        return
    }
    print("habits: synthetic fixture")
    let fixture = scratchFolder("habits-fixture")
    guard buildFixture(at: fixture, exiftool: exiftool) else {
        failures.append("habits: could not build the synthetic fixture")
        return
    }
    testWalk(fixture)
    print("habits: engine run (meta)")
    guard let stats = await runEngine(fixture) else { return }
    testHTML(fixture.appendingPathComponent("LightTable 拍摄习惯.html"), stats: stats)
    await testCacheReuse(fixture)

    if let python = findPython() {
        print("habits: parity with photo_habits.py")
        parity(fixture: fixture, stats: stats, python: python)
    } else {
        print("habits: python3 or reference/photo_habits.py missing, skipping parity")
    }
    await clipSmokeTest()
}

// MARK: - Unit cases

private func row(_ pairs: [(String, ExifValue)]) -> ExifValue { .object(pairs) }

private func testValueParsing() {
    expect(Records.num(.number("50")) == 50, "integer number")
    expect(Records.num(.string("1/250")) == 1.0 / 250, "rational string")
    expect(Records.num(.string("f/2.8")) == 2.8, "f-number string")
    expect(Records.num(.string("50.0 mm")) == 50, "focal string")
    expect(Records.num(.string("1/0")) == nil, "division by zero is no value")
    expect(Records.num(.string("")) == nil && Records.num(nil) == nil, "empty")
    expect(Records.num(.string("0x10")) == nil, "no hex, like Python float()")
    expect(ExifValue.number("2024").pythonString == "2024" && ExifValue.number("2024.0").pythonString == "2024.0",
           "numbers print like Python str()")
    let parsed = try? ExifJSONParser.parse(Data(#"[{"SourceFile":"aé.jpg","Subject":["人像",2024],"FNumber":2.8,"X":null}]"#.utf8))
    if case .array(let rows)? = parsed {
        let r = Records.Row(rows[0])
        expect(r["SourceFile"] == .string("aé.jpg"), "unicode escape")
        expect(Records.textList(r["Subject"]) == ["人像", "2024"], "keyword list with a number")
        expect(Records.num(r.numeric("FNumber")) == 2.8, "numeric lookup")
    } else {
        failures.append("HabitsTests: JSON parser failed")
    }
    expect(Records.bodyName(make: "SONY", model: "ILCE-7M4") == "Sony ILCE-7M4", "Sony body name")
    expect(Records.bodyName(make: "Canon", model: "Canon EOS R6") == "Canon EOS R6", "model already has make")
    expect(Records.bodyName(make: "NIKON CORPORATION", model: "NIKON Z 6") == "NIKON Z 6", "Nikon prefix")
    expect(Records.bodyName(make: "", model: "") == "(未知机身)", "unknown body")
    expect(Records.stemKey("/a/B/IMG_1.RW2.xmp") == Records.stemKey("/a/b/img_1.jpg"), "sidecar stem key")
    expect(Records.splitext(".hidden") == (".hidden", ""), "dot file has no extension")
}

private func testTimeParsing() {
    expect(LocalTime.parse("2024:05:01 10:20:30")?.iso == "2024-05-01T10:20:30", "plain time")
    expect(LocalTime.parse("2024:05:01 10:20:30+08:00")?.iso == "2024-05-01T10:20:30", "zone suffix ignored")
    expect(LocalTime.parse("2024:5:1 9:05:03")?.iso == "2024-05-01T09:05:03", "one-digit fields like strptime")
    expect(LocalTime.parse("2024:05:01 10:20")?.iso == "2024-05-01T10:20:00", "minutes only")
    expect(LocalTime.parse("0000:00:00 00:00:00") == nil, "zero date")
    expect(LocalTime.parse("2023:02:29 10:00:00") == nil, "not a leap year")
    expect(LocalTime.parse("2024:05:01 10:20:60") == nil, "second 60")
    expect(LocalTime.parse("2024:10:21 12:00:00")?.weekday == 0, "Monday is 0")
}

private func testAliasMatching() {
    expect(HabitCategories.aliasHits("Street 2024") == ["街头"], "English whole word")
    expect(HabitCategories.aliasHits("Concatenate").isEmpty, "cat inside a word does not count")
    expect(HabitCategories.aliasHits("location").isEmpty, "no partial English match")
    expect(HabitCategories.aliasHits("cat_2024") == ["动物"], "underscore is a word boundary")
    expect(HabitCategories.aliasHits("宠物猫") == ["动物"], "Chinese substring")
    expect(HabitCategories.aliasHits("2023 街拍") == ["街头"], "Chinese folder name")
    expect(HabitCategories.aliasHits("Family Portraits") == ["人像"], "case-insensitive, first category only once")
    expect(HabitCategories.aliasHits("still life") == ["静物"], "multi-word alias")
    var r = stubRecord(path: "/root/风景/2024 街拍/a.jpg")
    expect(HabitCategories.byTags(r, root: "/root")?.0 == "街头", "deepest folder wins")
    r.keywords = ["family"]
    expect(HabitCategories.byTags(r, root: "/root")! == ("人像", "关键词"), "keyword beats folder")
    let rootNamed = stubRecord(path: "/photos/风景/a.jpg")
    expect(HabitCategories.byTags(rootNamed, root: "/photos/风景") == nil, "root folder name does not count")
    var scene = stubRecord(path: "/r/a.jpg")
    scene.scene = "Landscape"
    expect(HabitCategories.byCamera(scene) == ("风景", "相机场景模式"), "scene mode")
    scene.scene = ""
    scene.faces = 2
    expect(HabitCategories.byCamera(scene) == ("人像", "人脸检测"), "faces")
}

private func testKeywordsIgnoreOwn() {
    let d = Records.Row(row([
        ("HierarchicalSubject", .array([.string("TravelCut|主题|自然景观"), .string("TravelCut|组|组 0001"), .string("旅行|巴黎")])),
        ("Subject", .array([.string("自然景观"), .string("组 0001"), .string("巴黎"), .string("街拍")])),
    ]))
    let keywords = Records.keywords(d)
    expect(!keywords.contains("自然景观") && !keywords.contains("组 0001") && !keywords.contains("TravelCut"),
           "photo-grouping keywords ignored, got \(keywords)")
    expect(keywords.contains("街拍") && keywords.contains("巴黎") && keywords.contains("旅行"), "user keywords kept")
    expect(HabitCategories.firstInOrder(keywords.flatMap(HabitCategories.aliasHits)) == "街头",
           "自然 in TravelCut's theme does not make it 风景")
}

private func testDedupAndFilters() {
    func photo(_ path: String, model: String = "ILCE-7M4", make: String = "SONY", time: String? = "2024:05:01 10:00:00",
               extra: [(String, ExifValue)] = []) -> ExifValue {
        var pairs: [(String, ExifValue)] = [("SourceFile", .string(path)), ("Make", .string(make)), ("Model", .string(model))]
        if let time { pairs.append(("DateTimeOriginal", .string(time))) }
        return row(pairs + extra)
    }
    let images = [
        photo("/r/a/DSC1.JPG", extra: [("Rating", .number("2")), ("Subject", .string("人像"))]),
        photo("/r/a/DSC1.ARW"),
        photo("/r/backup/DSC1.JPG"),
        photo("/r/a/DSC2.JPG", time: nil),
        photo("/r/b/DSC2.JPG", time: nil),
        photo("/r/x/export.jpg", extra: [("Software", .string("Adobe Photoshop Lightroom Classic 13.0"))]),
        photo("/r/x/export.arw", time: "2024:05:01 11:00:00", extra: [("Software", .string("Adobe Photoshop Lightroom Classic 13.0"))]),
        photo("/r/p/IMG_1.HEIC", model: "iPhone 15 Pro", make: "Apple"),
        photo("/r/s/screenshot.png", model: "", make: ""),
    ]
    let sidecars = [row([("SourceFile", .string("/r/a/DSC1.xmp")), ("Rating", .number("4")), ("Subject", .string("动物"))])]
    let result = Records.build(images: images, sidecars: sidecars, includeExports: false, includePhones: false)
    let stats = Dictionary(uniqueKeysWithValues: result.stats)
    expect(stats["文件总数"] == 9, "all files counted")
    expect(stats["软件导出件，跳过"] == 1, "only rendered exports are skipped (RAW with Lightroom software stays)")
    expect(stats["无相机信息（截图、扫描件等），跳过"] == 1, "no camera info skipped")
    expect(stats["重复（RAW+JPEG 或备份），合并"] == 2, "RAW+JPEG and backup merged; undated copies in other folders are not")
    let dsc1 = result.all.first { $0.path.hasSuffix("DSC1.ARW") }
    expect(dsc1 != nil, "RAW preferred over JPEG")
    expect(dsc1?.rating == 4, "max of in-file and sidecar rating, got \(String(describing: dsc1?.rating))")
    expect(dsc1?.keywords.contains("人像") == true && dsc1?.keywords.contains("动物") == true, "keywords merged from JPEG and sidecar")
    expect(result.all.count == 5 && result.habit.count == 4, "phone kept in all, left out of habit")
    let withPhones = Records.build(images: images, sidecars: sidecars, includeExports: true, includePhones: true)
    expect(withPhones.habit.count == 6, "include exports and phones")
}

private func testFormatting() {
    expect(Fmt.pct(1, 3) == "33.3%" && Fmt.pct(0, 0) == "—", "percent")
    expect(Fmt.shutter(1.0 / 250) == "1/250" && Fmt.shutter(2) == "2s" && Fmt.shutter(0.4) == "1/2", "shutter, 1/2.5 rounds to even")
    expect(Fmt.bar(1, 2) == String(repeating: "█", count: 15), "bar")
    expect(Fmt.median([1, nil, 3, 2, 4]) == 2.5, "median skips missing")
    var c = OrderedCounter(["b", "a", "a", "b", "c"])
    c.add("c")
    expect(c.mostCommon().map(\.0) == ["b", "a", "c"], "ties keep first-seen order")
}

private func stubRecord(path: String) -> PhotoRecord {
    PhotoRecord(path: path, ext: "jpg", raw: false, body: "B", make: "", phone: false, lens: "L", time: nil,
                focal: nil, eqFocal: nil, crop: nil, fnum: nil, eqFnum: nil, maxAp: nil, shutter: nil, iso: nil,
                program: "", ev: nil, metering: "", wb: "", flash: nil, portrait: nil, rating: nil, label: "",
                export: false, orient: nil, keywords: [], faces: 0, scene: "", category: nil)
}

// MARK: - Fixture

/// Deterministic pseudo-random numbers so the fixture is the same every run.
private struct LCG {
    var state: UInt64
    mutating func next(_ n: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(n))
    }
    mutating func pick<T>(_ items: [T]) -> T { items[next(items.count)] }
}

private func writeJPEG(_ url: URL, width: Int, height: Int, shade: Int) {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return }
    context.setFillColor(red: CGFloat(shade % 7) / 7, green: 0.5, blue: CGFloat(shade % 5) / 5, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

private struct Shot {
    var rel: String
    var tags: [String]
    var portrait = false
    /// Copies made after tags are written (RAW twin with the same EXIF, backup copy).
    var copies: [String] = []
}

/// ~190 files covering every rule: five bodies, a zoom and a tele lens, keyword and folder
/// categories, RAW+JPEG pairs with sidecars, backups, exports, phones, files without camera data
/// or date, bursts, ratings, orientation, flash, scene modes and tagged people.
private func fixtureShots() -> [Shot] {
    var rng = LCG(state: 42)
    var shots: [Shot] = []
    func time(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> String {
        String(format: "-DateTimeOriginal=%04d:%02d:%02d %02d:%02d:%02d", year, month, day, hour, minute, second)
    }
    let isos = [100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600]
    let shutters = ["1/8000", "1/2000", "1/1000", "1/500", "1/250", "1/125", "1/60", "1/30", "1/8", "1/2.5", "2"]
    let evs = ["-1.7", "-1", "-0.3", "0", "0", "0", "0.3", "0.7", "1.3"]
    func exposure() -> [String] {
        ["-ISO=\(rng.pick(isos))", "-ExposureTime=\(rng.pick(shutters))", "-ExposureCompensation=\(rng.pick(evs))",
         "-ExposureProgram#=\(rng.pick([1, 2, 3, 3, 4]))", "-MeteringMode#=\(rng.pick([2, 3, 5, 5]))",
         "-WhiteBalance#=\(rng.pick([0, 0, 1]))", "-Flash#=\(rng.pick([0, 16, 16, 1, 9, 24]))"]
    }
    func rating() -> [String] { rng.next(10) < 6 ? ["-XMP-xmp:Rating=\(1 + rng.next(5))"] : [] }

    // Sony zoom: wide and long ends, bursts, some street keywords and tagged people.
    for i in 0..<40 {
        let focal = rng.pick([24, 24, 24, 28, 35, 40, 50, 70, 70])
        var tags = ["-Make=SONY", "-Model=ILCE-7M4", "-LensModel=FE 24-70mm F2.8 GM II", "-FocalLength=\(focal)",
                    "-FocalLengthIn35mmFormat=\(focal)", "-FNumber=\(rng.pick([2.8, 2.8, 4, 5.6, 8, 11]))",
                    "-MaxApertureValue=2.8", time(2024, 5, 1 + i / 10, 8 + i % 12, i, i >= 10 && i < 14 ? 30 + i : rng.next(60))]
        if i >= 10 && i < 14 { tags.append("-SubSecTimeOriginal=\(i)") }
        if i % 5 == 0 { tags.append("-XMP-dc:Subject=Street") }
        if i % 7 == 0 { tags.append("-XMP-lr:HierarchicalSubject=旅行|风景") }
        if i % 6 == 1 { tags += ["-XMP-iptcExt:PersonInImage=Alice", "-XMP-iptcExt:PersonInImage=Bob"] }
        if i % 9 == 2 { tags.append("-XMP-dc:Subject=location") }
        if i % 11 == 3 { tags.append("-XMP-xmp:Label=Red") }
        if i % 4 == 0 { tags.append("-Orientation#=6") }
        var shot = Shot(rel: "Sony/2024-05 旅行/DSC\(1000 + i).JPG", tags: tags + exposure() + rating())
        if i < 3 { shot.copies = ["Backup/DSC\(1000 + i).JPG"] }
        shots.append(shot)
    }
    // Sony tele in a folder named for birds: 动物 by folder; mostly rated for the tele "留片" line.
    for i in 0..<30 {
        let focal = rng.pick([70, 100, 135, 200, 200, 180])
        var tags = ["-Make=SONY", "-Model=ILCE-7M4", "-LensModel=FE 70-200mm F4 Macro G OSS II", "-FocalLength=\(focal)",
                    "-FocalLengthIn35mmFormat=\(focal)", "-FNumber=\(rng.pick([4, 4, 4, 5.6, 8]))",
                    time(2023, 11, 3 + i / 8, 6 + i % 10, i * 2 % 60, rng.next(60))]
        if i < 26 { tags.append("-XMP-xmp:Rating=\(1 + i % 5)") }
        if i % 3 == 0 { tags.append("-XMP-dc:Subject=cats") }
        shots.append(Shot(rel: "Sony/野生 birds/DSC\(2000 + i).JPG", tags: tags + exposure()))
    }
    // X100V: built-in lens (no lens tag), APS-C equivalents; street folder, family keyword wins.
    for i in 0..<30 {
        var tags = ["-Make=FUJIFILM", "-Model=X100V", "-FocalLength=23", "-FocalLengthIn35mmFormat=35",
                    "-FNumber=\(rng.pick([2, 2, 2.8, 4, 5.6]))", time(2023, 3 + i % 4, 10 + i % 15, 12 + i % 9, i, rng.next(60))]
        if i % 4 == 0 { tags.append("-XMP-dc:Subject=family") }
        shots.append(Shot(rel: "X100V/2023 街拍/DSCF\(3000 + i).JPG", tags: tags + exposure() + rating(), portrait: i % 3 == 0))
    }
    // Canon RF50 without a 35mm tag (full frame assumed), wide open often; landscape folder.
    for i in 0..<25 {
        var tags = ["-Make=Canon", "-Model=Canon EOS R6", "-LensModel=RF50mm F1.8 STM", "-FocalLength=50",
                    "-FNumber=\(rng.pick([1.8, 1.8, 2.8, 8, 11, 16]))", time(2022, 7, 1 + i, 5 + i % 16, i, rng.next(60))]
        if i % 5 == 0 { tags.append("-Orientation#=8") }
        shots.append(Shot(rel: "Canon/Landscapes/IMG_\(4000 + i).JPG", tags: tags + exposure() + rating()))
    }
    // Canon food → 静物; and a folder where "cat" is only part of a word.
    for i in 0..<12 {
        let tags = ["-Make=Canon", "-Model=Canon EOS R6", "-LensModel=RF50mm F1.8 STM", "-FocalLength=50",
                    "-FNumber=\(rng.pick([1.8, 2.8, 4]))", time(2024, 1, 2, 12 + i % 3, i * 3, rng.next(60))]
        shots.append(Shot(rel: "Canon/food/IMG_\(4100 + i).JPG", tags: tags + exposure() + rating()))
    }
    for i in 0..<3 {
        let tags = ["-Make=Canon", "-Model=Canon EOS R6", "-LensModel=RF50mm F1.8 STM", "-FocalLength=50", "-FNumber=4",
                    time(2024, 1, 3, 9, i, 0), "-XMP-dc:Subject=宠物猫"]
        shots.append(Shot(rel: "Canon/Concatenate/IMG_\(4200 + i).JPG", tags: tags + (i == 0 ? [] : ["-XMP-dc:Subject=人物"])))
    }
    // Canon scene modes and missing dates.
    for (i, scene) in [2, 1, 1, 0].enumerated() {
        let tags = ["-Make=Canon", "-Model=Canon EOS R6", "-LensModel=RF50mm F1.8 STM", "-FocalLength=50", "-FNumber=5.6",
                    "-SceneCaptureType#=\(scene)", time(2024, 2, 5, 15, i, 0)]
        shots.append(Shot(rel: "Canon/misc/IMG_\(4300 + i).JPG", tags: tags + exposure()))
    }
    for i in 0..<3 {
        shots.append(Shot(rel: "Canon/misc/NODATE_\(i).JPG",
                          tags: ["-Make=Canon", "-Model=Canon EOS R6", "-FocalLength=85", "-FNumber=2"] + exposure()))
    }
    // Nikon: junk LensModel with a real Lens tag, 35mm tag set to 0 so the fallback is used.
    for i in 0..<15 {
        let tags = ["-Make=NIKON CORPORATION", "-Model=NIKON Z 6", "-LensModel=----", "-XMP-aux:Lens=NIKKOR Z 35mm f/1.8 S",
                    "-FocalLength=35", "-FocalLengthIn35mmFormat=0", "-FNumber=\(rng.pick([1.8, 2.8, 5.6]))",
                    time(2024, 8, 20 + i % 5, 19 + i % 5, i, rng.next(60))]
        shots.append(Shot(rel: "Nikon/城市建筑夜景/DSC_\(5000 + i).JPG", tags: tags + exposure() + rating(), portrait: i % 2 == 0))
    }
    // RAW+JPEG pairs (the RAW is a renamed JPEG copy; exiftool reads it by content) with sidecars.
    for i in 0..<5 {
        let tags = ["-Make=SONY", "-Model=ILCE-7M4", "-LensModel=FE 24-70mm F2.8 GM II", "-FocalLength=35",
                    "-FocalLengthIn35mmFormat=35", "-FNumber=2.8", time(2024, 6, 1, 10, i, 0), "-SubSecTimeOriginal=50"]
            + (i == 0 ? ["-XMP-xmp:Rating=2"] : []) + exposure()
        shots.append(Shot(rel: "Sony/RAW/DSC\(6000 + i).JPG", tags: tags, copies: ["Sony/RAW/DSC\(6000 + i).ARW"]))
    }
    // Exports and phones are left out; no-camera files count only in 文件总数.
    for i in 0..<4 {
        shots.append(Shot(rel: "Export/DSC\(1000 + i)-edit.jpg",
                          tags: ["-Make=SONY", "-Model=ILCE-7M4", "-Software=Adobe Photoshop Lightroom Classic 13.0 (Macintosh)",
                                 "-FocalLength=50", time(2024, 5, 1, 9, i, 0)]))
    }
    shots.append(Shot(rel: "Export/snap.jpg", tags: ["-Make=FUJIFILM", "-Model=X100V", "-XMP-xmp:CreatorTool=Snapseed",
                                                     "-FocalLength=23", time(2023, 3, 10, 12, 0, 0)]))
    for i in 0..<6 {
        shots.append(Shot(rel: "iPhone/IMG_\(7000 + i).JPG",
                          tags: ["-Make=Apple", "-Model=iPhone 15 Pro", "-LensModel=iPhone 15 Pro back camera 6.765mm f/1.78",
                                 "-FocalLength=6.765", "-FocalLengthIn35mmFormat=24", "-FNumber=1.78",
                                 time(2024, 5, 2, 18, i, 0)] + exposure()))
    }
    shots.append(Shot(rel: "Screens/screenshot.jpg", tags: ["-Software=macOS"]))
    shots.append(Shot(rel: "Screens/scan.jpg", tags: ["-Make=Epson"]))
    // Hidden folders are skipped by both tools.
    shots.append(Shot(rel: ".hidden/DSC9999.JPG", tags: ["-Make=SONY", "-Model=ILCE-7M4", time(2024, 5, 1, 9, 0, 0)]))
    return shots
}

/// Writes JPEGs, tags them with one exiftool call, makes RAW twins and backups, and adds sidecars.
private func buildFixture(at root: URL, exiftool: URL) -> Bool {
    let manager = FileManager.default
    let shots = fixtureShots()
    var args: [String] = []
    for (i, shot) in shots.enumerated() {
        let url = root.appendingPathComponent(shot.rel)
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        writeJPEG(url, width: shot.portrait ? 48 : 72, height: shot.portrait ? 72 : 48, shade: i)
        args += ["-overwrite_original", "-charset", "filename=utf8", "-codedcharacterset=utf8"] + shot.tags + [url.path, "-execute"]
    }
    let argfile = root.deletingLastPathComponent().appendingPathComponent("habits-fixture.args")
    try? args.joined(separator: "\n").write(to: argfile, atomically: true, encoding: .utf8)
    do {
        _ = try SupervisedProcess.runToCompletion(executable: exiftool, arguments: ["-q", "-q", "-@", argfile.path], timeout: 300)
    } catch {
        return false
    }
    for shot in shots {
        for copy in shot.copies {
            let target = root.appendingPathComponent(copy)
            try? manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? manager.copyItem(at: root.appendingPathComponent(shot.rel), to: target)
        }
    }
    // Sidecars: one named like Lightroom (DSC6001.xmp), one like darktable (DSC6002.ARW.xmp).
    func xmp(rating: Int, subject: String?, label: String?) -> String {
        """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/"
         xmp:Rating="\(rating)"\(label.map { " xmp:Label=\"\($0)\"" } ?? "")>
        \(subject.map { "<dc:subject><rdf:Bag><rdf:li>\($0)</rdf:li></rdf:Bag></dc:subject>" } ?? "")
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
    }
    try? xmp(rating: 5, subject: "动物", label: nil).write(to: root.appendingPathComponent("Sony/RAW/DSC6001.xmp"), atomically: true, encoding: .utf8)
    try? xmp(rating: 3, subject: nil, label: "Green").write(to: root.appendingPathComponent("Sony/RAW/DSC6002.ARW.xmp"), atomically: true, encoding: .utf8)
    try? xmp(rating: 1, subject: "风景", label: nil).write(to: root.appendingPathComponent("Sony/RAW/DSC6000.xmp"), atomically: true, encoding: .utf8)
    // AppleDouble junk is skipped by name.
    try? Data([0, 5, 22, 7]).write(to: root.appendingPathComponent("Sony/RAW/._DSC6000.JPG"))
    return manager.fileExists(atPath: root.appendingPathComponent("Sony/RAW/DSC6004.ARW").path)
}

private func testWalk(_ fixture: URL) {
    let root = HabitsEngine.normalizedRoot(fixture)
    let listing = ExifScanner.walk(root, excludeDirs: [])
    expect(!listing.images.contains { $0.contains("/.hidden/") }, "hidden folders skipped")
    expect(!listing.images.contains { $0.contains("/._") }, "AppleDouble files skipped")
    expect(listing.sidecars.count == 3, "sidecars found, got \(listing.sidecars.count)")
    let excluded = ExifScanner.walk(root, excludeDirs: ["export"])
    expect(!excluded.images.contains { $0.contains("/Export/") } && excluded.images.count == listing.images.count - 5,
           "excluded folders by substring, case-insensitive")
    let own = fixture.appendingPathComponent("LightTable 高光")
    try? FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
    try? FileManager.default.copyItem(at: fixture.appendingPathComponent("Canon/food/IMG_4100.JPG"), to: own.appendingPathComponent("x.jpg"))
    expect(ExifScanner.walk(root, excludeDirs: []).images.count == listing.images.count, "LightTable output folders skipped")
    try? FileManager.default.removeItem(at: own)
}

private func runEngine(_ fixture: URL) async -> [String: Any]? {
    var options = HabitsOptions(root: fixture, outputHTML: fixture.appendingPathComponent("LightTable 拍摄习惯.html"))
    options.content = .meta
    do {
        let started = Date()
        let summary = try await HabitsEngine().run(options) { _, _ in }
        print("habits: \(summary.scannedFiles) files, \(summary.photoCount) photos in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        expect(!summary.clipUsed, "meta mode never looks at images")
        guard let file = summary.statsFile, let data = try? Data(contentsOf: file),
              let stats = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            failures.append("habits: stats.json missing")
            return nil
        }
        expect(file.deletingLastPathComponent().lastPathComponent == ".lighttable-cache", "caches in <root>/.lighttable-cache")
        return stats
    } catch {
        failures.append("habits: engine failed: \(error.localizedDescription)")
        return nil
    }
}

private func testHTML(_ url: URL, stats: [String: Any]) {
    guard let html = try? String(contentsOf: url, encoding: .utf8) else {
        failures.append("habits: HTML report missing")
        return
    }
    let external = try! NSRegularExpression(pattern: #"<(script|link|img|iframe)[^>]+(src|href)\s*=\s*"?(https?:)?//"#, options: [.caseInsensitive])
    expect(external.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) == nil, "no external scripts, styles or images")
    expect(!html.contains("http://") && !html.contains("https://"), "no network URLs at all")
    expect(html.contains("<style>") && html.contains("<svg"), "inline styles and SVG charts")
    let counts = stats["categoryCounts"] as? [String: Int] ?? [:]
    for name in HabitCategories.subjects {
        if (counts[name] ?? 0) > 0 {
            expect(html.contains("<label for=\"f\(HabitCategories.subjects.firstIndex(of: name)! + 1)\">\(name)"), "filter offers \(name)")
            expect(html.contains("以下只统计「\(name)」"), "pre-rendered section for \(name)")
        } else {
            expect(html.contains("<span class=\"disabled\" title=\"没有这类照片\">\(name)"), "empty category \(name) shown disabled")
        }
    }
    for title in ["概览", "机身", "照片内容", "镜头", "等效焦距", "光圈", "曝光", "拍摄时间", "横竖构图", "长焦专题", "35mm 附近专题"] {
        expect(html.contains("<h2>\(title)"), "section \(title) present")
    }
}

private func testCacheReuse(_ fixture: URL) async {
    let cacheFile = fixture.appendingPathComponent(".lighttable-cache/exif.json")
    let before = (try? FileManager.default.attributesOfItem(atPath: cacheFile.path)[.modificationDate] as? Date) ?? nil
    var options = HabitsOptions(root: fixture, outputHTML: fixture.appendingPathComponent("again.html"))
    options.content = .meta
    let messages = MessageLog()
    let started = Date()
    _ = try? await HabitsEngine().run(options) { message, _ in messages.add(message) }
    let seconds = Date().timeIntervalSince(started)
    expect(!messages.all.contains { $0.hasPrefix("读取照片信息") }, "second run reads EXIF from the cache only")
    expect(before != nil && seconds < 5, "cached re-run is fast (\(String(format: "%.2f", seconds)) s)")
    try? FileManager.default.removeItem(at: fixture.appendingPathComponent("again.html"))
}

private final class MessageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

// MARK: - Parity

private func findPython() -> (URL, URL)? {
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("reference/photo_habits.py")
    guard FileManager.default.fileExists(atPath: script.path) else { return nil }
    for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
        let python = URL(fileURLWithPath: dir).appendingPathComponent("python3")
        if FileManager.default.isExecutableFile(atPath: python.path) { return (python, script) }
    }
    return nil
}

private struct MDTable: Equatable {
    var heading: String
    var headers: [String]
    var rows: [[String]]
}

/// Tables of a photo-habits report.md, each with the nearest heading above it.
private func markdownTables(_ text: String) -> [MDTable] {
    var tables: [MDTable] = []
    var heading = ""
    var current: [[String]] = []
    func cells(_ line: String) -> [String] {
        var out: [String] = []
        var cell = ""
        var escaped = false
        for ch in line.dropFirst().dropLast() {
            if escaped { cell.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "|" { out.append(cell.trimmingCharacters(in: .whitespaces)); cell = ""; continue }
            cell.append(ch)
        }
        out.append(cell.trimmingCharacters(in: .whitespaces))
        return out
    }
    func flush() {
        if current.count >= 2 { tables.append(MDTable(heading: heading, headers: current[0], rows: Array(current.dropFirst(2)))) }
        current = []
    }
    for line in text.components(separatedBy: "\n") {
        if line.hasPrefix("|") { current.append(cells(line)); continue }
        flush()
        if line.hasPrefix("#") { heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
    }
    flush()
    return tables
}

private let factPrefixes = ["（有该数据的", "共 ", "光圈比", "- 光线", "只看留片", "闪光灯触发", "> 以下各节只统计", "没有等效", "没有这段"]

private func markdownFacts(_ text: String) -> [String] {
    text.components(separatedBy: "\n").filter { line in factPrefixes.contains { line.hasPrefix($0) } }
}

private func viewTables(_ view: [String: Any]) -> ([MDTable], [String]) {
    var tables: [MDTable] = []
    var facts: [String] = []
    for section in view["sections"] as? [[String: Any]] ?? [] {
        for block in section["blocks"] as? [[String: Any]] ?? [] {
            switch block["kind"] as? String {
            case "table":
                let t = block["table"] as? [String: Any] ?? [:]
                tables.append(MDTable(heading: t["heading"] as? String ?? "", headers: t["headers"] as? [String] ?? [],
                                      rows: t["rows"] as? [[String]] ?? []))
            case "fact": facts.append(block["text"] as? String ?? "")
            default: break
            }
        }
    }
    return (tables, facts)
}

private func compareTables(_ python: [MDTable], _ swift: [MDTable], _ label: String) -> Int {
    expect(python.count == swift.count, "\(label): table count \(swift.count) vs photo-habits \(python.count)")
    var cells = 0
    for (p, s) in zip(python, swift) {
        expect(p.heading == s.heading, "\(label): heading \(s.heading) vs \(p.heading)")
        expect(p.headers == s.headers, "\(label) \(p.heading): headers \(s.headers) vs \(p.headers)")
        expect(p.rows.count == s.rows.count, "\(label) \(p.heading): \(s.rows.count) rows vs \(p.rows.count)")
        for (pr, sr) in zip(p.rows, s.rows) {
            expect(pr == sr, "\(label) \(p.heading): row \(sr) vs photo-habits \(pr)")
            cells += pr.count
        }
    }
    return cells
}

/// Minimal CSV reader for photos.csv (quoted fields, doubled quotes).
private func parseCSV(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var quoted = false
    var chars = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
    chars.append("\n")
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if quoted {
            if c == "\"" {
                if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
            } else { field.append(c) }
        } else if c == "\"" { quoted = true
        } else if c == "," { row.append(field); field = ""
        } else if c == "\r\n" || c == "\n" || c == "\r" {
            if !(row.isEmpty && field.isEmpty) { row.append(field); rows.append(row) }
            row = []; field = ""
        } else { field.append(c) }
        i += 1
    }
    return rows
}

private func parity(fixture: URL, stats: [String: Any], python: (URL, URL)) {
    let out = scratchFolder("habits-photo-habits")
    let root = HabitsEngine.normalizedRoot(fixture)
    func runPython(_ extra: [String], outDir: URL) -> String? {
        do {
            let result = try SupervisedProcess.runToCompletion(
                executable: python.0, arguments: ["-I", python.1.path] + extra + ["--content", "meta", "--out", outDir.path], timeout: 300)
            guard result.exit == .exited(0) else {
                failures.append("habits: photo_habits.py failed: \(result.stderrTail)")
                return nil
            }
            return try String(contentsOf: outDir.appendingPathComponent("report.md"), encoding: .utf8)
        } catch {
            failures.append("habits: could not run photo_habits.py: \(error)")
            return nil
        }
    }
    // The engine's .lighttable-cache is hidden, so photo-habits does not see it either.
    guard let report = runPython([root], outDir: out) else { return }
    let views = stats["views"] as? [[String: Any]] ?? []
    guard let allView = views.first(where: { $0["name"] as? String == "全部" }) else {
        failures.append("habits: stats.json has no 全部 view")
        return
    }
    let (swiftTables, swiftFacts) = viewTables(allView)
    var cells = compareTables(markdownTables(report), swiftTables, "全部")
    expect(markdownFacts(report) == swiftFacts, "全部: sentences \(swiftFacts) vs photo-habits \(markdownFacts(report))")
    var facts = swiftFacts.count

    // Per-photo fields against photos.csv.
    let csv = parseCSV((try? String(contentsOf: out.appendingPathComponent("photos.csv"), encoding: .utf8)) ?? "")
    let photos = stats["photos"] as? [[String: Any]] ?? []
    expect(csv.count - 1 == photos.count, "photo count \(photos.count) vs photos.csv \(csv.count - 1)")
    var fields = 0
    if let header = csv.first {
        for (line, photo) in zip(csv.dropFirst(), photos) {
            for (column, name) in header.enumerated() where column < line.count {
                let expected = line[column]
                let value = photo[name]
                let same: Bool
                if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
                    same = expected == (n.boolValue ? "True" : "False")
                } else if let n = value as? NSNumber {
                    same = Double(expected).map { abs($0 - n.doubleValue) < 1e-9 * max(1, abs($0)) } ?? false
                } else if value == nil || value is NSNull {
                    same = expected.isEmpty
                } else {
                    same = expected == "\(value!)"
                }
                expect(same, "photo \(photo["path"] ?? "?") \(name): \(String(describing: value)) vs photos.csv \(expected)")
                fields += 1
            }
        }
    }

    // Each category view against photo-habits --category, from the sections after 照片内容.
    let cache = out.appendingPathComponent("exif_cache.json")
    for view in views.dropFirst() {
        guard let name = view["name"] as? String else { continue }
        let dir = scratchFolder("habits-photo-habits-\(name)")
        guard let text = runPython(["--from-cache", cache.path, "--category", name], outDir: dir) else { continue }
        let marker = text.range(of: "> 以下各节只统计")
        let tail = marker.map { String(text[$0.lowerBound...]) } ?? ""
        let (tables, viewFacts) = viewTables(view)
        cells += compareTables(markdownTables(tail), tables, name)
        expect(markdownFacts(tail) == viewFacts, "\(name): sentences \(viewFacts) vs photo-habits \(markdownFacts(tail))")
        facts += viewFacts.count
    }
    print("habits: parity compared \(cells) table cells, \(facts) sentences, \(fields) photo fields across \(views.count) views")
}

// MARK: - MobileCLIP

/// Classifies a few bundled macOS sample pictures when the model is already installed.
/// Never downloads in tests.
private func clipSmokeTest() async {
    guard HabitsClip.isModelInstalled else {
        print("habits: MobileCLIP model not installed, skipping image classification smoke test")
        return
    }
    let samples: [(String, Set<String>)] = [
        ("/Library/User Pictures/Animals/Eagle.heic", ["动物"]),
        ("/Library/User Pictures/Animals/Zebra.heic", ["动物"]),
        ("/Library/User Pictures/Flowers/Sunflower.heic", ["静物", "风景"]),
    ].filter { FileManager.default.fileExists(atPath: $0.0) }
    guard !samples.isEmpty else {
        print("habits: no sample pictures found, skipping image classification smoke test")
        return
    }
    print("habits: MobileCLIP smoke test")
    do {
        let probs = try await HabitsClip.probabilities(for: samples.map { URL(fileURLWithPath: $0.0) })
        for (sample, p) in zip(samples, probs) {
            guard let p else { failures.append("habits: could not read \(sample.0)"); continue }
            let category = HabitsClip.category(for: p)
            expect(sample.1.contains(category), "\(sample.0) classified as \(category) \(p)")
            expect(abs(p.values.reduce(0, +) - 1) < 0.01, "probabilities sum to 1")
        }
    } catch {
        print("habits: MobileCLIP could not load (\(error.localizedDescription)), skipping smoke test")
        return
    }

    // Whole engine in .clip mode on camera-tagged copies; the second run must hit the content cache.
    guard let exiftool = Tools.find(.exiftool) else { return }
    let folder = scratchFolder("habits-clip")
    let picks = ["/Library/User Pictures/Animals/Eagle.heic", "/Library/User Pictures/Animals/Zebra.heic",
                 "/System/Library/Desktop Pictures/.thumbnails/The Beach.heic"].filter { FileManager.default.fileExists(atPath: $0) }
    for (i, path) in picks.enumerated() {
        // Some sample pictures are relative symlinks; copy the bytes.
        try? Data(contentsOf: URL(fileURLWithPath: path).resolvingSymlinksInPath()).write(to: folder.appendingPathComponent("P\(i).heic"))
    }
    _ = try? Tools.run(exiftool, ["-q", "-q", "-overwrite_original", "-Make=SONY", "-Model=ILCE-7M4", "-Software=", "-CreatorTool=",
                                  "-DateTimeOriginal=2024:05:01 10:00:00", folder.path])
    var options = HabitsOptions(root: folder, outputHTML: folder.appendingPathComponent("r.html"))
    options.content = .clip
    do {
        let first = try await HabitsEngine().run(options) { _, _ in }
        expect(first.clipUsed, "clip mode looked at images")
        expect(first.categoryCounts["动物"] == picks.filter { $0.contains("Animals") }.count, "animals by MobileCLIP: \(first.categoryCounts)")
        let log = MessageLog()
        _ = try await HabitsEngine().run(options) { message, _ in log.add(message) }
        expect(!log.all.contains { $0.hasPrefix("看图分类") }, "second run reuses cached classifications")
    } catch {
        failures.append("habits: clip-mode run failed: \(error.localizedDescription)")
    }
}

/// Tuning aid for the 其他 threshold: `LIGHTTABLE_HABITS_TUNE=<file with one image path per line>
/// lighttable-selftest habits` prints MobileCLIP's probabilities per image as TSV.
func runHabitsTuning(_ listFile: String) async {
    let paths = ((try? String(contentsOfFile: listFile, encoding: .utf8)) ?? "")
        .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    guard let probs = try? await HabitsClip.probabilities(for: paths.map { URL(fileURLWithPath: $0) }) else {
        print("habits tuning: MobileCLIP unavailable")
        return
    }
    for (path, p) in zip(paths, probs) {
        guard let p else { print("\(path)\tunreadable"); continue }
        let sorted = p.sorted { $0.value > $1.value }
        print("\((path as NSString).lastPathComponent)\t" + sorted.prefix(3).map { "\($0.key) \(String(format: "%.2f", $0.value))" }.joined(separator: "\t"))
    }
}
