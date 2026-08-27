package music.mu.android

import android.app.Application
import music.mu.android.db.MuDatabase

/** App 進入點：持有 DB 單例（之後的釘選下載等也掛這裡）。 */
class MuApp : Application() {
    val database: MuDatabase by lazy { MuDatabase.build(this) }
}
