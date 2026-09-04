import SwiftUI
import CrateKit

/// Crate — macOS 選單列常駐（PLAN §7 Phase 3 D2）。
/// NSStatusItem + NSPopover 装 SwiftUI 內容；無 Dock 圖示（LSUIElement）。
@main
struct CrateMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() } // 選單列 app：不開正規視窗
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let model = MacModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MacContentView().environmentObject(model))
        popover.contentSize = NSSize(width: 400, height: 560)
        self.popover = popover

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "music.note",
                                      accessibilityDescription: "Crate")
        item.button?.setAccessibilityIdentifier("crate.statusItem")
        item.button?.action = #selector(togglePopover)
        statusItem = item
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
