//
//  IconKeeperApp.swift
//  IconKeeper
//
//  App entry point: the main window, Settings, and the menu bar companion,
//  all sharing a single AppStore.
//

import SwiftUI

/// Real process entry point. Splits the headless `--agent` path (run by the
/// launchd LaunchAgent) from the normal GUI launch before SwiftUI starts.
@main
struct IconKeeperMain {
    static func main() {
        if CommandLine.arguments.dropFirst().contains("--agent") {
            AgentRunner.runAndExit() // never returns
        }
        IconKeeperApp.main()
    }
}

struct IconKeeperApp: App {
    @State private var store = AppStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(store)
                .onAppear {
                    store.startMonitoring()
                    NotificationManager.shared.requestAuthorization()
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environment(store)
                .frame(width: 480, height: 560)
        }

        MenuBarExtra {
            MenuBarView()
                .environment(store)
        } label: {
            Image(systemName: store.driftedCount > 0 ? "exclamationmark.shield.fill" : "checkmark.shield")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Keeps the app (and its menu bar companion) alive after the window closes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
