import Foundation

/// The statistics of photo-habits, section by section. Table headings, headers and cell formats
/// follow `photo_habits.py` exactly; only the explanations (notes) are reworded for the HTML.
struct ReportBuilder {
    let all: [PhotoRecord]
    let habit: [PhotoRecord]
    let stats: [(String, Int)]
    let includePhones: Bool
    let clipUsed: Bool
    /// Smallest f-number seen per lens, over all habit photos (not only the filtered category).
    let lensMin: [String: Double]

    init(all: [PhotoRecord], habit: [PhotoRecord], stats: [(String, Int)], includePhones: Bool, clipUsed: Bool) {
        self.all = all
        self.habit = habit
        self.stats = stats
        self.includePhones = includePhones
        self.clipUsed = clipUsed
        var lensMin: [String: Double] = [:]
        for r in habit where truthy(r.fnum) { lensMin[r.lens] = min(lensMin[r.lens] ?? 99, r.fnum!) }
        self.lensMin = lensMin
    }

    typealias Bucket = (String, (Double) -> Bool)
    static func rng(_ lo: Double, _ hi: Double) -> (Double) -> Bool { { lo <= $0 && $0 < hi } }

    static let focalBuckets: [Bucket] = [
        ("< 20mm", rng(0, 20)), ("20–23mm", rng(20, 24)), ("24–27mm", rng(24, 28)),
        ("28–34mm", rng(28, 35)), ("35–44mm", rng(35, 45)), ("45–59mm", rng(45, 60)),
        ("60–69mm", rng(60, 70)), ("70–99mm", rng(70, 100)), ("100–134mm", rng(100, 135)),
        ("135–199mm", rng(135, 200)), ("200–299mm", rng(200, 300)), ("≥ 300mm", rng(300, 1e9)),
    ]
    static let apertureBuckets: [Bucket] = [
        ("≤ f/1.4", rng(0, 1.5)), ("f/1.5–1.9", rng(1.5, 2.0)), ("f/2–2.7", rng(2.0, 2.8)),
        ("f/2.8–3.9", rng(2.8, 4.0)), ("f/4–5.5", rng(4.0, 5.6)), ("f/5.6–7.9", rng(5.6, 8.0)),
        ("f/8–10", rng(8.0, 11.0)), ("≥ f/11", rng(11.0, 1e9)),
    ]
    static let hourBuckets: [Bucket] = [
        ("5–8 点", rng(5, 9)), ("9–11 点", rng(9, 12)), ("12–15 点", rng(12, 16)),
        ("16–19 点", rng(16, 20)), ("20–4 点", { $0 >= 20 || $0 < 5 }),
    ]

    // MARK: Helpers

    /// Count per bucket; first matching bucket wins. Shares are of photos that have the value.
    func bucketTable(_ heading: String, _ column: String, _ recs: [PhotoRecord],
                     _ value: (PhotoRecord) -> Double?, _ buckets: [Bucket]) -> [ReportBlock] {
        var counts = [Int](repeating: 0, count: buckets.count)
        var have = 0
        for r in recs {
            guard let v = value(r) else { continue }
            have += 1
            if let i = buckets.firstIndex(where: { $0.1(v) }) { counts[i] += 1 }
        }
        let rows = buckets.indices.map { i in
            [buckets[i].0, "\(counts[i])", Fmt.pct(counts[i], have), Fmt.bar(counts[i], have)]
        }
        var blocks = [ReportBlock.table(heading, .buckets, [column, "张数", "占比", ""], rows)]
        if have != recs.count { blocks.append(.fact("（有该数据的 \(have) 张）")) }
        return blocks
    }

