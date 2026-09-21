//
//  KeychainManager.swift
//  BaseiOSAppHost
//
//  Host-side keychain slot management. The host OWNS the slot registry: the
//  two runtime flavors live in separate sandbox containers, so the old
//  shared-container registry is impossible — instead the host claims a
//  guest's slot before launch and passes the number to the runtime as a
//  --keychain-slot launch argument (Keychain.m short-circuits its own claim
//  path when the argument is present). Registry file:
//
//    ~/Library/Application Support/BaseiOSApp/keychain_slots.plist
//
//    "<guest bundle ID>": <slot number>   // permanent assignment
//    "free_list": [ <slot numbers> ]      // reclaimed, reusable slots
//
//  The pre-split registry (inside the legacy runtime container) is imported
//  once by GuestStore.migrateLegacyIfNeeded().
//
//  Cross-process lock: the same O_CREAT|O_EXCL `.keychain_slots.lock` file
//  protocol Keychain.m uses (stale locks older than 10s are broken).
//

import Foundation
import Security

// MARK: - Bridges to Keychain.m helpers not compiled into the host

@_silgen_name("SecTaskCreateFromSelf")
private func c_SecTaskCreateFromSelf(_ allocator: CFAllocator?) -> CFTypeRef?

@_silgen_name("SecTaskCopyValueForEntitlement")
private func c_SecTaskCopyValueForEntitlement(_ task: CFTypeRef,
                                              _ entitlement: CFString,
                                              _ error: UnsafeMutablePointer<CFError?>?) -> CFTypeRef?

enum KeychainManager {

    private static let maxSlotID = 127

    // MARK: - Team identity

