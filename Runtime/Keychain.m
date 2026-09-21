//
//  Keychain.m
//  BaseiOSApp
//
//  Created by Venti on 24/2/26.
//

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "utils.h"
#import <CommonCrypto/CommonDigest.h>
#import "../litehook/src/litehook.h"
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>

#if TARGET_OS_MACCATALYST
SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);
#else
SecTrustRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
CFTypeRef SecTaskCopyValueForEntitlement(SecTrustRef task, CFStringRef entitlement, CFErrorRef *error);
#endif
extern void* (*msHookFunction)(void *symbol, void *hook, void **old);
OSStatus (*orig_SecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result) = SecItemAdd;
OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result) = SecItemCopyMatching;
OSStatus (*orig_SecItemUpdate)(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) = SecItemUpdate;
OSStatus (*orig_SecItemDelete)(CFDictionaryRef query) = SecItemDelete;
SecKeyRef (*orig_SecKeyCreateRandomKey)(CFDictionaryRef parameters, CFErrorRef *error) = SecKeyCreateRandomKey;
SecKeyRef (*orig_SecKeyCreateWithData)(CFDataRef keyData, CFDictionaryRef parameters, CFErrorRef *error) = SecKeyCreateWithData;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
OSStatus (*orig_SecKeyGeneratePair)(CFDictionaryRef query, SecKeyRef *publicKey, SecKeyRef *privateKey) = SecKeyGeneratePair;
#pragma clang diagnostic pop
NSString* accessGroup = nil;
NSString* containerId = nil;

NSString* getTeamIdentifier(void) {
    static NSString* ans = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void* taskSelf = SecTaskCreateFromSelf(NULL);
        CFErrorRef error = NULL;
        CFTypeRef cfans = SecTaskCopyValueForEntitlement(taskSelf, CFSTR("com.apple.developer.team-identifier"), &error);
        if(CFGetTypeID(cfans) == CFStringGetTypeID()) {
            ans = (__bridge NSString*)cfans;
        }
        CFRelease(taskSelf);
    });
    return ans;
}

#pragma mark - Access-group slot registry

// Forward declarations (Keychain.h is not imported here; the launcher reaches
// these via @_silgen_name).
void KeychainWipeGroupID(int groupID);
NSNumber* KeychainGroupIDForBundleID(NSString* bundleID);

// Every guest gets a numbered access group "<teamID>.<base>.shared[.N]" —
// one private keychain slot per guest. Assignments live in a registry plist
// at a fixed host-sandbox path (guests redirect HOME and rewrite the main
// bundle before touching defaults, so standardUserDefaults would diverge per
// process):
//
//   "<guest bundle ID>": <slot number>   // permanent assignment
//   "free_list": [ <slot numbers> ]      // reclaimed, reusable slots
//
// MAX_KEYCHAIN_GROUP_ID must match the numbered keychain-access-groups in
// iOSAppRunner.entitlements.
static const int MAX_KEYCHAIN_GROUP_ID = 127;

// Access-group base (Info.plist KeychainAccessGroupBase), captured before
// guests rewrite the main bundle; shared by both runtime flavors.
static NSString* keychainHostAppID = nil;
// Host sandbox home, captured before guests redirect HOME.
static NSString* keychainHostHome = nil;

void KeychainSetHostBundleID(NSString* hostBundleID) {
    if (keychainHostAppID == nil && hostBundleID.length > 0) {
        keychainHostAppID = [hostBundleID copy];
    }
}

// Host pre-assigned slot via --keychain-slot; -1 until set.
static int assignedSlotOverride = -1;

void KeychainSetAssignedSlot(int slotNumber) {
    if (assignedSlotOverride == -1 && slotNumber >= 0 && slotNumber <= MAX_KEYCHAIN_GROUP_ID) {
        assignedSlotOverride = slotNumber;
    }
}

// main.m hands us the real sandbox home (guests redirect HOME before hooks
// run); the launcher never redirects HOME, so NSHomeDirectory() is a valid
// fallback there.
void KeychainSetHostHome(NSString* hostHomePath) {
    if (keychainHostHome == nil && hostHomePath.length > 0) {
        keychainHostHome = [hostHomePath copy];
    }
}

