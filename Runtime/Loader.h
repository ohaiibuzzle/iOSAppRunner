//
//  Loader.h
//  iOSAppRunner
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const LoaderFeatureScene;
FOUNDATION_EXPORT NSString *const LoaderFeatureGroupContainer;
FOUNDATION_EXPORT NSString *const LoaderFeatureResolution;
FOUNDATION_EXPORT NSString *const LoaderFeatureKeychain;
FOUNDATION_EXPORT NSString *const LoaderFeatureDeviceSpoof;
FOUNDATION_EXPORT NSString *const LoaderSpoofKeyMachine;   // hw.machine (e.g. "iPad14,6")
FOUNDATION_EXPORT NSString *const LoaderSpoofKeyModel;     // hw.model (defaults to machine)
FOUNDATION_EXPORT NSString *const LoaderSpoofKeyOSVersion; // kern.osproductversion (optional)

/// Returns whether `feature` is enabled for the given guest bundle. Missing
/// key (or a missing manifest) evaluates to YES, so a guest with no manifest
/// keeps the legacy always-on behavior.
FOUNDATION_EXPORT BOOL LoaderIsFeatureEnabled(NSBundle *appBundle, NSString *feature);

/// Returns a non-empty string override from the guest's RunnerFeatures.plist,
/// or nil when the key is missing/empty (so the caller can use its default).
FOUNDATION_EXPORT NSString * _Nullable LoaderSpoofValue(NSBundle *appBundle, NSString *key);

NS_ASSUME_NONNULL_END
