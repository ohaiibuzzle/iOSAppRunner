//
//  FeatureConfig.swift
//  BaseiOSAppHost
//

import SwiftUI

// MARK: - Feature configuration (shared with the runtime's Loader)

/// The per-app hooks. `all` are **runtime-toggleable** — edited after import
/// from the Compatibility sheet, and read at launch by the runtime's Loader.
struct HostFeature: Identifiable {
    let id: String
    let name: String
    let detail: String

    /// Runtime-toggleable hooks shown in the Compatibility Settings sheet.
    /// Keys must match the `LoaderFeature*` constants in Runtime/Loader.h.
    static let all: [HostFeature] = [
        HostFeature(id: "resolution", name: String(localized: "Spoof display resolution"),
                    detail: String(localized:
                        "Fake UIScreen to match the Mac's display and lock the window size (unless the app supports resizing).")),
        HostFeature(id: "deviceSpoof", name: String(localized: "Spoof device (sysctl)"),
                    detail: String(localized: "Report an iPad to apps that check hw.machine / hw.model via sysctl."))
    ]

    /// Import-time-only toggles, shown in the Import sheet. Add any future
    /// convert-time features here.
    static let importOnly: [HostFeature] = [
        HostFeature(id: "scene", name: String(localized: "UIScene compatibility fix"),
                    detail: String(localized: "Inject a scene manifest for legacy apps that uses the legacy UIScene lifecycle."))
    ]

    /// Default enabled-state per feature. `scene` (import-time) is default-OFF;
    /// runtime hooks default ON. Keep in sync with GuestStore's conversion
    /// defaults and Runtime/Loader.h.
    static let defaultValues: [String: Bool] = [
        "scene": false,
        "groupContainer": true,
        "resolution": true,
        "keychain": true,
        "deviceSpoof": true
    ]
}

/// Device-spoofing configuration shared between the host UI and the runtime
/// hooks. Keys are written into the guest's RunnerFeatures.plist; keep in
/// sync with the `LoaderSpoofKey*` constants in Runtime/Loader.h.
enum DeviceSpoofConfig {
    static let machineKey = "spoofDeviceMachine"   // hw.machine
    static let modelKey = "spoofDeviceModel"       // hw.model
    static let osVersionKey = "spoofDeviceOSVersion" // kern.osproductversion

    /// Built-in fallbacks used by the hooks when an override is empty.
    static let defaultMachine = "iPad14,6"
    static let defaultModel = "iPad14,6"
}
