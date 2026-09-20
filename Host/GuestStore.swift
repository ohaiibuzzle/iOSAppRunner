//
//  GuestStore.swift
//  BaseiOSAppHost
//
//  Host-side guest management: shared-container paths, the import-time
//  conversion pipeline (dylibify, unquarantine, RunnerFeatures provisioning,
//  scene-manifest injection, Catalyst build-version retarget), install into
//  the shared runtime container, deletion with full data cleanup, and
//  per-app RunnerFeatures.plist editing.
//
//  The two runtime apps share one bundle ID, so their sandbox container
//  (~/Library/Containers/<runtimeBundleID>/Data) is the single home both
//  runtimes see as NSHomeDirectory(). Guests live in Data/apps, per-guest
//  data in Data/<guestBundleID>.
//

import Foundation

// MARK: - Bridges to the conversion pipeline (Dylibifier.m / MachOPatcher.m)

@_silgen_name("dylibify")
func c_dylibify(_ macho: UnsafePointer<CChar>,
                _ saveto: UnsafePointer<CChar>) -> Int32

@_silgen_name("macho_set_maccatalyst_build_version")
func c_setMacCatalystBuildVersion(_ path: UnsafePointer<CChar>,
                                  _ minosX: UInt32, _ minosY: UInt32,
                                  _ sdkX: UInt32, _ sdkY: UInt32) -> Int32

@_silgen_name("strip_xattrs_recursive")
func c_stripXattrsRecursive(_ path: UnsafePointer<CChar>) -> Int32

@_silgen_name("macho_is_loadable_image")
func c_machoIsLoadableImage(_ path: UnsafePointer<CChar>) -> Int32

@_silgen_name("macho_add_rpath")
func c_machoAddRpath(_ path: UnsafePointer<CChar>,
                     _ rpath: UnsafePointer<CChar>) -> Int32

// MARK: - Runtime modes

/// Per-app runtime selection, stored as the `runtime` key in the guest's
/// RunnerFeatures.plist. `auto` prefers Catalyst, falling back to iOS.
enum RuntimeMode: String {
    case catalyst
    case ios
    case auto

    static let defaultMode: RuntimeMode = .catalyst
}

// MARK: - Paths

enum GuestPaths {
    /// Bundle ID shared by both runtime apps. Read from the host's Info.plist
    /// (`RuntimeBundleIdentifier`, expanded at build time); falls back to
    /// stripping the `.Host` suffix from the host's own bundle ID.
    static var runtimeBundleID: String {
        if let configured = Bundle.main.object(forInfoDictionaryKey: "RuntimeBundleIdentifier") as? String,
           !configured.isEmpty, !configured.hasPrefix("$(") {
            return configured
        }
        let hostID = Bundle.main.bundleIdentifier ?? ""
        if hostID.hasSuffix(".Host") {
            return String(hostID.dropLast(".Host".count))
        }
        return hostID
    }

    /// The shared sandbox container the runtimes see as their home.
    static var containerDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(runtimeBundleID, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
    }

    static var appsDirectory: URL {
        containerDirectory.appendingPathComponent("apps", isDirectory: true)
    }

    /// Per-guest data directory (Documents/Library/Caches/…).
    static func guestHome(_ bundleID: String) -> URL {
        containerDirectory.appendingPathComponent(bundleID, isDirectory: true)
    }

    static var displayResolutionFile: URL {
        containerDirectory.appendingPathComponent("display_resolution.plist")
    }

    /// Legacy request files from the old queue-based launcher; cleaned up so
    /// stale requests can't launch a guest under the new headless runtimes.
    static var appToLaunchFile: URL {
        containerDirectory.appendingPathComponent("app_to_launch.txt")
    }

    static var pendingLaunchDirectory: URL {
        containerDirectory.appendingPathComponent("pending_launch", isDirectory: true)
    }

    static func ensureAppsDirectory() {
        try? FileManager.default.createDirectory(at: appsDirectory,
                                                 withIntermediateDirectories: true)
    }
}

// MARK: - Import / conversion errors

enum ImportError: LocalizedError {
    case missingPayload
    case missingAppBundle
    case missingExecutableName
    case dylibifyFailed(Int32)
    case replaceExecutableFailed(Error)

    var errorDescription: String? {
        switch self {
        case .missingPayload: return String(localized: "IPA is missing the Payload directory.")
        case .missingAppBundle: return String(localized: "IPA does not contain a .app bundle.")
        case .missingExecutableName:
            return String(localized: "Could not determine CFBundleExecutable from the bundle's Info.plist.")
        case .dylibifyFailed(let code):
            return String(localized: "dylibify failed (rc=\(code)).")
        case .replaceExecutableFailed(let err):
            return String(localized: "Failed to swap the dylibified executable in: \(err.localizedDescription)")
        }
    }
}

// MARK: - Conversion + install

enum GuestStore {

