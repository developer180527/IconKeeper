//
//  StatusBadge.swift
//  IconKeeper
//
//  A small colored pill that visualizes an app's protection status.
//

import SwiftUI

extension AppStatus {
    var color: Color {
        switch self {
        case .protected: .green
        case .applying, .drifted: .orange
        case .paused: .gray
        case .missing: .gray
        case .failed: .red
        }
    }
}

struct StatusBadge: View {
    let status: AppStatus

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.symbolName)
                .imageScale(.small)
            Text(status.label)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(status.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.14), in: Capsule())
    }
}

/// A small status dot, used in compact contexts like the menu bar list.
struct StatusDot: View {
    let status: AppStatus
    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 8, height: 8)
    }
}
