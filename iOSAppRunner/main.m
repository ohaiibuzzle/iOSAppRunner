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
#import <unistd.h>
#import "Resolution.h"
#import "GroupContainer.h"
#import "WindowHooks.h"
#import "Loader.h"
#import "SceneLifecycleHook.h"

static int runHostLauncher(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, @"LauncherAppDelegate");
    }
}

// Atomically claim the oldest queued launch request written by the launcher
static NSString *claimPendingLaunch(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *pendingDir = [NSHomeDirectory() stringByAppendingPathComponent:@"pending_launch"];

    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:pendingDir error:nil];
    if (entries.count == 0) {
        return nil;
    }

    // Oldest request first, so launches are honored in order.
    NSArray<NSString *> *sorted = [entries sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDate *da = [fm attributesOfItemAtPath:[pendingDir stringByAppendingPathComponent:a] error:nil].fileModificationDate;
        NSDate *db = [fm attributesOfItemAtPath:[pendingDir stringByAppendingPathComponent:b] error:nil].fileModificationDate;
        return [da compare:db];
    }];

    for (NSString *name in sorted) {
        // Skip hidden files (including our own in-flight `.claimed-*` markers).
        if ([name hasPrefix:@"."] || ![name.pathExtension isEqualToString:@"txt"]) {
            continue;
        }
        NSString *src = [pendingDir stringByAppendingPathComponent:name];
        NSString *dst = [pendingDir stringByAppendingPathComponent:
                         [NSString stringWithFormat:@".claimed-%d-%@", getpid(), name]];
        if (rename(src.fileSystemRepresentation, dst.fileSystemRepresentation) != 0) {
            continue; // lost the race for this request; try the next one
        }
        NSString *bundleName = [[NSString stringWithContentsOfFile:dst encoding:NSUTF8StringEncoding error:nil]
                                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        unlink(dst.fileSystemRepresentation);
        if (bundleName.length > 0) {
            return bundleName;
        }
    }
    return nil;
}

@import MachO;
int appMainImageIndex = 0;
void* appExecutableHandle;

static void *getAppEntryPoint(void *handle) {
    uint32_t entryoff = 0;
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


int main(int argc, char * argv[]) {
    // Determine which app bundle to load. When the selection is missing or
    // invalid, fall through to the SwiftUI launcher (LauncherAppDelegate) so the
    // user can pick / import apps.
    NSError *error;
    NSString *appToLaunchPath = [NSHomeDirectory() stringByAppendingPathComponent:@"app_to_launch.txt"];
    NSString *appBundleName = nil;

    // Claim a queued launch request.
    appBundleName = claimPendingLaunch();

    // In case we pass --launch-app (for, eg. integration with PlayCover)
    if (appBundleName.length == 0) {
        for (int i = 1; i + 1 < argc; i++) {
            if (strcmp(argv[i], "--launch-app") == 0) {
                appBundleName = [NSString stringWithUTF8String:argv[i + 1]];
                break;
            }
        }
    }

    // 3. Backward-compat: fall back to app_to_launch.txt.
    if (appBundleName.length == 0 && [[NSFileManager defaultManager] fileExistsAtPath:appToLaunchPath]) {
        appBundleName = [NSString stringWithContentsOfFile:appToLaunchPath encoding:NSUTF8StringEncoding error:nil];
        appBundleName = [appBundleName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }

    NSString *appBundlePath = nil;
    if (appBundleName.length > 0) {
        NSString *candidate = [NSHomeDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"apps/%@", appBundleName]];
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate isDirectory:&isDir] && isDir) {
            appBundlePath = candidate;
        } else {
            NSLog(@"Selected app bundle missing at %@; showing launcher", candidate);
        }
    }

    if (!appBundlePath) {
        return runHostLauncher(argc, argv);
    }

    NSString *hostAppIdentifier = [[NSBundle mainBundle] bundleIdentifier];

    // Load the App.app bundle from [app sandbox data folder]/apps/[app bundle name]
    NSBundle *appBundle = [NSBundle bundleWithPath:appBundlePath];

    NSLog(@"%@", [NSString stringWithFormat:@"Bundle loaded %@", appBundle.bundleIdentifier]);
    init_bypassDyldLibValidation();
    
    const char **path = _CFGetProcessPath();
        const char *appExecPath = appBundle.executablePath.fileSystemRepresentation;
    *path = appExecPath;
    overwriteExecPath(appExecPath);

    // Create a new HOME for guest app inside the app's sandbox
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
    // Strip the launcher's private --launch-app <name> tokens so the guest sees
    // a clean argument list.
    NSUInteger launchFlagIdx = [objcArgv indexOfObject:@"--launch-app"];
    if (launchFlagIdx != NSNotFound) {
        NSUInteger len = MIN((NSUInteger)2, objcArgv.count - launchFlagIdx);
        [objcArgv removeObjectsInRange:NSMakeRange(launchFlagIdx, len)];
    }
    objcArgv[0] = appBundle.executablePath;
    [NSProcessInfo.processInfo performSelector:@selector(setArguments:) withObject:objcArgv];
    NSProcessInfo.processInfo.processName = appBundle.infoDictionary[@"CFBundleExecutable"];
    *_CFGetProgname() = NSProcessInfo.processInfo.processName.UTF8String;
    Class swiftNSProcessInfo = NSClassFromString(@"_NSSwiftProcessInfo");
    if(swiftNSProcessInfo) {
        // Swizzle the arguments method to return the ObjC arguments
        SEL selector = @selector(arguments);
        method_setImplementation(class_getInstanceMethod(swiftNSProcessInfo, selector), class_getMethodImplementation(NSProcessInfo.class, selector));
    }
    
    // Remove the indicator (so next launch we go back to the main UI)
    [[NSFileManager defaultManager] removeItemAtPath:appToLaunchPath error: &error];

    if (appBundle) {
        NSLog(@"Successfully loaded app bundle");
        // dlopen app's main executable
        NSString *executablePath = [appBundle executablePath];
        if (executablePath) {
            // Get the entry point of the guest app
            appMainImageIndex = _dyld_image_count();
            hook_init(); // dyld-validation bypass is always needed to load the guest
            SceneLifecycleHooksInit(); // Catalyst: don't fatally terminate guests with no scene manifest
            if (LoaderIsFeatureEnabled(appBundle, LoaderFeatureScene)) {
                GuestWindowHooksInit();
            }
            if (LoaderIsFeatureEnabled(appBundle, LoaderFeatureResolution)) {
                DisplayHooksInit();
            }
            if (LoaderIsFeatureEnabled(appBundle, LoaderFeatureGroupContainer)) {
                GroupContainerHooksInit();
            }
            if (LoaderIsFeatureEnabled(appBundle, LoaderFeatureKeychain)) {
                SecItemGuestHooksInit(hostAppIdentifier, appBundle.bundleIdentifier);
            }
            void *handle = dlopen(executablePath.UTF8String, RTLD_LAZY|RTLD_GLOBAL|RTLD_FIRST);
            appExecutableHandle = handle;
            if (handle) {
                int (*appMain)(int, char **) = (int (*)(int, char **))getAppEntryPoint(handle);
                NSLog(@"Successfully dlopened app's executable");
                // Hand the guest a clean argv (just its executable path) so our
                // private --launch-app tokens never leak into the guest process.
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
    [[NSFileManager defaultManager] removeItemAtPath:appToLaunchPath error: &error];
}

