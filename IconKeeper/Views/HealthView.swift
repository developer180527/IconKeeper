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
        case .warning: "exclamationmark.heart.fill"
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

/// The transparent, per-criterion breakdown used in the app detail sheet.
struct HealthSection: View {
    let health: IconHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Health").font(.headline)
                Spacer()
                HealthPill(level: health.overall)
            }

            VStack(spacing: 12) {
                ForEach(health.checks) { check in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: check.level.checkGlyph)
                            .foregroundStyle(check.level.color)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(check.title).font(.callout.weight(.semibold))
                            Text(check.detail)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Label(check.criterion, systemImage: "info.circle")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .labelStyle(.titleAndIcon)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            Text("Overall health reflects the most severe check. Paused apps aren't evaluated.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
