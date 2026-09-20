//
//  KeychainManager.swift
//  BaseiOSAppHost
//
//  Host-side keychain slot management. The slot machinery itself lives in the
//  runtimes (Runtime/Keychain.m); the host reads/writes the same registry
//  file inside the shared container and deletes slot items directly via
//  SecItem (the host carries the same keychain-access-groups entitlement).
//
//  Registry file: <shared container>/Library/keychain_slots.plist
//    "<guest bundle ID>": <slot number>   // permanent assignment
//    "free_list": [ <slot numbers> ]      // reclaimed, reusable slots
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
        let base = "\(team).\(GuestPaths.runtimeBundleID).shared"
        return slot == 0 ? base : "\(base).\(slot)"
    }

    // MARK: - Registry access

    private static var registryURL: URL {
        GuestPaths.containerDirectory
            .appendingPathComponent("Library", isDirectory: true)
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

    // MARK: - Cross-process lock (same protocol as Keychain.m)

    private static var slotLockURL: URL {
        GuestPaths.containerDirectory.appendingPathComponent(".keychain_slots.lock")
    }

    private static func acquireSlotLock() -> Int32 {
        let path = slotLockURL.path
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
                kSecUseDataProtectionKeychain as String: true,
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
                    return "Could not reset keychain: \(claimedError ?? "unknown error")"
                }
                writeRegistry(registry)
                slot = claimed
            }
            guard let slot else { return "Could not reset keychain: unknown error" }
            wipeSlotItems(slot: slot)
            return "Reset keychain (slot \(slot))"
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
            claimedError = "All \(maxSlotID) keychain slots are in use; delete an app to free one."
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
                return "No keychain slot to release"
            }

            wipeSlotItems(slot: slot)
            registry.removeValue(forKey: bundleID)

            var freeList = ((registry["free_list"] as? [Any]) ?? [])
            freeList.append(NSNumber(value: slot))
            registry["free_list"] = freeList
            writeRegistry(registry)
            return "Keychain slot \(slot) wiped and reclaimed"
        }
    }

    /// Debug bulk wipe: deletes every keychain item the runtimes stored for
    /// guest apps — slot 0 (legacy unnumbered group), every registered slot,
    /// and every group named in the host's own entitlement.
    static func wipeAllGuestItems() -> String {
        let classes: [CFString] = [kSecClassGenericPassword, kSecClassInternetPassword,
                                   kSecClassCertificate, kSecClassKey]

        var groups = Set<String>()
        var slots: Set<Int32> = [0]
        let registry = readRegistry()
        for (bundleID, slot) in assignedSlots(in: registry) {
            slots.insert(slot)
            NSLog("KeychainManager: registry slot %d — %@", slot, bundleID as NSString)
        }

        if let task = c_SecTaskCreateFromSelf(nil) {
            if let team = c_SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.team-identifier" as CFString, nil) as? String {
                let base = "\(team).\(GuestPaths.runtimeBundleID).shared"
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
        }

        var enumerated = 0
        var deletedSomething = false
        for cls in classes {
            var out: AnyObject?
            let countQuery: [CFString: Any] = [
                kSecClass: cls,
                kSecMatchLimit: kSecMatchLimitAll,
                kSecReturnAttributes: true,
                kSecUseDataProtectionKeychain: kCFBooleanTrue,
            ]
            if SecItemCopyMatching(countQuery as CFDictionary, &out) == errSecSuccess,
               let items = out as? [[String: Any]] {
                enumerated += items.count
            }

            if SecItemDelete([kSecClass: cls,
                              kSecUseDataProtectionKeychain: kCFBooleanTrue] as CFDictionary) == errSecSuccess {
                deletedSomething = true
            }
            for group in groups {
                if SecItemDelete([kSecClass: cls,
                                  kSecAttrAccessGroup: group,
                                  kSecUseDataProtectionKeychain: kCFBooleanTrue] as CFDictionary) == errSecSuccess {
                    deletedSomething = true
                }
            }
        }

        if enumerated > 0 {
            return "Deleted \(enumerated) keychain item\(enumerated == 1 ? "" : "s")."
        }
        if deletedSomething {
            return "Keychain wiped."
        }
        return "No keychain items found."
    }
}
