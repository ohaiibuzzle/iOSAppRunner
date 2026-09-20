//
//  GuestConversion.swift
//  BaseiOSAppHost
//

import Foundation

/// Convert-time bundle surgery shared by the import pipeline. Split out
/// of GuestStore to keep each file focused: this covers the per-guest
/// manifests and the Mach-O retargeting done when a guest is installed.
enum GuestConversion {

    /// Writes a default `RunnerFeatures.plist` (every hook enabled, Catalyst
    /// runtime mode, JIT on) so a freshly-imported guest behaves like a
    /// legacy host install. The host UI edits it per-app; the runtime gates
    /// each hook init on it via Loader.
    ///
    /// An existing manifest is **preserved** (defaults fill in missing keys
    /// only), so a user's per-app toggles survive a re-import / re-convert.
    static func writeRunnerFeatures(bundleURL: URL, importFeatures: [String: Bool]) {
        let featuresURL = bundleURL.appendingPathComponent("RunnerFeatures.plist")
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: featuresURL),
           let existing = try? PropertyListSerialization.propertyList(from: data,
                                                                      options: [],
                                                                      format: nil) as? [String: Any] {
            dict = existing
        }
        // Import-time features come from the Import sheet; they are convert-time
        // decisions, not runtime toggles.
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

    /// Rewrites the guest's Info.plist so UIKit can connect a scene under
    /// Catalyst.
    ///
    /// Honours the per-app `scene` feature (RunnerFeatures.plist): when a
    /// guest has `scene` disabled, the Info.plist is left byte-for-byte
    /// untouched, so the guest runs with its own scene configuration or none
    /// at all.
    ///
    /// A legacy guest with no application-role scene config is pointed at the
    /// runtimes' `GuestSceneDelegate`; a scene-native guest keeps its own
    /// delegate.
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

    /// Recursively walks the whole app bundle and retargets every Mach-O image
    /// (frameworks, .dylibs, loadable bundles, and the dylibified main
    /// executable) to Mac Catalyst, then injects the iOS-support Swift rpath.
    ///
    /// Images are identified by inspecting their Mach-O header rather than by
    /// trusting the bundle layout or file extensions, so binaries dyld would
    /// otherwise reject are caught wherever they live — Frameworks/,
    /// PlugIns/*.appex, nested frameworks, loadable .bundles, and
    /// extension-less helpers alike.
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

    // Catalyst hosts all the iOS Swift runtime overlays in the dyld cache
    // under /System/iOSSupport/usr/lib/swift. Guest Swift frameworks link them
    // via @rpath/libswift*.dylib, but their own rpaths don't reach that
    // directory, so dyld can't bind them when we dlopen the guest. Add the
    // iOS-support Swift dir as an LC_RPATH so those references resolve.
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
