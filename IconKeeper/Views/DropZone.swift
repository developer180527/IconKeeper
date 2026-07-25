//
//  DropZone.swift
//  IconKeeper
//
//  A reusable drag-and-drop target that filters by file extension and reports
//  whether it's currently being targeted (so content can highlight).
//

import SwiftUI

struct DropZone<Content: View>: View {
    /// Decides whether a dropped URL is acceptable. A predicate rather than a
    /// set of extensions, because folders are identified by being directories
    /// rather than by any extension.
    var accepts: (URL) -> Bool
    var onDrop: ([URL]) -> Void
    @ViewBuilder var content: (_ isTargeted: Bool) -> Content

    @State private var isTargeted = false

    /// Convenience for the common "match these file extensions" case.
    init(
        allowedExtensions: Set<String>,
        onDrop: @escaping ([URL]) -> Void,
        @ViewBuilder content: @escaping (_ isTargeted: Bool) -> Content
    ) {
        self.accepts = { allowedExtensions.contains($0.pathExtension.lowercased()) }
        self.onDrop = onDrop
        self.content = content
    }

    init(
        accepts: @escaping (URL) -> Bool,
        onDrop: @escaping ([URL]) -> Void,
        @ViewBuilder content: @escaping (_ isTargeted: Bool) -> Content
    ) {
        self.accepts = accepts
        self.onDrop = onDrop
        self.content = content
    }

    var body: some View {
        content(isTargeted)
            .dropDestination(for: URL.self) { urls, _ in
                let matches = urls.filter(accepts)
                guard !matches.isEmpty else { return false }
                onDrop(matches)
                return true
            } isTargeted: { isTargeted = $0 }
    }
}
