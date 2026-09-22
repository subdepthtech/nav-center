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
                .frame(minWidth: LayoutMetrics.minimumWindowSize.width, minHeight: LayoutMetrics.minimumWindowSize.height)
                .task {
                    appDelegate.store = store
                    await store.bootstrap()
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button(KeyboardShortcutRegistry.refresh.title) {
                    Task { await store.refresh() }
                }
                .keyboardShortcut(KeyEquivalent(KeyboardShortcutRegistry.refresh.key.first!), modifiers: KeyboardShortcutRegistry.refresh.modifiers)
            }
            CommandMenu("Go") {
                ForEach(Array(DashboardDestination.allCases.enumerated()), id: \.element.id) { index, destination in
                    Button(destination.title) { store.requestedDestination = destination }
                        .keyboardShortcut(KeyEquivalent(KeyboardShortcutRegistry.destinations[index].key.first!), modifiers: .command)
                }
                Divider()
                Button(KeyboardShortcutRegistry.back.title) { store.closePackage() }
                    .keyboardShortcut(KeyEquivalent(KeyboardShortcutRegistry.back.key.first!), modifiers: KeyboardShortcutRegistry.back.modifiers)
                    .disabled(store.selectedPackage == nil)
                Button(KeyboardShortcutRegistry.find.title) { store.searchFocusRequest += 1 }
                    .keyboardShortcut(KeyEquivalent(KeyboardShortcutRegistry.find.key.first!), modifiers: KeyboardShortcutRegistry.find.modifiers)
                Button(KeyboardShortcutRegistry.codex.title) { store.isCodexPanelPresented.toggle() }
                    .keyboardShortcut(KeyEquivalent(KeyboardShortcutRegistry.codex.key.first!), modifiers: KeyboardShortcutRegistry.codex.modifiers)
                Divider()
                Button(KeyboardShortcutRegistry.ats.title) { store.requestedRailAction = .atsScan }
                    .keyboardShortcut(KeyEquivalent(KeyboardShortcutRegistry.ats.key.first!), modifiers: KeyboardShortcutRegistry.ats.modifiers)
                    .disabled(store.selectedPackage == nil)
                Button(KeyboardShortcutRegistry.export.title) { store.requestedRailAction = .exportArtifacts }
                    .keyboardShortcut(KeyEquivalent(KeyboardShortcutRegistry.export.key.first!), modifiers: KeyboardShortcutRegistry.export.modifiers)
                    .disabled(store.selectedPackage == nil)
            }
            CommandGroup(replacing: .appSettings) {
                Button(KeyboardShortcutRegistry.settings.title) { store.requestedDestination = .settings }
                    .keyboardShortcut(KeyEquivalent(KeyboardShortcutRegistry.settings.key.first!), modifiers: KeyboardShortcutRegistry.settings.modifiers)
            }
            CommandGroup(after: .help) {
                Button("Copy Redacted Diagnostics") {
                    Task { await store.copyRedactedDiagnostics() }
                }
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
