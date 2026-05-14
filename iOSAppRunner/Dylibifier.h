//
//  Dylibifier.h
//  iOSAppRunner
//
//  Reusable copy of the dylibify routine. Converts an MH_EXECUTE Mach-O
//  into an MH_DYLIB so it can be dlopen()'d as a library.
//

#ifndef Dylibifier_h
#define Dylibifier_h

#ifdef __cplusplus
extern "C" {
#endif

/// Reads the Mach-O at @c macho, writes a dylibified copy to @c saveto.
/// Returns 0 on success and a negative value on failure. @c saveto must
/// not already exist.
int dylibify(const char *macho, const char *saveto);

#ifdef __cplusplus
}
#endif

#endif /* Dylibifier_h */
