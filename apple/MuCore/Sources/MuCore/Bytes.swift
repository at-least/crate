import Foundation

/// 位元組讀取 helper — 一律顯式端序（model.md §4）。
enum Bytes {
    static func u16be(_ b: [UInt8], _ off: Int) -> Int {
        Int(b[off]) << 8 | Int(b[off + 1])
    }

    static func u24be(_ b: [UInt8], _ off: Int) -> Int {
        Int(b[off]) << 16 | Int(b[off + 1]) << 8 | Int(b[off + 2])
    }

    static func u32be(_ b: [UInt8], _ off: Int) -> Int {
        Int(b[off]) << 24 | Int(b[off + 1]) << 16 | Int(b[off + 2]) << 8 | Int(b[off + 3])
    }

    static func u32le(_ b: [UInt8], _ off: Int) -> Int {
        Int(b[off + 3]) << 24 | Int(b[off + 2]) << 16 | Int(b[off + 1]) << 8 | Int(b[off])
    }
}

/// codepoint 序比較（UTF-8 位元組序 = codepoint 序）。
func codePointCompare(_ a: String, _ b: String) -> Bool {
    Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8))
}

/// model.md §1.3 的 trim 集合。
func trimContract(_ s: String) -> String {
    var start = s.startIndex
    let end = s.endIndex
    let set: Set<Character> = [" ", "\t", "\r", "\n", "\u{0}"]
    while start < end, set.contains(s[start]) { start = s.afterIndex(start) }
    var e = end
    while e > start {
        let prev = s.index(before: e)
        if !set.contains(s[prev]) { break }
        e = prev
    }
    return String(s[start..<e])
}

private extension String {
    func afterIndex(_ i: Index) -> Index { index(after: i) }
}

/// 副檔名 → format（model.md §1.1）。非音訊 → nil。
func formatFor(_ name: String) -> String? {
    guard name.contains(".") else { return nil }
    let ext = String(name.split(separator: ".", omittingEmptySubsequences: false).last ?? "")
    switch ext.lowercased() {
    case "flac": return "flac"
    case "mp3": return "mp3"
    case "m4a", "mp4": return "m4a"
    case "ogg": return "ogg"
    case "opus": return "opus"
    case "wav": return "wav"
    default: return nil
    }
}

extension Data {
    var bytes: [UInt8] { [UInt8](self) }
}
