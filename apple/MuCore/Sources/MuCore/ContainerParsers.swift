import Foundation

/// FLAC / Ogg(+Vorbis,Opus) / WAV / MP4(ilst) 容器與註解解析。
/// 一律經 ChunkedReader 只讀結構需要的位元組（model.md §1.8；存取序列即規格）。
enum ContainerParsers {

    // ---- FLAC ----
    static func flacTags(_ r: ChunkedReader) throws -> [String: String]? {
        guard try r.bytes(0, 4) == Array("fLaC".utf8) else { return nil }
        var out: [String: String] = [:]
        var i = 4
        while i + 4 <= r.size {
            let h = try r.bytes(i, 4)
            let last = h[0] & 0x80 != 0
            let btype = Int(h[0] & 0x7F)
            let blen = Bytes.u24be(h, 1)
            let start = i + 4
            let end = min(r.size, start + blen)
            if btype == 4, end > start { // VORBIS_COMMENT；PICTURE 等跳過
                let block = try r.bytes(start, end - start)
                vorbisCommentInto(block, 0, block.count, &out)
            }
            if last { break }
            i = start + blen
        }
        return out
    }

    // ---- Ogg / Opus：前 64KB 視窗 bytewise 掃 magic ----
    static func oggTags(_ r: ChunkedReader) throws -> [String: String]? {
        guard r.size >= 4 else { return nil }
        let window = try r.bytes(0, min(ChunkedReader.chunk, r.size))
        guard Array(window[0..<4]) == Array("OggS".utf8) else { return nil }
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
            guard let eq = kv.firstIndex(of: "="), eq > kv.startIndex else { continue }
            let k = String(kv[kv.startIndex..<eq]).uppercased()
            let v = trimContract(String(kv[kv.index(after: eq)...]))
            if out[k] == nil { out[k] = v }
        }
    }

    // ---- WAV ----
    static func isWav(_ r: ChunkedReader) throws -> Bool {
        guard r.size >= 12 else { return false }
        let h = try r.bytes(0, 12)
        return Array(h[0..<4]) == Array("RIFF".utf8) && Array(h[8..<12]) == Array("WAVE".utf8)
    }

    // ---- MP4 / M4A：box 巡訪只讀 header，payload 以範圍表示 ----
    struct BoxRef { let type: [UInt8]; let start: Int; let end: Int }

    static func boxes(_ r: ChunkedReader, _ from: Int, _ to: Int) throws -> [BoxRef] {
        var out: [BoxRef] = []
        var i = from
        while i + 8 <= to {
            let h = try r.bytes(i, 8)
            var size = Bytes.u32be(h, 0)
            let type = Array(h[4..<8])
            var hdr = 8
            if size == 1 {
                guard i + 16 <= to else { break }
                let h2 = try r.bytes(i + 8, 8)
                size = 0
                for q in 0..<8 { size = size << 8 | Int(h2[q]) }
                hdr = 16
            } else if size == 0 {
                size = to - i
            }
            guard size >= hdr, i + size <= to else { break }
            out.append(BoxRef(type: type, start: i + hdr, end: i + size))
            i += size
        }
        return out
    }

    static func m4aTags(_ r: ChunkedReader) throws -> [String: String]? {
        var foundMoov = false
        var ilst: BoxRef? = nil

        func walk(_ from: Int, _ to: Int, _ insideMeta: Bool) throws {
            for box in try boxes(r, from, to) {
                let t = String(decoding: box.type, as: UTF8.self)
                if t == "moov" {
                    foundMoov = true
                    try walk(box.start, box.end, false)
                } else if t == "udta" {
                    try walk(box.start, box.end, false)
                } else if t == "meta" {
                    if box.end - box.start > 4 { try walk(box.start + 4, box.end, true) }
                } else if insideMeta, t == "ilst" {
                    ilst = box
                }
            }
        }
        try walk(0, r.size, false)
        guard foundMoov else { return nil }
        guard let ilst else { return [:] }

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
        for box in try boxes(r, ilst.start, ilst.end) {
            let key = textKey[box.type]
            let nkey = numKey[box.type]
            if key == nil && nkey == nil { continue }
            for d in try boxes(r, box.start, box.end) {
                guard String(decoding: d.type, as: UTF8.self) == "data" else { continue }
                let dd = try r.bytes(d.start, d.end - d.start)
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

    static func indexOf(_ hay: [UInt8], _ needle: [UInt8]) -> Int? {
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

    static func lastIndexOf(_ hay: [UInt8], _ needle: [UInt8]) -> Int? {
        if needle.isEmpty || hay.count < needle.count { return nil }
        var i = hay.count - needle.count
        while i >= 0 {
            var ok = true
            for j in 0..<needle.count where hay[i + j] != needle[j] { ok = false; break }
            if ok { return i }
            i -= 1
        }
        return nil
    }

    // ---- 陣列 API（測試相容；包成 MemorySource）----
    static func oggTags(_ data: [UInt8]) -> [String: String]? {
        try! oggTags(ChunkedReader(bytes: data))
    }

    static func parseDuration(_ fmt: String, _ data: [UInt8]) -> Int? {
        try! parseDuration(fmt, ChunkedReader(bytes: data))
    }
}

// ---- 時長（model.md §1.7 / §1.8）----

extension ContainerParsers {

    private static let mp3BrM1 = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    private static let mp3BrM2 = [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]

    static func parseDuration(_ fmt: String, _ r: ChunkedReader) throws -> Int? {
        let size = r.size
        switch fmt {
        case "flac":
            if size < 8 + 34 { return nil }
            let d = try r.bytes(0, 42)
            if Array(d[0..<4]) != Array("fLaC".utf8) || d[4] & 0x7F != 0 { return nil }
            let rate = (Int(d[18]) << 12) | (Int(d[19]) << 4) | (Int(d[20]) >> 4)
            var total = Int(d[21] & 0xF) << 32
            for q in 0..<4 { total |= Int(d[22 + q]) << (24 - 8 * q) }
            if rate == 0 || total == 0 { return nil }
            return total * 1000 / rate
        case "mp3":
            var off = 0
            if size >= 3, try r.bytes(0, 3) == Array("ID3".utf8) {
                if size < 10 { return nil }
                let h = try r.bytes(6, 4)
                off = 10 + (((Int(h[0]) & 0x7F) << 21) | ((Int(h[1]) & 0x7F) << 14) |
                    ((Int(h[2]) & 0x7F) << 7) | (Int(h[3]) & 0x7F))
            }
            let n = min(off + 65536, size - 3) - off
            if n <= 0 { return nil }
            let buf = try r.bytes(off, n + 2)
            for i in 0..<n {
                if buf[i] == 0xFF && buf[i + 1] & 0xE0 == 0xE0 {
                    let ver = (Int(buf[i + 1]) >> 3) & 3
                    let layer = (Int(buf[i + 1]) >> 1) & 3
                    let br = (Int(buf[i + 2]) >> 4) & 0xF
                    let sr = (Int(buf[i + 2]) >> 2) & 3
                    if ver != 1 && layer == 1 && br != 0 && br != 15 && sr != 3 {
                        let kbps = (ver == 3 ? mp3BrM1 : mp3BrM2)[br - 1]
                        return (size - (off + i)) * 8 / kbps
                    }
                }
            }
            return nil
        case "m4a":
            func find(_ from: Int, _ to: Int) throws -> (Int, Int)? {
                for box in try boxes(r, from, to) {
                    let t = String(decoding: box.type, as: UTF8.self)
                    if t == "moov" {
                        if let res = try find(box.start, box.end) { return res }
                    } else if t == "mvhd" {
                        let len = box.end - box.start
                        let p = try r.bytes(box.start, min(len, 32))
                        if p.isEmpty { return nil }
                        if p[0] == 0 {
                            if len < 20 { return nil }
                            return (Bytes.u32be(p, 12), Bytes.u32be(p, 16))
                        }
                        if len < 32 { return nil }
                        var dur = 0
                        for q in 0..<8 { dur = (dur << 8) | Int(p[24 + q]) }
                        return (Bytes.u32be(p, 20), dur)
                    }
                }
                return nil
            }
            guard let res = try find(0, size), res.0 != 0, res.1 != 0 else { return nil }
            return res.1 * 1000 / res.0
        case "ogg", "opus":
            let tailOff = max(0, size - ChunkedReader.chunk)
            let tail = try r.bytes(tailOff, size - tailOff)
            guard let pRel = lastIndexOf(tail, Array("OggS".utf8)) else { return nil }
            let p = pRel + tailOff
            guard size >= p + 14 else { return nil }
            let g = try r.bytes(p + 6, 8)
            var granule = 0
            for q in 0..<8 { granule |= Int(g[q]) << (8 * q) }
            let head = try r.bytes(0, min(ChunkedReader.chunk, size))
            if fmt == "opus" {
                guard let h = indexOf(head, Array("OpusHead".utf8)), size >= h + 12 else { return nil }
                let ps = try r.bytes(h + 10, 2)
                let preskip = Int(ps[0]) | (Int(ps[1]) << 8)
                let v = (granule - preskip) * 1000 / 48000
                return v > 0 ? v : nil
            }
            guard let v = indexOf(head, [1] + Array("vorbis".utf8)), size >= v + 16 else { return nil }
            let rate = Bytes.u32le(try r.bytes(v + 12, 4), 0)
            if rate == 0 || granule == 0 { return nil }
            return granule * 1000 / rate
        case "wav":
            if try !isWav(r) { return nil }
            var byteRate = 0, dataSize = -1
            var i = 12
            while i + 8 <= size {
                let ch = try r.bytes(i, 8)
                let cid = String(decoding: ch[0..<4], as: UTF8.self)
                let csz = Bytes.u32le(ch, 4)
                if cid == "fmt " && csz >= 12 {
                    if i + 20 <= size { byteRate = Bytes.u32le(try r.bytes(i + 16, 4), 0) }
                } else if cid == "data" {
                    dataSize = csz
                }
                i += 8 + csz + (csz & 1)
            }
            if byteRate == 0 || dataSize < 0 { return nil }
            return dataSize * 1000 / byteRate
        default:
            return nil
        }
    }
}
