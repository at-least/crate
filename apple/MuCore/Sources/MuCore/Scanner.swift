import Foundation

/// 掃描器（model.md §1–§2）：同輸入樹 → byte-identical canonical JSON。
public struct Scanner {

    public struct Track: Equatable {
        public let album: String, albumArtist: String, albumId: String, artist: String
        public let disc: Int, format: String, id: String, path: String
        public let sizeBytes: Int, tagOk: Bool, title: String
        public let trackNo: Int?, year: Int?
        public let compilation: Bool, durationMs: Int?
    }

    public struct Album: Equatable {
        public let albumArtist: String, artTrackId: String?, compilation: Bool
        public let id: String, name: String, trackCount: Int, year: Int?
    }

    public struct PlaylistItem: Equatable {
        public let durationMs: Int?, missing: Bool, position: Int
        public let ref: String, trackId: String?
    }

    public struct Playlist: Equatable {
        public let id: String, items: [PlaylistItem], name: String, path: String
    }

    public struct ScanError: Equatable {
        public let code: String, path: String
    }

    public struct ScanResult {
        public let albums: [Album], errors: [ScanError]
        public let playlists: [Playlist], tracks: [Track]
    }

    public static let unknownArtist = "<Unknown Artist>"
    public static let noAlbum = "<No Album>"
    static let filenamePattern = try! NSRegularExpression(pattern: "^(\\d{1,3})\\s-\\s(.+)$")

