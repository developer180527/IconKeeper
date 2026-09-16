//
//  AppStore+Discovery.swift
//  IconKeeper
//
//  Recovering customizations whose records were lost (e.g. a wiped config):
//  apps that still carry IconKeeper's marker and a custom icon.
//

import AppKit

extension AppStore {
    /// Scans the Applications folders, off the main thread, for bundles that
    /// carry IconKeeper's marker but aren't tracked.
    func discoverOrphans() {
        let trackedPaths = apps.map(\.bundlePath)
        let trackedIDs = Set(apps.map(\.id))
        Task {
            let found = await Task.detached(priority: .utility) {
                Self.scanForOrphans(trackedPaths: trackedPaths, trackedIDs: trackedIDs)
            }.value
            discoveredOrphans = found
        }
    }

    private nonisolated static func scanForOrphans(trackedPaths: [String], trackedIDs: Set<UUID>) -> [DiscoveredApp] {
        let fileManager = FileManager.default
        let dirs = [
            "/Applications",
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
        ]
        let tracked = Set(trackedPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        var found: [DiscoveredApp] = []
        for dir in dirs {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(entry)
                let resolved = url.resolvingSymlinksInPath().path
                guard !tracked.contains(resolved),
                      let marker = BundleMarker.read(from: url),
                      !trackedIDs.contains(marker.appID),
                      IconManager.isCustomIconApplied(at: url) else { continue }
                found.append(DiscoveredApp(bundlePath: url.path, displayName: marker.displayName, markerAppID: marker.appID))
            }
        }
        return found
    }

    /// Re-adopts a discovered app: extracts its currently-applied icon into the
    /// library and resumes managing it. Works even if the original library
    /// asset was lost, because the applied icon is read straight off the bundle.
    func adoptDiscovered(_ discovered: DiscoveredApp) {
        let persistence = self.persistence
        let path = discovered.bundlePath
        let name = discovered.displayName
        // Off the list straight away, so a second click can't queue it twice.
        dismissDiscovered(discovered)
        fileWork.enqueue(kind: .other) { [weak self] in
            let outcome: Result<AdoptedBundle, Error> = await Task.detached(priority: .userInitiated) {
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: path) else { return .failure(IconError.bundleMissing) }
                do {
                    let staged = try IconImporter.stageCurrentIcon(of: url, name: name, persistence: persistence)
                    return .success(AdoptedBundle(
                        staged: staged,
                        bundleIdentifier: IconManager.bundleIdentifier(of: url),
                        reference: IconEngine.captureReference(of: url, into: persistence.renders),
                        fingerprint: DiskFingerprint.read(path: path),
                        bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            switch outcome {
            case .failure(IconError.bundleMissing):
                return
            case .failure(let error):
                self.report("Couldn't adopt \(name): \(error.localizedDescription)")
            case .success(let adopted):
                guard !self.apps.contains(where: { $0.bundlePath == path }) else { return }
                let icon = self.admit(adopted.staged)
                // Keep the id it was managed under, so its history still matches.
                let id = discovered.markerAppID.flatMap { self.item($0) == nil ? $0 : nil } ?? UUID()
                let app = ProtectedApp(
                    id: id,
                    bundlePath: path,
                    kind: .app,
                    bundleIdentifier: adopted.bundleIdentifier,
                    displayName: name,
                    customIconID: icon.id,
                    originalIconBackupFilename: nil, // genuine is hidden now; captured on the next update
                    appliedRenderFilename: adopted.reference,
                    bookmark: adopted.bookmark,
                    isProtectionEnabled: true,
                    lastAppliedDate: Date()
                )
                self.apps.append(app)
                self.fingerprints[id] = adopted.fingerprint
                self.lastDriftScore[id] = 0
                self.updateRuntime(id) {
                    $0.location = .present
                    $0.verdict = .matches
                }
                self.log(.added, item: app, message: "Re-adopted after discovery.")
                self.persist()
                self.syncWatchers()
                let marker = ManagedMarker(appID: id, iconID: icon.id, displayName: name, markedAt: Date())
                await Task.detached(priority: .utility) { BundleMarker.write(marker, to: URL(fileURLWithPath: path)) }.value
            }
        }
    }

    private struct AdoptedBundle: Sendable {
        let staged: IconLibraryItem
        let bundleIdentifier: String?
        let reference: String?
        let fingerprint: DiskFingerprint?
        let bookmark: Data?
    }

    /// Removes the custom icon from a discovered app, reverting it to genuine.
    func restoreDiscovered(_ discovered: DiscoveredApp) {
        let path = discovered.bundlePath
        dismissDiscovered(discovered)
        fileWork.enqueue(kind: .other) { [weak self] in
            let failure: String? = await Task.detached(priority: .userInitiated) {
                let url = URL(fileURLWithPath: path)
                do {
                    try IconManager.removeCustomIcon(from: url)
                    BundleMarker.remove(from: url)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self else { return }
            if let failure {
                self.report("Couldn't restore \(discovered.displayName): \(failure)")
            } else {
                self.log(.restored, item: nil, name: discovered.displayName, message: "Restored original icon (recovered).")
            }
        }
    }

    func dismissDiscovered(_ discovered: DiscoveredApp) {
        discoveredOrphans.removeAll { $0.id == discovered.id }
    }

    func dismissAllDiscovered() {
        discoveredOrphans.removeAll()
    }
}
