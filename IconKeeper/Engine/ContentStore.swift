//
//  ContentStore.swift
//  IconKeeper
//
//  A directory of files named by the SHA-256 of their contents.
//
//  Backups and render references used to be one file per item. Most items
//  share an original — every plain folder has the same default icon — so a
//  thousand folders meant a thousand identical 1024px PNGs. Content addressing
//  stores each distinct image once; items reference it by name, and a file is
//  deleted only when no item references it any more.
//

import CryptoKit
import Foundation

nonisolated struct ContentStore: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Stores `data` (if not already present) and returns its filename.
    func store(_ data: Data, fileExtension: String) throws -> String {
        let filename = "\(Self.hash(data)).\(fileExtension)"
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        return filename
    }

    /// The file's URL, or `nil` when the name isn't a plain filename. Names come
    /// from the config, which can be imported — never let one escape the directory.
    func url(for filename: String) -> URL? {
        guard Self.isSafeFilename(filename) else { return nil }
        return directory.appendingPathComponent(filename, isDirectory: false)
    }

    func remove(_ filename: String) {
        guard let url = url(for: filename) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes files no record refers to. Recently written files are spared:
    /// the background agent may have just written one it hasn't reported yet.
    @discardableResult
    func removeUnreferenced(keeping referenced: Set<String>, olderThan age: TimeInterval = 600, now: Date = Date()) -> Int {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return 0 }
        var removed = 0
        for file in files where !referenced.contains(file.lastPathComponent) {
            let modified = (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) > age else { continue }
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hashFile(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return hash(data)
    }

    static func isSafeFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}
