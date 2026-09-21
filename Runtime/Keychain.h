//
//  Keychain.h
//  BaseiOSApp
//
//  Created by Venti on 24/2/26.
//

#import <Foundation/Foundation.h>

// Installs the guest keychain hooks. `hostId` is the host's bundle ID and
// `groupId` is the guest's bundle ID; the guest's access-group slot is
// acquired (or reused) as part of this call. See Keychain.m for the
// slot-registry details.
void SecItemGuestHooksInit(NSString* hostId, NSString* groupId);

// Tells the keychain code which bundle ID / sandbox home the *host* uses.
// Guest processes rewrite the main bundle and redirect HOME before hooks run,
// so main.m captures both values beforehand and passes them in. The launcher
// process never needs to call either function.
//
// KeychainSetHostBundleID now receives the *keychain access-group base*
// (KeychainAccessGroupBase from Info.plist), not the runtime's own bundle ID:
// the two runtime flavors have separate bundle IDs but must resolve the same
// ".shared[.N]" groups.
void KeychainSetHostBundleID(NSString* hostBundleID);
void KeychainSetHostHome(NSString* hostHomePath);

// Pins the guest's keychain slot to a number the host pre-assigned in its own
// slot registry and passed as a --keychain-slot launch argument. When set,
// KeychainAcquireGroupID short-circuits and never touches the registry: the
// runtime flavors live in separate sandbox containers, so a runtime-owned
// shared registry is no longer possible. Call before
// SecItemGuestHooksInit; pass a negative number (or don't call) to keep the
// legacy self-claim behavior (manual debugging without the host).
void KeychainSetAssignedSlot(int slotNumber);

// Slot registry access, for the launcher (Swift reaches these via
// @_silgen_name). Safe to call from any process in the host sandbox.
//
//  - KeychainAcquireGroupID: returns the guest's existing slot, or claims a
//    new one (fres freed slots first). Fails only when all slots are taken.
//  - KeychainReleaseGroupID: wipes the guest's keychain items and returns its
//    slot to the free pool. No-op if the guest never had a slot.
//  - KeychainWipeGroupID: deletes every item in a numbered slot.
//  - KeychainGroupIDForBundleID: current slot for a bundle ID, or nil.
BOOL KeychainAcquireGroupID(NSString* bundleID, int *outGroupID, NSString** outErrorDescription);
void KeychainReleaseGroupID(NSString* bundleID);
void KeychainWipeGroupID(int groupID);
NSString* KeychainGroupIDForBundleID(NSString* bundleID);