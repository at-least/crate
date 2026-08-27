package mu.core

/**
 * provider.md §2.1 重試政策（錯誤語意契約，fixtures err_cases/）。
 * 錯誤種類以 [ProviderErrorKind] 表示；時脈與 sleep 由 caller 注入（測試確定性）。
 */
object RetryPolicy {

    enum class ProviderErrorKind { AUTH, TRANSIENT, NOT_FOUND }

    val TRANSIENT_DELAYS_MS = longArrayOf(1000, 2000, 4000, 8000, 16000)
    const val MAX_TRANSIENT_RETRIES = 5

    data class Outcome(val result: String, val reauths: Int, val sleeps: List<Long>)

    /**
     * [op] 回傳 null = 成功，否則為該次錯誤。[onReauth] 於重授權時被呼叫。
     * [sleep] 注入（測試收集序列；正式接 System::sleep 或協程 delay）。
     */
    fun run(
        op: () -> ProviderErrorKind?,
        onReauth: () -> Unit = {},
        sleep: (Long) -> Unit = {},
    ): Outcome {
        val sleeps = ArrayList<Long>()
        var transient = 0
        var reauthUsed = false
        var reauths = 0
        while (true) {
            val err = op()
            if (err == null) return Outcome("ok", reauths, sleeps)
            when (err) {
                ProviderErrorKind.NOT_FOUND -> return Outcome("notfound", reauths, sleeps)
                ProviderErrorKind.AUTH -> {
                    if (reauthUsed) return Outcome("auth", reauths, sleeps)
                    reauthUsed = true
                    reauths++
                    onReauth()
                }
                ProviderErrorKind.TRANSIENT -> {
                    if (transient >= MAX_TRANSIENT_RETRIES) {
                        return Outcome("transient", reauths, sleeps)
                    }
                    sleeps.add(TRANSIENT_DELAYS_MS[transient])
                    transient++
                }
            }
        }
    }

    fun kindFromJson(s: String): ProviderErrorKind = when (s) {
        "transient" -> ProviderErrorKind.TRANSIENT
        "auth" -> ProviderErrorKind.AUTH
        "notfound" -> ProviderErrorKind.NOT_FOUND
        "ok" -> error("ok is not an error kind")
        else -> error("unknown error kind: $s")
    }
}
