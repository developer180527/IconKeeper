//
//  DropZone.swift
//  IconKeeper
//
//  A reusable drag-and-drop target that filters by file extension and reports
//  whether it's currently being targeted (so content can highlight).
//

import SwiftUI

struct DropZone<Content: View>: View {
    var allowedExtensions: Set<String>
    var onDrop: ([URL]) -> Void
    @ViewBuilder var content: (_ isTargeted: Bool) -> Content

    @State private var isTargeted = false

    var body: some View {
        content(isTargeted)
            .dropDestination(for: URL.self) { urls, _ in
                let matches = urls.filter { allowedExtensions.contains($0.pathExtension.lowercased()) }
                guard !matches.isEmpty else { return false }
                onDrop(matches)
                return true
            } isTargeted: { isTargeted = $0 }
    }
}
