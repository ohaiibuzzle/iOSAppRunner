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

@interface UIScreen (Hooks)
@end

@implementation UIScreen (Hooks)

- (CGRect)hooked_bounds {
    return CGRectMake(0, 0, 3000, 2000);
}

- (CGRect)hooked_nativeBounds {
    return CGRectMake(0, 0, 3000, 2000);
}

- (CGFloat)hooked_scale {
    return 2.0;
}

- (CGFloat)hooked_nativeScale {
    return 2.0;
}

@end

@interface UIWindowScene (Hooks)
@end

@implementation UIWindowScene (Hooks)

- (void)hooked_setDelegate:(id)delegate {
    [self hooked_setDelegate:delegate];
    
    if ([self respondsToSelector:NSSelectorFromString(@"sizeRestrictions")]) {
        id restrictions = [self valueForKey:@"sizeRestrictions"];
        if (restrictions) {
            // 3000x2000 pixels at 2.0 scale = 1500x1000 points
            CGSize fixedSize = CGSizeMake(1500, 1000);
            [restrictions setValue:[NSValue valueWithCGSize:fixedSize] forKey:@"minimumSize"];
            [restrictions setValue:[NSValue valueWithCGSize:fixedSize] forKey:@"maximumSize"];
        }
    }
}

@end

void DisplayHooksInit(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Swizzle([UIScreen class], @selector(bounds), @selector(hooked_bounds));
        Swizzle([UIScreen class], @selector(nativeBounds), @selector(hooked_nativeBounds));
        Swizzle([UIScreen class], @selector(scale), @selector(hooked_scale));
        Swizzle([UIScreen class], @selector(nativeScale), @selector(hooked_nativeScale));
        
        Swizzle([UIWindowScene class], @selector(setDelegate:), @selector(hooked_setDelegate:));
    });
}
