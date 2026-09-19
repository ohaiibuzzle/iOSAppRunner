//
//  Loader.m
//  iOSAppRunner
//

#import "Loader.h"

NSString *const LoaderFeatureScene                = @"scene";
NSString *const LoaderFeatureGroupContainer       = @"groupContainer";
NSString *const LoaderFeatureResolution           = @"resolution";
NSString *const LoaderFeatureKeychain             = @"keychain";
NSString *const LoaderFeatureDeviceSpoof          = @"deviceSpoof";

NSString *const LoaderSpoofKeyMachine             = @"spoofDeviceMachine";
NSString *const LoaderSpoofKeyModel               = @"spoofDeviceModel";
NSString *const LoaderSpoofKeyOSVersion           = @"spoofDeviceOSVersion";

static NSDictionary *FeaturesForBundle(NSBundle *bundle) {
    static NSString *gBundlePath;
    static NSDictionary *gFeatures;

    NSString *path = bundle.bundlePath;
    if (gBundlePath && [gBundlePath isEqualToString:path]) {
        return gFeatures;
    }

    gBundlePath = [path copy];
    gFeatures = [NSDictionary dictionaryWithContentsOfFile:
                 [path stringByAppendingPathComponent:@"RunnerFeatures.plist"]];
    return gFeatures;
}

BOOL LoaderIsFeatureEnabled(NSBundle *appBundle, NSString *feature) {
    NSDictionary *features = FeaturesForBundle(appBundle);
    id value = features[feature];
    // Missing manifest or missing key = enabled (legacy always-on behavior).
    if (value == nil) {
        return YES;
    }
    return [value boolValue];
}

NSString * _Nullable LoaderSpoofValue(NSBundle *appBundle, NSString *key) {
    NSDictionary *features = FeaturesForBundle(appBundle);
    id value = features[key];
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
        return value;
    }
    return nil;
}