    func crosstab(_ heading: String, _ column: String, _ groups: [(String, [PhotoRecord])],
                  _ value: (PhotoRecord) -> Double?, _ buckets: [Bucket]) -> ReportBlock {
        var columns: [String] = []
        var counts: [([Int], Int)] = []
        for (name, recs) in groups {
            var c = [Int](repeating: 0, count: buckets.count)
            var have = 0
            for r in recs {
                guard let v = value(r) else { continue }
                have += 1
                if let i = buckets.firstIndex(where: { $0.1(v) }) { c[i] += 1 }
            }
            columns.append("\(name)(\(have))")
            counts.append((c, have))
        }
        let rows = buckets.indices.map { i in
            [buckets[i].0] + counts.map { c, have in c[i] != 0 ? Fmt.pct(c[i], have) : "" }
        }
        return .table(heading, .crosstab, [column] + columns, rows)
    }

    func isWideOpen(_ r: PhotoRecord) -> Bool? {
        guard let f = r.fnum else { return nil }
        guard let ref = or(r.maxAp, lensMin[r.lens]), ref != 0 else { return nil }
        return f <= ref * 1.06
    }

    private func wideOpenShare(_ rs: [PhotoRecord]) -> String {
        let wo = rs.compactMap(isWideOpen)
        return Fmt.pct(wo.filter { $0 }.count, wo.count)
    }

    private func ratedShare(_ rs: [PhotoRecord]) -> String { Fmt.pct(rs.filter(\.rated).count, rs.count) }

    // MARK: Sections

    func overview(root: String, category: String?, categoryCount: Int?) -> ReportSection {
        let times = all.compactMap(\.time)
        let days = Set(times.map(\.date))
        var rows = stats.map { [$0.0, "\($0.1)"] }
        rows += [["去重后照片", "\(all.count)"],
                 ["其中手机", "\(all.filter(\.phone).count)"],
                 ["进入习惯分析" + (includePhones ? "（含手机）" : "（不含手机）"), "\(habit.count)"]]
        if let category, let categoryCount { rows.append(["只看类别", "\(category)：\(categoryCount) 张"]) }
        rows.append(["拍摄天数", "\(days.count)"])
        if let lo = times.min(), let hi = times.max() { rows.append(["时间跨度", "\(lo.date) 至 \(hi.date)"]) }
        let nrated = habit.filter(\.rated).count
        rows.append(["有星级（≥1 星）", "\(nrated)（\(Fmt.pct(nrated, habit.count))）"])
        var blocks = [ReportBlock.table("概览", .keyValue, ["项目", "数值"], rows)]
        if nrated < 30 { blocks.append(.note("星级照片太少，下文「留片」相关的数字参考价值有限。")) }
        return ReportSection(id: "overview", title: "概览", blocks: blocks)
    }

    func bodies() -> ReportSection {
        let groups = groupedBySize(all) { $0.body }
        let rows = groups.map { body, rs -> [String] in
            let ts = rs.compactMap(\.time)
            let days = Set(ts.map(\.date)).count
            let span = ts.isEmpty ? "—" : "\(ts.min()!.yearMonth) 至 \(ts.max()!.yearMonth)"
            return [body, "\(rs.count)", Fmt.pct(rs.count, all.count), "\(days)",
                    days > 0 ? String(format: "%.0f", Double(rs.count) / Double(days)) : "—", span,
                    String(format: "%.0f%%", Double(rs.filter(\.raw).count) / Double(rs.count) * 100)]
        }
        var blocks = [ReportBlock.table("机身", .plain, ["机身", "张数", "占比", "拍摄天数", "张/天", "使用期间", "RAW 比例"], rows)]
        let years = Set(all.compactMap { $0.time?.year }).sorted()
        let top = OrderedCounter(all.map(\.body)).mostCommon(8).map(\.0)
        if !years.isEmpty {
            let yearRows = years.map { y -> [String] in
                let c = OrderedCounter(all.filter { $0.time?.year == y }.map(\.body))
                return ["\(y)", "\(c.total)"] + top.map { c[$0] > 0 ? "\(c[$0])" : "" }
            }
            blocks.append(.table("每年各机身张数", .plain, ["年份", "合计"] + top, yearRows))
        }
        return ReportSection(id: "bodies", title: "机身", blocks: blocks)
    }

