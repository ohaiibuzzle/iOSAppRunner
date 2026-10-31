//
//  KeychainManager.swift
//  BaseiOSAppHost
//
//  Host-side keychain slot management. The host owns the slot registry
//  (~/Library/Application Support/BaseiOSApp/keychain_slots.plist) and
//  passes a guest's slot to the runtime as --keychain-slot; Keychain.m
//  short-circuits its own claim path when the argument is present. The
//  cross-process lock protocol matches Keychain.m.
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

    /// Host-owned slot registry; the host is its single writer.
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

    /// All assigned slots in the registry (excluding the free list).
    private static func assignedSlots(in registry: [String: Any]) -> [(bundleID: String, slot: Int32)] {
        registry.compactMap { key, value in
            guard key != "free_list", let num = value as? NSNumber else { return nil }
            return (key, num.int32Value)
        }
    }

    // MARK: - Cross-process lock (same protocol as Keychain.m)

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
    private static func withSlotLock<T>(_ body: () throws -> T) throws -> T {
        let fd = acquireSlotLock()
        guard fd >= 0 else {
            throw SlotError(errorDescription: String(localized: "Timed out waiting for the keychain slot registry."))
        }
        defer { releaseSlotLock(fd) }
        return try body()
    }

    // MARK: - Slot operations

    /// Returns the guest's slot, claiming one if it never had any (passed to
    /// the runtime as --keychain-slot). nil on lock or registry failure.
    static func ensureSlot(for bundleID: String) -> Int32? {
        return try? withSlotLock { () -> Int32? in
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

    /// Deletes every keychain item in a slot's access group (all four item
    /// classes, data-protection keychain).
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

    struct SlotError: LocalizedError {
        let errorDescription: String?
    }

    /// Per-app keychain reset: deletes the guest's keychain items but keeps
    /// its slot assignment. Falls back to a fresh slot claim when the guest
    /// never had one. Returns the slot that was reset.
    static func resetKeychain(bundleID: String) throws -> Int32 {
        try withSlotLock { () throws -> Int32 in
            var registry = readRegistry()
            if let existing = (registry[bundleID] as? NSNumber)?.int32Value {
                wipeSlotItems(slot: existing)
                return existing
            }
            // Guest never had a slot; claim one so the reset lands
            // somewhere the guest will use later.
            guard let claimed = claimSlot(bundleID: bundleID, registry: &registry) else {
                throw SlotError(errorDescription: claimedError ?? String(localized: "unknown error"))
            }
            writeRegistry(registry)
            wipeSlotItems(slot: claimed)
            return claimed
        }
    }

    private static var claimedError: String?

    /// Slot allocator mirroring Keychain.m; caller holds the lock and owns
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

    /// Reclaims a guest's slot: wipe items, remove the assignment, return
    /// the number to the free list. No-op for an unknown bundle ID.
    static func releaseSlot(bundleID: String) {
        do { try withSlotLock {
            var registry = readRegistry()
            guard let slot = (registry[bundleID] as? NSNumber)?.int32Value else { return }

            wipeSlotItems(slot: slot)
            registry.removeValue(forKey: bundleID)

            var freeList = ((registry["free_list"] as? [Any]) ?? [])
            freeList.append(NSNumber(value: slot))
            registry["free_list"] = freeList
            writeRegistry(registry)
            NSLog("KeychainManager: slot %d wiped and reclaimed", slot)
        } } catch {
            NSLog("KeychainManager: could not release slot for %@: %@",
                  bundleID as NSString, error.localizedDescription as NSString)
        }
    }

    /// Debug bulk wipe: every keychain item stored for guest apps (slot 0,
    /// every registered slot, and every group in the host's own entitlement).
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

    /// Guest item access groups: every registered slot's shared group plus
    /// every group named in the host's own entitlement.
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
