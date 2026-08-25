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

// Legacy version-min load commands. Older prebuilt frameworks/dylibs encode
// their target OS with these instead of LC_BUILD_VERSION; define fallbacks in
// case a given SDK header omits any of them.
#ifndef LC_VERSION_MIN_MACOSX
#define LC_VERSION_MIN_MACOSX 0x24
#endif
#ifndef LC_VERSION_MIN_IPHONEOS
#define LC_VERSION_MIN_IPHONEOS 0x25
#endif
#ifndef LC_VERSION_MIN_TVOS
#define LC_VERSION_MIN_TVOS 0x2F
#endif
#ifndef LC_VERSION_MIN_WATCHOS
#define LC_VERSION_MIN_WATCHOS 0x30
#endif

#define MP_SWAP32(x) __builtin_bswap32(x)

static uint32_t encode_version(uint32_t major, uint32_t minor) {
    return ((major & 0xFFFF) << 16) | ((minor & 0xFF) << 8);
}

static bool is_version_min_cmd(uint32_t cmd) {
    return cmd == LC_VERSION_MIN_IPHONEOS ||
           cmd == LC_VERSION_MIN_MACOSX ||
           cmd == LC_VERSION_MIN_TVOS ||
           cmd == LC_VERSION_MIN_WATCHOS;
}

