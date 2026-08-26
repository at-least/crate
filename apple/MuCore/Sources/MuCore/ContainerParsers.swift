import Foundation

/// FLAC / Ogg(+Vorbis,Opus) / WAV / MP4(ilst) 容器與註解解析。
enum ContainerParsers {

    // ---- FLAC ----
    static func flacTags(_ data: [UInt8]) -> [String: String]? {
        guard data.count >= 4, data[0] == 0x66, data[1] == 0x4C, data[2] == 0x61, data[3] == 0x43
        else { return nil } // "fLaC"
        var out: [String: String] = [:]
        var i = 4
        while i + 4 <= data.count {
            let last = data[i] & 0x80 != 0
            let btype = Int(data[i] & 0x7F)
            let blen = Bytes.u24be(data, i + 1)
            let start = i + 4
            let end = min(data.count, start + blen)
            if btype == 4, end > start {
                vorbisCommentInto(data, start, end, &out)
            }
            if last { break }
            i = start + blen
            if blen < 0 { break }
        }
        return out
    }

    // ---- Ogg / Opus：前 64KB bytewise 掃 magic（fixtures/README 已釘死） ----
    static func oggTags(_ data: [UInt8]) -> [String: String]? {
        guard data.count >= 4,
              String(decoding: data[0..<4], as: UTF8.self) == "OggS" else { return nil }
        let window = Array(data.prefix(65536))
        if let p = indexOf(window, Array("OpusTags".utf8)) {
            var out: [String: String] = [:]
            vorbisCommentInto(window, p + 8, window.count, &out)
            return out
        }
        if let p = indexOf(window, [3] + Array("vorbis".utf8)) {
            var out: [String: String] = [:]
            vorbisCommentInto(window, p + 7, window.count, &out)
            return out
        }
        return [:]
    }

    private static func vorbisCommentInto(
        _ b: [UInt8], _ from: Int, _ to: Int, _ out: inout [String: String]
    ) {
        var j = from
        guard j + 4 <= to else { return }
        let vendorLen = Bytes.u32le(b, j)
        j += 4
        guard vendorLen >= 0, j + vendorLen + 4 <= to else { return }
        j += vendorLen
        let count = Bytes.u32le(b, j)
        j += 4
        guard count >= 0 else { return }
        for _ in 0..<count {
            guard j + 4 <= to else { return }
            let vlen = Bytes.u32le(b, j)
            j += 4
            guard vlen >= 0, j + vlen <= to else { return }
            let kv = String(decoding: b[j..<j + vlen], as: UTF8.self)
            j += vlen
            guard let eq = kv.firstIndex(of: "=") else { continue }
            let k = String(kv[kv.startIndex..<eq]).uppercased()
            let v = trimContract(String(kv[kv.index(after: eq)...]))
            if out[k] == nil { out[k] = v }
        }
    }

    // ---- WAV ----
    static func isWav(_ data: [UInt8]) -> Bool {
        data.count >= 12 &&
            String(decoding: data[0..<4], as: UTF8.self) == "RIFF" &&
            String(decoding: data[8..<12], as: UTF8.self) == "WAVE"
    }

    // ---- MP4 / M4A ilst ----
    private struct Box { let type: [UInt8]; let payload: [UInt8] }

    private static func boxes(_ buf: [UInt8], _ from: Int = 0, _ to: Int? = nil) -> [Box] {
        let end = to ?? buf.count
        var out: [Box] = []
        var i = from
        while i + 8 <= end {
            var size = Bytes.u32be(buf, i)
            let type = Array(buf[(i + 4)..<(i + 8)])
            var hdr = 8
            if size == 1 {
                guard i + 16 <= end else { break }
                size = 0
                for q in 0..<8 { size = size << 8 | Int(buf[i + 8 + q]) }
                hdr = 16
            } else if size == 0 {
                size = end - i
            }
            guard size >= hdr, i + size <= end else { break }
            out.append(Box(type: type, payload: Array(buf[(i + hdr)..<(i + size)])))
            i += size
        }
        return out
    }

    static func m4aTags(_ data: [UInt8]) -> [String: String]? {
        var foundMoov = false
        var ilst: [UInt8]? = nil

        func walk(_ buf: [UInt8], _ insideMeta: Bool) {
            for box in boxes(buf) {
                let t = String(decoding: box.type, as: UTF8.self)
                if t == "moov" {
                    foundMoov = true
                    walk(box.payload, false)
                } else if t == "udta" {
                    walk(box.payload, false)
                } else if t == "meta", box.payload.count > 4 {
                    walk(Array(box.payload[4...]), true)
                } else if insideMeta, t == "ilst" {
                    ilst = box.payload
                }
            }
        }
        walk(data, false)
        guard foundMoov else { return nil }
        guard let payload = ilst else { return [:] }

        // atom type 是原始 4 bytes（© = 單 byte 0xA9，非 UTF-8），必須以 bytes 為鍵
        let textKey: [[UInt8]: String] = [
            [0xA9, 0x6E, 0x61, 0x6D]: "TITLE",        // ©nam
            [0xA9, 0x41, 0x52, 0x54]: "ARTIST",        // ©ART
            [0xA9, 0x61, 0x6C, 0x62]: "ALBUM",         // ©alb
            [0x61, 0x41, 0x52, 0x54]: "ALBUMARTIST",   // aART
            [0xA9, 0x64, 0x61, 0x79]: "YEAR",          // ©day
            [0x63, 0x70, 0x69, 0x6C]: "COMPILATION",   // cpil
        ]
        let numKey: [[UInt8]: String] = [
            [0x74, 0x72, 0x6B, 0x6E]: "TRACKNUMBER",   // trkn
            [0x64, 0x69, 0x73, 0x6B]: "DISCNUMBER",    // disk
        ]
        var out: [String: String] = [:]
        for box in boxes(payload) {
            let key = textKey[box.type]
            let nkey = numKey[box.type]
            for d in boxes(box.payload) {
                guard String(decoding: d.type, as: UTF8.self) == "data" else { continue }
                let dd = d.payload
                if let key, dd.count >= 9 {
                    let v = trimContract(String(decoding: dd[8...], as: UTF8.self))
                    if !v.isEmpty, out[key] == nil { out[key] = v }
                } else if let nkey, dd.count >= 6 {
                    let n = Bytes.u16be(dd, 4)
                    if n != 0, out[nkey] == nil { out[nkey] = String(n) }
                }
            }
        }
        return out
    }

    private static func indexOf(_ hay: [UInt8], _ needle: [UInt8]) -> Int? {
        guard hay.count >= needle.count, !needle.isEmpty else { return nil }
        for i in 0...(hay.count - needle.count) {
            if hay[i] == needle[0] {
                var match = true
                for j in 1..<needle.count where hay[i + j] != needle[j] { match = false; break }
                if match { return i }
            }
        }
        return nil
    }
}
