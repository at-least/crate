package music.mu.android

import android.app.Application
import music.mu.android.db.MuDatabase

/** App 進入點：持有 DB 單例與釘選管理器。 */
class MuApp : Application() {
    val database: MuDatabase by lazy { MuDatabase.build(this) }
    val pinManager: PinManager by lazy { PinManager(database.libraryDao(), filesDir) }
}
