import Foundation

/// One value from exiftool's `-j` output. Numbers keep their source text because photo-habits
/// (Python) turns values into strings with `str()`, which prints `2024` and `2024.0` differently;
/// `JSONSerialization` would lose that, and keyword or model strings would stop matching.
enum ExifValue: Equatable, Sendable {
    case string(String)
    case number(String)
    case bool(Bool)
    case array([ExifValue])
    case object([(String, ExifValue)])
    case null

    static func == (lhs: ExifValue, rhs: ExifValue) -> Bool {
        switch (lhs, rhs) {
        case let (.string(a), .string(b)), let (.number(a), .number(b)): a == b
        case let (.bool(a), .bool(b)): a == b
        case let (.array(a), .array(b)): a == b
        case let (.object(a), .object(b)): a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.null, .null): true
        default: false
        }
    }

    /// Python's `str(v)` for values json.loads produced.
    var pythonString: String {
        switch self {
        case .string(let s): s
        case .number(let lexeme): Self.pythonNumberString(lexeme)
        case .bool(let b): b ? "True" : "False"
        case .null: "None"
        case .array(let items): "[" + items.map(\.pythonRepr).joined(separator: ", ") + "]"
        case .object(let pairs): "{" + pairs.map { "'\($0.0)': \($0.1.pythonRepr)" }.joined(separator: ", ") + "}"
        }
    }

    private var pythonRepr: String {
        if case .string(let s) = self { return "'\(s)'" }
        return pythonString
    }

    /// Integers print as written; anything with a fraction or exponent is a Python float, which
    /// prints its shortest round-trip form, as Swift's `description` does.
    static func pythonNumberString(_ lexeme: String) -> String {
        if lexeme.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) {
            guard let value = Double(lexeme) else { return lexeme }
            if value.isInfinite { return value < 0 ? "-inf" : "inf" }
            return pythonFloatRepr(value)
        }
        // json.loads("-0") is int 0; leading zeros are invalid JSON and never appear.
        if lexeme == "-0" { return "0" }
        return lexeme
    }

    /// `repr(float)`: shortest digits, scientific below 1e-4 and from 1e16, always with a dot or exponent.
    static func pythonFloatRepr(_ value: Double) -> String {
        var s = "\(value)"  // Swift: shortest round-trip, e.g. "1e-05", "1e+16", "50.0"
        if s.contains("e") {
            // Swift prints "1e-05"; Python too. Swift prints "5e-324" like Python. Mantissas match.
            if !s.contains("e-") && !s.contains("e+") { s = s.replacingOccurrences(of: "e", with: "e+") }
            return s
        }
        return s
    }

    var stringValue: String? { if case .string(let s) = self { s } else { nil } }
}

/// Minimal JSON reader for exiftool output and our own cache files.
struct ExifJSONParser {
    private let bytes: [UInt8]
    private var index = 0

    static func parse(_ data: Data) throws -> ExifValue {
        var parser = ExifJSONParser(bytes: [UInt8](data))
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw ParseError.trailing }
        return value
    }

    enum ParseError: Error { case unexpected(Int), trailing, badEscape }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private mutating func parseValue() throws -> ExifValue {
        guard index < bytes.count else { throw ParseError.unexpected(index) }
        switch bytes[index] {
        case UInt8(ascii: "{"):
            index += 1
            var pairs: [(String, ExifValue)] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw ParseError.unexpected(index) }
                let key = try parseString()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw ParseError.unexpected(index) }
                index += 1
                skipWhitespace()
                let value = try parseValue()
                // json.loads keeps the last of duplicate keys.
                if let existing = pairs.firstIndex(where: { $0.0 == key }) { pairs[existing].1 = value } else { pairs.append((key, value)) }
                skipWhitespace()
                guard index < bytes.count else { throw ParseError.unexpected(index) }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
                throw ParseError.unexpected(index)
            }
        case UInt8(ascii: "["):
            index += 1
            var items: [ExifValue] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try parseValue())
                skipWhitespace()
                guard index < bytes.count else { throw ParseError.unexpected(index) }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw ParseError.unexpected(index)
            }
        case UInt8(ascii: "\""):
            return .string(try parseString())
        case UInt8(ascii: "t"): return try literal("true", .bool(true))
        case UInt8(ascii: "f"): return try literal("false", .bool(false))
        case UInt8(ascii: "n"): return try literal("null", .null)
        default:
            let start = index
            while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
            guard index > start else { throw ParseError.unexpected(index) }
            return .number(String(decoding: bytes[start..<index], as: UTF8.self))
        }
    }

    private mutating func literal(_ word: String, _ value: ExifValue) throws -> ExifValue {
        let utf8 = Array(word.utf8)
        guard index + utf8.count <= bytes.count, Array(bytes[index..<index + utf8.count]) == utf8 else {
            throw ParseError.unexpected(index)
        }
        index += utf8.count
        return value
    }

    private mutating func parseString() throws -> String {
        index += 1  // opening quote
        var out: [UInt8] = []
        var scalars = String()
        func flush() {
            if !out.isEmpty { scalars += String(decoding: out, as: UTF8.self); out.removeAll() }
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") { index += 1; flush(); return scalars }
            if byte == UInt8(ascii: "\\") {
                index += 1
                guard index < bytes.count else { throw ParseError.badEscape }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800..<0xDC00).contains(code), index + 1 < bytes.count,
                       bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        index += 2
                        let low = try hex4()
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    flush()
                    scalars.unicodeScalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default: out.append(escape)  // \" \\ \/
                }
                continue
            }
            out.append(byte)
            index += 1
        }
        throw ParseError.unexpected(index)
    }

    private mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count, let code = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
        else { throw ParseError.badEscape }
        index += 4
        return code
    }
}

enum ExifJSONWriter {
    static func write(_ value: ExifValue, into out: inout String) {
        switch value {
        case .string(let s): writeString(s, into: &out)
        case .number(let lexeme): out += lexeme
        case .bool(let b): out += b ? "true" : "false"
        case .null: out += "null"
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                write(item, into: &out)
            }
            out += "]"
        case .object(let pairs):
            out += "{"
            for (i, pair) in pairs.enumerated() {
                if i > 0 { out += "," }
                writeString(pair.0, into: &out)
                out += ":"
                write(pair.1, into: &out)
            }
            out += "}"
        }
    }

    static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        out += "\""
    }
}
