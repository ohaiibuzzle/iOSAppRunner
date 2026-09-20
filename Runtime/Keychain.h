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
void KeychainSetHostBundleID(NSString* hostBundleID);
void KeychainSetHostHome(NSString* hostHomePath);

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