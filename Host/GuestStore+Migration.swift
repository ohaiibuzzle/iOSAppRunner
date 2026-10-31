//
//  GuestStore+Migration.swift
//  BaseiOSAppHost
//

import Foundation

// MARK: - Guest migration between runtime containers

enum MigrationError: LocalizedError {
    case guestRunning(String)
    case containerSetupFailed
    case deleteWhileRunning(String)

    var errorDescription: String? {
        switch self {
        case .guestRunning(let name):
            return String(localized: "\(name) is running; quit it before switching its runtime.")
        case .containerSetupFailed:
            return String(localized: "Could not set up the iOS runtime container; try again.")
        case .deleteWhileRunning(let name):
            return String(localized: "\(name) is running; quit it before deleting it.")
        }
    }
}

extension GuestStore {

    private static func otherFlavor(_ flavor: RuntimeFlavor) -> RuntimeFlavor {
        flavor == .catalyst ? .ios : .catalyst
    }

    /// Makes sure the guest (bundle + data) lives in `target`'s
    /// container, migrating it from a source container (stale iOS, other
    /// flavor — most authoritative first) when needed. Throws if the
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
}
