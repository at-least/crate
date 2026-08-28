import Foundation
import XCTest
@testable import MuCore

/// 覆蓋率缺口測試（acceptance.md 通用品質門檻：core 行覆蓋 ≥90%）。
/// 不改變任何產品碼行為——只補契約 fixtures 沒走到的分支：
/// RetryPolicy 注入式 run、Id3Parser extended header/編碼分支、SyncEngine 的
/// resolvedItems/BAD_CONTAINER/root 層 m3u8、Scanner 檔案系統入口與 parseTags 邊界、
/// ContainerParsers 的 m4a 64-bit box/mvhd v1/wav/mp3、LocalFolderProvider 守衛。
final class CoverageGapTest: XCTestCase {

    // MARK: - RetryPolicy（provider.md §2.1）

    func testRetryPolicyScriptedSequences() {
        func script(_ errs: [RetryPolicy.ProviderErrorKind?]) -> () -> RetryPolicy.ProviderErrorKind? {
            var i = 0
            return {
                defer { i += 1 }
                return i < errs.count ? errs[i] : nil
            }
        }
        // 暫態×2 後成功：退避 1s/2s
        XCTAssertEqual(
            RetryPolicy.Outcome(result: "ok", reauths: 0, sleeps: [1000, 2000]),
            RetryPolicy.run(op: script([.transient, .transient, nil])))
        // 暫態打滿 5 次上限：1/2/4/8/16s 後放棄
        XCTAssertEqual(
            RetryPolicy.Outcome(result: "transient", reauths: 0, sleeps: [1000, 2000, 4000, 8000, 16000]),
            RetryPolicy.run(op: script([.transient, .transient, .transient, .transient, .transient, .transient])))
        // auth：立即重授權一次（不睡），第二次 auth 才放棄
        var reauths = 0
        XCTAssertEqual(
            RetryPolicy.Outcome(result: "ok", reauths: 1, sleeps: []),
            RetryPolicy.run(op: script([.auth, nil]), onReauth: { reauths += 1 }))
        XCTAssertEqual(1, reauths)
        XCTAssertEqual(
            RetryPolicy.Outcome(result: "auth", reauths: 1, sleeps: []),
            RetryPolicy.run(op: script([.auth, .auth])))
        // notFound 不重試
        XCTAssertEqual(
            RetryPolicy.Outcome(result: "notfound", reauths: 0, sleeps: []),
            RetryPolicy.run(op: script([.notFound])))
        // 字串 → kind
        XCTAssertEqual(.transient, RetryPolicy.kind(from: "transient"))
        XCTAssertEqual(.auth, RetryPolicy.kind(from: "auth"))
        XCTAssertEqual(.notFound, RetryPolicy.kind(from: "notfound"))
        XCTAssertNil(RetryPolicy.kind(from: "other"))
    }

    // MARK: - SyncEngine.resolvedItems（App 層用；解析規則 = canonical items）

    func testResolvedItemsMatrix() throws {
        let root = try makeTempDir()
        let engine = SyncEngine(provider: LocalFolderProvider(root: root))
        func track(_ p: String, _ avail: Bool) -> SyncEngine.IndexedTrack {
            SyncEngine.IndexedTrack(
                track: Scanner.makeTrack(rel: p, fmt: "flac", size: 1, fields: nil, tagOkRaw: false),
                rev: "1:1", available: avail)
        }
        let report = SyncEngine.SyncReport(
            changes: [], scanned: [],
            tracks: [
                "a/01.flac": track("a/01.flac", true),
                "a/02.flac": track("a/02.flac", false),          // available=0 → 清單不解析（§3.2-5）
                "a/sub/x.flac": track("a/sub/x.flac", true),
            ],
            playlists: [
                "a/pl.m3u8": SyncEngine.RawPlaylist(name: "pl", items: [
                    SyncEngine.RawItem(position: 0, ref: "01.flac", durationMs: nil),        // 命中
                    SyncEngine.RawItem(position: 1, ref: "./01.flac", durationMs: nil),      // 去 ./
                    SyncEngine.RawItem(position: 2, ref: "sub\\x.flac", durationMs: nil),    // 反斜線
                    SyncEngine.RawItem(position: 3, ref: "/abs.flac", durationMs: nil),      // 絕對路徑 → nil
                    SyncEngine.RawItem(position: 4, ref: "../out.flac", durationMs: nil),    // 出界 → nil
                    SyncEngine.RawItem(position: 5, ref: "02.flac", durationMs: nil),        // unavailable → nil
                    SyncEngine.RawItem(position: 6, ref: "missing.flac", durationMs: nil),   // 無此軌 → nil
                ]),
            ],
            errors: [:])
        let resolved = engine.resolvedItems(report)
        XCTAssertEqual(
            ["a/01.flac", "a/01.flac", "a/sub/x.flac", nil, nil, nil, nil],
            resolved["a/pl.m3u8"])
    }

