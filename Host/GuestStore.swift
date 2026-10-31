//
//  GuestStore.swift
//  BaseiOSAppHost
//
//  Host-side guest management: container paths, the import/conversion
//  pipeline, install, cross-container migration, deletion, and the per-app
//  RunnerFeatures.plist. The two runtime flavors have separate bundle IDs
//  and therefore separate sandbox containers; a guest lives in exactly one
//  (Data/apps holds its bundle, Data/<guestBundleID> its data).
//

import Darwin
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

/// Per-app runtime selection (the `runtime` key in RunnerFeatures.plist).
enum RuntimeMode: String {
    case catalyst
    case ios

    static let defaultMode: RuntimeMode = .catalyst
}

// MARK: - Import / conversion errors

enum ImportError: LocalizedError {
    case missingPayload
    case missingAppBundle
    case missingExecutableName
    case dylibifyFailed(Int32)
    case replaceExecutableFailed(Error)
    case invalidBundleID(String)
    case conversionFailed([String])

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
        case .invalidBundleID(let id):
            return String(localized: "The app's bundle identifier \"\(id)\" is not a valid folder name.")
        case .conversionFailed(let paths):
            return String(localized: "Could not retarget \(paths.joined(separator: ", ")).")
        }
    }
}

// MARK: - Conversion + install

enum GuestStore {

    /// Import-time conversion, run on the extracted bundle in scratch space
    /// before it enters its container:
    ///   1. dylibify the main executable
    ///   2. recursively strip extended attributes (unquarantine)
    ///   3. write / merge RunnerFeatures.plist
    ///   4. inject a scene manifest for legacy apps (per the `scene` flag)
    ///   5. retarget every loadable Mach-O to Mac Catalyst + Swift rpath
    ///
    /// The retarget runs unconditionally: Catalyst only loads Catalyst
    /// images, iOS loads those fine, so one pass serves both flavors. No
    /// codesign step: the runtimes' LCDyld hooks let dyld load unsigned
    /// binaries.
    static func convert(bundleURL: URL) throws {
        let fm = FileManager.default

        // 1. Find the main executable via Info.plist.
        let execName = readInfoPlist(at: bundleURL)?["CFBundleExecutable"] as? String
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

        // 3. Unquarantine (strip all xattrs recursively).
        _ = c_stripXattrsRecursive(bundleURL.path)

        // 4. Fill RunnerFeatures.plist defaults (a re-import keeps its settings).
        var defaults: [String: Any] = HostFeature.defaultValues
        defaults["runtime"] = RuntimeMode.defaultMode.rawValue
        writeRunnerFeatures([:], defaults: defaults, for: bundleURL)

        // 5. Legacy guests need a scene manifest or UIApplicationMain aborts
        //    under Catalyst; scene-native guests keep their own delegate.
        GuestConversion.injectSceneManifest(bundleURL: bundleURL)

        // 6. Retarget every loadable image to Catalyst + add the Swift rpath.
        let failed = GuestConversion.retargetAllMachOImages(bundleURL: bundleURL)
        guard failed.isEmpty else { throw ImportError.conversionFailed(failed) }
    }