    private static func teamIdentifier() -> String? {
        guard let task = c_SecTaskCreateFromSelf(nil),
              let value = c_SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.team-identifier" as CFString, nil) as? String,
              !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Access-group string for a slot: slot 0 is the legacy unnumbered
    /// ".shared" group; registered slots are ".shared.N".
    private static func accessGroup(for slot: Int32) -> String? {
        guard let team = teamIdentifier() else { return nil }
        let base = "\(team).\(GuestPaths.keychainAccessGroupBase).shared"
        return slot == 0 ? base : "\(base).\(slot)"
    }

    // MARK: - Registry access

    /// Host-owned slot registry. The runtime flavors live in separate sandbox
    /// containers, so the registry can no longer live in a runtime container;
    /// the host is now its single writer (the runtimes only ever receive the
    /// pre-assigned slot number as a launch argument).
    private static var registryURL: URL {
        GuestPaths.hostSupportDirectory
            .appendingPathComponent("keychain_slots.plist")
    }

    private static func readRegistry() -> [String: Any] {
        (NSDictionary(contentsOfFile: registryURL.path) as? [String: Any]) ?? [:]
    }

    private static func writeRegistry(_ registry: [String: Any]) {
        try? FileManager.default.createDirectory(at: registryURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        (registry as NSDictionary).write(to: registryURL, atomically: true)
    }

    /// Current slot for a bundle ID, or nil.
    static func slot(for bundleID: String) -> Int32? {
        let registry = readRegistry()
        return (registry[bundleID] as? NSNumber)?.int32Value
    }

    /// All assigned slots in the registry (excluding the free list).
    private static func assignedSlots(in registry: [String: Any]) -> [(bundleID: String, slot: Int32)] {
        registry.compactMap { key, value in
            guard key != "free_list", let num = value as? NSNumber else { return nil }
            return (key, num.int32Value)
        }
    }

    // MARK: - Cross-process lock (same protocol as Keychain.m; the host is
    // now the only registry writer, but the file lock is kept so a second
    // host instance cannot interleave registry writes)

    private static var slotLockURL: URL {
        registryURL.deletingLastPathComponent()
            .appendingPathComponent(".keychain_slots.lock")
    }

    private static func acquireSlotLock() -> Int32 {
        let path = slotLockURL.path
        try? FileManager.default.createDirectory(at: slotLockURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let deadline = Date().addingTimeInterval(10.0)
        while true {
            let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd >= 0 {
                return fd
            }
            if errno != EEXIST {
                return -1
            }
            // Stale lock from a crashed process?
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let created = attrs[.creationDate] as? Date,
               Date().timeIntervalSince(created) > 10.0 {
                unlink(path)
                continue
            }
            if Date() >= deadline {
                NSLog("KeychainManager: timed out waiting for the slot registry lock")
                return -1
            }
            usleep(20 * 1000)
        }
    }

    private static func releaseSlotLock(_ fd: Int32) {
        guard fd >= 0 else { return }
        close(fd)
        unlink(slotLockURL.path)
    }

    /// Runs `body` while holding the cross-process slot lock.
    private static func withSlotLock<T>(_ body: () throws -> T) rethrows -> T {
        let fd = acquireSlotLock()
        defer { releaseSlotLock(fd) }
        return try body()
    }

    // MARK: - Slot operations

    /// Returns the guest's slot, claiming one if it never had any. Called by
    /// the launcher before every guest launch; the number is passed to the
    /// runtime as --keychain-slot. Returns nil on registry failure — the
    /// runtime then falls back to its own legacy claim path (single container,
    /// manual-debugging scenario).
    static func ensureSlot(for bundleID: String) -> Int32? {
        return withSlotLock { () -> Int32? in
            var registry = readRegistry()
            if let existing = (registry[bundleID] as? NSNumber)?.int32Value {
                return existing
            }
            guard let claimed = claimSlot(bundleID: bundleID, registry: &registry) else {
                NSLog("KeychainManager: could not claim a slot for %@: %@",
                      bundleID as NSString, (claimedError ?? "unknown error") as NSString)
                return nil
            }
            writeRegistry(registry)
            return claimed
        }
    }

    /// One-time import of the pre-split registry, which lived in the legacy
    /// shared runtime container. Runs before the guest migration so migrated
    /// guests keep their slots. No-op once the new registry exists.
    static func importLegacyAssignmentsIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: registryURL.path) else { return }
        let legacyURL = GuestPaths.legacyContainerDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("keychain_slots.plist")
        guard let legacy = NSDictionary(contentsOfFile: legacyURL.path) as? [String: Any],
              !legacy.isEmpty else { return }

        var assignments: [String: Int32] = [:]
        for (key, value) in legacy where key != "free_list" {
            if let num = value as? NSNumber {
                assignments[key] = num.int32Value
            }
        }
        guard !assignments.isEmpty else { return }

        // Free list recomputed as every slot not assigned; drops any slot
        // numbers the old scheme handed out beyond the cap.
        var registry: [String: Any] = [:]
        for (bundleID, slot) in assignments.sorted(by: { $0.key < $1.key }) {
            registry[bundleID] = NSNumber(value: slot)
        }
        let assigned = Set(assignments.values)
        registry["free_list"] = (1...maxSlotID).filter { !assigned.contains(Int32($0)) }
            .map { NSNumber(value: $0) }
        writeRegistry(registry)
        NSLog("KeychainManager: imported %d slot assignments from the legacy registry",
              assignments.count)
    }

    /// Deletes every keychain item stored in a numbered slot's access group
    /// (all four item classes, data-protection keychain). No-op when the team
    /// identity is unavailable.
    @discardableResult
    static func wipeSlotItems(slot: Int32) -> Bool {
        guard let group = accessGroup(for: slot) else {
            NSLog("KeychainManager: no team identifier; cannot build access group for slot \(slot)")
            return false
        }
        return wipeAccessGroup(group)
    }

    private static func wipeAccessGroup(_ group: String) -> Bool {
        let classes: [CFString] = [kSecClassGenericPassword, kSecClassInternetPassword,
                                   kSecClassCertificate, kSecClassKey]
        var deletedAnything = false
        for cls in classes {
            var query: [String: Any] = [
                kSecClass as String: cls,
                kSecUseDataProtectionKeychain as String: true
            ]
            if !group.isEmpty {
                query[kSecAttrAccessGroup as String] = group
            }
            if SecItemDelete(query as CFDictionary) == errSecSuccess {
                deletedAnything = true
            }
        }
        return deletedAnything
    }

    /// Per-app keychain reset: deletes the guest's keychain items but keeps
    /// its slot assignment (so the next launch starts logged out, in the same
    /// slot). Falls back to a fresh slot claim when the guest never had one.
    /// Returns a user-presentable summary.
    static func resetKeychain(bundleID: String) -> String {
        let result = withSlotLock { () -> String in
            var registry = readRegistry()

            var slot = (registry[bundleID] as? NSNumber)?.int32Value
            if slot == nil {
                // Guest never launched with the keychain hook; claim a slot
                // the same way Keychain.m does so the reset lands somewhere
                // the guest will use later.
                guard let claimed = claimSlot(bundleID: bundleID, registry: &registry) else {
                    let unknown = String(localized: "unknown error")
                    return String(localized: "Could not reset keychain: \(claimedError ?? unknown)")
                }
                writeRegistry(registry)
                slot = claimed
            }
            guard let slot else {
                let unknown = String(localized: "unknown error")
                return String(localized: "Could not reset keychain: \(unknown)")
            }
            wipeSlotItems(slot: slot)
            return String(localized: "Reset keychain (slot \(slot))")
        }
        return result
    }

    private static var claimedError: String?

    /// Slot allocator mirroring Keychain.m: reuse the lowest freed number,
    /// otherwise extend past every used slot. Caller holds the lock and owns
    /// the mutable registry copy.
    private static func claimSlot(bundleID: String, registry: inout [String: Any]) -> Int32? {
        claimedError = nil

        var freeList = (registry["free_list"] as? [Any]) ?? []
        if let first = freeList.first as? NSNumber {
            freeList.removeFirst()
            registry["free_list"] = freeList
            let slot = first.int32Value
            registry[bundleID] = NSNumber(value: slot)
            return slot
        }

        let highest = assignedSlots(in: registry).map(\.slot).max() ?? 0
        guard highest < maxSlotID else {
            claimedError = String(localized: "All \(maxSlotID) keychain slots are in use; delete an app to free one.")
            return nil
        }
        let slot = highest + 1
        registry[bundleID] = NSNumber(value: slot)
        return slot
    }

    /// Reclaims a guest's slot: deletes every keychain item stored in that
    /// slot, removes the assignment, and returns the number to the free list
    /// for reuse by the next guest. No-op for a bundle ID that never had a
    /// slot. Returns a user-presentable summary.
    @discardableResult
    static func releaseSlot(bundleID: String) -> String {
        return withSlotLock { () -> String in
            var registry = readRegistry()
            guard let slot = (registry[bundleID] as? NSNumber)?.int32Value else {
                return String(localized: "No keychain slot to release")
            }

            wipeSlotItems(slot: slot)
            registry.removeValue(forKey: bundleID)

            var freeList = ((registry["free_list"] as? [Any]) ?? [])
            freeList.append(NSNumber(value: slot))
            registry["free_list"] = freeList
            writeRegistry(registry)
            return String(localized: "Keychain slot \(slot) wiped and reclaimed")
        }
    }

    /// Debug bulk wipe: deletes every keychain item the runtimes stored for
    /// guest apps — slot 0 (legacy unnumbered group), every registered slot,
    /// and every group named in the host's own entitlement.
    static func wipeAllGuestItems() -> String {
        let classes: [CFString] = [kSecClassGenericPassword, kSecClassInternetPassword,
                                   kSecClassCertificate, kSecClassKey]

        var slots: Set<Int32> = [0]
        for (bundleID, slot) in assignedSlots(in: readRegistry()) {
            slots.insert(slot)
            NSLog("KeychainManager: registry slot %d — %@", slot, bundleID as NSString)
        }

        let groups = collectAccessGroups(slots: slots)
        let (enumerated, deletedSomething) = deleteItems(classes: classes, groups: groups)

        if enumerated > 0 {
            return String(localized: "Deleted \(enumerated) keychain items.")
        }
        if deletedSomething {
            return String(localized: "Keychain wiped.")
        }
        return String(localized: "No keychain items found.")
    }

    /// The access groups that guest items can live in: the shared group of
    /// every registered slot plus every group named in the host's own
    /// keychain-access-groups entitlement.
    private static func collectAccessGroups(slots: Set<Int32>) -> Set<String> {
        var groups = Set<String>()
        guard let task = c_SecTaskCreateFromSelf(nil) else { return groups }

        if let team = c_SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.team-identifier" as CFString, nil) as? String {
            let base = "\(team).\(GuestPaths.keychainAccessGroupBase).shared"
            for slot in slots {
                groups.insert(slot == 0 ? base : "\(base).\(slot)")
            }
        }
        if let entitled = c_SecTaskCopyValueForEntitlement(
            task, "keychain-access-groups" as CFString, nil) as? [Any] {
            for group in entitled.compactMap({ $0 as? String }) {
                groups.insert(group)
            }
        }
        return groups
    }

