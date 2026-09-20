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

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Runtime", selection: Binding(
                        get: { model.runtimeMode(for: app) },
                        set: { model.setRuntimeMode($0, for: app) }
                    )) {
                        Text("Catalyst").tag(RuntimeMode.catalyst)
                        Text("iOS (Designed for iPad)").tag(RuntimeMode.ios)
                        Text("Auto").tag(RuntimeMode.auto)
                    }
                    .pickerStyle(.radioGroup)
                } header: {
                    Text("Runtime")
                } footer: {
                    Text("Data are shared between the runtimes.")
                }

                Section {
                    ForEach(HostFeature.all) { feature in
                        Toggle(isOn: Binding(
                            get: { model.featureEnabled(feature.id, for: app) },
                            set: { model.setFeature(feature.id, enabled: $0, for: app) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.name)
                                Text(feature.detail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Compatibility")
                } footer: {
                    Text("Runtime hooks can be used to mitigate issues with the guest app.")
                }

                if model.featureEnabled("deviceSpoof", for: app) {
                    DeviceSpoofFields(app: app)
                        .environmentObject(model)
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 480, minHeight: 480)

            HStack {
                Button("Reset") {
                    for feature in HostFeature.all {
                        model.setFeature(feature.id, enabled: HostFeature.defaultValues[feature.id] ?? true, for: app)
                    }
                    for key in [DeviceSpoofConfig.machineKey,
                                DeviceSpoofConfig.modelKey,
                                DeviceSpoofConfig.osVersionKey] {
                        model.setSpoofOverride(key, value: "", for: app)
                    }
                }
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
}

/// Customizable device identity shown when the "Spoof device (sysctl)" hook
/// is enabled. Values are written to the guest's RunnerFeatures.plist and
/// read by DeviceSpoof.m at launch; empty fields use the built-in iPad
/// defaults.
struct DeviceSpoofFields: View {
    let app: InstalledApp
    @EnvironmentObject private var model: HostModel

    /// Real (unspoofed) host identity, for the field hints.
    private let realMachine = GuestStore.realSysctlValue("hw.machine") ?? "unknown"
    private let realModel = GuestStore.realSysctlValue("hw.model") ?? "unknown"
    private let realOSVersion = GuestStore.realSysctlValue("kern.osproductversion") ?? "unknown"

    var body: some View {
        Section {
            spoofField("Machine (hw.machine)",
                       key: DeviceSpoofConfig.machineKey,
                       hint: String(localized: "Real: \(realMachine)"))
            spoofField("Model (hw.model)",
                       key: DeviceSpoofConfig.modelKey,
                       hint: String(localized: "Real: \(realModel); empty = same as machine"))
            spoofField("iOS version (kern.osproductversion)",
                       key: DeviceSpoofConfig.osVersionKey,
                       hint: String(localized: "Real: \(realOSVersion)"))
        } header: {
            Text("Device identity")
        } footer: {
            Text("Values returned by sysctl/sysctlbyname. Defaults to real device's values")
        }
    }

    private func spoofField(_ title: String, key: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextField(hint, text: Binding(
                get: { model.spoofOverride(key, for: app) },
                set: { model.setSpoofOverride(key, value: $0, for: app) }
            ))
            .textFieldStyle(.roundedBorder)
            Text(hint)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
