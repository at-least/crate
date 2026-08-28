import Foundation
import MuCore

/// 掃描效能檢查（B2 的 Apple 側對照；`swift run perfcheck [libPath] [albums]`）。
/// 無 libPath 時以 contract fixture FLAC 合成 N 張專輯 × 8 軌的暫存庫。
/// 注意：合成檔極小——本基準以「檔案數」為成本主軸（目錄 walk + 每檔 parse）；
/// 真實庫的 IO 量更大，GDrive 相位再以 rangeRead 上限校準。
let args = CommandLine.arguments
let albums = args.count > 2 ? Int(args[2]) ?? 500 : 500
let tracksPerAlbum = 8
let budgetSeconds: Double = 300 // B2：< 5 分鐘

let fm = FileManager.default
var lib: URL
var cleanup = false

if args.count > 1 {
    lib = URL(fileURLWithPath: args[1])
} else {
    // 找 repo 的 fixture FLAC（自 cwd 逐層上溯）
    var fixture: URL?
    var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
    while true {
        let f = dir.appendingPathComponent(
            "contract/fixtures/cases/flac_no_tags/lib/Aurora/Northern Lights/01 - Rise.flac")
        if fm.fileExists(atPath: f.path) { fixture = f; break }
        if dir.path == "/" { break }
        dir = dir.deletingLastPathComponent()
    }
    guard let src = fixture else {
        FileHandle.standardError.write("fixture not found (run from repo)\n".data(using: .utf8)!)
        exit(2)
    }
    let data = try! Data(contentsOf: src)
    lib = fm.temporaryDirectory.appendingPathComponent("mu-perf-\(UUID().uuidString)")
    for a in 0..<albums {
        let d = lib.appendingPathComponent("Artist \(a)/Album \(a)")
        try! fm.createDirectory(at: d, withIntermediateDirectories: true)
        for t in 1...tracksPerAlbum {
            try! data.write(to: d.appendingPathComponent(String(format: "%02d - Track.flac", t)))
        }
    }
    cleanup = true
}
defer { if cleanup { try? fm.removeItem(at: lib) } }

let provider = LocalFolderProvider(root: lib)

let t0 = Date()
let snap = provider.snapshot()
let snapSec = Date().timeIntervalSince(t0)

let engine = SyncEngine(provider: provider)
let t1 = Date()
let report = try engine.sync()
let firstSec = Date().timeIntervalSince(t1)

let t2 = Date()
let report2 = try engine.sync()
let deltaSec = Date().timeIntervalSince(t2)

print("""
albums=\(albums) tracks=\(albums * tracksPerAlbum) files=\(snap.count)
snapshot  \(String(format: "%.2f", snapSec))s
firstScan \(String(format: "%.2f", firstSec))s  (indexed=\(report.tracks.count))
deltaSync \(String(format: "%.3f", deltaSec))s  (changes=\(report2.changes.count))
total     \(String(format: "%.2f", snapSec + firstSec))s  budget=\(Int(budgetSeconds))s
""")
exit(snapSec + firstSec < budgetSeconds ? 0 : 1)
