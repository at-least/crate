import Foundation

/// provider.md §2.1 重試政策（錯誤語意契約，fixtures err_cases/）。
/// 時脈與 sleep 由 caller 注入（測試確定性）。
public enum RetryPolicy {

    public enum ProviderErrorKind: String {
        case auth, transient
        case notFound = "notfound"
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
        default: return nil
        }
    }
}