    // MARK: - SyncEngine：BAD_CONTAINER 落 errors + root 層 m3u8 名稱

    func testSyncBadContainerAndRootLevelPlaylist() throws {
        let root = try makeTempDir()
        try Data("garbage".utf8).write(to: root.appendingPathComponent("bad.flac"))
        try Data("#EXTM3U\r\n#EXTINF:1.5\r\n./a.flac\r\n".utf8)
            .write(to: root.appendingPathComponent("root.m3u8"))
        let engine = SyncEngine(provider: LocalFolderProvider(root: root))
        let report = try engine.sync()
        XCTAssertEqual(1, report.errors.count)
        XCTAssertEqual("BAD_CONTAINER", report.errors["bad.flac"]?.code)
        // root 層清單：名稱去副檔名；ref 去 ./
        XCTAssertEqual("root", report.playlists["root.m3u8"]?.name)
        XCTAssertEqual([SyncEngine.RawItem(position: 0, ref: "a.flac", durationMs: 1500)],
                       report.playlists["root.m3u8"]?.items)
        // canonical 的 errors 輸出（errorPairs）
        let json = CanonicalJson.render(engine.canonical(report))
        XCTAssertTrue(json.contains("\"BAD_CONTAINER\""))
    }

    // MARK: - Id3Parser：extended header 與文字編碼分支

