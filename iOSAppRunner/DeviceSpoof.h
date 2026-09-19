//
//  DeviceSpoof.h
//  iOSAppRunner
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Presents the Mac as a (configurable) iOS device — an iPad by default — to
/// guest apps that fingerprint the hardware through sysctl.
///
/// Covered call paths:
///   * `sysctlbyname("hw.machine")` / `("hw.model")` — what virtually every app uses
///   * `sysctl({CTL_HW, HW_MACHINE|HW_MODEL})` — the MIB-based variant
///   * `sysctlbyname("kern.osproductversion")` — only when an override is set,
///     so guests that expect an iOS version (e.g. "17.5.1") get one
///
/// Values come from the guest's `RunnerFeatures.plist` (`spoofDeviceMachine`,
/// `spoofDeviceModel`, `spoofDeviceOSVersion`); missing values fall back to the
/// built-in iPad defaults. `appBundle` is the guest bundle whose manifest
/// should be consulted.
void DeviceSpoofHooksInit(NSBundle *appBundle);

/// Re-apply the litehook rebinds. Images loaded *after* `DeviceSpoofHooksInit`
/// (i.e. the dlopen'ed guest executable and its frameworks) bind their sysctl
/// imports to the real implementation at load time, so this must run once more
/// after the guest dlopen, before any guest code executes.
void DeviceSpoofRebindLoadedImages(void);

NS_ASSUME_NONNULL_END