    /// Installs an IPA: extract, convert in scratch, move into the container
    /// matching the app's runtime mode (fresh installs default to Catalyst;
    /// re-installs keep the existing residence — a cross-container install
    /// would strand the guest in two containers and trip the launcher's
    /// fail-closed residence check). Returns the installed bundle name.
    static func install(from ipa: URL) throws -> String {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

        defer { try? fm.removeItem(at: scratch) }

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
        // The data folder is named by the raw ID; refuse anything that could escape it.
        if let bundleID, bundleID.isEmpty || bundleID.contains("/") || bundleID == "." || bundleID == ".." {
            throw ImportError.invalidBundleID(bundleID)
        }
        let installName = sanitizedInstallName(bundleID) ?? bundle.lastPathComponent

        // Residence: existing install's container; Catalyst for fresh installs.
        let previous = locateInstalledGuest(installName: installName)
        let target: RuntimeFlavor = previous.map {
            runtimeMode(for: $0.url) == .ios ? RuntimeFlavor.ios : .catalyst
        } ?? .catalyst

        // Carry the previous manifest over so settings survive the reinstall.
        if let previous,
           let data = try? Data(contentsOf: previous.url.appendingPathComponent("RunnerFeatures.plist")) {
            try? data.write(to: bundle.appendingPathComponent("RunnerFeatures.plist"))
        }

        // Convert *before* anything is removed: a failed import must not
        // destroy the existing install.
        try convert(bundleURL: bundle)

        // Prime the iOS UUID container first or the bundle lands in the
        // stale bundle-ID-named one.
        if target == .ios {
            guard RuntimeLauncher.ensureIOSRuntimeContainer() else {
                throw MigrationError.containerSetupFailed
            }
        }
        GuestPaths.ensureAppsDirectory(for: target)

        // Replace: drop every copy of this bundle (a guest lives in exactly
        // one container; a second copy is residue). Refuse while running.
        let homeName = bundleID ?? installName.replacingOccurrences(of: ".app", with: "")
        for flavor in [RuntimeFlavor.catalyst, .ios] {
            let copyURL = GuestPaths.appsDirectory(for: flavor).appendingPathComponent(installName)
            guard fm.fileExists(atPath: copyURL.path) else { continue }
            let home = GuestPaths.guestHome(homeName, in: flavor)
            if fm.fileExists(atPath: home.path), GuestPaths.guestIsRunning(guestHome: home) {
                throw MigrationError.guestRunning(homeName)
            }
            try fm.removeItem(at: copyURL)
        }
        // And any copy in the pre-discovery (bundle-ID-named) iOS container.
        if let stale = GuestPaths.staleIdentityContainerDirectory(for: .ios) {
            try? fm.removeItem(at: stale.appendingPathComponent("apps").appendingPathComponent(installName))
        }

        let destination = GuestPaths.appsDirectory(for: target).appendingPathComponent(installName)
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

    /// Full guest cleanup: wipe + reclaim the keychain slot, remove guest
    /// data from every container. Refuses while the guest runs.
    static func deleteWithCleanup(bundleID: String?, appURL: URL) throws {
        if let bid = bundleID, !bid.isEmpty {
            for flavor in [RuntimeFlavor.catalyst, .ios] {
                let home = GuestPaths.guestHome(bid, in: flavor)
                if FileManager.default.fileExists(atPath: home.path),
                   GuestPaths.guestIsRunning(guestHome: home) {
                    throw MigrationError.deleteWhileRunning(bid)
                }
            }
            KeychainManager.releaseSlot(bundleID: bid)

            for flavor in [RuntimeFlavor.catalyst, .ios] {
                let guestHome = GuestPaths.guestHome(bid, in: flavor).path
                if FileManager.default.fileExists(atPath: guestHome) {
                    try FileManager.default.removeItem(atPath: guestHome)
                }
            }
        }

        try FileManager.default.removeItem(at: appURL)
    }

    // MARK: - RunnerFeatures.plist

    static func readPlist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    static func writePlist(_ plist: [String: Any], to url: URL,
                           format: PropertyListSerialization.PropertyListFormat = .xml,
                           options: Data.WritingOptions = []) {
        if let out = try? PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0) {
            try? out.write(to: url, options: options)
        }
    }

    /// Reads a guest's RunnerFeatures.plist, or nil when absent.
    static func readRunnerFeatures(for appURL: URL) -> [String: Any]? {
        readPlist(at: appURL.appendingPathComponent("RunnerFeatures.plist"))
    }

    /// Merges into a guest's RunnerFeatures.plist: `defaults` fill missing
    /// keys only, `update` overrides, `remove` drops keys.
    static func writeRunnerFeatures(_ update: [String: Any], remove: [String] = [],
                                    defaults: [String: Any] = [:], for appURL: URL) {
        var plist = readRunnerFeatures(for: appURL) ?? [:]
        for (key, value) in defaults where plist[key] == nil { plist[key] = value }
        for (key, value) in update { plist[key] = value }
        for key in remove { plist.removeValue(forKey: key) }
        writePlist(plist, to: appURL.appendingPathComponent("RunnerFeatures.plist"))
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

    /// Locates a guest's bundle (flavor + URL). Launch reads the configured
    /// mode from this copy, never a UI-cached URL.
    static func locateInstalledGuest(installName: String) -> (flavor: RuntimeFlavor, url: URL)? {
        let fm = FileManager.default
        for flavor in [RuntimeFlavor.catalyst, .ios] {
            let url = GuestPaths.appsDirectory(for: flavor).appendingPathComponent(installName)
            if fm.fileExists(atPath: url.path) { return (flavor, url) }
        }
        // Guests stranded in the pre-discovery bundle-ID-named iOS container
        // still count as iOS residence.
        if let stale = GuestPaths.staleIdentityContainerDirectory(for: .ios) {
            let url = stale.appendingPathComponent("apps").appendingPathComponent(installName)
            if fm.fileExists(atPath: url.path) { return (.ios, url) }
        }
        return nil
    }

    /// Real (unspoofed) sysctl string, for the Compat-sheet field hints.
    static func realSysctlValue(_ name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }

    static func readInfoPlist(at appURL: URL) -> [String: Any]? {
        readPlist(at: appURL.appendingPathComponent("Info.plist"))
    }
}
