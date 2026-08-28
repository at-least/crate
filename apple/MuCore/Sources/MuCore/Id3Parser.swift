import Foundation

/// 正規化 tag 欄位（model.md §1.2）。空字串 = 缺失。
struct TagFields {
    let title: String?
    let artist: String?
    let albumArtist: String?
    let album: String?
    let trackNo: Int?
    let disc: Int?
    let year: Int?
    let compilation: Bool

    static func from(_ tags: [String: String]) -> TagFields {
        func f(_ k: String) -> String? { tags[k].flatMap { $0.isEmpty ? nil : $0 } }
        func num(_ s: String?) -> Int? {
            guard let s, !s.isEmpty else { return nil }
            let head = s.prefix { $0.isNumber && $0.isASCII }
            return Int(head)
        }
        let y = f("YEAR") ?? f("DATE")
        var year: Int?
        if let y, y.count >= 4 {
            let head4 = y.prefix(4)
            if head4.allSatisfy({ $0.isNumber && $0.isASCII }) { year = Int(head4) }
        }
        return TagFields(
            title: f("TITLE"), artist: f("ARTIST"), albumArtist: f("ALBUMARTIST"),
            album: f("ALBUM"), trackNo: num(tags["TRACKNUMBER"]), disc: num(tags["DISCNUMBER"]),
            year: year, compilation: tags["COMPILATION"] == "1"
        )
    }
}

/// ID3v2.3 / v2.4 解析（model.md §1.2–1.3；v2.2 → nil 走 fallback）。
enum Id3Parser {
    static let frameKeys: [String: String] = [
        "TIT2": "TITLE", "TPE1": "ARTIST", "TALB": "ALBUM", "TPE2": "ALBUMARTIST",
        "TRCK": "TRACKNUMBER", "TPOS": "DISCNUMBER", "TYER": "YEAR", "TDRC": "DATE",
        "TCMP": "COMPILATION", "TCP": "COMPILATION",
    ]

    /// 陣列 API（測試相容）。
    static func parse(_ data: [UInt8]) -> [String: String]? {
        try! parse(ChunkedReader(bytes: data))
    }

    /// 只讀 frame header；非關注 frame（APIC 等）以 size 跳過（model.md §1.8）。
    static func parse(_ r: ChunkedReader) throws -> [String: String]? {
        guard r.size >= 10 else { return nil }
        let h = try r.bytes(0, 10)
        guard h[0] == 0x49, h[1] == 0x44, h[2] == 0x33 else { return nil }
        let verMajor = Int(h[3])
        let flags = Int(h[5])
        func ss(_ b: [UInt8], _ o: Int) -> Int {
            (Int(b[o]) & 0x7F) << 21 | (Int(b[o + 1]) & 0x7F) << 14 |
                (Int(b[o + 2]) & 0x7F) << 7 | (Int(b[o + 3]) & 0x7F)
        }
        var bodyStart = 10
        let bodyEnd = min(r.size, 10 + ss(h, 6))
        guard (3...4).contains(verMajor) else { return nil }
        if flags & 0x40 != 0 { // extended header
            guard bodyEnd - bodyStart >= 4 else { return nil }
            let e = try r.bytes(bodyStart, 4)
            let ext = verMajor == 3 ? Bytes.u32be(e, 0) + 4 : ss(e, 0)
            bodyStart = min(bodyEnd, bodyStart + ext)
        }
        var out: [String: String] = [:]
        var i = bodyStart
        while i + 10 <= bodyEnd {
            let fh = try r.bytes(i, 10)
            let fid = String(decoding: fh[0..<4], as: UTF8.self)
            if fid == "\u{0}\u{0}\u{0}\u{0}" { break }
            let fsize = verMajor == 3 ? Bytes.u32be(fh, 4) : ss(fh, 4)
            let fStart = i + 10
            let fEnd = min(bodyEnd, fStart + fsize)
            if let key = frameKeys[fid], fEnd > fStart {
                let fdata = try r.bytes(fStart, fEnd - fStart)
                let enc = Int(fdata[0])
                var rawEnd = fdata.count
                for j in 1..<fdata.count where fdata[j] == 0 { rawEnd = j; break }
                let raw = Array(fdata[1..<rawEnd])
                let value = trimContract(decodeText(enc, raw))
                if !value.isEmpty, out[key] == nil { out[key] = value }
            }
            i = fStart + fsize
        }
        return out
    }

    static func decodeText(_ enc: Int, _ raw: [UInt8]) -> String {
        switch enc {
        case 0:
            return String(raw.map { Character(UnicodeScalar($0)) })
        case 1:
            guard raw.count >= 2, raw.count % 2 == 0 else { return "" }
            if raw[0] == 0xFF, raw[1] == 0xFE {
                return decodeUtf16(Array(raw[2...]), bigEndian: false)
            }
            if raw[0] == 0xFE, raw[1] == 0xFF {
                return decodeUtf16(Array(raw[2...]), bigEndian: true)
            }
            if raw[0] == 0 { return decodeUtf16(raw, bigEndian: true) }
            return decodeUtf16(raw, bigEndian: false)
        case 2:
            guard raw.count % 2 == 0 else { return "" }
            return decodeUtf16(raw, bigEndian: true)
        case 3:
            return String(decoding: raw, as: UTF8.self)
        default:
            return ""
        }
    }

    private static func decodeUtf16(_ bytes: [UInt8], bigEndian: Bool) -> String {
        var units = [UInt16]()
        units.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            let u: UInt16 = bigEndian
                ? UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1])
                : UInt16(bytes[i + 1]) << 8 | UInt16(bytes[i])
            units.append(u)
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }
}
