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

    static func parse(_ data: [UInt8]) -> [String: String]? {
        guard data.count >= 10, data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else { return nil }
        let verMajor = Int(data[3])
        let flags = Int(data[5])
        let size = (Int(data[6]) & 0x7F) << 21 | (Int(data[7]) & 0x7F) << 14 |
            (Int(data[8]) & 0x7F) << 7 | (Int(data[9]) & 0x7F)
        var body = Array(data[min(data.count, 10)...])
        if body.count > size { body = Array(body.prefix(size)) }
        guard (3...4).contains(verMajor) else { return nil }
        if flags & 0x40 != 0 { // extended header
            guard body.count >= 4 else { return nil }
            let ext = verMajor == 3 ? Bytes.u32be(body, 0) + 4 :
                (Int(body[0]) & 0x7F) << 21 | (Int(body[1]) & 0x7F) << 14 |
                (Int(body[2]) & 0x7F) << 7 | (Int(body[3]) & 0x7F)
            body = ext < body.count ? Array(body[ext...]) : []
        }
        var out: [String: String] = [:]
        var order: [String] = []
        var i = 0
        while i + 10 <= body.count {
            let fid = String(decoding: body[i..<i + 4], as: UTF8.self)
            if fid == "\u{0}\u{0}\u{0}\u{0}" { break }
            let fsize = verMajor == 3 ? Bytes.u32be(body, i + 4) :
                (Int(body[i + 4]) & 0x7F) << 21 | (Int(body[i + 5]) & 0x7F) << 14 |
                (Int(body[i + 6]) & 0x7F) << 7 | (Int(body[i + 7]) & 0x7F)
            guard fsize >= 0 else { break }
            let fStart = i + 10
            let fEnd = min(body.count, fStart + fsize)
            if let key = frameKeys[fid], fEnd > fStart {
                let enc = Int(body[fStart])
                var rawEnd = fEnd
                for j in (fStart + 1)..<fEnd where body[j] == 0 { rawEnd = j; break }
                let raw = Array(body[(fStart + 1)..<rawEnd])
                let value = trimContract(decodeText(enc, raw))
                if !value.isEmpty, out[key] == nil {
                    out[key] = value
                    order.append(key)
                }
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
