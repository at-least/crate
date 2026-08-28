import SwiftUI
import MuKit

/// App 進入點：持有 DB 與釘選管理器（≈ Android MuApp）。
@main
struct MuiOSApp: App {
    @StateObject private var model: AppModel

    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        let db: MuDatabase
        do {
            db = try MuDatabase(url: support.appendingPathComponent("mu.db"))
        } catch {
            fatalError("mu.db open failed: \(error)")
        }
        let pinManager = PinManager(db: db, pinsDir: support.appendingPathComponent("pins"))
        _model = StateObject(wrappedValue: AppModel(db: db, pinManager: pinManager))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}
