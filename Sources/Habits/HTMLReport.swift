import Foundation

/// Renders the report as one self-contained HTML file: inline CSS, charts as inline SVG or CSS
/// bars, no scripts and no network. The category filter is a row of radio buttons; CSS shows the
/// matching pre-rendered view, so it works even where scripts are blocked (e.g. Quick Look).
enum HTMLReport {
    struct Card {
        let label: String
        let value: String
        let detail: String
    }

    static func render(title: String, subtitle: String, generated: String, cards: [Card], views: [ReportView]) -> String {
        var out = """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(title))</title>
        <style>\(css(viewCount: HabitCategories.subjects.count + 1))</style>
        </head>
        <body>
        <div class="page">

        """
        // Radio inputs first so the CSS sibling selectors below can see them.
        let names = ["全部"] + HabitCategories.subjects
        for (i, name) in names.enumerated() where views.contains(where: { $0.name == name }) {
            out += "<input type=\"radio\" name=\"cat\" id=\"f\(i)\" class=\"filter-input\"\(i == 0 ? " checked" : "")>\n"
        }
        out += """
        <header>
        <h1>\(esc(title))</h1>
        <p class="sub">\(esc(subtitle))</p>
        <p class="gen">生成于 \(esc(generated))</p>
        </header>
        <div class="cards">
        """
        for card in cards {
            out += "<div class=\"card\"><div class=\"card-label\">\(esc(card.label))</div><div class=\"card-value\">\(esc(card.value))</div>"
                + (card.detail.isEmpty ? "" : "<div class=\"card-detail\">\(esc(card.detail))</div>") + "</div>"
        }
        out += "</div>\n<nav class=\"filter\" aria-label=\"按题材筛选\"><span class=\"filter-title\">按题材看：</span>"
        for (i, name) in names.enumerated() {
            if let view = views.first(where: { $0.name == name }) {
                out += "<label for=\"f\(i)\">\(esc(name))<span class=\"n\">\(view.count)</span></label>"
            } else {
                out += "<span class=\"disabled\" title=\"没有这类照片\">\(esc(name))<span class=\"n\">0</span></span>"
            }
        }
        out += "</nav>\n<main class=\"views\">\n"
        for (i, name) in names.enumerated() {
            guard let view = views.first(where: { $0.name == name }) else { continue }
            out += "<div class=\"view\" id=\"v\(i)\">\n"
            if i > 0 { out += "<p class=\"banner\">以下只统计「\(esc(name))」\(view.count) 张照片</p>\n" }
            out += toc(view)
            for section in view.sections { out += render(section, viewIndex: i) }
            out += "</div>\n"
        }
        out += """
        </main>
        <footer>LightTable 拍摄习惯 · 数据来自照片的 EXIF，RAW+JPEG 与备份只算一张</footer>
        </div>
        </body>
        </html>

        """
        return out
    }

    private static func toc(_ view: ReportView) -> String {
        let links = view.sections.map { "<a href=\"#\($0.id)-\(view.name)\">\(esc(shortTitle($0.title)))</a>" }
        return "<p class=\"toc\">" + links.joined() + "</p>\n"
    }

    private static func shortTitle(_ title: String) -> String {
        title.components(separatedBy: "（").first ?? title
    }

    private static func render(_ section: ReportSection, viewIndex: Int) -> String {
        var out = "<section id=\"\(section.id)-\(viewName(viewIndex))\">\n<h2>\(esc(section.title))</h2>\n"
        var listOpen = false
        for block in section.blocks {
            if block.kind == .fact, let text = block.text, text.hasPrefix("- ") {
                if !listOpen { out += "<ul class=\"facts\">"; listOpen = true }
                out += "<li>\(esc(String(text.dropFirst(2))))</li>"
                continue
            }
            if listOpen { out += "</ul>\n"; listOpen = false }
            switch block.kind {
            case .fact:
                let text = block.text ?? ""
                if text.hasPrefix("> 以下各节只统计") { continue }  // shown as the view banner
                out += "<p class=\"fact\">\(esc(text))</p>\n"
            case .note:
                out += "<p class=\"note\">\(esc(block.text ?? ""))</p>\n"
            case .table:
                guard let table = block.table else { continue }
                if table.heading != section.title { out += "<h3>\(esc(table.heading))</h3>\n" }
                out += render(table)
            }
        }
        if listOpen { out += "</ul>\n" }
        return out + "</section>\n"
    }

    private static func viewName(_ index: Int) -> String {
        (["全部"] + HabitCategories.subjects)[index]
    }

    static func render(_ table: ReportTable) -> String {
        switch table.kind {
        case .buckets: return bars(table)
        case .hours: return columns(table, labelEvery: 3)
        case .columns: return columns(table, labelEvery: 1)
        case .crosstab: return heatTable(table)
        case .plain, .keyValue: return plainTable(table, keyValue: table.kind == .keyValue)
        }
    }

