//
//  GuestPaths.swift
//  BaseiOSAppHost
//

import Darwin
import Foundation

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
    /// migrating a guest. The kernel releases flock on process death, which
    /// can trail ⌘Q by a few seconds, so a held lock is re-probed for up to
    /// `grace` seconds. Blocks; call off the main thread.
    static func guestIsRunning(guestHome: URL, grace: TimeInterval = 3) -> Bool {
        let lockPath = guestHome.appendingPathComponent(".guest.lock").path
        let fd = open(lockPath, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(grace)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else { return true }
            usleep(100_000)
        }
        flock(fd, LOCK_UN)
        return false
    }
}
