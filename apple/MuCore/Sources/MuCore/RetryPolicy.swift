import Foundation

/// provider.md §2.1 重試政策（錯誤語意契約，fixtures err_cases/）。
/// 時脈與 sleep 由 caller 注入（測試確定性）。
public enum RetryPolicy {

    public enum ProviderErrorKind: String {
        case auth, transient
        case notFound = "notfound"
        case conflict
    }

    public static let transientDelaysMs: [Int] = [1000, 2000, 4000, 8000, 16000]
    public static let maxTransientRetries = 5

    public struct Outcome: Equatable {
        public let result: String
        public let reauths: Int
        public let sleeps: [Int]
    }

    /// `op` 回傳 nil = 成功。`sleep` 注入（測試收集；正式接 Task.sleep）。
    public static func run(
        op: () -> ProviderErrorKind?,
        onReauth: () -> Void = {},
        sleep: (Int) -> Void = { _ in }
    ) -> Outcome {
        var sleeps: [Int] = []
        var transient = 0
        var reauthUsed = false
        var reauths = 0
        while true {
            guard let err = op() else { return Outcome(result: "ok", reauths: reauths, sleeps: sleeps) }
            switch err {
            case .notFound:
                return Outcome(result: "notfound", reauths: reauths, sleeps: sleeps)
            case .conflict:
                return Outcome(result: "conflict", reauths: reauths, sleeps: sleeps)
            case .auth:
                if reauthUsed {
                    return Outcome(result: "auth", reauths: reauths, sleeps: sleeps)
                }
                reauthUsed = true
                reauths += 1
                onReauth()
            case .transient:
                if transient >= maxTransientRetries {
                    return Outcome(result: "transient", reauths: reauths, sleeps: sleeps)
                }
                sleeps.append(transientDelaysMs[transient])
                transient += 1
            }
        }
    }

    public static func kind(from s: String) -> ProviderErrorKind? {
        switch s {
        case "transient": return .transient
        case "auth": return .auth
        case "notfound": return .notFound
        case "conflict": return .conflict
        default: return nil
        }
    }
}

/// FakeProvider 的檔案面（provider.md §2.1）：in-memory、rev = 遞增整數字串。
public final class FakeFiles {

    public struct PutResult: Equatable {
        public let ok: Bool
        public let error: String?
        public let rev: String?
    }

    private var files: [String: (text: String, rev: String)] = [:]
    private var seq = 0

    private func nextRev() -> String {
        seq += 1
        return String(seq)
    }

    @discardableResult
    public func seed(_ path: String, _ text: String) -> String {
        let r = nextRev()
        files[path] = (text, r)
        return r
    }

    public func currentRev(_ path: String) -> String? {
        files[path]?.rev
    }

    public func putText(_ path: String, _ text: String, parentRev: String?) -> PutResult {
        let cur = files[path]
        if let parentRev, cur == nil || cur!.rev != parentRev {
            return PutResult(ok: false, error: "conflict", rev: nil)
        }
        let r = nextRev()
        files[path] = (text, r)
        return PutResult(ok: true, error: nil, rev: r)
    }
}
