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
#import "litehook/litehook.h"

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

int getGroupIDFromAccessGroup(NSString* accessGroup) {
    // Check if this ID is in NSUserDefaults, if not, generate a new one and save it to NSUserDefaults
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *groupIdKey = [NSString stringWithFormat:@"%@_group_id", accessGroup];
    NSNumber *groupIdNum = [defaults objectForKey:groupIdKey];
    if (groupIdNum) {
        return groupIdNum.intValue;
    } else {
        // Read the last group ID from NSUserDefaults, if not exist, start with 1
        NSString *lastGroupIdKey = [NSString stringWithFormat:@"%@_last_group_id", accessGroup];
        NSNumber *lastGroupIdNum = [defaults objectForKey:lastGroupIdKey];
        int newGroupId = lastGroupIdNum ? lastGroupIdNum.intValue + 1 : 1;
        [defaults setObject:@(newGroupId) forKey:groupIdKey];
        [defaults setObject:@(newGroupId) forKey:lastGroupIdKey];
        [defaults synchronize];
        return newGroupId;
    }
}

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
        return new_SecItemDelete(query);
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

void SecItemGuestHooksInit(NSString* groupId)  {
    containerId = [NSString stringWithUTF8String:getenv("HOME")].lastPathComponent;
    int keychainGroupId = getGroupIDFromAccessGroup(groupId);
    NSString* hostAppIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    if(keychainGroupId == 0) {
        accessGroup = [NSString stringWithFormat:@"%@.shared", hostAppIdentifier];
    } else {
        accessGroup = [NSString stringWithFormat:@"%@.shared.%d", hostAppIdentifier, keychainGroupId];
    }

    NSLog(@"[LC] Keychain access group: %@", accessGroup);
    
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
        NSLog(@"[LC] failed to access keychain access group %@", accessGroup);
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
