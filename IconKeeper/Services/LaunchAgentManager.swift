//
//  LaunchAgentManager.swift
//  IconKeeper
//
//  Installs/removes a launchd LaunchAgent that watches the app folders and
//  relaunches IconKeeper's binary in `--agent` mode on a change — giving
//  protection even when the GUI app isn't running.
//
//  The plist is written at runtime (not bundled) so it can point at the app's
//  current executable path (surviving the app being moved) and expand the
//  user's home `~/Applications` directory — neither of which a static bundled
//  plist can do.
//
//  Triggering: `RunAtLoad` covers login, `StartInterval` is the *reliable*
//  periodic trigger (launchd `WatchPaths` on a directory proved unreliable for
//  content changes on macOS, so it's kept only as a best-effort bonus). Each
//  launch is a short-lived process that sweeps and exits — no resident daemon.
//

import Foundation

@MainActor
enum LaunchAgentManager {
    static let label = "developer180527.IconKeeper.Agent"

    /// How often launchd relaunches the agent to sweep for drift (seconds).
    /// Offline drift only happens on app updates, which are infrequent — 10
    /// minutes keeps latency low at negligible cost (each run is milliseconds).
    static let sweepInterval = 600

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist", isDirectory: false)
    }

    /// Whether the LaunchAgent is currently installed.
    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Writes the plist for the current executable and (re)loads it.
    static func enable() throws {
        let execPath = Bundle.main.executableURL?.path ?? Bundle.main.bundlePath

        var watchPaths = ["/Applications"]
        let userApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").path
        if FileManager.default.fileExists(atPath: userApps) {
            watchPaths.append(userApps)
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [execPath, "--agent"],
            "RunAtLoad": true,            // reapply at login
            "StartInterval": sweepInterval, // reliable periodic sweep
            "WatchPaths": watchPaths,     // best-effort responsiveness (may not fire)
            "ProcessType": "Background",
            "ThrottleInterval": 10,
        ]

        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        reload()
    }

    /// Unloads and removes the LaunchAgent.
    static func disable() {
        bootout()
        try? FileManager.default.removeItem(at: plistURL)
    }

    /// If installed but the recorded executable path no longer matches (the app
    /// was moved/updated), rewrite and reload so the agent keeps working.
    static func refresh() {
        guard isEnabled else { return }
        if installedExecPath() != Bundle.main.executableURL?.path {
            try? enable()
        }
    }

    // MARK: - Private

    private static func installedExecPath() -> String? {
        guard
            let data = try? Data(contentsOf: plistURL),
            let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let args = dict["ProgramArguments"] as? [String]
        else { return nil }
        return args.first
    }

    private static var domain: String { "gui/\(getuid())" }

    private static func reload() {
        bootout()
        runLaunchctl(["bootstrap", domain, plistURL.path])
    }

    private static func bootout() {
        runLaunchctl(["bootout", "\(domain)/\(label)"])
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
