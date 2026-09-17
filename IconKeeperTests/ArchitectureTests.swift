//
//  ArchitectureTests.swift
//  IconKeeperTests
//
//  Keeps the UI decoupled from the backend, mechanically.
//
//  Views may read published state (`index`, `summary`, `library`, `activity`,
//  health, settings) and call store actions and the async view-support APIs.
//  They may not reach the engine, the file system, persistence, or the raw
//  model — each of those means disk I/O or engine work in a view body, or a
//  subscription to state far broader than what the view shows.
//

import Foundation
import Testing

@Suite("Architecture")
struct ArchitectureTests {
    /// Forbidden in any view, with the reason shown when one appears.
    private static let forbidden: [(pattern: String, reason: String)] = [
        ("IconManager.", "engine: classify/names/icons read the disk — use AppStore view-support APIs"),
        ("IconEngine", "engine: icon writes belong to the store's file-work queue"),
        ("Verifier.", "engine: evaluation runs in the store"),
        ("DriftPolicy", "engine: policy decisions belong to the store"),
        ("BundleMarker", "engine: xattr I/O"),
        ("IconImporter", "engine: conversion runs iconutil"),
        ("ConfigTransfer", "engine: import planning belongs to the store"),
        ("ContentStore", "persistence"),
        ("PersistenceController", "persistence"),
        ("LaunchAgentManager", "system integration belongs to the store"),
        ("LoginItemManager", "system integration belongs to the store"),
        ("FileManager", "disk I/O on the main thread"),
        ("Data(contentsOf", "disk I/O on the main thread"),
        ("NSImage(contentsOf", "image decoding on the main thread — use IconThumbnail"),
        ("Bundle(url", "Info.plist reads on the main thread"),
        ("store.apps", "raw model: subscribes the view to every item change — read `index`/`entry(for:)`"),
        ("store.runtime", "raw engine state"),
        ("store.fingerprints", "raw engine state"),
        ("store.lastDriftScore", "raw engine state — use driftScores(limit:)"),
        ("store.persistence", "persistence"),
        ("store.fileWork", "engine queue"),
        ("store.item(", "raw model — use entry(for:)"),
        ("store.status(for", "raw model — the index carries status"),
    ]

    /// The view layer's image loader is the one place allowed to touch the
    /// file system and NSWorkspace icons — always off the main thread.
    private static let exemptions: [String: Set<String>] = [
        "IconThumbnails.swift": ["FileManager"],
    ]

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("IconKeeper", isDirectory: true)
    }

    private static func viewSources() throws -> [URL] {
        let root = sourceRoot
        var files = [root.appendingPathComponent("ContentView.swift")]
        let views = root.appendingPathComponent("Views", isDirectory: true)
        let enumerator = try #require(FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    @Test("Views don't reach the engine, the disk, or the raw model")
    func viewsAreDecoupled() throws {
        let files = try Self.viewSources()
        #expect(files.count > 10, "expected to find the view sources under \(Self.sourceRoot.path)")
        var violations: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let exempt = Self.exemptions[file.lastPathComponent] ?? []
            for (number, line) in text.components(separatedBy: .newlines).enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                for rule in Self.forbidden where !exempt.contains(rule.pattern) && code.contains(rule.pattern) {
                    violations.append("\(file.lastPathComponent):\(number + 1) uses `\(rule.pattern)` — \(rule.reason)")
                }
            }
        }
        #expect(violations.isEmpty, Comment(rawValue: "\n" + violations.joined(separator: "\n")))
    }

    @Test("Engine and model types don't depend on SwiftUI")
    func engineHasNoUI() throws {
        let root = Self.sourceRoot
        var violations: [String] = []
        for folder in ["Engine", "Models", "Services"] {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
                let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                if text.contains("import SwiftUI") { violations.append("\(folder)/\(name) imports SwiftUI") }
            }
        }
        #expect(violations.isEmpty, Comment(rawValue: "\n" + violations.joined(separator: "\n")))
    }
}
