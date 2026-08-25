//
//  WindowHooks.m
//  iOSAppRunner
//
//  Catalyst requires a UIWindow to belong to a UIWindowScene before any of its
//  content is presented. Legacy iOS guests build their window the classic way
//  (`[[UIWindow alloc] initWith...]` + `makeKeyAndVisible`), which yields an
//  orphan window with no scene — the process shows an empty window. We attach
//  the guest's window to the real UIWindowScene so its content actually renders.
//
//  The scene owns one host placeholder window (created by GuestSceneDelegate)
//  so the scene is never empty; the moment a distinctly guest window is shown,
//  the placeholder is demoted so it can't sit blank on top of real content.
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

/// Called by the scene delegate once a real UIWindowScene exists. Any guest
/// window that was created & shown *before* the scene connected (a race in the
/// scene lifecycle) is attached to the scene now. Returns the first adopted
/// guest window so the caller can skip creating a placeholder.
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

    // A real guest window just came up: put our blank placeholder to bed so it
    // can't cover the guest's content.
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