static NSString* currentHostAppID(void) {
    return keychainHostAppID ?: [[NSBundle mainBundle] bundleIdentifier];
}

// Per-process lock around the free-list read-modify-write; the file lock below
// extends it across processes.
static NSLock* keychainRegistryLock(void) {
    static NSLock* lock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSLock new]; });
    return lock;
}

// Cross-process mutex for the registry: O_CREAT|O_EXCL, stale locks older
// than 10s broken, 10s timeout.
static NSString* slotLockPath(void) {
    // Prefer the captured host home; guests may have redirected HOME already.
    NSString* base = keychainHostHome ?: NSHomeDirectory();
    return [base stringByAppendingPathComponent:@".keychain_slots.lock"];
}

static int acquireSlotLock(void) {
    const char* lockPath = slotLockPath().fileSystemRepresentation;
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
    while (true) {
        int fd = open(lockPath, O_CREAT | O_EXCL | O_WRONLY, 0644);
        if (fd >= 0) {
            return fd;
        }
        if (errno != EEXIST) {
            return -1;
        }
        struct stat st;
        if (stat(lockPath, &st) == 0 &&
            [NSDate date].timeIntervalSince1970 - (double)st.st_birthtimespec.tv_sec > 10.0) {
            unlink(lockPath); // stale lock from a crashed process
            continue;
        }
        if ([deadline timeIntervalSinceNow] <= 0) {
            NSLog(@"Keychain: timed out waiting for the slot registry lock");
            return -1;
        }
        usleep(20 * 1000);
    }
}

static void releaseSlotLock(int fd) {
    if (fd < 0) return;
    close(fd);
    unlink(slotLockPath().fileSystemRepresentation);
}

// A plain plist, NOT CFPreferences: guests redirect HOME before hooks run,
// so cfprefsd would resolve the host's preferences domain to a path inside
// the guest home and host/guest views would silently diverge.
static NSString* slotRegistryPath(void) {
    NSString* base = keychainHostHome ?: NSHomeDirectory();
    return [base stringByAppendingPathComponent:@"Library/keychain_slots.plist"];
}

