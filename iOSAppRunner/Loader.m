//
//  Loader.m
//  iOSAppRunner
//

#import "Loader.h"

NSString *const LoaderFeatureScene                = @"scene";
NSString *const LoaderFeatureGroupContainer       = @"groupContainer";
NSString *const LoaderFeatureResolution           = @"resolution";
NSString *const LoaderFeatureKeychain             = @"keychain";

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