    /// Horizontal bars as HTML so labels stay readable on a phone.
    private static func bars(_ table: ReportTable) -> String {
        let counts = table.rows.map { Int($0[1]) ?? 0 }
        let top = max(counts.max() ?? 0, 1)
        var out = "<div class=\"bars\" role=\"table\" aria-label=\"\(esc(table.heading))\">"
        for (row, count) in zip(table.rows, counts) {
            let width = Double(count) / Double(top) * 100
            out += "<div class=\"bar-row\(count == 0 ? " zero" : "")\" role=\"row\">"
                + "<span class=\"bar-label\" role=\"cell\">\(esc(row[0]))</span>"
                + "<span class=\"bar-track\" role=\"cell\"><span class=\"bar-fill\" style=\"width:\(String(format: "%.1f", width))%\"></span></span>"
                + "<span class=\"bar-value\" role=\"cell\">\(count) 张<em>\(esc(row[2]))</em></span></div>"
        }
        return out + "</div>\n"
    }

    /// Vertical bars as inline SVG.
    private static func columns(_ table: ReportTable, labelEvery: Int) -> String {
        let counts = table.rows.map { Int($0[1]) ?? 0 }
        let top = max(counts.max() ?? 0, 1)
        let n = counts.count
        let width = 480.0, height = 200.0, base = 170.0, plotTop = 18.0
        let slot = width / Double(n)
        let barWidth = slot * 0.7
        var svg = "<svg class=\"cols\" viewBox=\"0 0 \(Int(width)) \(Int(height))\" role=\"img\" aria-label=\"\(esc(table.heading))\">"
        svg += "<line x1=\"0\" y1=\"\(base)\" x2=\"\(width)\" y2=\"\(base)\" class=\"axis\"/>"
        for (i, count) in counts.enumerated() {
            let h = Double(count) / Double(top) * (base - plotTop)
            let x = Double(i) * slot + (slot - barWidth) / 2
            let label = table.rows[i][0]
            svg += "<rect x=\(q(x)) y=\(q(base - h)) width=\(q(barWidth)) height=\(q(h)) rx=\"2\" class=\"col\">"
                + "<title>\(esc(label))：\(count) 张（\(esc(table.rows[i][2]))）</title></rect>"
            if count > 0, n <= 12 || count == top {
                svg += "<text x=\(q(x + barWidth / 2)) y=\(q(base - h - 4)) class=\"v\">\(count)</text>"
            }
            if i % labelEvery == 0 {
                let short = labelEvery > 1 ? String(label.prefix(2)) : label
                svg += "<text x=\(q(x + barWidth / 2)) y=\(q(base + 18)) class=\"l\">\(esc(short))</text>"
            }
        }
        svg += "</svg>"
        let caption = labelEvery > 1 ? "<p class=\"caption\">横轴是几点（0–23 时），柱高是张数</p>" : ""
        return "<div class=\"chart\">\(svg)</div>\(caption)\n"
    }

    private static func q(_ v: Double) -> String { "\"\(String(format: "%.1f", v))\"" }

    /// Shares per group; darker cells are larger shares.
    private static func heatTable(_ table: ReportTable) -> String {
        var out = "<div class=\"table-wrap\"><table class=\"heat\"><thead><tr>"
        out += table.headers.map { "<th>\(esc(groupHeader($0)))</th>" }.joined()
        out += "</tr></thead><tbody>"
        for row in table.rows {
            out += "<tr><th>\(esc(row[0]))</th>"
            for cell in row.dropFirst() {
                let share = Double(cell.dropLast()) ?? 0
                let alpha = min(0.85, share / 100 * 1.6)
                out += "<td style=\"background:rgba(37,99,235,\(String(format: "%.2f", alpha)))\(alpha > 0.45 ? ";color:#fff" : "")\">\(esc(cell))</td>"
            }
            out += "</tr>"
        }
        return out + "</tbody></table></div>\n"
    }

    /// "人像(40)" → "人像 40 张".
    private static func groupHeader(_ header: String) -> String {
        guard header.hasSuffix(")"), let open = header.lastIndex(of: "(") else { return header }
        return "\(header[..<open]) \(header[header.index(after: open)..<header.index(before: header.endIndex)]) 张"
    }

