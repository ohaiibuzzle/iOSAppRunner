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

/// Returns whether `feature` is enabled for the given guest bundle. Missing
/// key (or a missing manifest) evaluates to YES, so a guest with no manifest
/// keeps the legacy always-on behavior.
FOUNDATION_EXPORT BOOL LoaderIsFeatureEnabled(NSBundle *appBundle, NSString *feature);

NS_ASSUME_NONNULL_END
