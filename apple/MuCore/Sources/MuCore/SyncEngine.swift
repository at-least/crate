import Foundation

/// 同步引擎（sync-rules.md §3）：delta 變更 → 索引狀態。
/// 純邏輯狀態機；儲存形態是實作細節。契約輸出 canonical(SyncReport)
/// 須與 Python 參考實作 byte-identical（sync_generate.py）。
public final class SyncEngine {

    public enum Kind: String { case added, removed, modified }

    public struct SyncChange: Equatable {
        public let path: String, kind: Kind, rev: String
    }

    /// 索引軌：掃描資料（Scanner.Track）+ rev + available。
    public struct IndexedTrack {
        public let track: Scanner.Track
        public let rev: String
        public let available: Bool
    }

    /// m3u8 raw（ref → trackId 在輸出時對 available 集合解析）。
    public struct RawItem {
        public let position: Int, ref: String
        public let durationMs: Int?
    }

    public struct RawPlaylist {
        public let name: String
        public let items: [RawItem]
    }

    public struct SyncReport {
        public let changes: [SyncChange]
        public let scanned: [String]
        public let tracks: [String: IndexedTrack]
        public let playlists: [String: RawPlaylist]
        public let errors: [String: Scanner.ScanError]
    }

    private let provider: LocalFolderProvider
    private var cursor: [String: String]?
    private var tracks: [String: IndexedTrack] = [:]
    private var playlists: [String: RawPlaylist] = [:]
    private var errors: [String: Scanner.ScanError] = [:]

    public init(provider: LocalFolderProvider) {
        self.provider = provider
    }

    /// 一輪同步。afterDelta：測試縫（delta 後、掃描前；模擬掃描中拔檔）。
    public func sync(afterDelta: (() -> Void)? = nil) -> SyncReport {
        let snap = provider.snapshot()
        let prev = cursor ?? [:]
        var changes: [SyncChange] = []
        for path in Set(snap.keys).union(prev.keys).sorted(by: codePointCompare) {
            if prev[path] == nil {
                changes.append(SyncChange(path: path, kind: .added, rev: snap[path]!))
            } else if snap[path] == nil {
                changes.append(SyncChange(path: path, kind: .removed, rev: prev[path]!))
            } else if snap[path] != prev[path] {
                changes.append(SyncChange(path: path, kind: .modified, rev: snap[path]!))
            }
        }
        let relevant = changes.filter {
            formatFor($0.path) != nil || $0.path.lowercased().hasSuffix(".m3u8")
        }

        var pending: [SyncChange] = []
        for c in relevant where c.kind != .removed {
            pending.append(c)
        }
        for c in relevant where c.kind == .removed {
            if let it = tracks[c.path] {
                tracks[c.path] = IndexedTrack(track: it.track, rev: it.rev, available: false)
            }
            playlists.removeValue(forKey: c.path)
            errors.removeValue(forKey: c.path)
        }
        afterDelta?()
        var scanned: [String] = []
        for c in pending {
            guard let data = provider.readBytes(c.path) else { continue } // §3.2-4 靜默丟棄
            scanned.append(c.path)
            if c.path.lowercased().hasSuffix(".m3u8") {
                playlists[c.path] = parseM3u8Raw(
                    text: String(decoding: data, as: UTF8.self), rel: c.path)
                continue
            }
            let fmt = formatFor(c.path)!
            guard let (fields, tagOk) = Scanner.parseTags(fmt: fmt, data: data) else {
                tracks.removeValue(forKey: c.path)
                errors[c.path] = Scanner.ScanError(code: "BAD_CONTAINER", path: c.path)
                continue
            }
            errors.removeValue(forKey: c.path)
            tracks[c.path] = IndexedTrack(
                track: Scanner.makeTrack(
                    rel: c.path, fmt: fmt, size: data.count,
                    fields: fields, tagOkRaw: tagOk,
                    durationMs: ContainerParsers.parseDuration(fmt, data)),
                rev: c.rev, available: true)
        }
        cursor = snap
        return SyncReport(changes: relevant, scanned: scanned,
                          tracks: tracks, playlists: playlists, errors: errors)
    }

    /// raw 清單 → 已解析音軌（App 層用；解析規則與 canonical 的 items 完全一致）。
    /// 回傳 (playlistPath, 每項 trackId 或 nil)。
    func resolvedItems(_ r: SyncReport) -> [String: [String?]] {
        let audioOk = Set(r.tracks.filter { $0.value.available }.keys)
        var out: [String: [String?]] = [:]
        for (p, pl) in r.playlists {
            let base = p.contains("/") ? String(p[p.startIndex..<p.lastIndex(of: "/")!]) : ""
            out[p] = pl.items.map { raw in
                var ref = raw.ref.replacingOccurrences(of: "\\", with: "/")
                while ref.hasPrefix("./") { ref = String(ref.dropFirst(2)) }
                if ref.hasPrefix("/") { return nil }
                let joined = base.isEmpty ? ref : base + "/" + ref
                if let resolved = Scanner.normPath(joined), audioOk.contains(resolved) {
                    return resolved
                }
                return nil
            }
        }
        return out
    }

