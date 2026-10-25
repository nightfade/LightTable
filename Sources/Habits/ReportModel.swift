import Foundation

/// The report as data: sections of tables and short sentences, with every cell already formatted
/// exactly as photo-habits prints it. The HTML is drawn from this, and `stats.json` is this
/// serialised, so the parity test compares what the user actually sees.
struct ReportTable: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Label, count, share, bar: drawn as a horizontal bar chart.
        case buckets
        /// Hour of day: vertical bars.
        case hours
        /// Weekday or month: vertical bars.
        case columns
        /// Shares per group, drawn as a heat-shaded table.
        case crosstab
        case plain
        /// Two-column item/value list.
        case keyValue
    }
    var heading: String
    var kind: Kind
    var headers: [String]
    var rows: [[String]]
}

struct ReportBlock: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case table
        /// A sentence carrying numbers; part of the parity comparison.
        case fact
        /// Explanation for the reader; worded for LightTable, not compared.
        case note
    }
    var kind: Kind
    var table: ReportTable?
    var text: String?

    static func table(_ heading: String, _ kind: ReportTable.Kind, _ headers: [String], _ rows: [[String]]) -> ReportBlock {
        ReportBlock(kind: .table, table: ReportTable(heading: heading, kind: kind, headers: headers, rows: rows), text: nil)
    }
    static func fact(_ text: String) -> ReportBlock { ReportBlock(kind: .fact, table: nil, text: text) }
    static func note(_ text: String) -> ReportBlock { ReportBlock(kind: .note, table: nil, text: text) }
}

struct ReportSection: Codable, Sendable {
    var id: String
    var title: String
    var blocks: [ReportBlock]
}

/// One filter choice: 全部 or a subject category.
struct ReportView: Codable, Sendable {
    var name: String
    var count: Int
    var sections: [ReportSection]
}

// MARK: - Python-compatible formatting

enum Fmt {
    /// `f"{a / b * 100:.1f}%"`, or "—" when b is 0.
    static func pct(_ a: Double, _ b: Double) -> String {
        b != 0 ? String(format: "%.1f%%", a / b * 100) : "—"
    }
    static func pct(_ a: Int, _ b: Int) -> String { pct(Double(a), Double(b)) }

    /// Python's `round()`: halves go to the even neighbour.
    static func pyRound(_ v: Double) -> Int { Int(v.rounded(.toNearestOrEven)) }

    static func bar(_ a: Int, _ b: Int, width: Int = 30) -> String {
        b != 0 ? String(repeating: "█", count: max(0, pyRound(Double(a) / Double(b) * Double(width)))) : ""
    }

    static func fmt(_ v: Double?, _ digits: Int = 0) -> String {
        guard let v else { return "—" }
        return String(format: "%.\(digits)f", v)
    }

    /// `f"{v:g}"`
    static func g(_ v: Double) -> String { String(format: "%g", v) }

    static func shutter(_ s: Double?) -> String {
        guard let s else { return "—" }
        return s < 1 ? "1/\(pyRound(1 / s))" : "\(g(s))s"
    }

    /// `statistics.median` of the values that are present.
    static func median(_ values: [Double?]) -> Double? {
        let v = values.compactMap { $0 }.sorted()
        guard !v.isEmpty else { return nil }
        return v.count % 2 == 1 ? v[v.count / 2] : (v[v.count / 2 - 1] + v[v.count / 2]) / 2
    }
}

/// `collections.Counter` with `most_common`: ties keep first-seen order.
struct OrderedCounter<Key: Hashable> {
    private(set) var keys: [Key] = []
    private var counts: [Key: Int] = [:]

    init() {}
    init(_ items: some Sequence<Key>) { for item in items { add(item) } }

    mutating func add(_ key: Key, _ n: Int = 1) {
        if counts[key] == nil { keys.append(key) }
        counts[key, default: 0] += n
    }
    subscript(_ key: Key) -> Int { counts[key] ?? 0 }
    var total: Int { counts.values.reduce(0, +) }
    var isEmpty: Bool { keys.isEmpty }

    func mostCommon(_ n: Int? = nil) -> [(Key, Int)] {
        let sorted = keys.enumerated().sorted { a, b in
            let ca = counts[a.element]!, cb = counts[b.element]!
            return ca != cb ? ca > cb : a.offset < b.offset
        }.map { ($0.element, counts[$0.element]!) }
        return n.map { Array(sorted.prefix($0)) } ?? sorted
    }
}

/// `defaultdict(list)` keeping first-seen key order, sorted by group size like
/// `sorted(by.items(), key=lambda x: -len(x[1]))`.
func groupedBySize<Key: Hashable>(_ records: [PhotoRecord], _ key: (PhotoRecord) -> Key?) -> [(Key, [PhotoRecord])] {
    var order: [Key] = []
    var groups: [Key: [PhotoRecord]] = [:]
    for r in records {
        guard let k = key(r) else { continue }
        if groups[k] == nil { order.append(k) }
        groups[k, default: []].append(r)
    }
    return order.enumerated().sorted { a, b in
        let ca = groups[a.element]!.count, cb = groups[b.element]!.count
        return ca != cb ? ca > cb : a.offset < b.offset
    }.map { ($0.element, groups[$0.element]!) }
}

/// Python string ordering is by code point; Swift's `<` on String is not always.
func pyLess(_ a: String, _ b: String) -> Bool { a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) }
