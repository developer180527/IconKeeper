//
//  DashboardComponents.swift
//  IconKeeper
//
//  The dashboard's building blocks: summary cards that double as the primary
//  filter, the pinned filter bar, removable chips, and the status pill.
//

import SwiftUI

// MARK: - Summary card

/// A count with a meaning, which filters the list when clicked.
struct SummaryCard: View {
    let scope: DashboardQuery.Scope
    let count: Int
    let caption: String
    let tint: Color
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: scope.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(count == 0 && scope == .attention ? .secondary : tint)
                        .frame(width: 26, height: 26)
                        .background(tint.opacity(isSelected ? 0.22 : 0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    Text(scope.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(count, format: .number)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(count)))
                    .foregroundStyle(.primary)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(tint.opacity(0.10)) : AnyShapeStyle(.background.secondary))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? tint.opacity(0.55) : Color.primary.opacity(isHovered ? 0.14 : 0.07),
                                  lineWidth: isSelected ? 1.5 : 1)
            }
            .shadow(color: .black.opacity(isHovered ? 0.10 : 0.04), radius: isHovered ? 8 : 3, y: isHovered ? 3 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .help(isSelected ? "Showing \(scope.title.lowercased()) — click to show everything" : "Show \(scope.title.lowercased())")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Chips

/// A removable refinement ("Icon Reset ✕").
struct FilterChip: View {
    let title: String
    let symbol: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).imageScale(.small)
            Text(title).lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .padding(3)
                    .background(.primary.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Remove this filter")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Color.accentColor)
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
        .fixedSize()
    }
}

// MARK: - Status pill

/// One pill that says what matters about an item: its protection state, or —
/// when that's fine — a health concern worth a look.
struct StatusPill: View {
    let status: AppStatus
    let health: HealthLevel?

    private var presentation: (label: String, symbol: String, color: Color, help: String) {
        if status == .protected, let health, health == .warning || health == .problem {
            return ("Check Health", health == .problem ? "heart.slash.fill" : "exclamationmark.triangle.fill",
                    health.color, "The icon is in place, but a health check needs attention. Open details to see which.")
        }
        let help: String = switch status {
        case .protected: "Your icon is in place and being watched."
        case .checking: "IconKeeper hasn't checked this item since launch yet."
        case .applying: "Applying the icon now."
        case .restoring: "Restoring the original icon."
        case .drifted: "The icon was reset and hasn't been put back yet."
        case .paused: "Protection is off for this item."
        case .missing: "The item can't be found at its saved location."
        case .trashed: "The item is in the Trash, so protection is paused."
        case .externallyChanged: "A different icon was applied outside IconKeeper. Keep yours, or adopt the new one."
        case .failed(let message): message
        }
        return (status.label, status.symbolName, status.color, help)
    }

    var body: some View {
        let p = presentation
        HStack(spacing: 5) {
            if status == .applying || status == .restoring || status == .checking {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: p.symbol).imageScale(.small)
            }
            Text(p.label).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(p.color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(p.color.opacity(0.13), in: Capsule())
        .fixedSize()
        .help(p.help)
    }
}

// MARK: - Item icon

/// The item's assigned icon with a small badge saying whether it's an app or folder.
struct ItemIconView: View {
    let url: URL?
    let kind: ItemKind
    var size: CGFloat = 40

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            IconThumbnail(url: url, size: size) {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(.quaternary)
                    .overlay(Image(systemName: kind.symbolName).foregroundStyle(.secondary))
            }

            Image(systemName: kind == .app ? "app.fill" : "folder.fill")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 15, height: 15)
                .background(kind == .app ? Color.blue : Color.teal, in: Circle())
                .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                .offset(x: 3, y: 3)
                .accessibilityLabel(kind.label)
        }
    }
}
