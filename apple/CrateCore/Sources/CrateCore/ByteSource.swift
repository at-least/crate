import Foundation

/// 掃描器的輸入（model.md §1.8）：size + read(offset, length)（裁切到 size）。
/// 雲端 read 可拋 `ProviderError`（.notFound = 讀取中檔案消失 → 引擎靜默丟棄；其他 → 續掃）。
public protocol ByteSource {
    var size: Int { get }
    func read(offset: Int, length: Int) throws -> [UInt8]
}

/// 記憶體來源（測試 / 陣列 API 相容包裝）。
public struct MemorySource: ByteSource {
    public let data: [UInt8]
    public init(_ data: [UInt8]) { self.data = data }
    public var size: Int { data.count }
    public func read(offset: Int, length: Int) throws -> [UInt8] {
        guard offset < data.count, length > 0 else { return [] }
        return Array(data[offset..<min(data.count, offset + length)])
    }
}

/// 本地檔案來源（open 時取 size；讀取中檔案消失 → .notFound）。
public struct FileSource: ByteSource {
    public let url: URL
    public let size: Int

    /// 不存在 → nil。
    public init?(url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = attrs[.size] as? NSNumber else { return nil }
        self.url = url
        self.size = n.intValue
    }

    public func read(offset: Int, length: Int) throws -> [UInt8] {
        guard let fh = try? FileHandle(forReadingFrom: url) else { throw ProviderError.notFound }
        defer { try? fh.close() }
        try fh.seek(toOffset: UInt64(offset))
        return (try fh.read(upToCount: length))?.bytes ?? []
    }
}

/// 64 KiB 對齊 chunk、每 chunk 抓一次（快取）；三實作同算法 → 觸碰 chunk 集合一致（model.md §1.8）。
public final class ChunkedReader {
    public static let chunk = 65536

    public let size: Int
    private let src: any ByteSource
    private var chunks: [Int: [UInt8]] = [:]
    public private(set) var fetches = 0

    public init(_ src: any ByteSource) {
        self.src = src
        self.size = src.size
    }

    public convenience init(bytes: [UInt8]) { self.init(MemorySource(bytes)) }

    /// [offset, offset+length) 裁切到 size；越界/空 → []。
    public func bytes(_ off: Int, _ length: Int) throws -> [UInt8] {
        guard off >= 0, off < size, length > 0 else { return [] }
        let end = min(size, off + length)
        let c = Self.chunk
        var out: [UInt8] = []
        out.reserveCapacity(end - off)
        for k in (off / c)...((end - 1) / c) {
            if chunks[k] == nil {
                let start = k * c
                chunks[k] = try src.read(offset: start, length: min(c, size - start))
                fetches += 1
            }
            let data = chunks[k]!
            let a = max(off, k * c) - k * c
            let b = min(end, (k + 1) * c) - k * c
            guard a < b, b <= data.count else { continue }
            out.append(contentsOf: data[a..<b])
        }
        return out
    }
}
