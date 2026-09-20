//
//  ImportSheet.swift
//  BaseiOSAppHost
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Import sheet

/// Import confirmation / options sheet, shown after picking one or more IPAs.
/// Convert-time toggles are only offered for single imports — for a batch
/// they're troubleshooting knobs, and the batch runs with the defaults.
struct ImportOptionsView: View {
    let urls: [URL]
    @EnvironmentObject private var model: HostModel
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: [String: Bool] = [:]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(urls.count == 1 ? String(localized: "Selected app") : String(localized: "Selected apps (\(urls.count))")) {
                    ForEach(urls, id: \.self) { url in
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if urls.count == 1 {
                    Section {
                        ForEach(HostFeature.importOnly) { feature in
                            Toggle(isOn: Binding(
                                get: { enabled[feature.id] ?? (HostFeature.defaultValues[feature.id] ?? false) },
                                set: { enabled[feature.id] = $0 }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(feature.name)
                                    Text(feature.detail)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 420, minHeight: 240)

            HStack {
                Button("Cancel") {
                    model.pendingImportURLs = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Import") {
                    let urls = self.urls
                    let features = enabled
                    Task {
                        await model.importIPAs(urls, importFeatures: features)
                    }
                    model.pendingImportURLs = nil
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isWorking)
            }
            .padding()
        }
    }
}