// Rewrites a single thin Mach-O slice so its target platform becomes
// Mac Catalyst. Any existing LC_BUILD_VERSION is patched in place; a legacy
// LC_VERSION_MIN_* command is converted into an LC_BUILD_VERSION (which is 8
// bytes larger), growing the load-command region and shifting the commands
// that follow it into the header padding that precedes the first section.
//
// The load commands are rebuilt in memory and written back in one shot, so no
// section data ever moves and no other file offsets need adjusting. If the
// slice has neither a build-version nor a version-min command (nothing we can
// retarget), or if there isn't enough header padding to grow into, the slice
// is left untouched and *outFoundMissing is set so the caller can warn.
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

    size_t header_size;
    uint32_t ncmds, sizeofcmds;
    if (magic == MH_MAGIC_64) {
        struct mach_header_64 hdr;
        if (pread(fd, &hdr, sizeof(hdr), slice_offset) != sizeof(hdr)) {
            return -1;
        }
        header_size = sizeof(hdr);
        ncmds = hdr.ncmds;
        sizeofcmds = hdr.sizeofcmds;
    } else if (magic == MH_MAGIC) {
        struct mach_header hdr;
        if (pread(fd, &hdr, sizeof(hdr), slice_offset) != sizeof(hdr)) {
            return -1;
        }
        header_size = sizeof(hdr);
        ncmds = hdr.ncmds;
        sizeofcmds = hdr.sizeofcmds;
    } else {
        // Unknown slice magic - not a thin Mach-O we can patch.
        return -1;
    }

    // Sanity-bound the load-command region before allocating.
    if (sizeofcmds == 0 || sizeofcmds > (16u * 1024 * 1024)) {
        return -1;
    }

    off_t lc_offset = slice_offset + (off_t)header_size;
    uint8_t *lc = malloc(sizeofcmds);
    if (!lc) {
        return -1;
    }
    if (pread(fd, lc, sizeofcmds, lc_offset) != (ssize_t)sizeofcmds) {
        free(lc);
        return -1;
    }

    // First pass: validate the command stream and record the lowest non-zero
    // section file offset, which bounds how far the load commands may grow.
    uint64_t minSectionOffset = UINT64_MAX;
    uint32_t off = 0;
    for (uint32_t i = 0; i < ncmds; i++) {
        if (off + sizeof(struct load_command) > sizeofcmds) {
            free(lc);
            return -1;
        }
        struct load_command *cmd = (struct load_command *)(lc + off);
        if (cmd->cmdsize < sizeof(struct load_command) ||
            off + cmd->cmdsize > sizeofcmds) {
            free(lc);
            return -1;
        }
        if (cmd->cmd == LC_SEGMENT_64 &&
            cmd->cmdsize >= sizeof(struct segment_command_64)) {
            struct segment_command_64 *seg = (struct segment_command_64 *)(lc + off);
            struct section_64 *sects = (struct section_64 *)(lc + off + sizeof(*seg));
            for (uint32_t s = 0; s < seg->nsects; s++) {
                if (sects[s].offset != 0 && sects[s].offset < minSectionOffset) {
                    minSectionOffset = sects[s].offset;
                }
            }
        } else if (cmd->cmd == LC_SEGMENT &&
                   cmd->cmdsize >= sizeof(struct segment_command)) {
            struct segment_command *seg = (struct segment_command *)(lc + off);
            struct section *sects = (struct section *)(lc + off + sizeof(*seg));
            for (uint32_t s = 0; s < seg->nsects; s++) {
                if (sects[s].offset != 0 && sects[s].offset < minSectionOffset) {
                    minSectionOffset = sects[s].offset;
                }
            }
        }
        off += cmd->cmdsize;
    }

    // Second pass: rebuild the load commands. Converting a version-min command
    // grows it by 8 bytes, so allow that much slack per command in the buffer.
    uint8_t *out = malloc((size_t)sizeofcmds + (size_t)ncmds * 8 + 8);
    if (!out) {
        free(lc);
        return -1;
    }
    uint32_t outLen = 0;
    bool setPlatform = false;
    off = 0;
    for (uint32_t i = 0; i < ncmds; i++) {
        struct load_command *cmd = (struct load_command *)(lc + off);
        uint32_t cmd_id = cmd->cmd;
        uint32_t cmd_sz = cmd->cmdsize;

        if (cmd_id == LC_BUILD_VERSION &&
            cmd_sz >= sizeof(struct build_version_command)) {
            // Preserve the existing command (including any tool entries) and
            // only overwrite the platform/version fields.
            memcpy(out + outLen, lc + off, cmd_sz);
            struct build_version_command *dst =
                (struct build_version_command *)(out + outLen);
            dst->platform = platform;
            dst->minos = minos;
            dst->sdk = sdk;
            outLen += cmd_sz;
            setPlatform = true;
        } else if (is_version_min_cmd(cmd_id)) {
            struct build_version_command bv;
            memset(&bv, 0, sizeof(bv));
            bv.cmd = LC_BUILD_VERSION;
            bv.cmdsize = sizeof(struct build_version_command); // ntools == 0
            bv.platform = platform;
            bv.minos = minos;
            bv.sdk = sdk;
            bv.ntools = 0;
            memcpy(out + outLen, &bv, sizeof(bv));
            outLen += sizeof(bv);
            setPlatform = true;
        } else {
            memcpy(out + outLen, lc + off, cmd_sz);
            outLen += cmd_sz;
        }
        off += cmd_sz;
    }

    free(lc);

    if (!setPlatform) {
        // Nothing to retarget on this slice.
        free(out);
        if (outFoundMissing) {
            *outFoundMissing = true;
        }
        return 0;
    }

    // If the region grew, make sure it still fits before the first section's
    // file data. This nearly always holds (binaries carry ample header
    // padding), but refuse to write rather than clobber section content.
    if (outLen > sizeofcmds && minSectionOffset != UINT64_MAX &&
        (uint64_t)header_size + outLen > minSectionOffset) {
        NSLog(@"[machopatcher] not enough header padding to expand load commands "
              @"(need %llu bytes, first section at %llu); slice left as-is",
              (unsigned long long)((uint64_t)header_size + outLen),
              (unsigned long long)minSectionOffset);
        free(out);
        if (outFoundMissing) {
            *outFoundMissing = true;
        }
        return 0;
    }

    // Write the rebuilt commands. When the region grew, the extra bytes land in
    // what was previously header padding; section data is untouched.
    if (pwrite(fd, out, outLen, lc_offset) != (ssize_t)outLen) {
        free(out);
        return -1;
    }
    free(out);

    if (outLen != sizeofcmds) {
        // ncmds is unchanged (one command in, one command out); only the
        // aggregate size grew.
        if (magic == MH_MAGIC_64) {
            struct mach_header_64 hdr;
            if (pread(fd, &hdr, sizeof(hdr), slice_offset) != sizeof(hdr)) {
                return -1;
            }
            hdr.sizeofcmds = outLen;
            if (pwrite(fd, &hdr, sizeof(hdr), slice_offset) != sizeof(hdr)) {
                return -1;
            }
        } else {
            struct mach_header hdr;
            if (pread(fd, &hdr, sizeof(hdr), slice_offset) != sizeof(hdr)) {
                return -1;
            }
            hdr.sizeofcmds = outLen;
            if (pwrite(fd, &hdr, sizeof(hdr), slice_offset) != sizeof(hdr)) {
                return -1;
            }
        }
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
        NSLog(@"[machopatcher] %s: at least one slice carried no LC_BUILD_VERSION or LC_VERSION_MIN_* command (or lacked header padding to grow), so its platform was left unchanged.", path);
        // Caller can decide; treat as soft failure.
        return 1;
    }
    return rc;
}