    /// Full import pipeline, run on the extracted-but-uninstalled bundle
    /// inside scratch space (the plan: conversion happens *before* the guest
    /// is moved into the shared container):
    ///
    ///   1. dylibify the main executable
    ///   2. strip extended attributes recursively (unquarantine)
    ///   3. write / merge the per-app feature manifest (RunnerFeatures.plist)
    ///   4. inject a scene manifest for legacy apps (Catalyst needs the scene
    ///      lifecycle; honoured per the `scene` feature flag)
    ///   5. retarget every loadable Mach-O image to Mac Catalyst
    ///      (11.0 / 14.0) and add the iOS-support Swift rpath
    ///
    /// The retarget pass is applied **unconditionally**, regardless of the
    /// app's runtime mode: Mac Catalyst bundles only load Catalyst-platform
    /// dylibs, but iOS has no problem loading Catalyst images, so one pass
    /// covers both runtimes and switching modes never re-converts.
    ///
    /// The ad-hoc codesign step from the old convert.sh is intentionally
    /// omitted: the runtimes install hooked_mmap/hooked___fcntl (LCDyld.m),
    /// which let dyld load unsigned binaries via anonymous RWX mappings
    /// (permitted by `RUNTIME_EXCEPTION_ALLOW_UNSIGNED_EXECUTABLE_MEMORY`).
    static func convert(bundleURL: URL, importFeatures: [String: Bool]) throws {
        let fm = FileManager.default

        // 1. Find the main executable via Info.plist.
        let plistURL = bundleURL.appendingPathComponent("Info.plist")
        var execName: String?
        if let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data,
                                                                   options: [],
                                                                   format: nil) as? [String: Any] {
            execName = plist["CFBundleExecutable"] as? String
        }
        guard let exec = execName, !exec.isEmpty else {
            throw ImportError.missingExecutableName
        }
        let execURL = bundleURL.appendingPathComponent(exec)

        // 2. dylibify into a sibling temp path, then atomically swap.
        let tmpURL = bundleURL.appendingPathComponent(exec + ".dylibified")
        try? fm.removeItem(at: tmpURL)
        let rc = execURL.path.withCString { src in
            tmpURL.path.withCString { dst in
                c_dylibify(src, dst)
            }
        }
        guard rc == 0 else { throw ImportError.dylibifyFailed(rc) }

