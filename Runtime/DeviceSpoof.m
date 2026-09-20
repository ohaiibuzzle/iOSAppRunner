//
//  DeviceSpoof.m
//  iOSAppRunner
//
// Hooks `sysctl` / `sysctlbyname` so guest hardware fingerprinting sees an
// iPad (or any other configurable device) instead of the Mac's real identity.
//

#import <sys/sysctl.h>
#import <string.h>
#import "DeviceSpoof.h"
#import "hooks.h"
#import "Loader.h"

// Capture the real libsystem_kernel implementations at image-load time —
// before any litehook rebind patches the GOTs — so the hooks can forward
// unspoofed queries (same trick as hooks.m's `orig_dlsym`).
static int (*real_sysctl)(int *, u_int, void *, size_t *, void *, size_t) = sysctl;
static int (*real_sysctlbyname)(const char *, void *, size_t *, void *, size_t) = sysctlbyname;

// Default identity: iPad Pro 12.9" (M2). Overridable per-app via
// RunnerFeatures.plist — see the LoaderSpoofKey* constants in Loader.h.
static NSString *gSpoofedMachine;   // "hw.machine"  (e.g. "iPad14,6")
static NSString *gSpoofedModel;     // "hw.model"    (defaults to machine)
static NSString *gSpoofedOSVersion; // "kern.osproductversion" (optional)

static const char *FallbackMachine = "iPad14,6";

/// Standard sysctl copy-out semantics for a string value: report the needed
/// size when oldp is NULL; otherwise copy (truncating to the caller's buffer)
/// including the NUL terminator when there is room.
static int CopySpoofValue(const char *value, void *oldp, size_t *oldlenp) {
    if (!value) {
        value = FallbackMachine;
    }
    size_t needed = strlen(value) + 1;

    if (oldp == NULL || (oldlenp && *oldlenp == 0)) {
        if (oldlenp) {
            *oldlenp = needed;
        }
        return 0;
    }
    size_t room = oldlenp ? *oldlenp : 0;
    size_t copied = (room < needed) ? room : needed;
    memcpy(oldp, value, copied);
    if (oldlenp) {
        *oldlenp = copied;
    }
    return 0;
}

/// On real iPads the MIB `HW_MACHINE` reports the device family ("iPad")
/// while `hw.machine` reports the exact model ("iPad14,6"). Derive the family
/// from the configured machine name (everything before the first comma).
static NSString *SpoofedMachineFamily(void) {
    NSString *machine = gSpoofedMachine;
    if (machine.length == 0) {
        return @"iPad";
    }
    NSRange comma = [machine rangeOfString:@","];
    if (comma.location != NSNotFound && comma.location > 0) {
        return [machine substringToIndex:comma.location];
    }
    return machine;
}

static int hook_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp,
                       void *newp, size_t newlen) {
    // Only spoof reads (newp == NULL) of hardware identity MIBs.
    if (name != NULL && namelen == 2 && newp == NULL && name[0] == CTL_HW) {
        if (name[1] == HW_MACHINE) {
            return CopySpoofValue(SpoofedMachineFamily().UTF8String, oldp, oldlenp);
        }
        if (name[1] == HW_MODEL) {
            return CopySpoofValue(gSpoofedModel.UTF8String ?: FallbackMachine, oldp, oldlenp);
        }
    }
    return real_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
}

static int hook_sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                             void *newp, size_t newlen) {
    if (name != NULL && newp == NULL) {
        if (strcmp(name, "hw.machine") == 0) {
            return CopySpoofValue(gSpoofedMachine.UTF8String ?: FallbackMachine, oldp, oldlenp);
        }
        if (strcmp(name, "hw.model") == 0) {
            return CopySpoofValue(gSpoofedModel.UTF8String ?: FallbackMachine, oldp, oldlenp);
        }
        if (gSpoofedOSVersion && strcmp(name, "kern.osproductversion") == 0) {
            return CopySpoofValue(gSpoofedOSVersion.UTF8String, oldp, oldlenp);
        }
    }
    return real_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

void DeviceSpoofRebindLoadedImages(void) {
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, real_sysctl, hook_sysctl, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, real_sysctlbyname, hook_sysctlbyname, nil);
}

void DeviceSpoofHooksInit(NSBundle *appBundle) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *machine = LoaderSpoofValue(appBundle, LoaderSpoofKeyMachine);
        gSpoofedMachine = machine.length > 0 ? [machine copy] : @"iPad14,6";

        NSString *model = LoaderSpoofValue(appBundle, LoaderSpoofKeyModel);
        gSpoofedModel = model.length > 0 ? [model copy] : gSpoofedMachine;

        NSString *osVersion = LoaderSpoofValue(appBundle, LoaderSpoofKeyOSVersion);
        gSpoofedOSVersion = osVersion.length > 0 ? [osVersion copy] : nil;

        NSLog(@"[DeviceSpoof] presenting as hw.machine=%@ hw.model=%@ os=%@",
              gSpoofedMachine, gSpoofedModel, gSpoofedOSVersion ?: @"(host value)");
    });
    DeviceSpoofRebindLoadedImages();
}