    func content() -> ReportSection {
        var byCat: [String: [PhotoRecord]] = [:]
        for r in habit { byCat[r.category ?? "", default: []].append(r) }
        let cats = byCat.keys.sorted { a, b in
            let ca = byCat[a]!.count, cb = byCat[b]!.count
            if ca != cb { return ca > cb }
            return (HabitCategories.all.firstIndex(of: a) ?? 99) < (HabitCategories.all.firstIndex(of: b) ?? 99)
        }
        var blocks: [ReportBlock] = [
            .note(clipUsed
                ? "每张照片按 关键词 → 文件夹名 → MobileCLIP 看图 → 相机场景模式与人脸 的顺序判断题材，用第一个有结果的。"
                : "每张照片按 关键词 → 文件夹名 → 相机场景模式与人脸 的顺序判断题材。这次没有看图，有人的街拍会被算成人像，判断不了的记为「未分类」。"),
        ]
        let src = OrderedCounter(habit.map { $0.categorySource.isEmpty ? "无可用信号" : $0.categorySource })
        blocks.append(.table("分类依据", .plain, ["依据", "张数", "占比"],
                             src.mostCommon().map { [$0.0, "\($0.1)", Fmt.pct($0.1, habit.count)] }))
        if clipUsed, byCat["其他"] != nil {
            blocks.append(.note("看图时最有把握的题材概率低于 \(Int(HabitCategories.clipMinimumProbability * 100))% 的照片归入「其他」。"))
        }
        let rows = cats.map { c -> [String] in
            let rs = byCat[c]!
            let ori = rs.compactMap(\.portrait)
            let topLens = OrderedCounter(rs.map(\.lens)).mostCommon(1)[0]
            return [c, "\(rs.count)", Fmt.pct(rs.count, habit.count),
                    Fmt.fmt(Fmt.median(rs.map(\.eqFocal))), Fmt.fmt(Fmt.median(rs.map(\.eqFnum)), 1),
                    wideOpenShare(rs), Fmt.fmt(Fmt.median(rs.map(\.iso))),
                    Fmt.shutter(Fmt.median(rs.map(\.shutter))), Fmt.pct(ori.filter { $0 }.count, ori.count),
                    ratedShare(rs), "\(topLens.0)（\(Fmt.pct(topLens.1, rs.count))）"]
        }
        blocks.append(.table("各类别的习惯", .plain,
                             ["类别", "张数", "占比", "中位等效焦距", "中位等效光圈", "全开比例", "中位 ISO",
                              "中位快门", "竖拍比例", "留片率(≥1星)", "最常用镜头"], rows))
        let groups = cats.filter { byCat[$0]!.count >= 10 }.map { ($0, byCat[$0]!) }
        if !groups.isEmpty {
            blocks.append(.note("下面三张表每列加起来是 100%，少于 10 张的题材不列。"))
            blocks.append(crosstab("各类别的等效焦距分布", "等效焦距", groups, \.eqFocal, Self.focalBuckets))
            blocks.append(crosstab("各类别的等效光圈分布", "等效光圈", groups, \.eqFnum, Self.apertureBuckets))
            blocks.append(crosstab("各类别的拍摄时段", "时段", groups, { $0.time.map { Double($0.hour) } }, Self.hourBuckets))
        }
        return ReportSection(id: "content", title: "照片内容", blocks: blocks)
    }

    func lenses(_ recs: [PhotoRecord]) -> ReportSection {
        let rows = groupedBySize(recs) { $0.lens }.map { lens, rs -> [String] in
            let ts = rs.compactMap(\.time)
            let days = Set(ts.map(\.date)).count
            let bodies = OrderedCounter(rs.map(\.body)).mostCommon(2).map(\.0).joined(separator: ", ")
            return [lens, bodies, "\(rs.count)", Fmt.pct(rs.count, recs.count), "\(days)",
                    ts.isEmpty ? "—" : "\(ts.min()!.yearMonth)–\(ts.max()!.yearMonth)",
                    Fmt.fmt(Fmt.median(rs.map(\.eqFocal))), Fmt.fmt(Fmt.median(rs.map(\.fnum)), 1),
                    wideOpenShare(rs), ratedShare(rs)]
        }
        return ReportSection(id: "lenses", title: "镜头", blocks: [
            .note("「全开」指用了这支镜头能开到的最大光圈；「等效焦距」按 35mm 全画幅换算。"),
            .table("镜头", .plain, ["镜头", "机身", "张数", "占比", "使用天数", "使用期间", "中位等效焦距",
                                   "中位光圈", "全开比例", "留片率(≥1星)"], rows),
        ])
    }

