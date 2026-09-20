//
//  GroupContainer.m
//  BaseiOSApp
//

#import "GroupContainer.h"
#import <objc/runtime.h>

static void GroupSwizzle(Class cls, SEL original, SEL swapped) {
    Method origMethod = class_getInstanceMethod(cls, original);
    Method swizzledMethod = class_getInstanceMethod(cls, swapped);
    if (origMethod && swizzledMethod) {
        method_exchangeImplementations(origMethod, swizzledMethod);
    }
}

@implementation NSFileManager (GroupContainerHooks)

- (nullable NSURL *)hooked_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    if (groupIdentifier.length == 0) {
        return nil;
    }
    // Guest sandbox home: build a per-group directory we control.
    NSString *safeName = [groupIdentifier stringByReplacingOccurrencesOfString:@"/"
                                                                    withString:@"_"];
    NSString *dirPath = [[[NSHomeDirectory() stringByAppendingPathComponent:@"app-groups"]
        stringByAppendingPathComponent:safeName]
        stringByAppendingPathComponent:@""];

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dirPath isDirectory:&isDir] || !isDir) {
        NSError *error = nil;
        [fm createDirectoryAtPath:dirPath withIntermediateDirectories:YES
                        attributes:nil error:&error];
        if (error) {
            NSLog(@"[GroupContainer] could not create %@: %@", dirPath, error);
            return nil;
        }
    }
    return [NSURL fileURLWithPath:dirPath isDirectory:YES];
}

@end

void GroupContainerHooksInit(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = [NSFileManager class];
        Method orig = class_getInstanceMethod(cls,
            @selector(containerURLForSecurityApplicationGroupIdentifier:));
        if (!orig) {
            NSLog(@"[GroupContainer] original selector missing");
            return;
        }
        GroupSwizzle(cls,
            @selector(containerURLForSecurityApplicationGroupIdentifier:),
            @selector(hooked_containerURLForSecurityApplicationGroupIdentifier:));
        NSLog(@"[GroupContainer] interposed containerURLForSecurityApplicationGroupIdentifier:");
    });
}
