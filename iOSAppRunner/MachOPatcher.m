//
//  MachOPatcher.m
//  iOSAppRunner
//

#import "MachOPatcher.h"

#import <Foundation/Foundation.h>

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/xattr.h>
#include <unistd.h>
#include <dirent.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>

#include <mach-o/loader.h>
#include <mach-o/fat.h>

// Mach-O constants we use; PLATFORM_MACCATALYST may not be exposed by
// every SDK header, so define a fallback locally.
#ifndef PLATFORM_MACCATALYST
#define PLATFORM_MACCATALYST 6
#endif

#define MP_SWAP32(x) __builtin_bswap32(x)

static uint32_t encode_version(uint32_t major, uint32_t minor) {
    return ((major & 0xFFFF) << 16) | ((minor & 0xFF) << 8);
}

static int patch_slice(int fd,
                       off_t slice_offset,
                       uint32_t platform,
                       uint32_t minos,
                       uint32_t sdk,
                       bool *outFoundMissing) {
    uint32_t magic;
    if (pread(fd, &magic, sizeof(magic), slice_offset) != sizeof(magic)) {
        return -1;
    }

    bool is64;
    off_t lc_offset;
    uint32_t ncmds;
    if (magic == MH_MAGIC_64) {
        is64 = true;
        struct mach_header_64 hdr;
        if (pread(fd, &hdr, sizeof(hdr), slice_offset) != sizeof(hdr)) {
            return -1;
        }
        ncmds = hdr.ncmds;
        lc_offset = slice_offset + sizeof(hdr);
    } else if (magic == MH_MAGIC) {
        is64 = false;
        struct mach_header hdr;
        if (pread(fd, &hdr, sizeof(hdr), slice_offset) != sizeof(hdr)) {
            return -1;
        }
        ncmds = hdr.ncmds;
        lc_offset = slice_offset + sizeof(hdr);
    } else {
        // Unknown slice magic - not a thin Mach-O we can patch.
        return -1;
    }
    (void)is64;

    bool foundBuildVersion = false;
    off_t cursor = lc_offset;
    for (uint32_t i = 0; i < ncmds; i++) {
        struct load_command lc;
        if (pread(fd, &lc, sizeof(lc), cursor) != sizeof(lc)) {
            return -1;
        }
        if (lc.cmdsize < sizeof(lc)) {
            return -1;
        }
        if (lc.cmd == LC_BUILD_VERSION) {
            struct build_version_command bv;
            if (pread(fd, &bv, sizeof(bv), cursor) != sizeof(bv)) {
                return -1;
            }
            bv.platform = platform;
            bv.minos = minos;
            bv.sdk = sdk;
            // Keep the existing cmdsize and tool entries intact.
            if (pwrite(fd, &bv, sizeof(bv), cursor) != sizeof(bv)) {
                return -1;
            }
            foundBuildVersion = true;
        }
        cursor += lc.cmdsize;
    }

    if (!foundBuildVersion && outFoundMissing) {
        *outFoundMissing = true;
    }
    return 0;
}

int macho_set_maccatalyst_build_version(const char *path,
                                        uint32_t minosX, uint32_t minosY,
                                        uint32_t sdkX, uint32_t sdkY) {
    int fd = open(path, O_RDWR);
    if (fd < 0) {
        NSLog(@"[machopatcher] open failed: %s (%d)", path, errno);
        return -1;
    }

    uint32_t magic = 0;
    if (pread(fd, &magic, sizeof(magic), 0) != sizeof(magic)) {
        close(fd);
        return -1;
    }

    uint32_t platform = PLATFORM_MACCATALYST;
    uint32_t minos = encode_version(minosX, minosY);
    uint32_t sdk = encode_version(sdkX, sdkY);

    int rc = 0;
    bool missingBuildVersion = false;

    if (magic == FAT_CIGAM || magic == FAT_CIGAM_64) {
        // FAT (big-endian on disk for legacy magic 0xCAFEBABE).
        struct fat_header fh;
        if (pread(fd, &fh, sizeof(fh), 0) != sizeof(fh)) {
            close(fd);
            return -1;
        }
        uint32_t narch = MP_SWAP32(fh.nfat_arch);
        bool is64Fat = (magic == FAT_CIGAM_64);
        for (uint32_t i = 0; i < narch; i++) {
            uint64_t archOffset;
            if (is64Fat) {
                struct fat_arch_64 fa;
                off_t pos = sizeof(struct fat_header) + (off_t)i * sizeof(fa);
                if (pread(fd, &fa, sizeof(fa), pos) != sizeof(fa)) {
                    rc = -1; break;
                }
                archOffset = __builtin_bswap64(fa.offset);
            } else {
                struct fat_arch fa;
                off_t pos = sizeof(struct fat_header) + (off_t)i * sizeof(fa);
                if (pread(fd, &fa, sizeof(fa), pos) != sizeof(fa)) {
                    rc = -1; break;
                }
                archOffset = MP_SWAP32(fa.offset);
            }
            if (patch_slice(fd, (off_t)archOffset, platform, minos, sdk,
                            &missingBuildVersion) != 0) {
                rc = -1; break;
            }
        }
    } else if (magic == MH_MAGIC || magic == MH_MAGIC_64) {
        rc = patch_slice(fd, 0, platform, minos, sdk, &missingBuildVersion);
    } else {
        NSLog(@"[machopatcher] not a Mach-O: %s (magic=0x%x)", path, magic);
        rc = -1;
    }

    close(fd);

    if (rc == 0 && missingBuildVersion) {
        NSLog(@"[machopatcher] %s: at least one slice has no LC_BUILD_VERSION; the binary may use the legacy LC_VERSION_MIN_* and was not rewritten.", path);
        // Caller can decide; treat as soft failure.
        return 1;
    }
    return rc;
}

static int strip_xattrs_on_file(const char *path) {
    ssize_t size = listxattr(path, NULL, 0, XATTR_NOFOLLOW);
    if (size <= 0) {
        return 0;
    }
    char *names = malloc((size_t)size);
    if (!names) {
        return -1;
    }
    ssize_t read = listxattr(path, names, (size_t)size, XATTR_NOFOLLOW);
    if (read < 0) {
        free(names);
        return -1;
    }

    int rc = 0;
    ssize_t pos = 0;
    while (pos < read) {
        const char *name = names + pos;
        size_t len = strlen(name) + 1;
        if (removexattr(path, name, XATTR_NOFOLLOW) != 0 && errno != ENOATTR) {
            NSLog(@"[xattr] removexattr(%s, %s) failed: %d", path, name, errno);
            rc = -1;
        }
        pos += len;
    }
    free(names);
    return rc;
}

int strip_xattrs_recursive(const char *path) {
    struct stat st;
    if (lstat(path, &st) != 0) {
        return -1;
    }

    int rc = strip_xattrs_on_file(path);

    if (S_ISDIR(st.st_mode)) {
        DIR *dir = opendir(path);
        if (!dir) {
            return rc == 0 ? -1 : rc;
        }
        struct dirent *entry;
        while ((entry = readdir(dir)) != NULL) {
            if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
                continue;
            }
            char child[PATH_MAX];
            int n = snprintf(child, sizeof(child), "%s/%s", path, entry->d_name);
            if (n <= 0 || n >= (int)sizeof(child)) {
                continue;
            }
            if (strip_xattrs_recursive(child) != 0) {
                rc = -1;
            }
        }
        closedir(dir);
    }
    return rc;
}