        do {
            let originalMode = (try? fm.attributesOfItem(atPath: execURL.path))?[.posixPermissions]
            try fm.removeItem(at: execURL)
            try fm.moveItem(at: tmpURL, to: execURL)
            let mode = (originalMode as? NSNumber) ?? NSNumber(value: 0o755)
            try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: execURL.path)
        } catch {
            throw ImportError.replaceExecutableFailed(error)
        }

        // 3. Unquarantine: recursively strip com.apple.quarantine (and every
        //    other xattr, mirroring `xattr -cr`) from the payload.
        _ = c_stripXattrsRecursive(bundleURL.path)

        // 4. Write the per-app feature manifest. `importFeatures` holds the
        //    convert-time decisions chosen in the Import sheet (e.g. `scene`,
        //    default OFF); the runtime hooks default ON and stay toggleable.
        GuestConversion.writeRunnerFeatures(bundleURL: bundleURL, importFeatures: importFeatures)

        // 5. Catalyst requires the UIKit scene lifecycle. Old iOS guests call
        //    UIApplicationMain with the main bundle redirected to theirs, so
        //    their Info.plist must carry a scene manifest or UIApplicationMain
        //    aborts. Scene-native guests that already ship a manifest keep
        //    their own delegate.
        GuestConversion.injectSceneManifest(bundleURL: bundleURL)

        // 6. Build-version retargeting + Swift rpath for every loadable image.
        //    One Catalyst pass serves both runtimes (iOS loads Catalyst images
        //    fine; the iOS runtime itself is the iOS-platform binary).
        GuestConversion.retargetAllMachOImages(bundleURL: bundleURL)
    }

    /// Installs an IPA: extract, convert in scratch, then move the finished
    /// bundle into the shared container's apps directory. Returns the
    /// installed bundle name (e.g. "com.foo.Bar.app").
    static func install(from ipa: URL, importFeatures: [String: Bool]) throws -> String {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

        defer { try? fm.removeItem(at: scratch) }

        GuestPaths.ensureAppsDirectory()
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)

        try ZipExtractor.extract(zipURL: ipa, to: scratch)

        let payload = scratch.appendingPathComponent("Payload", isDirectory: true)
        guard fm.fileExists(atPath: payload.path) else {
            throw ImportError.missingPayload
        }
        let payloadContents = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
        guard let bundle = payloadContents.first(where: { $0.pathExtension.lowercased() == "app" }) else {
            throw ImportError.missingAppBundle
        }

        // Install under the guest's bundle ID (e.g. com.foo.Bar.app) so two
        // IPAs whose .app folders share a name can't collide on disk. Fall
        // back to the original folder name if the ID is missing/unusable.
        let bundleID = readInfoPlist(at: bundle)?["CFBundleIdentifier"] as? String
        let installName = sanitizedInstallName(bundleID) ?? bundle.lastPathComponent
        let destination = GuestPaths.appsDirectory.appendingPathComponent(installName)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }

        // Convert *before* the bundle enters the container.
        try convert(bundleURL: bundle, importFeatures: importFeatures)

        try fm.moveItem(at: bundle, to: destination)
        return installName
    }

    /// Restricts an install folder name to characters safe for a plain
    /// `apps/<name>` lookup in main.m (which does no escaping).
    static func sanitizedInstallName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let cleaned = raw.unicodeScalars.filter { allowed.contains($0) }
        let name = String(String.UnicodeScalarView(cleaned))
        return name.isEmpty ? nil : "\(name).app"
    }

    /// Full guest cleanup: wipes + reclaims the guest's keychain slot, removes
    /// the guest's data directory, and clears any legacy queued-launch
    /// artifacts so nothing can resurrect the app under the headless runtimes.
    /// Returns a user-presentable summary.
    static func deleteWithCleanup(bundleID: String?, appURL: URL) -> String {
        var summary: String?

        if let bid = bundleID, !bid.isEmpty {
            summary = KeychainManager.releaseSlot(bundleID: bid)

            let guestHome = GuestPaths.guestHome(bid).path
            if FileManager.default.fileExists(atPath: guestHome) {
                do {
                    try FileManager.default.removeItem(atPath: guestHome)
                    summary = summary.map { String(localized: "\($0) Data removed.") } ?? String(localized: "Data removed.")
                } catch {
                    return String(localized: "App deleted, but failed to remove guest data: \(error.localizedDescription)")
                }
            }

            // Legacy queue files from the old launcher.
            try? FileManager.default.removeItem(at: GuestPaths.appToLaunchFile)
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: GuestPaths.pendingLaunchDirectory.path) {
                for entry in entries where entry.hasSuffix(".txt") {
                    let url = GuestPaths.pendingLaunchDirectory.appendingPathComponent(entry)
                    if let name = try? String(contentsOf: url, encoding: .utf8),
                       name.trimmingCharacters(in: .whitespacesAndNewlines) == bid + ".app" {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
        }

        do {
            try FileManager.default.removeItem(at: appURL)
        } catch {
            return String(localized: "Delete failed: \(error.localizedDescription)")
        }
        return summary ?? String(localized: "Deleted app")
    }

    // MARK: - RunnerFeatures.plist

    /// Reads a guest's RunnerFeatures.plist, or nil when absent.
    static func readRunnerFeatures(for appURL: URL) -> [String: Any]? {
        let url = appURL.appendingPathComponent("RunnerFeatures.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data,
                                                                      options: [],
                                                                      format: nil) as? [String: Any] else {
            return nil
        }
        return plist
    }

    /// Writes (merges) keys into a guest's RunnerFeatures.plist.
    static func writeRunnerFeatures(_ update: [String: Any], for appURL: URL) {
        var plist = readRunnerFeatures(for: appURL) ?? [:]
        for (key, value) in update {
            plist[key] = value
        }
        if let out = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                         format: .xml,
                                                         options: 0) {
            try? out.write(to: appURL.appendingPathComponent("RunnerFeatures.plist"))
        }
    }

    /// Features that guests require to function at all; never user-disableable.
    /// Forced back to `true` whenever a manifest says otherwise (e.g. toggled
    /// off before these became mandatory).
    static let requiredFeatures: [String: Bool] = [
        "keychain": true,
        "groupContainer": true
    ]

    /// Rewrites a guest's RunnerFeatures.plist so every required feature is
    /// enabled. No-op when the manifest already complies.
    static func enforceRequiredFeatures(for appURL: URL) {
        guard let plist = readRunnerFeatures(for: appURL) else { return }
        var changed = false
        var repaired = plist
        for (key, value) in requiredFeatures where (plist[key] as? Bool) != value {
            repaired[key] = value
            changed = true
        }
        guard changed else { return }
        if let out = try? PropertyListSerialization.data(fromPropertyList: repaired,
                                                         format: .xml,
                                                         options: 0) {
            try? out.write(to: appURL.appendingPathComponent("RunnerFeatures.plist"))
            NSLog("[host] re-enabled required features for %@", appURL.lastPathComponent as NSString)
        }
    }

    /// Runtime mode for a guest; missing key = Catalyst (legacy behavior).
    static func runtimeMode(for appURL: URL) -> RuntimeMode {
        guard let plist = readRunnerFeatures(for: appURL),
              let raw = plist["runtime"] as? String,
              let mode = RuntimeMode(rawValue: raw) else {
            return .defaultMode
        }
        return mode
    }

    /// Reads a real sysctl string in the *host* process (the guest hooks
    /// never run here, so this always returns the true hardware value). Used
    /// to show the unspoofed identity as the hint in the compatibility text
    /// fields.
    static func realSysctlValue(_ name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }

    static func readInfoPlist(at appURL: URL) -> [String: Any]? {
        let plistURL = appURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data,
                                                                      options: [],
                                                                      format: nil) as? [String: Any] else {
            return nil
        }
        return plist
    }

}
