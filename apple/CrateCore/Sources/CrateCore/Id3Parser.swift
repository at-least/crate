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
    let rgTrackMb: Int?
    let rgAlbumMb: Int?

    static let rgKeys: Set<String> = ["REPLAYGAIN_TRACK_GAIN", "REPLAYGAIN_ALBUM_GAIN"]

    /// model.md §1.9：'-6.54 dB' → -654；無浮點；無整數位數字 → nil。
    static func parseGainMb(_ s: String?) -> Int? {
        guard let s else { return nil }
        let t = Array(s.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        var i = 0
        var sign = 1
        if i < t.count, t[i] == UInt8(ascii: "+") || t[i] == UInt8(ascii: "-") {
            sign = t[i] == UInt8(ascii: "-") ? -1 : 1
            i += 1
        }
        var j = i
        while j < t.count, t[j] >= 0x30, t[j] <= 0x39 { j += 1 }
        guard j > i else { return nil }
        var whole = 0
        for c in t[i..<j] { whole = whole * 10 + Int(c - 0x30) }
        var frac = 0
        if j < t.count, t[j] == UInt8(ascii: ".") {
            var k = j + 1
            var digits: [Int] = []
            while k < t.count, t[k] >= 0x30, t[k] <= 0x39, digits.count < 2 {
                digits.append(Int(t[k] - 0x30)); k += 1
            }
            while digits.count < 2 { digits.append(0) }
            frac = digits[0] * 10 + digits[1]
        }
        return sign * (whole * 100 + frac)
    }

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
            year: year, compilation: tags["COMPILATION"] == "1",
            rgTrackMb: parseGainMb(tags["REPLAYGAIN_TRACK_GAIN"]),
            rgAlbumMb: parseGainMb(tags["REPLAYGAIN_ALBUM_GAIN"])
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
            } else if fid == "TXXX", fEnd > fStart { // §1.9：description 決定鍵
                let fdata = try r.bytes(fStart, fEnd - fStart)
                let enc = Int(fdata[0])
                let (descB, rest) = splitNul(Array(fdata[1...]), enc)
                let key = trimContract(decodeText(enc, descB)).uppercased()
                if TagFields.rgKeys.contains(key) {
                    let (valB, _) = splitNul(rest, enc)
                    let value = trimContract(decodeText(enc, valB))
                    if !value.isEmpty, out[key] == nil { out[key] = value }
                }
            }
            i = fStart + fsize
        }
        return out
    }

    /// 依編碼切第一個終止符：Latin-1/UTF-8 = 1 NUL；UTF-16 = 對齊的 00 00。
    static func splitNul(_ raw: [UInt8], _ enc: Int) -> ([UInt8], [UInt8]) {
        if enc == 1 || enc == 2 {
            var i = 0
            while i + 1 < raw.count {
                if raw[i] == 0 && raw[i + 1] == 0 { return (Array(raw[..<i]), Array(raw[(i + 2)...])) }
                i += 2
            }
            return (raw, [])
        }
        guard let i = raw.firstIndex(of: 0) else { return (raw, []) }
        return (Array(raw[..<i]), Array(raw[(i + 1)...]))
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
