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
                .preferredColorScheme(.light)
                .task {
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