    /// SyncReport → canonical JSON（sync-rules §3.3）。
    func canonical(_ r: SyncReport) -> CanonicalJson.JSONValue {
        let audioOk = Set(r.tracks.filter { $0.value.available }.keys)
        let tracksOut: [CanonicalJson.JSONValue] =
            r.tracks.keys.sorted(by: codePointCompare).map { p in
                let it = r.tracks[p]!
                return .object(CanonicalJson.trackPairs(it.track) + [
                    ("available", .bool(it.available)),
                    ("rev", .string(it.rev)),
                ])
            }
        let playlistsOut: [CanonicalJson.JSONValue] =
            r.playlists.keys.sorted(by: codePointCompare).map { p in
                let pl = r.playlists[p]!
                let base = p.contains("/") ? String(p[p.startIndex..<p.lastIndex(of: "/")!]) : ""
                let items: [CanonicalJson.JSONValue] = pl.items.map { raw in
                    var ref = raw.ref.replacingOccurrences(of: "\\", with: "/")
                    while ref.hasPrefix("./") { ref = String(ref.dropFirst(2)) }
                    var trackId: String? = nil
                    if !ref.hasPrefix("/") {
                        let joined = base.isEmpty ? ref : base + "/" + ref
                        if let resolved = Scanner.normPath(joined), audioOk.contains(resolved) {
                            trackId = resolved
                        }
                    }
                    return .object([
                        ("durationMs", raw.durationMs.map { .int($0) } ?? .null),
                        ("missing", .bool(trackId == nil)),
                        ("position", .int(raw.position)),
                        ("ref", .string(raw.ref)),
                        ("trackId", trackId.map { .string($0) } ?? .null),
                    ])
                }
                return .object([
                    ("id", .string(p)),
                    ("items", .array(items)),
                    ("name", .string(pl.name)),
                    ("path", .string(p)),
                ])
            }
        let albums = Scanner.groupAlbums(
            r.tracks.keys.sorted(by: codePointCompare).map { r.tracks[$0]!.track }
        ).sorted {
            $0.albumArtist != $1.albumArtist
                ? codePointCompare($0.albumArtist, $1.albumArtist)
                : codePointCompare($0.name, $1.name)
        }.map { CanonicalJson.canonical($0) }
        let errorsOut: [CanonicalJson.JSONValue] =
            r.errors.keys.sorted(by: codePointCompare).map {
                .object(CanonicalJson.errorPairs(r.errors[$0]!))
            }
        let changesOut: [CanonicalJson.JSONValue] =
            r.changes.sorted {
                $0.path != $1.path
                    ? codePointCompare($0.path, $1.path)
                    : codePointCompare($0.kind.rawValue, $1.kind.rawValue)
            }.map {
                .object([
                    ("kind", .string($0.kind.rawValue)),
                    ("path", .string($0.path)),
                    ("rev", .string($0.rev)),
                ])
            }
        return .object([
            ("changes", .array(changesOut)),
            ("scanned", .array(r.scanned.sorted(by: codePointCompare).map { .string($0) })),
            ("index", .object([
                ("albums", .array(albums)),
                ("errors", .array(errorsOut)),
                ("playlists", .array(playlistsOut)),
                ("tracks", .array(tracksOut)),
            ])),
        ])
    }

    /// m3u8 raw 解析（model.md §2.3；不解析 trackId）。
    func parseM3u8Raw(text rawText: String, rel: String) -> RawPlaylist {
        let text = String(rawText.drop { $0 == "\u{FEFF}" })
        var items: [RawItem] = []
        var pendingDur: Int? = nil
        for line0 in text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false) {
            let line = line0.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXTINF:") {
                    let rest = String(line.dropFirst("#EXTINF:".count))
                    pendingDur = Scanner.extinfToMs(
                        String(rest.split(separator: ",", maxSplits: 1)[0]))
                }
                continue
            }
            var ref = line.replacingOccurrences(of: "\\", with: "/")
            while ref.hasPrefix("./") { ref = String(ref.dropFirst(2)) }
            items.append(RawItem(position: items.count, ref: ref, durationMs: pendingDur))
            pendingDur = nil
        }
        let name = rel.split(separator: "/").last.map(String.init) ?? rel
        return RawPlaylist(name: String(name.dropLast(5)), items: items)
    }
}
