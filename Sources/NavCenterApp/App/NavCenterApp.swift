import AppKit
import SwiftUI

@main
struct NavCenterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = DashboardStore()

    var body: some Scene {
        WindowGroup("Nav Center") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 820, minHeight: 620)
                .task {
                    appDelegate.store = store
                    await store.bootstrap()
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Refresh Dashboard") {
                    Task { await store.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: DashboardStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.hasUnsavedMasterResume else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Save master resume changes before quitting?"
        alert.informativeText = "Your unsaved master resume edits will be lost if you quit without saving."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Without Saving")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                let outcome = await store.saveMasterResume()
                sender.reply(toApplicationShouldTerminate: outcome == .saved)
            }
            return .terminateLater
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
