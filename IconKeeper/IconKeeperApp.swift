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
        // Hosting unit tests: run a bare application so the tests can load,
        // without the store touching the real configuration or any icons.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.run()
            return
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
                .onAppear { startServices() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .windowErrorAlert()
                .environment(store)
                .frame(width: 480, height: 560)
        }

        MenuBarExtra {
            MenuBarView()
                .environment(store)
        } label: {
            // A view, not an expression in the App body: reading the store here
            // would re-evaluate every scene whenever any count changed.
            // The label is always on screen, so monitoring starts even when
            // the app launches with no window (login item, closed at quit).
            MenuBarLabel(onAppear: startServices).environment(store)
        }
        .menuBarExtraStyle(.window)
    }

    private func startServices() {
        store.startMonitoring()
        if PersistenceController.dataDirectoryOverride == nil {
            NotificationManager.shared.requestAuthorization()
        } else {
            NotificationManager.shared.isEnabled = false
        }
    }
}

private struct MenuBarLabel: View {
    @Environment(AppStore.self) private var store
    var onAppear: () -> Void
    var body: some View {
        Image(systemName: store.summary.needsAttention > 0 ? "exclamationmark.shield.fill" : "checkmark.shield")
            .onAppear(perform: onAppear)
    }
}

/// Keeps the app (and its menu bar companion) alive after the window closes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