    /// Deletes every item in each class, globally and per access group.
    /// Returns the number of items seen and whether anything was deleted.
    private static func deleteItems(classes: [CFString], groups: Set<String>) -> (enumerated: Int, deletedSomething: Bool) {
        var enumerated = 0
        var deletedSomething = false
        for cls in classes {
            var out: AnyObject?
            let countQuery: [CFString: Any] = [
                kSecClass: cls,
                kSecMatchLimit: kSecMatchLimitAll,
                kSecReturnAttributes: true,
                kSecUseDataProtectionKeychain: kCFBooleanTrue
            ]
            if SecItemCopyMatching(countQuery as CFDictionary, &out) == errSecSuccess,
               let items = out as? [[String: Any]] {
                enumerated += items.count
            }

            if SecItemDelete([kSecClass: cls,
                              kSecUseDataProtectionKeychain: kCFBooleanTrue] as CFDictionary) == errSecSuccess {
                deletedSomething = true
            }
            for group in groups where SecItemDelete([kSecClass: cls,
                                                     kSecAttrAccessGroup: group,
                                                     kSecUseDataProtectionKeychain: kCFBooleanTrue] as CFDictionary) == errSecSuccess {
                deletedSomething = true
            }
        }
        return (enumerated, deletedSomething)
    }
}
