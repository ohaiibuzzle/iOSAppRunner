//
//  AppRow.swift
//  BaseiOSAppHost
//

import AppKit
import SwiftUI

// MARK: - Row

struct AppRow: View {
    let app: InstalledApp
    @ObservedObject var model: HostModel

    var body: some View {
        HStack(spacing: 12) {
            iconView
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.headline)
                if let bid = app.bundleIdentifier {
                    Text(bid)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            runtimeBadge
            if let version = app.version {
                Text(version)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var runtimeBadge: some View {
        let mode = model.runtimeModes[app.id] ?? .catalyst
        return Text(mode == .ios ? String(localized: "iOS") : mode == .auto ? String(localized: "Auto") : String(localized: "Catalyst"))
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.2)))
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = model.icons[app.id] {
            Image(nsImage: icon)
                .resizable().scaledToFill()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.gray.opacity(0.25))
                Image(systemName: "app.fill")
                    .foregroundColor(.gray)
            }
        }
    }
}
