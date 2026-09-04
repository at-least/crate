package at.least.crate.android

import android.app.Application
import at.least.crate.android.db.CrateDatabase

/** App 進入點：持有 DB 單例與釘選管理器。 */
class CrateApp : Application() {
    val database: CrateDatabase by lazy { CrateDatabase.build(this) }
    val pinManager: PinManager by lazy { PinManager(database.libraryDao(), filesDir) }
}
