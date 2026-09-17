//
//  DropZone.swift
//  IconKeeper
//
//  A reusable drag-and-drop target that filters by file extension and reports
//  whether it's currently being targeted (so content can highlight).
//

import SwiftUI

struct DropZone<Content: View>: View {
    /// Narrows dropped URLs to the acceptable ones. Async, so checks that need
    /// the disk (is this a folder?) run off the main thread.
    var filter: @MainActor ([URL]) async -> [URL]
    var onDrop: ([URL]) -> Void
    @ViewBuilder var content: (_ isTargeted: Bool) -> Content

    @State private var isTargeted = false

    /// Accepts files with these extensions — a string check, no disk access.
    init(
        allowedExtensions: Set<String>,
        onDrop: @escaping ([URL]) -> Void,
        @ViewBuilder content: @escaping (_ isTargeted: Bool) -> Content
    ) {
        self.filter = { urls in urls.filter { allowedExtensions.contains($0.pathExtension.lowercased()) } }
        self.onDrop = onDrop
        self.content = content
    }

    init(
        filter: @escaping @MainActor ([URL]) async -> [URL],
        onDrop: @escaping ([URL]) -> Void,
        @ViewBuilder content: @escaping (_ isTargeted: Bool) -> Content
    ) {
        self.filter = filter
        self.onDrop = onDrop
        self.content = content
    }

    var body: some View {
        content(isTargeted)
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                Task {
                    let matches = await filter(files)
                    if !matches.isEmpty { onDrop(matches) }
                }
                return true
            } isTargeted: { isTargeted = $0 }
    }
}
