//
//  MachOPatcher.h
//  iOSAppRunner
//
//  Minimal Mach-O / filesystem helpers used by the on-device install
//  pipeline to replace the convert.sh steps that previously relied on
//  the macOS-only `vtool` and `xattr` command line tools.
//

#ifndef MachOPatcher_h
#define MachOPatcher_h

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Sets `LC_BUILD_VERSION` (where present, in every Mach-O slice) of the
/// file at @c path to Mac Catalyst @c minosX.minosY / @c sdkX.sdkY.
/// Returns 0 on success and a negative value on failure. Slices that
/// only have `LC_VERSION_MIN_*` instead of `LC_BUILD_VERSION` are
/// reported via the return code but the rest of the file is still
/// patched; the caller can decide whether to treat that as fatal.
int macho_set_maccatalyst_build_version(const char *path,
                                        uint32_t minosX, uint32_t minosY,
                                        uint32_t sdkX, uint32_t sdkY);

/// Recursively strips extended attributes from @c path. Returns 0 on
/// success, negative on failure.
int strip_xattrs_recursive(const char *path);

#ifdef __cplusplus
}
#endif

#endif /* MachOPatcher_h */