// Reads the filetype of the first Mach-O slice at fd, transparently stepping
// into a fat container. Returns 0 (which is not a valid Mach-O filetype) if the
// file is not a Mach-O we recognise.
static uint32_t macho_first_slice_filetype(int fd) {
    uint32_t magic = 0;
    if (pread(fd, &magic, sizeof(magic), 0) != sizeof(magic)) {
        return 0;
    }

    off_t sliceOffset = 0;
    if (magic == FAT_CIGAM || magic == FAT_CIGAM_64) {
        struct fat_header fh;
        if (pread(fd, &fh, sizeof(fh), 0) != sizeof(fh)) {
            return 0;
        }
        if (MP_SWAP32(fh.nfat_arch) == 0) {
            return 0;
        }
        if (magic == FAT_CIGAM_64) {
            struct fat_arch_64 fa;
            if (pread(fd, &fa, sizeof(fa), sizeof(struct fat_header)) != sizeof(fa)) {
                return 0;
            }
            sliceOffset = (off_t)__builtin_bswap64(fa.offset);
        } else {
            struct fat_arch fa;
            if (pread(fd, &fa, sizeof(fa), sizeof(struct fat_header)) != sizeof(fa)) {
                return 0;
            }
            sliceOffset = (off_t)MP_SWAP32(fa.offset);
        }
        if (pread(fd, &magic, sizeof(magic), sliceOffset) != sizeof(magic)) {
            return 0;
        }
    }

    if (magic == MH_MAGIC_64) {
        struct mach_header_64 hdr;
        if (pread(fd, &hdr, sizeof(hdr), sliceOffset) != sizeof(hdr)) {
            return 0;
        }
        return hdr.filetype;
    } else if (magic == MH_MAGIC) {
        struct mach_header hdr;
        if (pread(fd, &hdr, sizeof(hdr), sliceOffset) != sizeof(hdr)) {
            return 0;
        }
        return hdr.filetype;
    }
    return 0;
}

