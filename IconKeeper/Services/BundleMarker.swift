//
//  BundleMarker.swift
//  IconKeeper
//
//  A small breadcrumb IconKeeper stamps onto every bundle it customizes, stored
//  as an extended attribute on the .app. It lets a fresh install rediscover its
//  own customizations even if the central config (Application Support) was wiped
//  — so a user's icons are never truly orphaned.
//
//  Extended attributes are excluded from the code-signature seal (like the
//  Finder-info/quarantine xattrs), so this never invalidates a signed app.
//

import Foundation

/// Metadata IconKeeper records on a managed bundle.
nonisolated struct ManagedMarker: Codable {
    var appID: UUID
    var iconID: UUID
    var displayName: String
    var markedAt: Date
}

nonisolated enum BundleMarker {
    private static let attribute = "com.iconkeeper.managed"

    static func write(_ marker: ManagedMarker, to bundleURL: URL) {
        guard let data = try? JSONEncoder().encode(marker) else { return }
        _ = data.withUnsafeBytes { buffer in
            setxattr(bundleURL.path, attribute, buffer.baseAddress, buffer.count, 0, 0)
        }
    }

    static func read(from bundleURL: URL) -> ManagedMarker? {
        let path = bundleURL.path
        let length = getxattr(path, attribute, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { buffer in
            getxattr(path, attribute, buffer.baseAddress, length, 0, 0)
        }
        guard read > 0 else { return nil }
        return try? JSONDecoder().decode(ManagedMarker.self, from: data)
    }

    static func exists(at bundleURL: URL) -> Bool {
        getxattr(bundleURL.path, attribute, nil, 0, 0, 0) > 0
    }

    static func remove(from bundleURL: URL) {
        _ = removexattr(bundleURL.path, attribute, 0)
    }
}