    func testId3ExtendedHeaderAndTextEncodings() {
        func be32(_ n: Int) -> [UInt8] {
            [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
        }
        func frame(_ id: String, _ payload: [UInt8]) -> [UInt8] {
            Array(id.utf8) + be32(payload.count) + [0, 0] + payload
        }
        func id3(_ flags: UInt8, _ body: [UInt8]) -> [UInt8] {
            [0x49, 0x44, 0x33, 3, 0, flags] + [
                UInt8((body.count >> 21) & 0x7F), UInt8((body.count >> 14) & 0x7F),
                UInt8((body.count >> 7) & 0x7F), UInt8(body.count & 0x7F),
            ] + body
        }
        // v2.3 extended header（flags 0x40；ext = u32be(6)+4 = 10 bytes）後接 TIT2
        let ext: [UInt8] = [0, 0, 0, 6, 0, 0, 0, 0, 0, 0]
        let parsed = Id3Parser.parse(
            id3(0x40, ext + frame("TIT2", [0] + Array("Hi".utf8))))
        XCTAssertEqual(["TITLE": "Hi"], parsed)
        // v2.2 → nil（guard (3...4)）
        XCTAssertNil(Id3Parser.parse([0x49, 0x44, 0x33, 2, 0, 0, 0, 0, 0, 0]))

        XCTAssertEqual("Hi", Id3Parser.decodeText(0, [0x48, 0x69]))                    // Latin-1
        XCTAssertEqual("Hi", Id3Parser.decodeText(1, [0xFF, 0xFE, 0x48, 0, 0x69, 0])) // UTF-16 BOM LE
        XCTAssertEqual("Hi", Id3Parser.decodeText(1, [0xFE, 0xFF, 0, 0x48, 0, 0x69])) // UTF-16 BOM BE
        XCTAssertEqual("Hi", Id3Parser.decodeText(1, [0, 0x48, 0, 0x69]))             // 無 BOM 首字節 0 → BE
        XCTAssertEqual("Hi", Id3Parser.decodeText(1, [0x48, 0, 0x69, 0]))             // 無 BOM → LE
        XCTAssertEqual("", Id3Parser.decodeText(1, [0x48]))                           // 奇數長度
        XCTAssertEqual("Hi", Id3Parser.decodeText(2, [0, 0x48, 0, 0x69]))             // UTF-16BE
        XCTAssertEqual("Hi", Id3Parser.decodeText(3, [0x48, 0x69]))                   // UTF-8
        XCTAssertEqual("", Id3Parser.decodeText(4, [0x48, 0x69]))                     // 未知編碼
    }

    func testTagFieldsNumberAndYearEdges() {
        XCTAssertEqual(3, TagFields.from(["TRACKNUMBER": "3/12"]).trackNo) // 前綴數字
        XCTAssertNil(TagFields.from(["TRACKNUMBER": ""]).trackNo)
        XCTAssertNil(TagFields.from(["TRACKNUMBER": "abc"]).trackNo)
        XCTAssertEqual(2020, TagFields.from(["DATE": "2020-05-01"]).year)
        XCTAssertNil(TagFields.from(["YEAR": "abcd99"]).year)
        XCTAssertEqual(2, TagFields.from(["DISCNUMBER": "2"]).disc)
    }

    // MARK: - Scanner：parseTags 邊界 + scan(root:) 守衛 + root 層清單

    func testParseTagsMp3Boundaries() {
        XCTAssertNil(Scanner.parseTags(fmt: "mp3", data: Array("no".utf8)))   // 無 ID3 無 sync → nil
        let raw = Scanner.parseTags(fmt: "mp3", data: [0xFF, 0xE0])           // sync bytes → 空 tag
        XCTAssertNotNil(raw)
        XCTAssertEqual(false, raw?.1)
        XCTAssertNil(Scanner.parseTags(fmt: "mp3", data: Array("ID3".utf8))) // "ID3" 但不足 10B
    }

    func testScannerScanRootScansRootLevelPlaylist() throws {
        guard let flac = fixtureBytes(
            "flac_no_tags/lib/Aurora/Northern Lights/01 - Rise.flac") else {
            return XCTFail("fixture flac not found")
        }
        let root = try makeTempDir()
        try flac.write(to: root.appendingPathComponent("loose.flac"))
        try Data("#EXTM3U\nloose.flac\n".utf8).write(to: root.appendingPathComponent("pl.m3u8"))
        let result = try Scanner.scan(root: root)
        XCTAssertEqual(1, result.tracks.count)
        XCTAssertEqual("loose.flac", result.playlists[0].items[0].trackId) // root 層清單 base=""
    }

    // MARK: - ContainerParsers：m4a 64-bit box / mvhd v1 / wav / mp3 / ogg

    func testParseDurationBranches() {
        func be32(_ n: Int) -> [UInt8] {
            [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
        }
        func le32(_ n: Int) -> [UInt8] {
            [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)]
        }
        func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            be32(payload.count + 8) + Array(type.utf8) + payload
        }
        // mvhd v0：timescale 1000、duration 2500
        let mvhd0 = box("mvhd", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + be32(1000) + be32(2500))
        let moov = box("moov", mvhd0)
        XCTAssertEqual(2500, ContainerParsers.parseDuration("m4a", moov))
        // mvhd v1（64-bit duration；p.count 需 ≥32：4+8+8+4(timescale@20)+8(dur@24)）
        let mvhd1 = box("mvhd", [1, 0, 0, 0]
            + [UInt8](repeating: 0, count: 16) + be32(1000) + be32(0) + be32(2500))
        XCTAssertEqual(2500, ContainerParsers.parseDuration("m4a", box("moov", mvhd1)))
        // mvhd v1 過短 → nil
        XCTAssertNil(ContainerParsers.parseDuration(
            "m4a", box("moov", box("mvhd", [1, 0, 0, 0] + [UInt8](repeating: 0, count: 12)))))
        // 前置 64-bit size（size==1）box 後仍找得到 moov
        let free64: [UInt8] = [0, 0, 0, 1] + Array("free".utf8)
            + be32(0) + be32(16) // 8-byte 實際 size = 16（big-endian）
        XCTAssertEqual(2500, ContainerParsers.parseDuration(
            "m4a", box("ftyp", []) + free64 + moov))
        // 尾端 size==0 box（吃到結尾）
        XCTAssertEqual(2500, ContainerParsers.parseDuration(
            "m4a", moov + [0, 0, 0, 0] + Array("free".utf8)))
        // wav：fmt byteRate 0 → nil；正常值 → 毫秒
        func wav(byteRate: Int, withData: Bool) -> [UInt8] {
            var fmt = [1, 0, 1, 0] + le32(44100) + le32(byteRate) + [0, 0, 16, 0]
            fmt += [UInt8](repeating: 0, count: 0)
            var out = Array("RIFF".utf8) + le32(4 + 8 + fmt.count + (withData ? 12 : 0))
                + Array("WAVE".utf8) + Array("fmt ".utf8) + le32(fmt.count) + fmt
            if withData { out += Array("data".utf8) + le32(176_400) }
            return out
        }
        XCTAssertNil(ContainerParsers.parseDuration("wav", wav(byteRate: 0, withData: true)))
        XCTAssertNil(ContainerParsers.parseDuration("wav", wav(byteRate: 176_400, withData: false)))
        XCTAssertEqual(1000, ContainerParsers.parseDuration("wav", wav(byteRate: 176_400, withData: true)))
        // mp3：MPEG1 Layer III 128kbps，104B → 104*8/128 = 6ms
        XCTAssertEqual(6, ContainerParsers.parseDuration(
            "mp3", [0xFF, 0xFB, 0x90, 0x00] + [UInt8](repeating: 0, count: 100)))
        // mp3：前置非 frame 位元組 → 掃描推進一行後命中（(105-1)*8/128 = 6）
        XCTAssertEqual(6, ContainerParsers.parseDuration(
            "mp3", [0x00, 0xFF, 0xFB, 0x90, 0x00] + [UInt8](repeating: 0, count: 100)))
        // mp3：ID3v2 前綴（大小 0）→ offset 跳越後命中
        XCTAssertEqual(6, ContainerParsers.parseDuration(
            "mp3", [0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, 0, 0xFF, 0xFB, 0x90, 0x00]
                + [UInt8](repeating: 0, count: 100)))
        // 未知格式 → nil（default 分支）
        XCTAssertNil(ContainerParsers.parseDuration("zzz", [1, 2, 3]))
        // trimContract：前後空白/結尾 NUL 一併修剪（Bytes.trimContract 兩個迴圈）
        XCTAssertEqual("Hi", trimContract(" Hi \u{0}\t"))
        // ogg：過短/無標記
        XCTAssertNil(ContainerParsers.parseDuration("ogg", [1, 2, 3]))
        XCTAssertNil(ContainerParsers.oggTags(Array("notogg".utf8)))          // 無 OggS 前綴 → nil
        XCTAssertEqual([:], ContainerParsers.oggTags(Array("OggS-junk".utf8))) // 有頁無標記 → 空 tag
    }

