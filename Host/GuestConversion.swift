//
//  GuestConversion.swift
//  BaseiOSAppHost
//

import Foundation

/// Convert-time bundle surgery shared by the import pipeline. Split out
/// of GuestStore to keep each file focused: this covers the per-guest
/// manifests and the Mach-O retargeting done when a guest is installed.
enum GuestConversion {

    /// Rewrites the guest's Info.plist with a scene manifest so UIKit can
    /// connect a scene under Catalyst. Skipped when the `scene` feature is
    /// off; scene-native guests keep their own delegate.
    static func injectSceneManifest(bundleURL: URL) {
        if GuestStore.readRunnerFeatures(for: bundleURL)?["scene"] as? Bool == false {
            NSLog("[converter] scene disabled for %@ — leaving scene manifest untouched", bundleURL.lastPathComponent)
            return
        }

        let plistURL = bundleURL.appendingPathComponent("Info.plist")
        guard var plist = GuestStore.readPlist(at: plistURL) else { return }

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

        GuestStore.writePlist(plist, to: plistURL, format: .binary, options: [.atomic])
    }

    /// Retargets every Mach-O image in the bundle to Mac Catalyst and adds
    /// the iOS-support Swift rpath. Images are found by header inspection,
    /// not file extension. Returns the bundle-relative paths that failed.
    static func retargetAllMachOImages(bundleURL: URL) -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var failed: [String] = []
        let prefix = bundleURL.path + "/"
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                continue
            }
            let isImage = fileURL.path.withCString { c_machoIsLoadableImage($0) } != 0
            guard isImage else { continue }
            let retargeted = fileURL.path.withCString {
                c_setMacCatalystBuildVersion($0, 11, 0, 14, 0)
            } >= 0
            // Guest Swift frameworks reference the iOS Swift overlays under
            // /System/iOSSupport/usr/lib/swift via @rpaths their own rpaths
            // don't cover; add it as LC_RPATH so those references resolve.
            let rpathed = fileURL.path.withCString { p in
                "/System/iOSSupport/usr/lib/swift".withCString { c_machoAddRpath(p, $0) }
            } >= 0
            if !retargeted || !rpathed {
                failed.append(fileURL.path.hasPrefix(prefix) ? String(fileURL.path.dropFirst(prefix.count)) : fileURL.path)
            }
        }
        return failed
    }
}
