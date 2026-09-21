//
//  GuestConversion.swift
//  BaseiOSAppHost
//

import Foundation

/// Convert-time bundle surgery shared by the import pipeline. Split out
/// of GuestStore to keep each file focused: this covers the per-guest
/// manifests and the Mach-O retargeting done when a guest is installed.
enum GuestConversion {

    /// Writes RunnerFeatures.plist defaults for a fresh import; an existing
    /// manifest is preserved (defaults fill missing keys only) and
    /// import-time features are applied on top.
    static func writeRunnerFeatures(bundleURL: URL, importFeatures: [String: Bool]) {
        let featuresURL = bundleURL.appendingPathComponent("RunnerFeatures.plist")
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: featuresURL),
           let existing = try? PropertyListSerialization.propertyList(from: data,
                                                                      options: [],
                                                                      format: nil) as? [String: Any] {
            dict = existing
        }
        // Import-time features from the Import sheet; not runtime toggles.
        for (key, value) in importFeatures {
            dict[key] = value
        }
        for (key, value) in HostFeature.defaultValues where dict[key] == nil {
            dict[key] = value
        }
        // Runtime-mode default (see RuntimeMode); absence means Catalyst.
        if dict["runtime"] == nil { dict["runtime"] = RuntimeMode.defaultMode.rawValue }
        if let out = try? PropertyListSerialization.data(fromPropertyList: dict,
                                                         format: .xml,
                                                         options: 0) {
            try? out.write(to: featuresURL)
        }
    }

    /// Rewrites the guest's Info.plist with a scene manifest so UIKit can
    /// connect a scene under Catalyst. Skipped when the `scene` feature is
    /// off; scene-native guests keep their own delegate.
    static func injectSceneManifest(bundleURL: URL) {
        let featuresURL = bundleURL.appendingPathComponent("RunnerFeatures.plist")
        if let featureData = try? Data(contentsOf: featuresURL),
           let featurePlist = try? PropertyListSerialization.propertyList(from: featureData,
                                                                          options: [],
                                                                          format: nil) as? [String: Any],
           featurePlist["scene"] as? Bool == false {
            NSLog("[converter] scene disabled for %@ — leaving scene manifest untouched", bundleURL.lastPathComponent)
            return
        }

        let plistURL = bundleURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              var plist = (try? PropertyListSerialization.propertyList(from: data,
                                                                       options: [],
                                                                       format: nil)) as? [String: Any] else {
            return
        }

        var manifest = (plist["UIApplicationSceneManifest"] as? [String: Any]) ?? [:]
        var configs = (manifest["UISceneConfigurations"] as? [String: Any]) ?? [:]
        let roleConfigs = (configs["UIWindowSceneSessionRoleApplication"] as? [[String: Any]]) ?? []
        if roleConfigs.isEmpty {
            configs["UIWindowSceneSessionRoleApplication"] = [[
                "UISceneConfigurationName": "Default Configuration",
                "UISceneDelegateClassName": "GuestSceneDelegate"
            ]]
        }
        // else: scene-native guest already wires its own delegate — preserve it.
        manifest["UISceneConfigurations"] = configs
        manifest["UIApplicationSupportsMultipleScenes"] = false
        plist["UIApplicationSceneManifest"] = manifest

        if let out = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                         format: .binary,
                                                         options: 0) {
            try? out.write(to: plistURL, options: [.atomic])
        }
    }

    /// Retargets every Mach-O image in the bundle to Mac Catalyst and adds
    /// the iOS-support Swift rpath. Images are found by header inspection,
    /// not file extension.
    static func retargetAllMachOImages(bundleURL: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                continue
            }
            let isImage = fileURL.path.withCString { c_machoIsLoadableImage($0) } != 0
            guard isImage else { continue }
            let rc = fileURL.path.withCString {
                c_setMacCatalystBuildVersion($0, 11, 0, 14, 0)
            }
            if rc < 0 {
                NSLog("[converter] failed to set build version on %@", fileURL.path as NSString)
            }
            injectSwiftRpath(at: fileURL)
        }
    }

    // Guest Swift frameworks reference the iOS Swift overlays under
    // /System/iOSSupport/usr/lib/swift via @rpaths their own rpaths don't
    // cover; add it as LC_RPATH so those references resolve.
    private static func injectSwiftRpath(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let rpath = "/System/iOSSupport/usr/lib/swift"
        let rc = url.path.withCString { p in
            rpath.withCString { c_machoAddRpath(p, $0) }
        }
        if rc < 0 {
            NSLog("[converter] failed to add Swift rpath on %@", url.path as NSString)
        }

}
}