    func focal(_ recs: [PhotoRecord]) -> ReportSection {
        var blocks = bucketTable("等效焦距", "等效焦距", recs, \.eqFocal, Self.focalBuckets)
        let rated = recs.filter(\.rated)
        if rated.count >= 30 {
            blocks += bucketTable("留片（≥1 星）的等效焦距", "等效焦距", rated, \.eqFocal, Self.focalBuckets)
        }
        var rows: [[String]] = []
        for (lens, rs) in groupedBySize(recs.filter { truthy($0.focal) }, { $0.lens }) {
            let fs = rs.map { $0.focal! }
            let lo = fs.min()!, hi = fs.max()!
            if rs.count < 30 || hi / lo < 1.3 { continue }
            let atLo = fs.filter { $0 <= lo * 1.05 }.count
            let atHi = fs.filter { $0 >= hi * 0.95 }.count
            let top = OrderedCounter(fs.map { Fmt.pyRound($0) }).mostCommon(5).map { "\($0.0)mm(\($0.1))" }.joined(separator: ", ")
            rows.append([lens, "\(rs.count)", "\(Fmt.g(lo))–\(Fmt.g(hi))mm", Fmt.pct(atLo, rs.count), Fmt.pct(atHi, rs.count), top])
        }
        if !rows.isEmpty {
            blocks.append(.note("停在广端或长端的比例高，说明焦段经常不够用。这里是镜头上的实际焦距，不是等效焦距。"))
            blocks.append(.table("变焦镜头停在哪", .plain, ["镜头", "张数", "实际用到的范围", "停在广端", "停在长端", "最常用焦距(张数)"], rows))
        }
        return ReportSection(id: "focal", title: "等效焦距", blocks: blocks)
    }

    func aperture(_ recs: [PhotoRecord]) -> ReportSection {
        var blocks = bucketTable("实际光圈", "光圈", recs, \.fnum, Self.apertureBuckets)
        blocks.append(.note("等效光圈按画幅换算景深：APS-C 的 f/1.2 约等于全画幅 f/1.8，X100 系列的 f/2 约等于全画幅 f/2.8。"))
        blocks += bucketTable("等效光圈（按画幅换算后的景深与总进光）", "等效光圈", recs, \.eqFnum, Self.apertureBuckets)
        return ReportSection(id: "aperture", title: "光圈", blocks: blocks)
    }

