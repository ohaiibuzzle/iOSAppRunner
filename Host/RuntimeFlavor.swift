//
//  RuntimeFlavor.swift
//  BaseiOSAppHost
//

import Foundation

enum RuntimeFlavor {
    case catalyst
    case ios

    var bundleName: String {
        switch self {
        case .catalyst: return "Runtime-Catalyst.app"
        case .ios: return "Runtime-iOS.app"
        }
    }

    /// Host Info.plist key carrying this flavor's bundle ID. The two flavors
    /// have separate IDs so LaunchServices treats them as distinct apps and
    /// both can run at the same time (a shared ID made `open` on the second
    /// flavor just activate the already-running instance).
    var infoPlistBundleIDKey: String {
        switch self {
        case .catalyst: return "RuntimeCatalystBundleIdentifier"
        case .ios: return "RuntimeiOSBundleIdentifier"
        }
    }

    var displayName: String {
        self == .catalyst ? "Catalyst" : "iOS"
    }

    /// This flavor's bundle ID from the host's Info.plist (nil when the key
    /// is missing or still carries an unexpanded build setting).
    var bundleIdentifier: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: infoPlistBundleIDKey) as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }
}
