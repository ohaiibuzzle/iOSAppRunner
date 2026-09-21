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
        // Sane defaults when the launcher never wrote the file.
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

/// Mirrors Mac Catalyst's UIRequiresFullScreen semantics: apps that don't
/// require full screen get a resizable window; others get a fixed one.
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

// Swizzling UIWindowScene.setDelegate: never fires (UIKit connects scene
// delegates on an internal path); react to UIWindowDidBecomeKeyNotification
// instead (same workaround as PlayCover).
static const void *kAppliedMarkerKey = &kAppliedMarkerKey;

static void ApplyDisplayFixups(UIWindow *window) {
    UIWindowScene *scene = window.windowScene;
    if (!scene) {
        return;
    }
    // Once per scene; repeat notifications must not re-fight a user resize.
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
            // Lock to the reported display size so it can't drift from
            // what UIScreen reports.
            CGSize fixedSize = CurrentDisplayMetrics(gHostHomeDirectory).pointSize;
            restrictions.minimumSize = fixedSize;
            restrictions.maximumSize = fixedSize;
        }
    }

    // Size restrictions only bound future resizing; for a locked window,
    // explicitly request the real geometry so frame restoration doesn't win.
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
