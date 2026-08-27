import Foundation

/// Canonical JSON 寫出器（model.md §2.2）。與 Kotlin 版逐條對應：
/// 鍵按 codepoint 排序、2 空格縮排、LF、檔尾 \n、短轉義 + \u00xx 小寫、
/// 非 ASCII 原樣、errors[].message 恆為 ""（契約豁免）。
public enum CanonicalJson {

    public static func render(_ value: JSONValue) -> String {
        var sb = ""
        renderValue(value, 0, &sb)
        sb.append("\n")
        return sb
    }

    public enum JSONValue {
        case null
        case bool(Bool)
        case int(Int)
        case string(String)
        case array([JSONValue])
        case object([(String, JSONValue)]) // 保序傳入；寫出前排序
    }

    private static func renderValue(_ v: JSONValue, _ indent: Int, _ sb: inout String) {
        switch v {
        case .null: sb += "null"
        case .bool(let b): sb += b ? "true" : "false"
        case .int(let i): sb += String(i)
        case .string(let s): escape(s, &sb)
        case .array(let a): renderArray(a, indent, &sb)
        case .object(let o): renderObject(o, indent, &sb)
        }
    }

    private static func renderArray(_ a: [JSONValue], _ indent: Int, _ sb: inout String) {
        if a.isEmpty { sb += "[]"; return }
        sb += "[\n"
        for (i, item) in a.enumerated() {
            indentStr(indent + 1, &sb)
            renderValue(item, indent + 1, &sb)
            if i != a.count - 1 { sb += "," }
            sb += "\n"
        }
        indentStr(indent, &sb)
        sb += "]"
    }

    private static func renderObject(_ o: [(String, JSONValue)], _ indent: Int, _ sb: inout String) {
        if o.isEmpty { sb += "{}"; return }
        let sorted = o.sorted { codePointCompare($0.0, $1.0) }
        sb += "{\n"
        for (i, (k, v)) in sorted.enumerated() {
            indentStr(indent + 1, &sb)
            escape(k, &sb)
            sb += ": "
            renderValue(v, indent + 1, &sb)
            if i != sorted.count - 1 { sb += "," }
            sb += "\n"
        }
        indentStr(indent, &sb)
        sb += "}"
    }

    private static func indentStr(_ n: Int, _ sb: inout String) {
        sb += String(repeating: " ", count: n * 2)
    }

    private static func escape(_ s: String, _ sb: inout String) {
        sb += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": sb += "\\\""
            case "\\": sb += "\\\\"
            case "\u{08}": sb += "\\b"
            case "\u{0C}": sb += "\\f"
            case "\n": sb += "\\n"
            case "\r": sb += "\\r"
            case "\t": sb += "\\t"
            default:
                if scalar.value < 0x20 {
                    sb += "\\u" + String(format: "%04x", scalar.value)
                } else {
                    sb.unicodeScalars.append(scalar)
                }
            }
        }
        sb += "\""
    }

    // ---- ScanResult → canonical ----

    public static func canonical(_ r: Scanner.ScanResult) -> JSONValue {
        .object([
            ("albums", .array(r.albums.map(canonical))),
            ("errors", .array(r.errors.map(canonical))),
            ("playlists", .array(r.playlists.map(canonical))),
            ("tracks", .array(r.tracks.map(canonical))),
        ])
    }

    static func canonical(_ a: Scanner.Album) -> JSONValue {
        .object([
            ("albumArtist", .string(a.albumArtist)),
            ("artTrackId", a.artTrackId.map { .string($0) } ?? .null),
            ("compilation", .bool(a.compilation)),
            ("id", .string(a.id)),
            ("name", .string(a.name)),
            ("trackCount", .int(a.trackCount)),
            ("year", a.year.map { .int($0) } ?? .null),
        ])
    }

    static func canonical(_ e: Scanner.ScanError) -> JSONValue {
        .object([
            ("code", .string(e.code)),
            ("message", .string("")), // 契約豁免
            ("path", .string(e.path)),
        ])
    }

    private static func canonical(_ p: Scanner.Playlist) -> JSONValue {
        .object([
            ("id", .string(p.id)),
            ("items", .array(p.items.map {
                .object([
                    ("durationMs", $0.durationMs.map { .int($0) } ?? .null),
                    ("missing", .bool($0.missing)),
                    ("position", .int($0.position)),
                    ("ref", .string($0.ref)),
                    ("trackId", $0.trackId.map { .string($0) } ?? .null),
                ])
            })),
            ("name", .string(p.name)),
            ("path", .string(p.path)),
        ])
    }

    static func trackPairs(_ t: Scanner.Track) -> [(String, JSONValue)] {
        [
            ("album", .string(t.album)),
            ("albumArtist", .string(t.albumArtist)),
            ("albumId", .string(t.albumId)),
            ("artist", .string(t.artist)),
            ("disc", .int(t.disc)),
            ("durationMs", t.durationMs.map { .int($0) } ?? .null), // model.md §1.7
            ("format", .string(t.format)),
            ("id", .string(t.id)),
            ("path", .string(t.path)),
            ("sizeBytes", .int(t.sizeBytes)),
            ("tagOk", .bool(t.tagOk)),
            ("title", .string(t.title)),
            ("trackNo", t.trackNo.map { .int($0) } ?? .null),
            ("year", t.year.map { .int($0) } ?? .null),
        ]
    }

    static func errorPairs(_ e: Scanner.ScanError) -> [(String, JSONValue)] {
        [
            ("code", .string(e.code)),
            ("message", .string("")), // 契約豁免
            ("path", .string(e.path)),
        ]
    }

    static func canonical(_ t: Scanner.Track) -> JSONValue {
        .object(trackPairs(t))
    }
}