static CFMutableDictionaryRef copyRegistry(void) {
    NSDictionary* raw = [NSDictionary dictionaryWithContentsOfFile:slotRegistryPath()];
    CFMutableDictionaryRef registry = NULL;
    if (raw.count > 0) {
        registry = CFDictionaryCreateMutableCopy(NULL, 0, (__bridge CFDictionaryRef)raw);
    }
    if (!registry) {
        registry = CFDictionaryCreateMutable(NULL, 0, &kCFCopyStringDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    return registry;
}

static void saveRegistry(CFMutableDictionaryRef registry) {
    NSDictionary* dict = (__bridge NSDictionary*)registry;
    if (![dict writeToFile:slotRegistryPath() atomically:YES]) {
        NSLog(@"Keychain: failed to write the slot registry");
    }
}

// One-time migration from the old counter scheme, which stored a per-guest
// "<bundleID>_group_id" integer in the guest's own preferences plist.
static int readLegacySlotNumber(NSString* guestBundleID) {
    NSString* legacyPath = [NSString stringWithFormat:@"%@/%@/Library/Preferences/%@.plist",
                            keychainHostHome ?: NSHomeDirectory(), guestBundleID, guestBundleID];
    NSDictionary* legacy = [NSDictionary dictionaryWithContentsOfFile:legacyPath];
    NSInteger value = [legacy[[guestBundleID stringByAppendingString:@"_group_id"]] integerValue];
    if (value <= 0 || value > MAX_KEYCHAIN_GROUP_ID) return 0;
    return (int)value;
}

static void migrateLegacySlotIfNeeded(NSString* guestBundleID, CFMutableDictionaryRef registry) {
    if (CFDictionaryContainsKey(registry, (__bridge CFStringRef)guestBundleID)) return;

    int legacy = readLegacySlotNumber(guestBundleID);
    if (legacy == 0) return;

    // Skip if another guest already owns this legacy slot.
    BOOL taken = NO;
    NSDictionary *snapshot = (__bridge NSDictionary *)registry;
    for (NSString *key in snapshot) {
        if ([key isEqualToString:@"free_list"]) continue;
        NSNumber *value = snapshot[key];
        if ([value isKindOfClass:[NSNumber class]] && value.intValue == legacy) {
            taken = YES;
            break;
        }
    }
    if (taken) return;

    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &legacy);
    CFDictionarySetValue(registry, (__bridge CFStringRef)guestBundleID, number);
    CFRelease(number);
    saveRegistry(registry);
    NSLog(@"Keychain: migrated legacy slot %d for %@", legacy, guestBundleID);
}

// Returns YES on success. On failure, outErrorDescription (optional) receives a
// user-presentable reason (slot exhaustion, etc.).
BOOL KeychainAcquireGroupID(NSString* bundleID, int *outGroupID, NSString** outErrorDescription) {
    if (outErrorDescription) *outErrorDescription = nil;
    if (bundleID.length == 0 || !outGroupID) return NO;

    // Host pre-assigned slot via --keychain-slot.
    if (assignedSlotOverride >= 0) {
        *outGroupID = assignedSlotOverride;
        return YES;
    }

    [keychainRegistryLock() lock];
    int lockFD = acquireSlotLock();
    CFMutableDictionaryRef registry = copyRegistry();
    migrateLegacySlotIfNeeded(bundleID, registry);

    // Already have a slot? Keep it stable across launches and reinstalls.
    CFNumberRef assigned = CFDictionaryGetValue(registry, (__bridge CFStringRef)bundleID);
    if (assigned) {
        if (CFNumberGetValue(assigned, kCFNumberIntType, outGroupID)) {
            CFRelease(registry);
            releaseSlotLock(lockFD);
            [keychainRegistryLock() unlock];
            return YES;
        }
        CFDictionaryRemoveValue(registry, (__bridge CFStringRef)bundleID);
    }

    // Claim a slot: reuse the lowest freed number first.
    CFArrayRef freeList = CFDictionaryGetValue(registry, CFSTR("free_list"));
    int newGroupID = 0;
    BOOL fromFreeList = NO;
    if (freeList && CFArrayGetCount(freeList) > 0) {
        CFNumberRef freeNum = (CFNumberRef)CFArrayGetValueAtIndex(freeList, 0);
        if (CFNumberGetValue(freeNum, kCFNumberIntType, &newGroupID)) {
            CFArrayRemoveValueAtIndex((CFMutableArrayRef)freeList, 0);
            fromFreeList = YES;
        }
    }
    if (!fromFreeList) {
        // Fresh allocation: extend past every used slot.
        int highest = 0;
        NSDictionary *snapshot = (__bridge NSDictionary *)registry;
        for (NSString *key in snapshot) {
            if ([key isEqualToString:@"free_list"]) continue;
            NSNumber *value = snapshot[key];
            if ([value isKindOfClass:[NSNumber class]] && value.intValue > highest) {
                highest = value.intValue;
            }
        }
        if (highest >= MAX_KEYCHAIN_GROUP_ID) {
            CFRelease(registry);
            releaseSlotLock(lockFD);
            [keychainRegistryLock() unlock];
            if (outErrorDescription) {
                *outErrorDescription = [NSString stringWithFormat:@"All %d keychain slots are in use; delete an app to free one.", MAX_KEYCHAIN_GROUP_ID];
            }
            return NO;
        }
        newGroupID = highest + 1;
    }

    CFNumberRef newNumber = CFNumberCreate(NULL, kCFNumberIntType, &newGroupID);
    CFDictionarySetValue(registry, (__bridge CFStringRef)bundleID, newNumber);
    CFRelease(newNumber);
    saveRegistry(registry);
    CFRelease(registry);

    releaseSlotLock(lockFD);
    [keychainRegistryLock() unlock];
    return YES;
}

// Reclaims a guest's slot: deletes every keychain item stored in that slot,
// then returns the number to the free list for reuse by the next guest. Safe
// to call for a bundle ID that never acquired a slot (no-op).
void KeychainReleaseGroupID(NSString* bundleID) {
    if (bundleID.length == 0) return;

    [keychainRegistryLock() lock];
    int lockFD = acquireSlotLock();
    CFMutableDictionaryRef registry = copyRegistry();

    CFNumberRef assigned = CFDictionaryGetValue(registry, (__bridge CFStringRef)bundleID);
    if (!assigned) {
        CFRelease(registry);
        releaseSlotLock(lockFD);
        [keychainRegistryLock() unlock];
        return;
    }
    int groupID = 0;
    CFNumberGetValue(assigned, kCFNumberIntType, &groupID);

    // Wipe before reissuing so the next guest can't read the previous one's
    // secrets.
    KeychainWipeGroupID(groupID);

    CFDictionaryRemoveValue(registry, (__bridge CFStringRef)bundleID);

    CFMutableArrayRef freeList = NULL;
    CFArrayRef existingFree = CFDictionaryGetValue(registry, CFSTR("free_list"));
    if (existingFree && CFGetTypeID(existingFree) == CFArrayGetTypeID()) {
        freeList = CFArrayCreateMutableCopy(NULL, 0, existingFree);
    } else {
        freeList = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    }
    CFNumberRef freeNum = CFNumberCreate(NULL, kCFNumberIntType, &groupID);
    CFArrayAppendValue(freeList, freeNum);
    CFRelease(freeNum);
    CFDictionarySetValue(registry, CFSTR("free_list"), freeList);
    CFRelease(freeList);

    saveRegistry(registry);
    CFRelease(registry);

    releaseSlotLock(lockFD);
    [keychainRegistryLock() unlock];
}

// Deletes every keychain item tagged with the given slot's access group.
void KeychainWipeGroupID(int groupID) {
    if (groupID < 0 || groupID > MAX_KEYCHAIN_GROUP_ID) return;

    NSString *teamID = getTeamIdentifier();
    if (!teamID) return;
    NSString *hostID = currentHostAppID();
    if (!hostID) return;
    NSString *group = nil;
    if (groupID == 0) {
        group = [NSString stringWithFormat:@"%@.%@.shared", teamID, hostID];
    } else {
        group = [NSString stringWithFormat:@"%@.%@.shared.%d", teamID, hostID, groupID];
    }

    NSArray *classes = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassCertificate,
        (__bridge id)kSecClassKey,
    ];
    for (id cls in classes) {
        NSDictionary *query = @{
            (__bridge id)kSecClass: cls,
            (__bridge id)kSecAttrAccessGroup: group,
            (__bridge id)kSecUseDataProtectionKeychain: @YES,
        };
        SecItemDelete((__bridge CFDictionaryRef)query);
        // errSecItemNotFound just means an empty slot; deletes are best-effort.
    }
}

