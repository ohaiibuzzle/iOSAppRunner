#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Resolution.h"

static void Swizzle(Class class, SEL originalSelector, SEL swizzledSelector) {
    Method originalMethod = class_getInstanceMethod(class, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(class, swizzledSelector);
    if (originalMethod && swizzledMethod) {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    }
}

#pragma mark - Resolution
static NSString *const kDisplayResolutionFileName = @"display_resolution.plist";

typedef struct {
    CGSize pointSize;   // UIScreen.bounds size — the launcher's measured content area, in points
    CGSize pixelSize;   // UIScreen.nativeBounds size — in native pixels
    CGFloat scale;
    CGRect systemFrame; // AppKit screen-space outer window frame (title bar + content),
                        // for requestGeometryUpdateWithPreferences: — sizeRestrictions alone
                        // only *bounds* a window, it doesn't move/resize one Mac Catalyst
                        // already placed via its own frame restoration.
} GuestDisplayMetrics;

static GuestDisplayMetrics CurrentDisplayMetrics(NSString *hostHomeDirectory) {
    static GuestDisplayMetrics metrics;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = [hostHomeDirectory stringByAppendingPathComponent:kDisplayResolutionFileName];
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        CGFloat width = [dict[@"width"] doubleValue];
        CGFloat height = [dict[@"height"] doubleValue];
        CGFloat scale = [dict[@"scale"] doubleValue];
        CGFloat frameX = [dict[@"frameX"] doubleValue];
        CGFloat frameY = [dict[@"frameY"] doubleValue];
        CGFloat frameWidth = [dict[@"frameWidth"] doubleValue];
        CGFloat frameHeight = [dict[@"frameHeight"] doubleValue];
        // Fall back to a sane default if the launcher never wrote this file
        // (e.g. a very first run), rather than reporting a zero-sized screen.
        if (width <= 0 || height <= 0) {
            width = 1512;
            height = 954;
        }
        if (scale <= 0) {
            scale = 2.0;
        }
        if (frameWidth <= 0 || frameHeight <= 0) {
            frameWidth = width;
            frameHeight = height;
        }
        metrics.pointSize = CGSizeMake(width, height);
        metrics.scale = scale;
        metrics.pixelSize = CGSizeMake(width * scale, height * scale);
        metrics.systemFrame = CGRectMake(frameX, frameY, frameWidth, frameHeight);
    });
    return metrics;
}

/// Whether the guest declares support for a resizable window, mirroring Mac
/// Catalyst's own `UIRequiresFullScreen` semantics: apps that opt out of
/// requiring full screen get a resizable window; apps that don't specify (or
/// explicitly require full screen) get a fixed-size, locked window.
static BOOL GuestWindowShouldBeResizable(void) {
    NSNumber *requiresFullScreen = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UIRequiresFullScreen"];
    if (requiresFullScreen == nil) {
        return NO;
    }
    return ![requiresFullScreen boolValue];
}

static NSString *gHostHomeDirectory;

@interface UIScreen (Hooks)
@end

@implementation UIScreen (Hooks)

- (CGRect)hooked_bounds {
    CGSize size = CurrentDisplayMetrics(gHostHomeDirectory).pointSize;
    return CGRectMake(0, 0, size.width, size.height);
}

- (CGRect)hooked_nativeBounds {
    CGSize size = CurrentDisplayMetrics(gHostHomeDirectory).pixelSize;
    return CGRectMake(0, 0, size.width, size.height);
}

- (CGFloat)hooked_scale {
    return CurrentDisplayMetrics(gHostHomeDirectory).scale;
}

- (CGFloat)hooked_nativeScale {
    return CurrentDisplayMetrics(gHostHomeDirectory).scale;
}

@end

// Swizzling `UIWindowScene.setDelegate:` (the original approach here) turned
// out to never actually fire for scene-native guests: UIKit connects a
// scene's delegate through an internal path that doesn't dispatch through
// the public `setDelegate:` selector, so a swizzle on it silently never
// runs. PlayCover hits the same wall and works around it by reacting to
// `UIWindow.didBecomeKeyNotification` instead — a plain NSNotification,
// guaranteed to fire, unlike a swizzle on an internal-dispatch method.
static const void *kAppliedMarkerKey = &kAppliedMarkerKey;

static void ApplyDisplayFixups(UIWindow *window) {
    UIWindowScene *scene = window.windowScene;
    if (!scene) {
        return;
    }
    // Only needs to run once per scene; guard against repeat
    // didBecomeKeyNotification firings (e.g. the user switching back to
    // this window later) re-fighting a user-initiated resize.
    if (objc_getAssociatedObject(scene, kAppliedMarkerKey)) {
        return;
    }
    objc_setAssociatedObject(scene, kAppliedMarkerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    BOOL resizable = GuestWindowShouldBeResizable();

    UISceneSizeRestrictions *restrictions = scene.sizeRestrictions;
    if (restrictions) {
        if (resizable) {
            restrictions.minimumSize = CGSizeZero;
            restrictions.maximumSize = CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX);
        } else {
            // Lock the window to the Mac's actual display resolution so it
            // can't be resized away from what we report via UIScreen.
            CGSize fixedSize = CurrentDisplayMetrics(gHostHomeDirectory).pointSize;
            restrictions.minimumSize = fixedSize;
            restrictions.maximumSize = fixedSize;
        }
    }

    // Size restrictions only *bound* future resizing — they don't retroactively
    // move/resize a window Mac Catalyst already placed via its own frame
    // restoration (e.g. inheriting wherever the launcher's window last sat).
    // For a locked window, explicitly request the real geometry so it actually
    // opens at the Mac's display resolution instead of that inherited frame.
    if (!resizable) {
        CGRect targetFrame = CurrentDisplayMetrics(gHostHomeDirectory).systemFrame;
        if (!CGRectIsEmpty(targetFrame)) {
            if (@available(iOS 16.0, *)) {
                if ([scene respondsToSelector:@selector(requestGeometryUpdateWithPreferences:errorHandler:)]) {
                    UIWindowSceneGeometryPreferencesMac *preferences =
                        [[UIWindowSceneGeometryPreferencesMac alloc] initWithSystemFrame:targetFrame];
                    [scene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError *error) {
                        if (error) {
                            NSLog(@"[Resolution] requestGeometryUpdateWithPreferences failed: %@", error);
                        }
                    }];
                }
            }
        }
    }
}

void DisplayHooksInit(NSString *hostHomeDirectory) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gHostHomeDirectory = [hostHomeDirectory copy];
        Swizzle([UIScreen class], @selector(bounds), @selector(hooked_bounds));
        Swizzle([UIScreen class], @selector(nativeBounds), @selector(hooked_nativeBounds));
        Swizzle([UIScreen class], @selector(scale), @selector(hooked_scale));
        Swizzle([UIScreen class], @selector(nativeScale), @selector(hooked_nativeScale));

        [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
                                                            object:nil
                                                             queue:[NSOperationQueue mainQueue]
                                                        usingBlock:^(NSNotification *note) {
            if ([note.object isKindOfClass:[UIWindow class]]) {
                ApplyDisplayFixups((UIWindow *)note.object);
            }
        }];
    });
}
