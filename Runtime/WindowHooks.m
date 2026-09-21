//
//  WindowHooks.m
//  iOSAppRunner
//

#import "WindowHooks.h"
#import <objc/runtime.h>

static UIWindowScene *gGuestWindowScene;
static UIWindow        *gPlaceholderWindow;
static UIWindow        *gLastGuestWindow;

void SetGuestWindowScene(void *scene) {
    gGuestWindowScene = (__bridge UIWindowScene *)scene;
}

void SetGuestPlaceholderWindow(void *window) {
    gPlaceholderWindow = (__bridge UIWindow *)window;
}

/// Attaches scene-less guest windows to the scene once it exists; returns
/// the first adopted window so the caller can skip a placeholder.
UIWindow *GuestAdoptSceneLessWindows(void) {
    UIWindowScene *scene = gGuestWindowScene;
    if (!scene) {
        return nil;
    }
    UIWindow *guest = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.windowScene == nil && w != gPlaceholderWindow) {
            w.windowScene = scene;
            if (!guest) {
                guest = w;
            }
        }
    }
    // Last-chance: a window tracked by the hook but not yet in `windows`.
    if (!guest && gLastGuestWindow && gLastGuestWindow.windowScene == nil) {
        gLastGuestWindow.windowScene = scene;
        guest = gLastGuestWindow;
    }
    if (guest) {
        NSLog(@"[WindowHooks] adopted guest window %@ onto scene %@", guest, scene);
    }
    return guest;
}

static void WindowSwizzle(Class cls, SEL original, SEL swapped) {
    Method origMethod = class_getInstanceMethod(cls, original);
    Method swizzledMethod = class_getInstanceMethod(cls, swapped);
    if (origMethod && swizzledMethod) {
        method_exchangeImplementations(origMethod, swizzledMethod);
    }
}

static UIWindowScene *CurrentGuestScene(void) {
    if (gGuestWindowScene) {
        return gGuestWindowScene;
    }
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.session.role == UIWindowSceneSessionRoleApplication) {
            return scene;
        }
    }
    return nil;
}

@implementation UIWindow (AppWindowHooks)

- (void)hooked_makeKeyAndVisible {
    BOOL wasSceneLess = (self.windowScene == nil);
    if (wasSceneLess) {
        gLastGuestWindow = self;
        UIWindowScene *scene = CurrentGuestScene();
        if (scene) {
            self.windowScene = scene;
        }
    }
    [self hooked_makeKeyAndVisible];

    if (wasSceneLess) {
        NSLog(@"[WindowHooks] makeKeyAndVisible attached window %@ to scene %@",
              self, self.windowScene);
    }

    // Hide our placeholder so it can't cover the guest's content.
    UIWindow *placeholder = gPlaceholderWindow;
    if (placeholder && placeholder != self && !placeholder.isHidden) {
        placeholder.hidden = YES;
        NSLog(@"[WindowHooks] hid placeholder %@ because guest window %@ shown", placeholder, self);
    }
}

@end

void GuestWindowHooksInit(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        WindowSwizzle([UIWindow class],
                       @selector(makeKeyAndVisible),
                       @selector(hooked_makeKeyAndVisible));
    });
}
