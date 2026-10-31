//
//  Dylibifier.m
//  iOSAppRunner
//
//  Host copy of the dylibify routine from the standalone dylibify CLI tool
//  by Jake James; kept logically equivalent for install-time conversion.
//

#import "Dylibifier.h"

#import <Foundation/Foundation.h>

#import <mach-o/loader.h>
#import <mach-o/swap.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DLB_SWAP32(p) __builtin_bswap32(p)

// Patches one 64-bit thin slice at slice_offset: MH_EXECUTE -> MH_DYLIB,
// __PAGEZERO remapped, LC_ID_DYLIB appended. Segment indices are unchanged,
// so the dyld bind/rebase opcodes need no edits. Nothing is written unless
// the new command fits in the header padding.
static int patch_slice(FILE *file, off_t slice_offset, const char *name) {
    struct mach_header_64 mh;
    fseeko(file, slice_offset, SEEK_SET);
    if (fread(&mh, sizeof(mh), 1, file) != 1 || mh.magic != MH_MAGIC_64) {
        NSLog(@"[dylibify] unrecognised magic 0x%x", mh.magic);
        return -1;
    }
    if (mh.sizeofcmds == 0 || mh.sizeofcmds > (16u * 1024 * 1024)) {
        NSLog(@"[dylibify] bad sizeofcmds %u", mh.sizeofcmds);
        return -1;
    }

    uint32_t idPathLen = (uint32_t)(strlen("@executable_path/") + strlen(name) + 1);
    uint32_t idSize = (uint32_t)((sizeof(struct dylib_command) + idPathLen + 7) & ~7u);

    uint8_t *lc = calloc(1, (size_t)mh.sizeofcmds + idSize);
    if (!lc || fread(lc, mh.sizeofcmds, 1, file) != 1) {
        free(lc);
        return -1;
    }

    uint64_t minSectionOffset = UINT64_MAX;
    uint32_t off = 0;
    for (uint32_t i = 0; i < mh.ncmds; i++) {
        struct load_command *cmd = (struct load_command *)(lc + off);
        if (mh.sizeofcmds - off < sizeof(*cmd) || cmd->cmdsize < sizeof(*cmd) ||
            cmd->cmdsize > mh.sizeofcmds - off) {
            NSLog(@"[dylibify] malformed load command %u", i);
            free(lc);
            return -1;
        }
        if (cmd->cmd == LC_SEGMENT_64 && cmd->cmdsize >= sizeof(struct segment_command_64)) {
            struct segment_command_64 *seg = (struct segment_command_64 *)cmd;
            if (!strcmp(seg->segname, "__PAGEZERO")) {
                seg->vmaddr = 0xFFFFC000;
                seg->vmsize = 0x4000;
            }
            uint32_t nsects = (cmd->cmdsize - sizeof(*seg)) / sizeof(struct section_64);
            struct section_64 *sects = (struct section_64 *)(seg + 1);
            for (uint32_t s = 0; s < seg->nsects && s < nsects; s++) {
                if (sects[s].offset != 0 && sects[s].offset < minSectionOffset) {
                    minSectionOffset = sects[s].offset;
                }
            }
        }
        off += cmd->cmdsize;
    }

    if (minSectionOffset != UINT64_MAX &&
        (uint64_t)sizeof(mh) + off + idSize > minSectionOffset) {
        NSLog(@"[dylibify] not enough header padding to add LC_ID_DYLIB to %s", name);
        free(lc);
        return -1;
    }

    struct dylib_command *idCmd = (struct dylib_command *)(lc + off);
    idCmd->cmd = LC_ID_DYLIB;
    idCmd->cmdsize = idSize;
    idCmd->dylib.name.offset = sizeof(struct dylib_command);
    idCmd->dylib.timestamp = 1;
    snprintf((char *)idCmd + sizeof(*idCmd), idPathLen, "@executable_path/%s", name);

    mh.filetype = MH_DYLIB;
    mh.flags |= MH_NO_REEXPORTED_DYLIBS;
    mh.ncmds += 1;
    mh.sizeofcmds += idSize;

    fseeko(file, slice_offset, SEEK_SET);
    int ok = fwrite(&mh, sizeof(mh), 1, file) == 1 && fwrite(lc, mh.sizeofcmds, 1, file) == 1;
    free(lc);
    return ok ? 0 : -1;
}

int dylibify(const char *macho, const char *saveto) {
    NSError *error = nil;
    NSFileManager *fileManager = [NSFileManager defaultManager];

    if ([fileManager fileExistsAtPath:@(saveto)]) {
        NSLog(@"[dylibify] destination already exists: %s", saveto);
        return -1;
    }

    [fileManager copyItemAtPath:@(macho) toPath:@(saveto) error:&error];
    if (error) {
        NSLog(@"[dylibify] copy failed: %@", error);
        return -1;
    }

    FILE *file = fopen(saveto, "r+b");
    if (!file) {
        NSLog(@"[dylibify] could not open destination for writing: %s", saveto);
        return -1;
    }

    const char *name = [[@(saveto) lastPathComponent] UTF8String];
    int rc = 0;
    uint32_t magic = 0;
    if (fread(&magic, sizeof(magic), 1, file) != 1) {
        rc = -1;
    } else if (magic == 0xBEBAFECA) {
        struct fat_header fat;
        fseeko(file, 0, SEEK_SET);
        if (fread(&fat, sizeof(fat), 1, file) != 1) {
            rc = -1;
        }
        uint32_t n = rc ? 0 : DLB_SWAP32(fat.nfat_arch);
        for (uint32_t i = 0; i < n && rc == 0; i++) {
            struct fat_arch arch;
            fseeko(file, sizeof(fat) + (off_t)i * sizeof(arch), SEEK_SET);
            if (fread(&arch, sizeof(arch), 1, file) != 1) {
                rc = -1;
                break;
            }
            rc = patch_slice(file, DLB_SWAP32(arch.offset), name);
        }
    } else {
        rc = patch_slice(file, 0, name);
    }

    fclose(file);
    return rc;
}
