//
//  GuestStore.swift
//  BaseiOSAppHost
//
//  Host-side guest management: per-flavor container paths, the import-time
//  conversion pipeline (dylibify, unquarantine, RunnerFeatures provisioning,
//  scene-manifest injection, Catalyst build-version retarget), install into
//  a runtime container, guest migration between the runtime containers,
//  deletion with full data cleanup, and per-app RunnerFeatures.plist
//  editing.
//
//  The two runtime flavors carry separate bundle IDs (so LaunchServices
//  treats them as distinct apps and both can run at once), which means each
//  has its own sandbox container. A guest lives in exactly one container:
//  Data/apps holds its bundle, Data/<guestBundleID> its data. When its
//  effective runtime flavor changes, the host migrates it between
//  containers (ensureGuestResides) before launching.
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

/// Per-app runtime selection, stored as the `runtime` key in the guest's
/// RunnerFeatures.plist.
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
    /// suffix from the host's own bundle ID. Both flavors then resolve to the
    /// same legacy container (degraded dev-build behavior, never the case in
    /// normal builds).
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

    /// Host-owned metadata directory (the host is unsandboxed; the runtimes
    /// never need to read it). Holds the keychain slot registry and the iOS
    /// runtime container cache.
    static var hostSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BaseiOSApp", isDirectory: true)
    }

    /// Sandbox container a runtime flavor sees as its NSHomeDirectory().
    ///
    /// Mac-iOS ("Designed for iPad") wrapped apps are the exception: at
    /// first LaunchServices registration, containermanagerd assigns them a
    /// stable **UUID-named** container (keyed to the app's signing
    /// personality) — macOS-platform flavors (Catalyst) get
    /// bundle-ID-named ones. The host learns the UUID from the runtime
    /// itself (RuntimeLauncher primes a stopped runtime and reads HOME from
    /// its environment), caches it below, and validates the cache against
    /// the container's own metadata on every use (one plist read).
    static func containerDirectory(for flavor: RuntimeFlavor) -> URL {
        let bundleID = flavorBundleID(flavor)
        if flavor == .ios, let name = knownMacIOSContainerName(for: bundleID) {
            return baseContainersDirectory.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("Data", isDirectory: true)
        }
        return baseContainersDirectory.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
    }

    /// The bundle-ID-named container an iOS flavor would use before its UUID
    /// container is known (fresh installs, or runs before discovery
    /// existed). Guests placed there are migrated into the real container on
    /// the next launch.
    static func staleIdentityContainerDirectory(for flavor: RuntimeFlavor) -> URL? {
        guard flavor == .ios else { return nil }
        return baseContainersDirectory.appendingPathComponent(flavorBundleID(flavor), isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
    }

    static func flavorBundleID(_ flavor: RuntimeFlavor) -> String {
        infoString(flavor.infoPlistBundleIDKey) ?? hostDerivedBaseID
    }

    // MARK: Mac-iOS container cache (runtime spill)

    /// Marker the iOS runtime writes at startup: its bundle ID, inside its
    /// own (UUID-named) container. This is how the host finds the container
    /// back — the wrapped Mac-iOS app's container is assigned by
    /// containermanagerd and not derivable from the bundle ID.
    static let runtimeMarkerFileName = ".baseiosapp-runtime"

    private static var iosContainerCacheFile: URL {
        hostSupportDirectory.appendingPathComponent("ios_runtime_container.txt")
    }

    /// The cached UUID container name for the iOS runtime, validated against
    /// the runtime's own marker (two stats + a tiny read — no scanning). nil
    /// when unknown/invalid; the launcher then re-discovers or re-primes.
    static func knownMacIOSContainerName(for bundleID: String) -> String? {
        guard let raw = try? String(contentsOf: iosContainerCacheFile, encoding: .utf8) else {
            return nil
        }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard markerContent(in: name) == bundleID else { return nil }
        return name
    }

    /// Cheap targeted scan for the runtime's marker: one stat per container
    /// directory (no plist parsing), reading only markers that exist. Used
    /// when the cache is cold or stale — after priming, or when the runtime's
    /// signing personality (and therefore container) changed.
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

    /// The pre-split shared container (both runtimes used one bundle ID).
    /// Existing guests still live here until migrateLegacyIfNeeded() moves
    /// them into their flavor's container.
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

    /// Default residence for fresh installs (Catalyst is the preferred
    /// flavor; ensureGuestResides moves the guest later if its runtime mode
    /// says otherwise).
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

    /// The runtime holds an exclusive flock on <guestHome>/.guest.lock for
    /// its whole lifetime (acquireGuestLock in main.m). The host probes it
    /// before migrating a guest between containers; flock is released by the
    /// kernel on process death, so crashed runtimes never leave stale locks.
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
    /// container, migrating it from wherever it currently resides when
    /// needed. Sources, most authoritative first: the iOS flavor's
    /// bundle-ID-named container (pre-discovery location), the other
    /// flavor's container, and the legacy pre-split container. Throws when
    /// the guest is currently running — its runtime holds the flock and its
    /// files cannot be moved underneath it.
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

        // Guest homes are named by bundle ID; reconstruct from the install
        // name ("com.foo.Bar.app" → "com.foo.Bar") when the host scan didn't
        // provide one.
        let homeName = guestBundleID ?? installName.replacingOccurrences(of: ".app", with: "")

        // 1. The app bundle. A running guest's runtime holds the flock and
        //    has its bundle's pages mapped — refuse to move under it.
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
                // App-group state is per-container; move it along unless the
                // target already has one (another guest's state lives there).
                let sourceGroups = sourceData.appendingPathComponent("app-groups", isDirectory: true)
                let targetGroups = targetData.appendingPathComponent("app-groups", isDirectory: true)
                if fm.fileExists(atPath: sourceGroups.path), !fm.fileExists(atPath: targetGroups.path) {
                    try? fm.moveItem(at: sourceGroups, to: targetGroups)
                }
                break
            }
        }

        // 2. The guest's data directory — may trail the bundle (manual
        //    copies, partial migrations) so it migrates independently.
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

    /// moveItem that tolerates leftover destination state from an earlier
    /// partial migration (moves are atomic renames, so leftovers are the only
    /// possible partial state).
    private static func moveReplacing(source: URL, destination: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: source, to: destination)
    }

    // MARK: - Legacy (pre-split) container upgrade

    /// One-time upgrade from the pre-split layout where both runtimes shared
    /// one bundle ID and therefore one container. Imports the keychain slot
    /// registry, then moves every installed guest into the container of its
    /// configured runtime flavor (Catalyst by default), and finally retires the
    /// emptied legacy directories. Idempotent; runs on every host startup.
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
                // Already migrated in an earlier run: the legacy copy is
                // stale and would block legacy retirement forever.
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

    /// Removes legacy directories that are now empty. Anything still holding
    /// data (failed migrations) is left in place and retried next startup.
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
    /// the guest's data directory from every runtime container (data may
    /// exist in either after runtime-mode switches), and clears any legacy
    /// queued-launch artifacts so nothing can resurrect the app under the
    /// headless runtimes. Returns a user-presentable summary.
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
            // And the pre-split shared container, for guests that never
            // launched after the upgrade.
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

    /// Finds where a guest's bundle currently resides: which runtime flavor's
    /// container holds it, and at what URL. Launch reads the configured mode
    /// from *this* copy — never from a UI-cached URL, which goes stale the
    /// moment a sheet-close migration moves the guest between containers.
    static func locateInstalledGuest(installName: String) -> (flavor: RuntimeFlavor, url: URL)? {
        let fm = FileManager.default
        for flavor in [RuntimeFlavor.catalyst, .ios] {
            let url = GuestPaths.appsDirectory(for: flavor).appendingPathComponent(installName)
            if fm.fileExists(atPath: url.path) { return (flavor, url) }
        }
        // A guest stranded in the iOS pre-discovery (bundle-ID-named)
        // container — placed there before the runtime's UUID container was
        // known — still counts as iOS residence; ensureIOSRuntimeContainer +
        // ensureGuestResides relocate it at launch / sheet close.
        if let stale = GuestPaths.staleIdentityContainerDirectory(for: .ios) {
            let url = stale.appendingPathComponent("apps").appendingPathComponent(installName)
            if fm.fileExists(atPath: url.path) { return (.ios, url) }
        }
        return nil
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
