//
//  main.m
//  BaseiOSApp
//
//  Created by Venti on 22/2/26.
//

#import <UIKit/UIKit.h>
#import "LCDyld.h"
#import "hooks.h"
#import "utils.h"
#import "Keychain.h"
#import <dlfcn.h>
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>
#import <signal.h>
#import <fcntl.h>
#import <sys/file.h>
#import "Resolution.h"
#import "GroupContainer.h"
#import "WindowHooks.h"
#import "DeviceSpoof.h"
#import "Loader.h"

@import MachO;

// NSProcessInfo's private arguments setter, for giving the guest a clean argv.
@interface NSProcessInfo (PrivateArguments)
- (void)setArguments:(NSArray<NSString *> *)arguments;
@end

int appMainImageIndex = 0;
void* appExecutableHandle;

static void *getAppEntryPoint(void *handle) {
    uint64_t entryoff = 0;
    const struct mach_header_64 *header = (struct mach_header_64 *)getGuestAppHeader();
    uint8_t *imageHeaderPtr = (uint8_t*)header + sizeof(struct mach_header_64);
    struct load_command *command = (struct load_command *)imageHeaderPtr;
    for(int i = 0; i < header->ncmds; ++i) {
        if(command->cmd == LC_MAIN) {
            struct entry_point_command ucmd = *(struct entry_point_command *)imageHeaderPtr;
            entryoff = ucmd.entryoff;
            break;
        }
        imageHeaderPtr += command->cmdsize;
        command = (struct load_command *)imageHeaderPtr;
    }
    assert(entryoff > 0);
    return (void *)header + entryoff;
}

#if TARGET_OS_IPHONE && !TARGET_OS_MACCATALYST
// The library-validation bypass and guest JIT need the debugger flag, so
// the iOS runtime stops itself here (--wait-for-host or
// BASEIOSAPP_WAIT_FOR_DEBUGGER=1) until the host attaches and detaches.
static void waitForDebugger(void) {
    NSLog(@"[wait-for-host] Stopping pid %d, waiting for the host to attach (library-validation bypass/JIT require a debugger)", getpid());
    kill(getpid(), SIGSTOP);
    NSLog(@"[wait-for-host] Host attached and detached, resuming");
}

static BOOL shouldWaitForHost(int argc, char *argv[]) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--wait-for-host") == 0) {
            return YES;
        }
    }
    return getenv("BASEIOSAPP_WAIT_FOR_DEBUGGER") != NULL;
}
#endif

static NSString *appToLaunchFromArgv(int argc, char *argv[]) {
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], "--launch-app") == 0) {
            return [NSString stringWithUTF8String:argv[i + 1]];
        }
    }
    return nil;
}

// Host pre-assigned keychain slot (--keychain-slot); -1 for legacy launches.
static int keychainSlotFromArgv(int argc, char *argv[]) {
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], "--keychain-slot") == 0) {
            return atoi(argv[i + 1]);
        }
    }
    return -1;
}

// Flock held for the process lifetime; the host probes it (non-blocking)
// before migrating a guest. Kernel-released on process death.
//
// Returns the held fd, or -1 when the guest is already running.
static int acquireGuestLock(NSString *guestHomeDir) {
    static int lockFD = -1;
    NSString *lockPath = [guestHomeDir stringByAppendingPathComponent:@".guest.lock"];
    int fd = open(lockPath.fileSystemRepresentation, O_RDWR | O_CREAT, 0644);
    if (fd < 0) {
        NSLog(@"[runtime] could not open guest lock %@: %s", lockPath, strerror(errno));
        return -1;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        NSLog(@"[runtime] guest %@ is already running; refusing double launch", guestHomeDir.lastPathComponent);
        close(fd);
        return -1;
    }
    // Deliberately never closed: the lock must outlive main().
    lockFD = fd;
    return lockFD;
}

// Backward compatibility: a plain app_to_launch.txt request file in the
// runtime's home (shared container Data directory).
static NSString *appToLaunchFromFile(void) {
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"app_to_launch.txt"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return nil;
    }
    NSString *name = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return name.length > 0 ? name : nil;
}

