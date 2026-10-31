//
//  CompatSheet.swift
//  BaseiOSAppHost
//

import SwiftUI

// MARK: - Compatibility sheet

/// Per-app settings sheet: runtime-mode + JIT selection and the runtime
/// hook toggles. Edits the guest's `RunnerFeatures.plist`; the runtime's
/// Loader consults it at launch to decide which host hooks run for this
/// specific guest.
struct CompatSettingsView: View {
    let app: InstalledApp
    @EnvironmentObject private var model: HostModel
    @Environment(\.dismiss) private var dismiss
    @State private var spoofResetToken = 0

    /// Names the app being edited; closing the sheet migrates its data.
    private var header: some View {
        HStack(spacing: 12) {
            Group {
                if let icon = model.icons[app.id] {
                    Image(nsImage: icon)
                        .resizable().scaledToFill()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.gray.opacity(0.25))
                        Image(systemName: "app.fill")
                            .foregroundStyle(.gray)
                    }
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName)
                    .font(.headline)
                if let bid = app.bundleIdentifier {
                    Text(bid)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                header
                Section {
                    Picker("Runtime", selection: Binding(
                        get: { model.runtimeMode(for: app) },
                        set: { model.setRuntimeMode($0, for: app) }
                    )) {
                        Text("Catalyst").tag(RuntimeMode.catalyst)
                        Text("iOS (Designed for iPad)").tag(RuntimeMode.ios)
                    }
                    .pickerStyle(.radioGroup)
                } header: {
                    Text("Runtime")
                } footer: {
                    Text("Closing this sheet moves the app and its data into the selected runtime's container.")
                }

                Section {
                    ForEach(HostFeature.all) { featureToggle($0) }
                } header: {
                    Text("Compatibility")
                } footer: {
                    Text("Runtime hooks can be used to mitigate issues with the guest app.")
                }

                if model.featureEnabled("deviceSpoof", for: app) {
                    DeviceSpoofFields(app: app, resetToken: spoofResetToken)
                        .environmentObject(model)
                }

                Section {
                    ForEach(HostFeature.importOnly) { featureToggle($0) }
                } header: {
                    Text("Import")
                } footer: {
                    Text("Applies when you re-import this app's IPA.")
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 480, minHeight: 480)

            HStack {
                Button("Restore Defaults") {
                    for feature in HostFeature.all {
                        model.setFeature(feature.id, enabled: HostFeature.defaultValues[feature.id] ?? true, for: app)
                    }
                    for key in [DeviceSpoofConfig.machineKey,
                                DeviceSpoofConfig.modelKey,
                                DeviceSpoofConfig.osVersionKey] {
                        model.setSpoofOverride(key, value: "", for: app)
                    }
                    spoofResetToken += 1
                }
                .help("Resets the hooks and device identity; the runtime choice is kept.")
                Spacer()
                Button("Done") {
                    model.compatSheetApp = nil
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }

    private func featureToggle(_ feature: HostFeature) -> some View {
        Toggle(isOn: Binding(
            get: { model.featureEnabled(feature.id, for: app) },
            set: { model.setFeature(feature.id, enabled: $0, for: app) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.name)
                Text(feature.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Customizable device identity shown when the "Spoof device (sysctl)" hook
/// is enabled. Values are written to the guest's RunnerFeatures.plist and
/// read by DeviceSpoof.m at launch; empty fields use the built-in iPad
/// defaults.
struct DeviceSpoofFields: View {
    let app: InstalledApp
    /// Bumped by Restore Defaults so the fields re-read their values.
    let resetToken: Int
    @EnvironmentObject private var model: HostModel

    /// Real (unspoofed) host identity, for the field hints.
    private let realMachine = GuestStore.realSysctlValue("hw.machine") ?? "unknown"
    private let realModel = GuestStore.realSysctlValue("hw.model") ?? "unknown"
    private let realOSVersion = GuestStore.realSysctlValue("kern.osproductversion") ?? "unknown"

    var body: some View {
        Section {
            // Placeholders show what an empty field means; captions show
            // the real Mac's value for reference.
            spoofField("Machine (hw.machine)",
                       key: DeviceSpoofConfig.machineKey,
                       placeholder: DeviceSpoofConfig.defaultMachine,
                       hint: String(localized: "This Mac: \(realMachine)"))
            spoofField("Model (hw.model)",
                       key: DeviceSpoofConfig.modelKey,
                       placeholder: String(localized: "Same as machine"),
                       hint: String(localized: "This Mac: \(realModel)"))
            spoofField("iOS version (kern.osproductversion)",
                       key: DeviceSpoofConfig.osVersionKey,
                       placeholder: realOSVersion,
                       hint: String(localized: "Empty reports this Mac's version"))
        } header: {
            Text("Device identity")
        } footer: {
            Text("Values returned by sysctl/sysctlbyname. Leave a field empty to use the value shown in it.")
        }
    }

    private func spoofField(_ title: String, key: String, placeholder: String, hint: String) -> some View {
        SpoofField(app: app, resetToken: resetToken, title: title, key: key, placeholder: placeholder, hint: hint)
    }
}

/// Text field with a local draft: the model trims before writing, so the
/// field never reads the trimmed value back while the user types.
private struct SpoofField: View {
    let app: InstalledApp
    let resetToken: Int
    let title: String
    let key: String
    let placeholder: String
    let hint: String
    @EnvironmentObject private var model: HostModel
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                // Written on every change, not on disappear: closing the
                // sheet may already be migrating the bundle by then.
                .onChange(of: text) { _, newValue in
                    model.setSpoofOverride(key, value: newValue, for: app)
                }
                .onAppear { text = model.spoofOverride(key, for: app) }
                .onChange(of: resetToken) { _, _ in text = model.spoofOverride(key, for: app) }
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