    public static func scan(root: URL) throws -> ScanResult {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw NSError(domain: "MuCore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot enumerate \(root)"])
        }
        var files: [String] = []
        for case let url as URL in enumerator {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
                files.append(rel)
            }
        }
        return try scan(files: files, read: { rel, maxBytes in
            try FileHandle(forReadingFrom: root.appendingPathComponent(rel))
                .read(upToCount: maxBytes)?.bytes ?? []
        })
    }

    /// 測試用注入面：files = 相對路徑；read 只讀需要的部分。
    static func scan(
        files: [String],
        read: (_ rel: String, _ maxBytes: Int) throws -> [UInt8]
    ) throws -> ScanResult {
        var tracks: [Track] = []
        var errors: [ScanError] = []
        var playlists: [Playlist] = []
        var audioPaths: Set<String> = []
        for rel in files where !rel.lowercased().hasSuffix(".m3u8") {
            if formatFor(rel) != nil { audioPaths.insert(rel) }
        }
        for rel in files {
            if rel.lowercased().hasSuffix(".m3u8") {
                let text = String(decoding: try read(rel, 8 << 20), as: UTF8.self)
                playlists.append(parseM3u8(text: text, rel: rel, audioPaths: audioPaths))
                continue
            }
            guard let fmt = formatFor(rel) else { continue }
            let data = try read(rel, 128 << 20)
            guard let (fields, tagOk) = parseTags(fmt: fmt, data: data) else {
                errors.append(ScanError(code: "BAD_CONTAINER", path: rel))
                continue
            }
            tracks.append(makeTrack(rel: rel, fmt: fmt, size: data.count,
                                    fields: fields, tagOkRaw: tagOk,
                                    durationMs: ContainerParsers.parseDuration(fmt, data)))
        }
        return ScanResult(
            albums: groupAlbums(tracks).sorted {
                $0.albumArtist != $1.albumArtist
                    ? codePointCompare($0.albumArtist, $1.albumArtist)
                    : codePointCompare($0.name, $1.name)
            },
            errors: errors.sorted { codePointCompare($0.path, $1.path) },
            playlists: playlists.sorted { codePointCompare($0.path, $1.path) },
            tracks: tracks.sorted { codePointCompare($0.path, $1.path) }
        )
    }

    static func parseTags(fmt: String, data: [UInt8]) -> (TagFields, Bool)? {
        let tags: [String: String]?
        switch fmt {
        case "flac": tags = ContainerParsers.flacTags(data)
        case "mp3":
            if let t = Id3Parser.parse(data) {
                tags = t
            } else if data.count >= 2, data[0] == 0xFF, data[1] & 0xE0 == 0xE0 {
                tags = [:]
            } else {
                tags = nil
            }
        case "m4a": tags = ContainerParsers.m4aTags(data)
        case "ogg", "opus": tags = ContainerParsers.oggTags(data)
        case "wav": tags = ContainerParsers.isWav(data) ? [:] : nil
        default: tags = nil
        }
        guard let tags else { return nil }
        return (TagFields.from(tags), !tags.isEmpty)
    }

    static func makeTrack(
        rel: String, fmt: String, size: Int, fields raw: TagFields?, tagOkRaw: Bool,
        durationMs: Int? = nil
    ) -> Track {
        let segs = rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let fname = segs.last ?? rel
        var stem = fname
        if let dotRange = fname.range(of: ".", options: .backwards) {
            stem = String(fname[fname.startIndex..<dotRange.lowerBound])
        }
        var fbTitle = stem
        var fbTrackNo: Int? = nil
        if let m = filenamePattern.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)) {
            if let r1 = Range(m.range(at: 1), in: stem), let r2 = Range(m.range(at: 2), in: stem) {
                let digits = String(stem[r1]).drop { $0 == "0" }
                fbTrackNo = Int(digits.isEmpty ? "0" : String(digits))
                fbTitle = String(stem[r2])
            }
        }
        let fbAlbumArtist = segs.count >= 3 ? segs[0] : unknownArtist
        let fbAlbum = segs.count >= 2 ? segs[segs.count - 2] : noAlbum
        let f = raw ?? TagFields.from([:])

        let artist = f.artist ?? f.albumArtist ?? fbAlbumArtist
        let albumArtist = f.albumArtist ?? f.artist ?? fbAlbumArtist
        let album = f.album ?? fbAlbum
        let title = f.title ?? fbTitle
        let trackNo = f.trackNo ?? fbTrackNo
        let ok = tagOkRaw && (f.title != nil || f.artist != nil || f.album != nil || f.albumArtist != nil)
        let compilation = f.compilation || albumArtist.lowercased() == "various artists"

        return Track(
            album: album, albumArtist: albumArtist, albumId: "alb|\(albumArtist)|\(album)",
            artist: artist, disc: f.disc ?? 1, format: fmt, id: rel, path: rel,
            sizeBytes: size, tagOk: ok, title: title, trackNo: trackNo, year: f.year,
            compilation: compilation, durationMs: durationMs
        )
    }

    static func groupAlbums(_ tracks: [Track]) -> [Album] {
        var byId: [String: [Track]] = [:]
        for t in tracks { byId[t.albumId, default: []].append(t) }
        return byId.values.map { ts in
            let sorted = ts.sorted { codePointCompare($0.path, $1.path) }
            return Album(
                albumArtist: sorted[0].albumArtist,
                artTrackId: sorted.first { $0.tagOk }?.id,
                compilation: sorted.contains { $0.compilation },
                id: sorted[0].albumId, name: sorted[0].album,
                trackCount: sorted.count,
                year: sorted.first { $0.year != nil }?.year
            )
        }
    }

    static func parseM3u8(text rawText: String, rel: String, audioPaths: Set<String>) -> Playlist {
        let text = String(rawText.drop { $0 == "\u{FEFF}" })
        let base: String
        if let lastSlash = rel.lastIndex(of: "/") {
            base = String(rel[rel.startIndex..<lastSlash])
        } else {
            base = ""
        }
        var pendingDur: Int? = nil
        var items: [PlaylistItem] = []
        for line0 in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = line0.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXTINF:") {
                    let rest = String(line.dropFirst("#EXTINF:".count))
                    pendingDur = extinfToMs(String(rest.split(separator: ",", maxSplits: 1)[0]))
                }
                continue
            }
            var ref = line.replacingOccurrences(of: "\\", with: "/")
            while ref.hasPrefix("./") { ref = String(ref.dropFirst(2)) }
            var trackId: String? = nil
            if !ref.hasPrefix("/") {
                let joined = base.isEmpty ? ref : base + "/" + ref
                if let resolved = normPath(joined), audioPaths.contains(resolved) {
                    trackId = resolved
                }
            }
            items.append(PlaylistItem(durationMs: pendingDur, missing: trackId == nil,
                                      position: items.count, ref: ref, trackId: trackId))
            pendingDur = nil
        }
        let name = rel.split(separator: "/").last.map(String.init) ?? rel
        let itemName = String(name.dropLast(5))
        return Playlist(id: rel, items: items, name: itemName, path: rel)
    }

    /// 無浮點 EXTINF 秒→毫秒（model.md §2.3）。非法 → nil。
    public static func extinfToMs(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        let neg = t.hasPrefix("-")
        let body = neg ? String(t.dropFirst()) : t
        let ip: String
        let fp: String
        if let dot = body.firstIndex(of: ".") {
            ip = String(body[body.startIndex..<dot])
            fp = String(body[body.index(after: dot)...])
        } else {
            ip = body
            fp = ""
        }
        if !ip.isEmpty, !ip.allSatisfy({ $0.isNumber && $0.isASCII }) { return nil }
        if !fp.isEmpty, !fp.allSatisfy({ $0.isNumber && $0.isASCII }) { return nil }
        let ipV = ip.isEmpty ? 0 : Int(ip) ?? 0
        let padded = fp + "000"
        let fpV = Int(String(padded.prefix(3))) ?? 0
        let v = ipV * 1000 + fpV
        return neg ? -v : v
    }

    /// 摺疊 `.`/`..`；出界 → nil。
    public static func normPath(_ p: String) -> String? {
        var out: [String] = []
        for seg in p.split(separator: "/", omittingEmptySubsequences: false) {
            switch seg {
            case ".", "": break
            case "..":
                if out.isEmpty { return nil }
                out.removeLast()
            default:
                out.append(String(seg))
            }
        }
        return out.joined(separator: "/")
    }
}
