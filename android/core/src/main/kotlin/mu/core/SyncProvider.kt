package mu.core

/**
 * 引擎面向的 provider 兩面（sync-rules §3）：快照 + 讀檔。
 * 本地（provider.md §6）永不拋；雲端（§8）重試耗盡/重授權失敗時拋 [ProviderException]。
 */
interface SyncProvider {
    /** path -> rev；全部檔案（含非音訊；過濾是引擎的事）。失敗 → 整輪 sync 拋錯、狀態不動。 */
    fun snapshot(): Map<String, String>

    /**
     * 掃描用開檔（model.md §1.8 ByteSource）；null = NotFound（引擎靜默丟棄）；其他失敗拋 [ProviderException] → §3.2-8 續掃。
     * 開檔後讀取中 404 → [ProviderException.NotFound]（同靜默丟棄）。
     */
    fun open(path: String): ByteSource?
}

/** provider.md §2 錯誤語意（重試耗盡後由 provider 拋出）。 */
sealed class ProviderException(message: String) : Exception(message) {
    /** 重授權後仍 401。 */
    class Auth : ProviderException("auth")

    /** 退避 5 次仍失敗。 */
    class Transient : ProviderException("transient")

    /** 404（引擎面：readBytes 回 null，不以此拋出）。 */
    class NotFound : ProviderException("notfound")

    /** 其他 4xx（不重試）。 */
    class Http(val status: Int) : ProviderException("http $status")
}