// Current slot number for a bundle ID, or nil when it never acquired one.
NSNumber* KeychainGroupIDForBundleID(NSString* bundleID) {
    if (bundleID.length == 0) return nil;
    [keychainRegistryLock() lock];
    CFMutableDictionaryRef registry = copyRegistry();
    CFNumberRef assigned = CFDictionaryGetValue(registry, (__bridge CFStringRef)bundleID);
    CFNumberRef retained = assigned ? (CFNumberRef)CFRetain(assigned) : NULL;
    CFRelease(registry);
    [keychainRegistryLock() unlock];
    if (!retained) return nil;
    int groupID = 0;
    CFNumberGetValue(retained, kCFNumberIntType, &groupID);
    CFRelease(retained);
    return @(groupID);
}

#pragma mark - Guest hooks

OSStatus new_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    NSMutableDictionary *attributesCopy = ((__bridge NSDictionary *)attributes).mutableCopy;
    attributesCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    // for keychain deletion in LCUI
    attributesCopy[@"alis"] = containerId;
    
    OSStatus status = orig_SecItemAdd((__bridge CFDictionaryRef)attributesCopy, result);
    if(status == errSecParam) {
        return orig_SecItemAdd(attributes, result);
    }
    
    return status;
}

OSStatus new_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    NSMutableDictionary *queryCopy = ((__bridge NSDictionary *)query).mutableCopy;
    queryCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    OSStatus status = orig_SecItemCopyMatching((__bridge CFDictionaryRef)queryCopy, result);
    if(status == errSecParam) {
        // if this search don't support kSecAttrAccessGroup, we just use the original search
        return orig_SecItemCopyMatching(query, result);
    }
    
    return status;
}