int macho_is_loadable_image(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        return 0;
    }
    uint32_t filetype = macho_first_slice_filetype(fd);
    close(fd);
    // MH_DYLIB covers frameworks and .dylibs (and the dylibified main
    // executable); MH_BUNDLE covers loadable plug-in bundles. These are the
    // images dyld maps and whose platform must match the host.
    return (filetype == MH_DYLIB || filetype == MH_BUNDLE) ? 1 : 0;
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
        if (strcmp(name, "com.apple.macl") != 0 &&
            removexattr(path, name, XATTR_NOFOLLOW) != 0 && errno != ENOATTR) {
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

// Appends an LC_RPATH load command to a single thin Mach-O slice at
// slice_offset, unless an identical rpath command is already present.
// The new command is written at the end of the load-command region, growing
// into the header padding that precedes the first section (same technique as
// patch_slice). Returns 0 on success, -1 on failure.
static int add_rpath_to_slice(int fd, off_t slice_offset, const char *rpath) {
    uint32_t magic;
    if (pread(fd, &magic, sizeof(magic), slice_offset) != sizeof(magic)) {
        return -1;
    }

    size_t header_size;
    uint32_t ncmds, sizeofcmds;
    if (magic == MH_MAGIC_64) {
        struct mach_header_64 hdr;
        if (pread(fd, &hdr, sizeof(hdr), slice_offset) != sizeof(hdr)) {
            return -1;
        }
        header_size = sizeof(hdr);
        ncmds = hdr.ncmds;
        sizeofcmds = hdr.sizeofcmds;
    } else if (magic == MH_MAGIC) {
        struct mach_header hdr;
        if (pread(fd, &hdr, sizeof(hdr), slice_offset) != sizeof(hdr)) {
            return -1;
        }
        header_size = sizeof(hdr);
        ncmds = hdr.ncmds;
        sizeofcmds = hdr.sizeofcmds;
    } else {
        return -1;
    }

    if (sizeofcmds == 0 || sizeofcmds > (16u * 1024 * 1024)) {
        return -1;
    }

    off_t lc_offset = slice_offset + (off_t)header_size;
    uint8_t *lc = malloc(sizeofcmds);
    if (!lc) {
        return -1;
    }
    if (pread(fd, lc, sizeofcmds, lc_offset) != (ssize_t)sizeofcmds) {
        free(lc);
        return -1;
    }

    // Walk the commands: find the first section's file offset (bounds how
    // far we can grow) and check whether the rpath already exists.
    uint64_t minSectionOffset = UINT64_MAX;
    bool alreadyPresent = false;
    uint32_t off = 0;
    for (uint32_t i = 0; i < ncmds; i++) {
        if (off + sizeof(struct load_command) > sizeofcmds) {
            free(lc);
            return -1;
        }
        struct load_command *cmd = (struct load_command *)(lc + off);
        if (cmd->cmdsize < sizeof(struct load_command) ||
            off + cmd->cmdsize > sizeofcmds) {
            free(lc);
            return -1;
        }
        if (cmd->cmd == LC_RPATH && cmd->cmdsize >= sizeof(struct rpath_command)) {
            struct rpath_command *rp = (struct rpath_command *)(lc + off);
            if (rp->path.offset < cmd->cmdsize &&
                strcmp((const char *)lc + off + rp->path.offset, rpath) == 0) {
                alreadyPresent = true;
            }
        } else if (cmd->cmd == LC_SEGMENT_64 &&
                   cmd->cmdsize >= sizeof(struct segment_command_64)) {
            struct segment_command_64 *seg = (struct segment_command_64 *)(lc + off);
            struct section_64 *sects = (struct section_64 *)(lc + off + sizeof(*seg));
            for (uint32_t s = 0; s < seg->nsects; s++) {
                if (sects[s].offset != 0 && sects[s].offset < minSectionOffset) {
                    minSectionOffset = sects[s].offset;
                }
            }
        } else if (cmd->cmd == LC_SEGMENT &&
                   cmd->cmdsize >= sizeof(struct segment_command)) {
            struct segment_command *seg = (struct segment_command *)(lc + off);
            struct section *sects = (struct section *)(lc + off + sizeof(*seg));
            for (uint32_t s = 0; s < seg->nsects; s++) {
                if (sects[s].offset != 0 && sects[s].offset < minSectionOffset) {
                    minSectionOffset = sects[s].offset;
                }
            }
        }
        off += cmd->cmdsize;
    }
    free(lc);

    if (alreadyPresent) {
        return 0;
    }

    // Build the new LC_RPATH command.
    uint32_t pathLen = (uint32_t)strlen(rpath) + 1;
    uint32_t rpathCmdSize = (uint32_t)(sizeof(struct rpath_command) + pathLen);
    bool is64 = (magic == MH_MAGIC_64);
    rpathCmdSize = (rpathCmdSize + (is64 ? 7u : 3u)) & ~(is64 ? 7u : 3u);

    uint64_t newLen = (uint64_t)sizeofcmds + rpathCmdSize;
    if (minSectionOffset != UINT64_MAX &&
        (uint64_t)header_size + newLen > minSectionOffset) {
        NSLog(@"[machopatcher] not enough header padding to add LC_RPATH to "
              @"slice at offset %lld; left as-is",
              (long long)slice_offset);
        return -1;
    }

    // Write the rpath command into the padding after the existing commands.
    uint8_t *rp = calloc(1, rpathCmdSize);
    if (!rp) {
        return -1;
    }
    struct rpath_command *rpc = (struct rpath_command *)rp;
    rpc->cmd = LC_RPATH;
    rpc->cmdsize = rpathCmdSize;
    rpc->path.offset = (uint32_t)sizeof(struct rpath_command);
    memcpy(rp + sizeof(struct rpath_command), rpath, pathLen);

    off_t writePos = lc_offset + (off_t)sizeofcmds;
    if (pwrite(fd, rp, rpathCmdSize, writePos) != (ssize_t)rpathCmdSize) {
        free(rp);
        return -1;
    }
    free(rp);

    // Bump ncmds and sizeofcmds in the header.
    if (is64) {
        struct mach_header_64 hdr;
        if (pread(fd, &hdr, sizeof(hdr), slice_offset) != sizeof(hdr)) {
            return -1;
        }
        hdr.ncmds += 1;
        hdr.sizeofcmds += rpathCmdSize;
        if (pwrite(fd, &hdr, sizeof(hdr), slice_offset) != sizeof(hdr)) {
            return -1;
        }
    } else {
        struct mach_header hdr;
        if (pread(fd, &hdr, sizeof(hdr), slice_offset) != sizeof(hdr)) {
            return -1;
        }
        hdr.ncmds += 1;
        hdr.sizeofcmds += rpathCmdSize;
        if (pwrite(fd, &hdr, sizeof(hdr), slice_offset) != sizeof(hdr)) {
            return -1;
        }
    }
    return 0;
}

int macho_add_rpath(const char *path, const char *rpath) {
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

    int rc = 0;
    if (magic == FAT_CIGAM || magic == FAT_CIGAM_64) {
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
            if (add_rpath_to_slice(fd, (off_t)archOffset, rpath) != 0) {
                rc = -1; break;
            }
        }
    } else if (magic == MH_MAGIC || magic == MH_MAGIC_64) {
        rc = add_rpath_to_slice(fd, 0, rpath);
    } else {
        NSLog(@"[machopatcher] not a Mach-O: %s (magic=0x%x)", path, magic);
        rc = -1;
    }

    close(fd);
    return rc;
}