    func exposure(_ recs: [PhotoRecord]) -> ReportSection {
        let iso: [Bucket] = [("≤ 200", Self.rng(0, 201)), ("201–400", Self.rng(201, 401)), ("401–800", Self.rng(401, 801)),
                             ("801–1600", Self.rng(801, 1601)), ("1601–3200", Self.rng(1601, 3201)),
                             ("3201–6400", Self.rng(3201, 6401)), ("6401–12800", Self.rng(6401, 12801)), ("> 12800", Self.rng(12801, 1e9))]
        let sh: [Bucket] = [("≥ 1s", Self.rng(1, 1e9)), ("1/2–1/30", Self.rng(1.0 / 30 - 1e-6, 1)),
                            ("1/31–1/60", Self.rng(1.0 / 60 - 1e-6, 1.0 / 30 - 1e-6)),
                            ("1/61–1/125", Self.rng(1.0 / 125 - 1e-6, 1.0 / 60 - 1e-6)),
                            ("1/126–1/250", Self.rng(1.0 / 250 - 1e-6, 1.0 / 125 - 1e-6)),
                            ("1/251–1/1000", Self.rng(1.0 / 1000 - 1e-6, 1.0 / 250 - 1e-6)),
                            ("快于 1/1000", Self.rng(0, 1.0 / 1000 - 1e-6))]
        var blocks = bucketTable("ISO", "ISO", recs, \.iso, iso)
        blocks += bucketTable("快门", "快门", recs, \.shutter, sh)

        let bodyRows = groupedBySize(recs) { $0.body }.map { body, rs -> [String] in
            let isos = rs.compactMap(\.iso).filter { $0 != 0 }
            return [body, "\(rs.count)", Fmt.fmt(Fmt.median(isos)), Fmt.pct(isos.filter { $0 >= 3200 }.count, isos.count),
                    Fmt.pct(isos.filter { $0 >= 6400 }.count, isos.count), Fmt.fmt(isos.max()),
                    Fmt.shutter(Fmt.median(rs.map(\.shutter)))]
        }
        blocks.append(.table("各机身的感光度", .plain, ["机身", "张数", "中位 ISO", "ISO ≥ 3200", "ISO ≥ 6400", "最高 ISO", "中位快门"], bodyRows))

        func counterRows(_ key: (PhotoRecord) -> String) -> [[String]] {
            OrderedCounter(recs.map { key($0).isEmpty ? "(无记录)" : key($0) }).mostCommon(8)
                .map { [$0.0, "\($0.1)", Fmt.pct($0.1, recs.count)] }
        }
        blocks.append(.table("曝光模式", .plain, ["模式", "张数", "占比"], counterRows(\.program)))
        blocks.append(.table("测光", .plain, ["测光", "张数", "占比"], counterRows(\.metering)))
        blocks.append(.table("白平衡", .plain, ["白平衡", "张数", "占比"], counterRows(\.wb)))

        let ev: [Bucket] = [("≤ −1.3", Self.rng(-1e9, -1.2)), ("−1 至 −0.3", Self.rng(-1.2, -0.2)), ("0", Self.rng(-0.2, 0.2)),
                            ("+0.3 至 +1", Self.rng(0.2, 1.2)), ("≥ +1.3", Self.rng(1.2, 1e9))]
        blocks += bucketTable("曝光补偿", "补偿", recs, \.ev, ev)
        let flashes = recs.compactMap(\.flash)
        let fired = flashes.filter { $0 }.count
        blocks.append(.fact("闪光灯触发：\(fired) 张，占有记录的 \(Fmt.pct(fired, flashes.count))"))
        return ReportSection(id: "exposure", title: "曝光", blocks: blocks)
    }

    func time(_ recs: [PhotoRecord]) -> ReportSection? {
        let ts = recs.compactMap { r in r.time.map { ($0, r.body) } }
            .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : pyLess($0.1, $1.1) }
        guard !ts.isEmpty else { return nil }
        let n = ts.count
        let hours = OrderedCounter(ts.map { $0.0.hour })
        let maxHour = hours.mostCommon(1).first?.1 ?? 0
        var blocks: [ReportBlock] = [
            .table("一天中的时段", .hours, ["时段", "张数", "占比", ""],
                   (0..<24).map { h in [String(format: "%02d:00", h), "\(hours[h])", Fmt.pct(hours[h], n), Fmt.bar(hours[h], maxHour, width: 25)] }),
        ]
        let wd = OrderedCounter(ts.map { $0.0.weekday })
        let names = Array("一二三四五六日")
        blocks.append(.table("星期", .columns, ["星期", "张数", "占比"], (0..<7).map { ["周\(names[$0])", "\(wd[$0])", Fmt.pct(wd[$0], n)] }))
        let mo = OrderedCounter(ts.map { $0.0.month })
        blocks.append(.table("月份（各年合计）", .columns, ["月份", "张数", "占比"], (1...12).map { ["\($0) 月", "\(mo[$0])", Fmt.pct(mo[$0], n)] }))