    private static func plainTable(_ table: ReportTable, keyValue: Bool) -> String {
        // The text bar column of the Markdown report adds nothing next to real charts.
        let keep = table.headers.indices.filter { !table.headers[$0].isEmpty }
        var out = "<div class=\"table-wrap\"><table class=\"\(keyValue ? "kv" : "data")\">"
        if !keyValue {
            out += "<thead><tr>" + keep.map { "<th>\(esc(table.headers[$0]))</th>" }.joined() + "</tr></thead>"
        }
        out += "<tbody>"
        for row in table.rows {
            out += "<tr>" + keep.enumerated().map { position, i in
                position == 0 ? "<th>\(esc(row[i]))</th>" : "<td>\(esc(row[i]))</td>"
            }.joined() + "</tr>"
        }
        return out + "</tbody></table></div>\n"
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func css(viewCount: Int) -> String {
        var rules = ""
        for i in 0..<viewCount {
            rules += "#f\(i):checked~.views #v\(i){display:block}#f\(i):checked~.filter label[for=f\(i)]{background:var(--accent);color:#fff;border-color:var(--accent)}#f\(i):checked~.filter label[for=f\(i)] .n{color:#dbeafe}"
        }
        return """
        :root{--accent:#2563eb;--ink:#1f2937;--muted:#6b7280;--line:#e5e7eb;--bg:#f8fafc;--card:#fff}
        *{box-sizing:border-box}
        body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.6 -apple-system,BlinkMacSystemFont,"PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif}
        .page{max-width:960px;margin:0 auto;padding:24px 16px 48px}
        header h1{margin:0;font-size:28px}
        .sub{margin:4px 0 0;color:var(--muted)}
        .gen{margin:2px 0 0;color:var(--muted);font-size:13px}
        .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;margin:20px 0}
        .card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px 14px}
        .card-label{font-size:13px;color:var(--muted)}
        .card-value{font-size:22px;font-weight:600;margin-top:2px;word-break:break-word}
        .card-detail{font-size:13px;color:var(--muted)}
        .filter-input{position:absolute;opacity:0;pointer-events:none}
        .filter{position:sticky;top:0;z-index:5;display:flex;flex-wrap:wrap;gap:8px;align-items:center;background:var(--bg);padding:10px 0;border-bottom:1px solid var(--line)}
        .filter-title{font-size:14px;color:var(--muted)}
        .filter label,.filter .disabled{border:1px solid var(--line);background:var(--card);border-radius:999px;padding:4px 12px;font-size:15px;cursor:pointer;user-select:none}
        .filter .disabled{opacity:.4;cursor:default}
        .filter .n{margin-left:6px;font-size:12px;color:var(--muted)}
        .view{display:none}
        .banner{background:#eff6ff;border:1px solid #bfdbfe;border-radius:10px;padding:8px 12px;margin:16px 0 0}
        .toc{display:flex;flex-wrap:wrap;gap:6px 14px;font-size:14px;margin:14px 0 0}
        .toc a{color:var(--accent);text-decoration:none}
        section{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px 18px;margin:18px 0;scroll-margin-top:60px}
        h2{margin:0 0 8px;font-size:21px}
        h3{margin:20px 0 8px;font-size:16px}
        .note{color:var(--muted);font-size:14px;margin:6px 0}
        .fact{margin:8px 0}
        .facts{margin:6px 0;padding-left:22px}
        .caption{color:var(--muted);font-size:13px;margin:2px 0 0;text-align:center}
        .table-wrap{overflow-x:auto;-webkit-overflow-scrolling:touch}
        table{border-collapse:collapse;font-size:14px;min-width:100%}
        th,td{padding:6px 10px;border-bottom:1px solid var(--line);text-align:right;white-space:nowrap}
        th:first-child,thead th:first-child{text-align:left}
        thead th{color:var(--muted);font-weight:600;background:#f9fafb}
        tbody th{font-weight:500;text-align:left;white-space:normal;min-width:120px}
        table.kv td{text-align:left;white-space:normal}
        table.heat td{text-align:center}
        .bars{display:grid;gap:4px;font-size:14px}
        .bar-row{display:grid;grid-template-columns:96px 1fr 112px;gap:10px;align-items:center}
        .bar-row.zero{color:#9ca3af}
        .bar-label{white-space:nowrap}
        .bar-track{background:#eef2f7;border-radius:4px;height:14px;overflow:hidden}
        .bar-fill{display:block;height:100%;background:var(--accent);border-radius:4px}
        .bar-value{text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums}
        .bar-value em{font-style:normal;color:var(--muted);margin-left:6px}
        .chart{width:100%}
        svg.cols{width:100%;height:auto;display:block}
        svg .axis{stroke:#cbd5e1}
        svg .col{fill:var(--accent)}
        svg text{font-size:13px;fill:#4b5563;text-anchor:middle}
        svg text.v{font-size:11px;fill:#374151}
        footer{color:var(--muted);font-size:13px;text-align:center;margin-top:24px}
        @media (max-width:560px){header h1{font-size:23px}section{padding:12px}.bar-row{grid-template-columns:84px 1fr 96px;gap:6px}.card-value{font-size:19px}}
        \(rules)
        """
    }
}