    // MARK: - LocalFolderProvider：不存在 root / readBytes

    func testLocalFolderProviderGuards() throws {
        XCTAssertEqual(
            [:],
            LocalFolderProvider(root: URL(fileURLWithPath: "/nonexistent-mu-coverage-xyz")).snapshot())
        XCTAssertNil(LocalFolderProvider(root: URL(fileURLWithPath: "/nonexistent-mu-coverage-xyz"))
            .readBytes("x.flac"))

        let root = try makeTempDir()
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("a.flac"))
        let provider = LocalFolderProvider(root: root)
        let snap = provider.snapshot()
        XCTAssertEqual(1, snap.count)
        XCTAssertTrue(snap["a.flac"]?.matchesRegex("^3:\\d+$") == true) // rev = "{size}:{mtimeMs}"
        XCTAssertEqual([1, 2, 3], provider.readBytes("a.flac"))
        XCTAssertNil(provider.readBytes("missing.flac"))
    }

    // MARK: - 輔助

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mu-core-cov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func fixtureBytes(_ rel: String) -> Data? {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while true {
            let f = dir.appendingPathComponent("contract/fixtures/cases/\(rel)")
            if FileManager.default.fileExists(atPath: f.path) { return try? Data(contentsOf: f) }
            if dir.path == "/" { return nil }
            dir = dir.deletingLastPathComponent()
        }
    }
}

private extension String {
    func matchesRegex(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}