        let perDay = OrderedCounter(ts.map { $0.0.date })
        let vals = perDay.keys.map { perDay[$0] }.sorted()
        let burst = zip(ts, ts.dropFirst()).filter { a, b in a.1 == b.1 && b.0.seconds - a.0.seconds <= 1 }.count
        let busiest = perDay.mostCommon(1)[0]
        blocks.append(.table("拍摄节奏", .keyValue, ["项目", "数值"], [
            ["拍摄天数", "\(perDay.keys.count)"],
            ["每个拍摄日张数（中位）", Fmt.fmt(Fmt.median(vals.map(Double.init)))],
            ["每个拍摄日张数（90 分位）", "\(vals[Int(Double(vals.count) * 0.9)])"],
            ["单日最多", "\(vals.last!)（\(busiest.0)）"],
            ["与上一张间隔 ≤ 1 秒（连拍或补拍）", "\(burst)（\(Fmt.pct(burst, n))）"],
        ]))
        return ReportSection(id: "time", title: "拍摄时间", blocks: blocks)
    }

    func orientation(_ recs: [PhotoRecord]) -> ReportSection? {
        let rows = groupedBySize(recs.filter { $0.portrait != nil }) { $0.body }.map { body, rs in
            [body, "\(rs.count)", Fmt.pct(rs.filter { $0.portrait! }.count, rs.count)]
        }
        guard !rows.isEmpty else { return nil }
        return ReportSection(id: "orientation", title: "横竖构图", blocks: [.table("横竖构图", .plain, ["机身", "有记录张数", "竖拍比例"], rows)])
    }

    /// Wide-aperture photos in good light (ISO ≤ 400) were probably opened up for background blur,
    /// the rest for light.
    private func lightVsBlur(_ rs: [PhotoRecord]) -> (Int, Int) {
        let blur = rs.filter { $0.iso != nil && $0.iso! <= 400 }.count
        return (blur, rs.count - blur)
    }

    func tele(_ recs: [PhotoRecord]) -> ReportSection {
        let title = "长焦专题（等效 ≥ 70mm）"
        let tele = recs.filter { truthy($0.eqFocal) && $0.eqFocal! >= 70 }
        guard !tele.isEmpty else { return ReportSection(id: "tele", title: title, blocks: [.fact("没有等效 70mm 以上的照片。")]) }
        var blocks: [ReportBlock] = [.fact("共 \(tele.count) 张，占习惯分析照片的 \(Fmt.pct(tele.count, recs.count))。")]
        blocks += bucketTable(title, "等效焦距", tele, \.eqFocal, Array(Self.focalBuckets[7...]))
        blocks.append(.table("用的镜头", .plain, ["镜头", "张数", "占比"],
                             OrderedCounter(tele.map(\.lens)).mostCommon(8).map { [$0.0, "\($0.1)", Fmt.pct($0.1, tele.count)] }))

        let known = tele.filter { truthy($0.fnum) && truthy($0.iso) }
        let already = known.filter { $0.fnum! >= 5.6 * 0.97 }
        let wider = known.filter { $0.fnum! < 5.6 * 0.97 }
        let order = ["换 f/5.6 后 ISO ≤ 1600，无影响", "ISO 1600–6400，可接受",
                     "ISO 6400–12800，画质明显下降", "ISO > 12800，基本废片或必须降快门"]
        var sim = [Int](repeating: 0, count: 4)
        for r in wider {
            let need = r.iso! * pow(5.6 / r.fnum!, 2)
            sim[need <= 1600 ? 0 : need <= 6400 ? 1 : need <= 12800 ? 2 : 3] += 1
        }
        let rows = [["本来就在 f/5.6 或更小", "\(already.count)", Fmt.pct(already.count, known.count)]]
            + order.indices.map { [order[$0], "\(sim[$0])", Fmt.pct(sim[$0], known.count)] }
        blocks.append(.note("假设快门不变，把光圈换成 f/5.6 后按光圈差折算需要的 ISO，用来回答「f/5.6 的长焦镜头够不够用」。"))
        blocks.append(.table("如果这些长焦照片都只能用 f/5.6", .plain, ["情况", "张数", "占比"], rows))

        let (blur, light) = lightVsBlur(wider)
        blocks.append(.fact("光圈比 f/5.6 大的 \(wider.count) 张里："))
        blocks.append(.fact("- 光线充足（ISO ≤ 400）仍开大，多半为了虚化：\(blur) 张（\(Fmt.pct(blur, wider.count))）"))
        blocks.append(.fact("- 光线不足，开大是为了进光：\(light) 张（\(Fmt.pct(light, wider.count))）"))

        let ratedTele = known.filter(\.rated)
        if ratedTele.count >= 20 {
            let rw = ratedTele.filter { $0.fnum! < 5.6 * 0.97 }
            let hurt = rw.filter { $0.iso! * pow(5.6 / $0.fnum!, 2) > 6400 }.count
            blocks.append(.fact("只看留片（≥1 星）的 \(ratedTele.count) 张长焦：光圈比 f/5.6 大的 \(rw.count) 张，"
                + "换 f/5.6 后 ISO 超过 6400 的 \(hurt) 张（\(Fmt.pct(hurt, ratedTele.count))）。"))
        }
        return ReportSection(id: "tele", title: title, blocks: blocks)
    }

    func thirtyFive(_ recs: [PhotoRecord]) -> ReportSection {
        let title = "35mm 附近专题（等效 28–44mm）"
        let rs = recs.filter { truthy($0.eqFocal) && $0.eqFocal! >= 28 && $0.eqFocal! < 45 }
        guard !rs.isEmpty else { return ReportSection(id: "35mm", title: title, blocks: [.fact("没有这段焦距的照片。")]) }
        let rows = groupedBySize(rs) { $0.lens }.map { lens, v -> [String] in
            let ef = v.compactMap(\.eqFnum).filter { $0 != 0 }
            let wide = v.filter { truthy($0.eqFnum) && $0.eqFnum! < 2.8 * 0.97 }
            let (blur, _) = lightVsBlur(wide)
            return [lens, "\(v.count)", Fmt.fmt(Fmt.median(ef), 1), Fmt.pct(wide.count, ef.count),
                    Fmt.pct(blur, wide.count), ratedShare(v)]
        }
        return ReportSection(id: "35mm", title: title, blocks: [
            .fact("共 \(rs.count) 张，占习惯分析照片的 \(Fmt.pct(rs.count, recs.count))。"),
            .note("X100 系列相当于全画幅 f/2.8。下表看这段焦距里有多少照片用了比 f/2.8 更大的等效光圈，其中多少是光线充足时为了虚化而开大。"),
            .table(title, .plain, ["镜头", "张数", "中位等效光圈", "等效 < f/2.8", "其中光线充足(为虚化)", "留片率"], rows),
        ])
    }

    /// Sections after 照片内容, for all habit photos or one category, like `--category`.
    func habitSections(_ recs: [PhotoRecord]) -> [ReportSection] {
        guard !recs.isEmpty else { return [] }
        return [lenses(recs), focal(recs), aperture(recs), exposure(recs)]
            + [time(recs), orientation(recs)].compactMap { $0 }
            + [tele(recs), thirtyFive(recs)]
    }

    func views(root: String) -> [ReportView] {
        var views = [ReportView(name: "全部", count: habit.count,
                                sections: [overview(root: root, category: nil, categoryCount: nil), bodies()]
                                    + (habit.isEmpty ? [] : [content()]) + habitSections(habit))]
        for name in HabitCategories.subjects {
            let recs = habit.filter { $0.category == name }
            guard !recs.isEmpty else { continue }
            var sections = habitSections(recs)
            sections[0].blocks.insert(.fact("> 以下各节只统计：\(name)（\(recs.count) 张）"), at: 0)
            views.append(ReportView(name: name, count: recs.count, sections: sections))
        }
        return views
    }
}
