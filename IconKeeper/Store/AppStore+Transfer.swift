//
//  AppStore+Transfer.swift
//  IconKeeper
//
//  Export and import of the configuration. The caller picks the file; the
//  store never opens a panel itself.
//

import Foundation

extension AppStore {
    func exportConfiguration(to destination: URL) {
        let apps = self.apps
        let icons = library.compactMap { item in persistence.libraryFileURL(for: item.filename).map { (item, $0) } }
        Task {
            let outcome: Result<Int, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let exported = icons.compactMap { item, url -> ExportedIcon? in
                        guard let data = try? Data(contentsOf: url) else { return nil }
                        return ExportedIcon(id: item.id, name: item.name, filename: item.filename, data: data)
                    }
                    let config = ExportedConfiguration(
                        version: ExportedConfiguration.currentVersion, exportedAt: Date(),
                        apps: apps, icons: exported)
                    try ConfigTransfer.encode(config).write(to: destination, options: .atomic)
                    return .success(exported.count)
                } catch {
                    return .failure(error)
                }
            }.value
            switch outcome {
            case .success(let iconCount):
                log(.exported, item: nil, name: "Configuration",
                    message: "Exported \(apps.count) item\(apps.count == 1 ? "" : "s") and \(iconCount) icon\(iconCount == 1 ? "" : "s").")
            case .failure(let error):
                report("Export failed: \(error.localizedDescription)")
            }
        }
    }

    func importConfiguration(from source: URL) {
        let existingItems = apps
        let existingLibrary = library
        let persistence = self.persistence
        Task {
            let outcome: Result<ConfigTransfer.Plan, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let config = try ConfigTransfer.decode(try Data(contentsOf: source))
                    let plan = ConfigTransfer.plan(config, existingItems: existingItems, existingLibrary: existingLibrary)
                    var written = plan
                    written.icons = plan.icons.filter { icon in
                        (try? persistence.writeLibraryIcon(icon.data, id: icon.item.id,
                                                           fileExtension: (icon.item.filename as NSString).pathExtension)) != nil
                    }
                    return .success(written)
                } catch let error as ConfigTransfer.ImportError {
                    return .failure(error)
                } catch {
                    return .failure(ConfigTransfer.ImportError.unreadable)
                }
            }.value

            let plan: ConfigTransfer.Plan
            switch outcome {
            case .failure(let error):
                report(error.localizedDescription)
                return
            case .success(let value):
                plan = value
            }

            // State may have changed while the file was read: check again.
            let libraryIDs = Set(library.map(\.id))
            for icon in plan.icons where !libraryIDs.contains(icon.item.id) {
                library.append(icon.item)
            }
            let knownIcons = Set(library.map(\.id))
            var added: [ProtectedApp] = []
            for var app in plan.items where item(app.id) == nil && !apps.contains(where: { $0.bundlePath == app.bundlePath }) {
                if let iconID = app.customIconID, !knownIcons.contains(iconID) { app.customIconID = nil }
                apps.append(app)
                added.append(app)
            }

            for app in added where app.isProtectionEnabled && app.customIconID != nil {
                // Back up first only if the genuine icon is showing — an item
                // already wearing a custom icon has nothing genuine to save.
                requestReapply(app.id, PendingReapply(automatic: false, backup: .ifNoCustomIcon, note: "Applied from an imported configuration."))
            }
            let skipped = plan.skippedItems + plan.items.count - added.count
            log(.imported, item: nil, name: "Configuration",
                message: "Imported \(added.count) item\(added.count == 1 ? "" : "s")"
                    + (skipped > 0 ? "; skipped \(skipped) already protected." : "."))
            persist()
            syncWatchers()
            scheduleVerify(added.map(\.id))
        }
    }
}