OSStatus new_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    NSMutableDictionary *queryCopy = ((__bridge NSDictionary *)query).mutableCopy;
    queryCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    
    NSMutableDictionary *attrCopy = ((__bridge NSDictionary *)attributesToUpdate).mutableCopy;
    attrCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;

    OSStatus status = orig_SecItemUpdate((__bridge CFDictionaryRef)queryCopy, (__bridge CFDictionaryRef)attrCopy);

    if(status == errSecParam) {
        return orig_SecItemUpdate(query, attributesToUpdate);
    }
    
    return status;
}

OSStatus new_SecItemDelete(CFDictionaryRef query){
    NSMutableDictionary *queryCopy = ((__bridge NSDictionary *)query).mutableCopy;
    queryCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    OSStatus status = orig_SecItemDelete((__bridge CFDictionaryRef)queryCopy);
    if(status == errSecParam) {
        // if this query doesn't support kSecAttrAccessGroup, retry unmodified
        return orig_SecItemDelete(query);
    }
    
    return status;
}

SecKeyRef new_SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    NSMutableDictionary *paramsCopy = ((__bridge NSDictionary *)parameters).mutableCopy;
    paramsCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    SecKeyRef key = orig_SecKeyCreateRandomKey((__bridge CFDictionaryRef)paramsCopy, error);
    if(!key && error && *error) {
        CFRelease(*error);
        *error = NULL;
        key = orig_SecKeyCreateRandomKey(parameters, error);
    }
    
    return key;
}

SecKeyRef new_SecKeyCreateWithData(CFDataRef keyData, CFDictionaryRef parameters, CFErrorRef *error) {
    NSMutableDictionary *paramsCopy = ((__bridge NSDictionary *)parameters).mutableCopy;
    paramsCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    SecKeyRef key = orig_SecKeyCreateWithData(keyData, (__bridge CFDictionaryRef)paramsCopy, error);
    if(!key && error && *error) {
        CFRelease(*error);
        *error = NULL;
        key = orig_SecKeyCreateWithData(keyData, parameters, error);
    }
    
    return key;
}

OSStatus new_SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    NSMutableDictionary *queryCopy = ((__bridge NSDictionary *)parameters).mutableCopy;
    queryCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    OSStatus status = orig_SecKeyGeneratePair((__bridge CFDictionaryRef)queryCopy, publicKey, privateKey);
    if(status == errSecParam) {
        return orig_SecKeyGeneratePair(parameters, publicKey, privateKey);
    }
    
    return status;
}

void SecItemGuestHooksInit(NSString* hostId, NSString* groupId)  {
    containerId = [NSString stringWithUTF8String:getenv("HOME")].lastPathComponent;
    KeychainSetHostBundleID(hostId);

    int keychainGroupId = 0;
    NSString *acquireError = nil;
    if (!KeychainAcquireGroupID(groupId, &keychainGroupId, &acquireError)) {
        // Fall back to the default access group rather than breaking the launch.
        NSLog(@"Keychain slot acquisition failed for %@: %@; using default access group", groupId, acquireError);
        return;
    }
    accessGroup = [NSString stringWithFormat:@"%@.%@.shared.%d", getTeamIdentifier(), hostId, keychainGroupId];

    NSLog(@"Keychain access group: %@", accessGroup);
    
    // check if the keychain access group is available
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: @"NonExistentKey",
        (__bridge id)kSecAttrService: @"NonExistentService",
        (__bridge id)kSecAttrAccessGroup: accessGroup,
        (__bridge id)kSecReturnData: @NO
    };
    
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, NULL);
    if(status == errSecMissingEntitlement) {
        NSLog(@"failed to access keychain access group %@", accessGroup);
        return;
    }
    
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemAdd, new_SecItemAdd, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemCopyMatching, new_SecItemCopyMatching, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemUpdate, new_SecItemUpdate, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemDelete, new_SecItemDelete, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyCreateRandomKey, new_SecKeyCreateRandomKey, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyCreateWithData, new_SecKeyCreateWithData, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyGeneratePair, new_SecKeyGeneratePair, nil);
}