int main(int argc, char * argv[]) {
#if TARGET_OS_IPHONE && !TARGET_OS_MACCATALYST
    // Spill the container marker (our bundle ID) so the host can find
    // this UUID-named container back.
    {
        NSString *marker = [NSHomeDirectory() stringByAppendingPathComponent:@".baseiosapp-runtime"];
        NSString *identifier = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        [identifier writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    // Stop before ANY work so the host can attach before guest dylibs load.
    if (shouldWaitForHost(argc, argv)) {
        waitForDebugger();
    }
#endif

    NSString *appBundleName = appToLaunchFromArgv(argc, argv) ?: appToLaunchFromFile();
    int keychainSlot = keychainSlotFromArgv(argc, argv);

    NSString *appBundlePath = nil;
    if (appBundleName.length > 0) {
        NSString *candidate = [NSHomeDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"apps/%@", appBundleName]];
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate isDirectory:&isDir] && isDir) {
            appBundlePath = candidate;
        } else {
            NSLog(@"[runtime] Requested app bundle missing at %@", candidate);
        }
    }

    // Headless runtime: no selection UI, the host app is the only launcher.
    if (!appBundlePath) {
        NSLog(@"[runtime] No valid launch request (--launch-app <installName>); exiting");
        return 1;
    }

    // Access-group base is shared across flavors (Info.plist
    // KeychainAccessGroupBase); capture bundle ID + HOME before the guest
    // rewrites them below.
    NSString *hostAppIdentifier = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"KeychainAccessGroupBase"];
    if (hostAppIdentifier.length == 0) {
        hostAppIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    }
    NSString *hostHomeDirectory = NSHomeDirectory();

    KeychainSetHostBundleID(hostAppIdentifier);
    KeychainSetHostHome(hostHomeDirectory);
    KeychainSetAssignedSlot(keychainSlot);

    // Load the App.app bundle from [shared container Data]/apps/[app bundle name]
    NSBundle *appBundle = [NSBundle bundleWithPath:appBundlePath];

    NSLog(@"%@", [NSString stringWithFormat:@"Bundle loaded %@", appBundle.bundleIdentifier]);
    init_bypassDyldLibValidation();

    const char **path = _CFGetProcessPath();
        const char *appExecPath = appBundle.executablePath.fileSystemRepresentation;
    *path = appExecPath;
    overwriteExecPath(appExecPath);

    // Create a new HOME for guest app inside the runtime's shared container
    NSString *homeDir = NSHomeDirectory();
    NSString *guestHomeDir = [homeDir stringByAppendingPathComponent:appBundle.bundleIdentifier];
    if (![[NSFileManager defaultManager] fileExistsAtPath:guestHomeDir]) {
        NSError *error = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:guestHomeDir withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            NSLog(@"Failed to create guest home directory: %@", error);
        } else {            NSLog(@"Successfully created guest home directory at %@", guestHomeDir);
        }
    }

    // Single instance per guest (see acquireGuestLock).
    if (acquireGuestLock(guestHomeDir) < 0) {
        return 2;
    }

    setenv("HOME", guestHomeDir.UTF8String, 1);
    setenv("CFFIXED_USER_HOME", guestHomeDir.UTF8String, 1);

    NSArray *dirList = @[@"Library/Caches", @"Library/Cookies", @"Documents", @"SystemData"];
    for (NSString *dir in dirList) {
        NSString *dirPath = [guestHomeDir stringByAppendingPathComponent:dir];
        if (![[NSFileManager defaultManager] fileExistsAtPath:dirPath]) {
            NSError *error = nil;
            [[NSFileManager defaultManager] createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:&error];
            if (error) {
                NSLog(@"Failed to create directory %@: %@", dir, error);
            } else {
                NSLog(@"Successfully created directory at %@", dirPath);
            }
        }
    }

    overwriteMainNSBundle(appBundle);
    overwriteMainCFBundle();

    NSMutableArray<NSString *> *objcArgv = NSProcessInfo.processInfo.arguments.mutableCopy;
    // Strip the host's private --launch-app <name> and --keychain-slot <N>
    // tokens so the guest sees a clean argument list.
    for (NSString *flag in @[@"--launch-app", @"--keychain-slot"]) {
        NSUInteger flagIdx = [objcArgv indexOfObject:flag];
        if (flagIdx != NSNotFound) {
            NSUInteger len = MIN((NSUInteger)2, objcArgv.count - flagIdx);
            [objcArgv removeObjectsInRange:NSMakeRange(flagIdx, len)];
        }
    }
    objcArgv[0] = appBundle.executablePath;
    [NSProcessInfo.processInfo setArguments:objcArgv];
    NSProcessInfo.processInfo.processName = appBundle.infoDictionary[@"CFBundleExecutable"];
    *_CFGetProgname() = NSProcessInfo.processInfo.processName.UTF8String;
    Class swiftNSProcessInfo = NSClassFromString(@"_NSSwiftProcessInfo");
    if(swiftNSProcessInfo) {
        // Swizzle the arguments method to return the ObjC arguments
        SEL selector = @selector(arguments);
        method_setImplementation(class_getInstanceMethod(swiftNSProcessInfo, selector), class_getMethodImplementation(NSProcessInfo.class, selector));
    }

    // Backward-compat request file is consumed once read.
    [[NSFileManager defaultManager] removeItemAtPath:
     [hostHomeDirectory stringByAppendingPathComponent:@"app_to_launch.txt"] error:nil];

    if (appBundle) {
        NSLog(@"Successfully loaded app bundle");
        // dlopen app's main executable
        NSString *executablePath = [appBundle executablePath];
        if (executablePath) {
            // Get the entry point of the guest app
            appMainImageIndex = _dyld_image_count();
            hook_init(); // dyld-validation bypass is always needed to load the guest
            // No scene-manifest patching needed: the runner claims SDK 17.0
            // via -platform_version (OTHER_LDFLAGS), which makes UIKit
            // tolerant of no-scene guests.
            if (LoaderIsFeatureEnabled(appBundle, LoaderFeatureScene)) {
                GuestWindowHooksInit();
            }
#if TARGET_OS_MACCATALYST
            if (LoaderIsFeatureEnabled(appBundle, LoaderFeatureResolution)) {
                DisplayHooksInit(homeDir);
            }
#endif
            if (LoaderIsFeatureEnabled(appBundle, LoaderFeatureGroupContainer)) {
                GroupContainerHooksInit();
            }
            if (LoaderIsFeatureEnabled(appBundle, LoaderFeatureKeychain)) {
                SecItemGuestHooksInit(hostAppIdentifier, appBundle.bundleIdentifier);
            }
            if (LoaderIsFeatureEnabled(appBundle, LoaderFeatureDeviceSpoof)) {
                DeviceSpoofHooksInit(appBundle);
            }
            void *handle = dlopen(executablePath.UTF8String, RTLD_LAZY|RTLD_GLOBAL|RTLD_FIRST);
            appExecutableHandle = handle;
            if (handle) {
                // Re-run the rebind: the dlopened images' sysctl imports were
                // bound to the real implementation, and their GOTs must be
                // patched before any guest code runs.
                if (LoaderIsFeatureEnabled(appBundle, LoaderFeatureDeviceSpoof)) {
                    DeviceSpoofRebindLoadedImages();
                }
                int (*appMain)(int, char **) = (int (*)(int, char **))getAppEntryPoint(handle);
                NSLog(@"Successfully dlopened app's executable");
                GuestCryptidPatchInit();
                char *guestArgv[] = { (char *)[executablePath UTF8String], NULL };
                int retcode = appMain(1, guestArgv);
                NSLog(@"App exited with code %d", retcode);
                return retcode;
            } else {
                NSLog(@"Failed to dlopen app's executable: %s", dlerror());
            }
        } else {
            NSLog(@"Failed to load app bundle");
        }
    }
    NSLog(@"Failed to launch app");
    return 1;
}
