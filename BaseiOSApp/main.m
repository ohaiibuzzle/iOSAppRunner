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


@import MachO;
int appMainImageIndex = 0;
void* appExecutableHandle;

static void *getAppEntryPoint(void *handle) {
    uint32_t entryoff = 0;
    const struct mach_header_64 *header = (struct mach_header_64 *)getGuestAppHeader();
    uint8_t *imageHeaderPtr = (uint8_t*)header + sizeof(struct mach_header_64);
    struct load_command *command = (struct load_command *)imageHeaderPtr;
    for(int i = 0; i < header->ncmds > 0; ++i) {
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
    // Load the App.app bundle from app resources
    NSBundle *appBundle = [NSBundle bundleWithPath:[[NSBundle mainBundle] pathForResource:@"App" ofType:@"app"]];
    NSLog([NSString stringWithFormat:@"Bundle loaded %@", appBundle.bundleIdentifier]);
    init_bypassDyldLibValidation();
    
    const char **path = _CFGetProcessPath();
    const char *oldPath = *path;
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

    if (appBundle) {
        NSLog(@"Successfully loaded app bundle");
        // dlopen app's main executable
        NSString *executablePath = [appBundle executablePath];
        if (executablePath) {
            // Get the entry point of the guest app
            appMainImageIndex = _dyld_image_count();
            hook_init();
            SecItemGuestHooksInit(appBundle.bundleIdentifier);
            void *handle = dlopen(executablePath.UTF8String, RTLD_LAZY|RTLD_GLOBAL|RTLD_FIRST);
            appExecutableHandle = handle;
            if (handle) {
                int (*appMain)(int, char **) = (int (*)(int, char **))getAppEntryPoint(handle);
                NSLog(@"Successfully dlopened app's executable");
                argv[0] = (char *)[executablePath UTF8String];
                return appMain(argc, argv);
            } else {
                NSLog(@"Failed to dlopen app's executable: %s", dlerror());
            }
        } else {
            NSLog(@"Failed to load app bundle");
        }
    }
}
