//
//  HealthView.swift
//  IconKeeper
//
//  Presentation for the icon-health layer: the compact pill shown on rows and
//  the transparent, criterion-by-criterion breakdown shown in app detail.
//

import SwiftUI

extension HealthLevel {
    var color: Color {
        switch self {
        case .ok: .green
        case .warning: .orange
        case .problem: .red
        case .unknown: .gray
        }
    }

    /// Word shown in the rollup pill.
    var label: String {
        switch self {
        case .ok: "Healthy"
        case .warning: "Attention"
        case .problem: "Issue"
        case .unknown: "Paused"
        }
    }

    /// Symbol for the rollup pill.
    var pillSymbol: String {
        switch self {
        case .ok: "heart.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .problem: "heart.slash.fill"
        case .unknown: "pause.circle.fill"
        }
    }

    /// Pass/warn/fail glyph used per individual check.
    var checkGlyph: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .problem: "xmark.octagon.fill"
        case .unknown: "minus.circle.fill"
        }
    }
}

/// Compact health rollup pill (dashboard rows, detail header).
struct HealthPill: View {
    let level: HealthLevel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: level.pillSymbol)
                .imageScale(.small)
            Text(level.label)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(level.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(level.color.opacity(0.14), in: Capsule())
    }
}

/// The per-criterion health breakdown in the detail sheet. Each check shows
/// its verdict; the rule behind it is one click away instead of always on
/// screen, so the section reads at a glance.
struct HealthSection: View {
    let health: IconHealth

    @State private var expanded: Set<String> = []

    private var passing: Int { health.checks.filter { $0.level == .ok }.count }
    private var evaluated: Int { health.checks.filter { $0.level != .unknown }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionTitle("Health")
                if evaluated > 0 {
                    Text("\(passing) of \(evaluated) passing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HealthPill(level: health.overall)
            }

            if health.checks.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(health.checks.enumerated()), id: \.element.id) { index, check in
                        if index > 0 { Divider().padding(.leading, 42) }
                        row(check)
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
            }
        }
    }

    private func row(_ check: HealthCheck) -> some View {
        let isExpanded = expanded.contains(check.id)
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                if isExpanded { expanded.remove(check.id) } else { expanded.insert(check.id) }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: check.level.checkGlyph)
                    .foregroundStyle(check.level.color)
                    .frame(width: 20)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(check.title).font(.callout.weight(.semibold))
                    Text(check.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if isExpanded {
                        Label(check.criterion, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .padding(.top, 3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "Hide how this is checked" : "Show how this is checked")
        .accessibilityLabel("\(check.title): \(check.detail)")
        .accessibilityHint(isExpanded ? check.criterion : "Shows how this is checked")
    }
}
