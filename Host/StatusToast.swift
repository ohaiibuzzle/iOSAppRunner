//
//  StatusToast.swift
//  BaseiOSAppHost
//

import SwiftUI

// MARK: - Status toast

/// Floating status notification: a material capsule pinned to the bottom of
/// the window, shown while work is in flight (spinner) and briefly after it
/// completes (checkmark). Hit-testing is disabled so it never intercepts
/// clicks meant for the list below.
struct StatusToast: View {
    @EnvironmentObject private var model: HostModel

    var body: some View {
        if model.isWorking || !model.status.isEmpty {
            HStack(spacing: 10) {
                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Text(model.status)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .textSelection(.disabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(.quaternary)
            }
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .padding(.bottom, 14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .allowsHitTesting(false)
        }
    }
}
