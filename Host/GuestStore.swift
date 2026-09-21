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

// MARK: - Paths

enum GuestPaths {

    // MARK: Info.plist lookups

    /// A build-expanded Info.plist string, or nil when the key is missing or
    /// still carries an unexpanded $(...) build setting (non-Xcode builds).
    private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    /// Fallback for unexpanded/missing Info.plist keys: strip the ".Host"
    /// suffix from the host's own bundle ID.
    private static var hostDerivedBaseID: String {
        let hostID = Bundle.main.bundleIdentifier ?? ""
        if hostID.hasSuffix(".Host") {
            return String(hostID.dropLast(".Host".count))
        }
        return hostID
    }

    // MARK: Keychain access groups

    /// Stable base for the ".shared[.N]" keychain access groups. Deliberately
    /// independent of the runtime bundle IDs: keychain items are keyed by
    /// access group, so the flavor split didn't orphan any guest keychain
    /// data. Must match the runtimes' KeychainAccessGroupBase.
    static var keychainAccessGroupBase: String {
        infoString("KeychainAccessGroupBase") ?? hostDerivedBaseID
    }

    // MARK: Containers

    /// Host-owned metadata directory: keychain slot registry + iOS container cache.
    static var hostSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BaseiOSApp", isDirectory: true)
    }

    /// Sandbox container a runtime flavor sees as its NSHomeDirectory().
    /// The iOS runtime's container is UUID-named (assigned by
    /// containermanagerd), so its name comes from the marker cache below;
    /// Catalyst's is bundle-ID-named.
    static func containerDirectory(for flavor: RuntimeFlavor) -> URL {
        let bundleID = flavorBundleID(flavor)
        if flavor == .ios, let name = knownMacIOSContainerName(for: bundleID) {
            return baseContainersDirectory.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("Data", isDirectory: true)
        }
        return baseContainersDirectory.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
    }

    /// Pre-discovery bundle-ID-named iOS container; guests found here are
    /// migrated into the real container later.
    static func staleIdentityContainerDirectory(for flavor: RuntimeFlavor) -> URL? {
        guard flavor == .ios else { return nil }
        return baseContainersDirectory.appendingPathComponent(flavorBundleID(flavor), isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
    }

    static func flavorBundleID(_ flavor: RuntimeFlavor) -> String {
        infoString(flavor.infoPlistBundleIDKey) ?? hostDerivedBaseID
    }

    // MARK: Mac-iOS container cache (runtime spill)

    /// Marker the iOS runtime writes inside its own container (its bundle
    /// ID) — how the host finds the UUID-named container back.
    static let runtimeMarkerFileName = ".baseiosapp-runtime"

    private static var iosContainerCacheFile: URL {
        hostSupportDirectory.appendingPathComponent("ios_runtime_container.txt")
    }

    /// Cached UUID container name for the iOS runtime, validated against the
    /// marker. nil when unknown/invalid; the launcher re-discovers or re-primes.
    static func knownMacIOSContainerName(for bundleID: String) -> String? {
        guard let raw = try? String(contentsOf: iosContainerCacheFile, encoding: .utf8) else {
            return nil
        }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard markerContent(in: name) == bundleID else { return nil }
        return name
    }

    /// Marker scan across containers, used when the cache is cold or stale.
    static func discoverMacIOSContainerName(for bundleID: String) -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: baseContainersDirectory.path) else {
            return nil
        }
        for entry in entries {
            let marker = baseContainersDirectory
                .appendingPathComponent(entry, isDirectory: true)
                .appendingPathComponent("Data", isDirectory: true)
                .appendingPathComponent(runtimeMarkerFileName)
            guard fm.fileExists(atPath: marker.path) else { continue }
            guard let content = try? String(contentsOf: marker, encoding: .utf8),
                  content.trimmingCharacters(in: .whitespacesAndNewlines) == bundleID else { continue }
            setCachedMacIOSContainerName(entry)
            return entry
        }
        return nil
    }

    /// Records a discovered container name.
    static func setCachedMacIOSContainerName(_ name: String) {
        try? FileManager.default.createDirectory(at: hostSupportDirectory,
                                                 withIntermediateDirectories: true)
        try? name.write(to: iosContainerCacheFile, atomically: true, encoding: .utf8)
    }

    private static func markerContent(in containerName: String) -> String? {
        let marker = baseContainersDirectory
            .appendingPathComponent(containerName, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent(runtimeMarkerFileName)
        guard let content = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pre-split shared container; emptied by migrateLegacyIfNeeded().
    static var legacyContainerDirectory: URL {
        let bundleID = infoString("LegacyRuntimeBundleIdentifier") ?? hostDerivedBaseID
        return baseContainersDirectory.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
    }

    private static var baseContainersDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
    }

    // MARK: Guest layout

    static func appsDirectory(for flavor: RuntimeFlavor) -> URL {
        containerDirectory(for: flavor).appendingPathComponent("apps", isDirectory: true)
    }

    /// Per-guest data directory (Documents/Library/Caches/…).
    static func guestHome(_ bundleID: String, in flavor: RuntimeFlavor) -> URL {
        containerDirectory(for: flavor).appendingPathComponent(bundleID, isDirectory: true)
    }

    static func displayResolutionFile(for flavor: RuntimeFlavor) -> URL {
        containerDirectory(for: flavor).appendingPathComponent("display_resolution.plist")
    }

    /// Legacy request files from the old queue-based launcher; cleaned up so
    /// stale requests can't launch a guest under the new headless runtimes.
    static func appToLaunchFile(for flavor: RuntimeFlavor) -> URL {
        containerDirectory(for: flavor).appendingPathComponent("app_to_launch.txt")
    }

    static func pendingLaunchDirectory(for flavor: RuntimeFlavor) -> URL {
        containerDirectory(for: flavor).appendingPathComponent("pending_launch", isDirectory: true)
    }

    /// Default residence for fresh installs — no prior copy of the guest in
    /// either container. Re-installs resolve the residence from the existing
    /// install instead (see GuestStore.install).
    static var containerDirectory: URL { containerDirectory(for: .catalyst) }
    static var appsDirectory: URL { appsDirectory(for: .catalyst) }

    static func ensureAppsDirectory(for flavor: RuntimeFlavor) {
        try? FileManager.default.createDirectory(at: appsDirectory(for: flavor),
                                                 withIntermediateDirectories: true)
    }

    static func ensureAppsDirectory() {
        ensureAppsDirectory(for: .catalyst)
    }

    // MARK: Guest running lock

    /// The runtime holds an exclusive flock on <guestHome>/.guest.lock while
    /// running (acquireGuestLock in main.m); the host probes it before
    /// migrating a guest. The kernel releases flock on process death.
    static func guestIsRunning(guestHome: URL) -> Bool {
        let lockPath = guestHome.appendingPathComponent(".guest.lock").path
        let fd = open(lockPath, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(fd, LOCK_UN)
        return false
    }
}

// MARK: - Guest migration between runtime containers

enum MigrationError: LocalizedError {
    case guestRunning(String)
    case containerSetupFailed

    var errorDescription: String? {
        switch self {
        case .guestRunning(let name):
            return String(localized: "\(name) is running; quit it before switching its runtime.")
        case .containerSetupFailed:
            return String(localized: "Could not set up the iOS runtime container; try again.")
        }
    }
}

extension GuestStore {

    private static func otherFlavor(_ flavor: RuntimeFlavor) -> RuntimeFlavor {
        flavor == .catalyst ? .ios : .catalyst
    }

    /// Makes sure the guest (bundle + data + app-groups) lives in `target`'s
    /// container, migrating it from a source container (stale iOS, other
    /// flavor, legacy — most authoritative first) when needed. Throws if the
    /// guest is currently running.
    static func ensureGuestResides(installName: String,
                                   guestBundleID: String?,
                                   target: RuntimeFlavor) throws {
        let fm = FileManager.default
        let targetData = GuestPaths.containerDirectory(for: target)

        var sourceDatas: [URL] = []
        if let stale = GuestPaths.staleIdentityContainerDirectory(for: target), stale != targetData {
            sourceDatas.append(stale)
        }
        sourceDatas.append(GuestPaths.containerDirectory(for: otherFlavor(target)))
        sourceDatas.append(GuestPaths.legacyContainerDirectory)

        // Home directories are named by bundle ID; fall back to the install name.
        let homeName = guestBundleID ?? installName.replacingOccurrences(of: ".app", with: "")

        // 1. The app bundle; refuse to move it under a running guest.
        let targetApps = targetData.appendingPathComponent("apps").appendingPathComponent(installName)
        if !fm.fileExists(atPath: targetApps.path) {
            for sourceData in sourceDatas {
                let sourceApps = sourceData.appendingPathComponent("apps").appendingPathComponent(installName)
                guard fm.fileExists(atPath: sourceApps.path) else { continue }
                NSLog("[migrate] bundle %@: %@ -> %@", installName as NSString,
                      sourceData.path as NSString, targetData.path as NSString)
                let sourceHome = sourceData.appendingPathComponent(homeName, isDirectory: true)
                if fm.fileExists(atPath: sourceHome.path),
                   GuestPaths.guestIsRunning(guestHome: sourceHome) {
                    throw MigrationError.guestRunning(homeName)
                }
                try fm.createDirectory(at: targetData.appendingPathComponent("apps", isDirectory: true),
                                       withIntermediateDirectories: true)
                try moveReplacing(source: sourceApps, destination: targetApps)
                // Move per-container app-group state along unless the target
                // already has one.
                let sourceGroups = sourceData.appendingPathComponent("app-groups", isDirectory: true)
                let targetGroups = targetData.appendingPathComponent("app-groups", isDirectory: true)
                if fm.fileExists(atPath: sourceGroups.path), !fm.fileExists(atPath: targetGroups.path) {
                    try? fm.moveItem(at: sourceGroups, to: targetGroups)
                }
                break
            }
        }

        // 2. The data directory — migrates independently (may trail the bundle).
        let targetHome = targetData.appendingPathComponent(homeName, isDirectory: true)
        if !fm.fileExists(atPath: targetHome.path) {
            for sourceData in sourceDatas {
                let sourceHome = sourceData.appendingPathComponent(homeName, isDirectory: true)
                guard fm.fileExists(atPath: sourceHome.path) else { continue }
                NSLog("[migrate] home %@: %@ -> %@", homeName as NSString,
                      sourceData.path as NSString, targetData.path as NSString)
                if GuestPaths.guestIsRunning(guestHome: sourceHome) {
                    throw MigrationError.guestRunning(homeName)
                }
                try moveReplacing(source: sourceHome, destination: targetHome)
                break
            }
        }
    }

    /// moveItem tolerating leftover destination state from a partial migration.
    private static func moveReplacing(source: URL, destination: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: source, to: destination)
    }

    // MARK: - Legacy (pre-split) container upgrade

    /// Idempotent upgrade from the pre-split single-container layout: import
    /// the keychain registry, move every guest into its flavor's container,
    /// retire the emptied legacy directories. Runs on every host startup.
    static func migrateLegacyIfNeeded() {
        KeychainManager.importLegacyAssignmentsIfNeeded()

        let fm = FileManager.default
        let legacyData = GuestPaths.legacyContainerDirectory
        let legacyApps = legacyData.appendingPathComponent("apps", isDirectory: true)
        let names = ((try? fm.contentsOfDirectory(atPath: legacyApps.path)) ?? [])
            .filter { $0.hasSuffix(".app") }

        for name in names {
            let bundleURL = legacyApps.appendingPathComponent(name)
            let mode = runtimeMode(for: bundleURL)
            let target: RuntimeFlavor = mode == .ios ? .ios : .catalyst
            let bundleID = readInfoPlist(at: bundleURL)?["CFBundleIdentifier"] as? String
            if fm.fileExists(atPath: GuestPaths.appsDirectory(for: target).appendingPathComponent(name).path) {
                // Already migrated: the legacy copy is stale and would block
                // retirement forever.
                try? fm.removeItem(at: bundleURL)
                continue
            }
            do {
                try ensureGuestResides(installName: name,
                                       guestBundleID: bundleID,
                                       target: target)
                let flavorName = target == .ios ? "iOS" : "Catalyst"
                NSLog("[host] migrated %@ to the %@ runtime container",
                      name as NSString, flavorName as NSString)
            } catch {
                NSLog("[host] legacy migration of %@ failed: %@",
                      name as NSString, error.localizedDescription as NSString)
            }
        }
        retireLegacyDirectories()
    }

    /// Removes legacy directories once empty; failed migrations retry next startup.
    private static func retireLegacyDirectories() {
        let fm = FileManager.default
        for relative in ["apps", "app-groups"] {
            let url = GuestPaths.legacyContainerDirectory.appendingPathComponent(relative, isDirectory: true)
            let remaining = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? [])
                .filter { !$0.hasPrefix(".") }
            if remaining.isEmpty, fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }
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

        // 3. Unquarantine (strip all xattrs recursively).
        _ = c_stripXattrsRecursive(bundleURL.path)

        // 4. Merge the Import-sheet features into RunnerFeatures.plist.
        GuestConversion.writeRunnerFeatures(bundleURL: bundleURL, importFeatures: importFeatures)

        // 5. Legacy guests need a scene manifest or UIApplicationMain aborts
        //    under Catalyst; scene-native guests keep their own delegate.
        GuestConversion.injectSceneManifest(bundleURL: bundleURL)

        // 6. Retarget every loadable image to Catalyst + add the Swift rpath.
        GuestConversion.retargetAllMachOImages(bundleURL: bundleURL)
    }

    /// Installs an IPA: extract, convert in scratch, move into the container
    /// matching the app's runtime mode (fresh installs default to Catalyst;
    /// re-installs keep the existing residence — a cross-container install
    /// would strand the guest in two containers and trip the launcher's
    /// fail-closed residence check). Returns the installed bundle name.
    static func install(from ipa: URL, importFeatures: [String: Bool]) throws -> String {
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

        // Convert *before* the bundle enters the container.
        try convert(bundleURL: bundle, importFeatures: importFeatures)

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
    /// data from every container, clear legacy launch artifacts. Returns a
    /// user-presentable summary.
    static func deleteWithCleanup(bundleID: String?, appURL: URL) -> String {
        var summary: String?

        if let bid = bundleID, !bid.isEmpty {
            summary = KeychainManager.releaseSlot(bundleID: bid)

            for flavor in [RuntimeFlavor.catalyst, .ios] {
                let guestHome = GuestPaths.guestHome(bid, in: flavor).path
                if FileManager.default.fileExists(atPath: guestHome) {
                    do {
                        try FileManager.default.removeItem(atPath: guestHome)
                        summary = summary.map { String(localized: "\($0) Data removed.") }
                            ?? String(localized: "Data removed.")
                    } catch {
                        return String(localized: "App deleted, but failed to remove guest data: \(error.localizedDescription)")
                    }
                }
            }

            // Legacy queue files from the old launcher (all containers).
            for flavor in [RuntimeFlavor.catalyst, .ios] {
                try? FileManager.default.removeItem(at: GuestPaths.appToLaunchFile(for: flavor))
                let pending = GuestPaths.pendingLaunchDirectory(for: flavor)
                if let entries = try? FileManager.default.contentsOfDirectory(atPath: pending.path) {
                    for entry in entries where entry.hasSuffix(".txt") {
                        let url = pending.appendingPathComponent(entry)
                        if let name = try? String(contentsOf: url, encoding: .utf8),
                           name.trimmingCharacters(in: .whitespacesAndNewlines) == bid + ".app" {
                            try? FileManager.default.removeItem(at: url)
                        }
                    }
                }
            }
            // And the pre-split shared container.
            let legacyHome = GuestPaths.legacyContainerDirectory.appendingPathComponent(bid, isDirectory: true).path
            try? FileManager.default.removeItem(atPath: legacyHome)
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

    /// Features guests require to function at all; never user-disableable.
    static let requiredFeatures: [String: Bool] = [
        "keychain": true,
        "groupContainer": true
    ]

    /// Re-enables required features in a guest's manifest; no-op when compliant.
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
