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

static void *dlb_load_bytes(FILE *obj_file, off_t offset, size_t size) {
    void *buf = calloc(1, size);
    fseek(obj_file, offset, SEEK_SET);
    fread(buf, size, 1, obj_file);
    return buf;
}

static void dlb_write_bytes(FILE *obj_file, off_t offset, size_t size, void *bytes) {
    fseek(obj_file, offset, SEEK_SET);
    fwrite(bytes, size, 1, obj_file);
}

static void dlb_patch_mach_header(FILE *obj_file, off_t offset, void *mh, BOOL is64bit) {
    if (is64bit) {
        ((struct mach_header_64 *)mh)->filetype = MH_DYLIB;
        ((struct mach_header_64 *)mh)->flags |= MH_NO_REEXPORTED_DYLIBS;
        dlb_write_bytes(obj_file, offset, sizeof(struct mach_header_64), mh);
    } else {
        ((struct mach_header *)mh)->filetype = MH_DYLIB;
        ((struct mach_header *)mh)->flags |= MH_NO_REEXPORTED_DYLIBS;
        dlb_write_bytes(obj_file, offset, sizeof(struct mach_header), mh);
    }
}

static void dlb_append_dylib_id_command(FILE *obj_file,
                                        off_t header_offset,
                                        off_t cmds_end_offset,
                                        BOOL is64bit,
                                        const char *target) {
    uint32_t cmdsize = (uint32_t)(sizeof(struct dylib_command) +
                                  [@(target) lastPathComponent].length + 18);
    if (is64bit) {
        cmdsize = (cmdsize + 7) & ~7;
    } else {
        cmdsize = (cmdsize + 3) & ~3;
    }

    struct dylib_command *dylib_cmd = (struct dylib_command *)calloc(1, cmdsize);
    dylib_cmd->cmd = LC_ID_DYLIB;
    dylib_cmd->cmdsize = cmdsize;
    dylib_cmd->dylib.name.offset = sizeof(struct dylib_command);
    dylib_cmd->dylib.timestamp = 1;
    dylib_cmd->dylib.current_version = 0;
    dylib_cmd->dylib.compatibility_version = 0;

    strcpy(
        (char *)dylib_cmd + sizeof(struct dylib_command),
        ([[NSString stringWithFormat:@"@executable_path/%@",
                                     [@(target) lastPathComponent]] UTF8String]));

    dlb_write_bytes(obj_file, cmds_end_offset, cmdsize, dylib_cmd);
    free(dylib_cmd);

    if (is64bit) {
        struct mach_header_64 *mh =
            dlb_load_bytes(obj_file, header_offset, sizeof(struct mach_header_64));
        mh->ncmds += 1;
        mh->sizeofcmds += cmdsize;
        dlb_write_bytes(obj_file, header_offset, sizeof(struct mach_header_64), mh);
        free(mh);
    } else {
        struct mach_header *mh =
            dlb_load_bytes(obj_file, header_offset, sizeof(struct mach_header));
        mh->ncmds += 1;
        mh->sizeofcmds += cmdsize;
        dlb_write_bytes(obj_file, header_offset, sizeof(struct mach_header), mh);
        free(mh);
    }
}

static void dlb_patch_pagezero(FILE *obj_file,
                               off_t offset,
                               struct load_command *cmd,
                               BOOL copied,
                               void *seg,
                               size_t sizeofseg,
                               const char *target) {
    if (cmd->cmd == LC_SEGMENT_64) {
        struct segment_command_64 *seg64 = (struct segment_command_64 *)seg;
        seg64->vmaddr = 0xFFFFC000;
        seg64->vmsize = 0x4000;
    } else if (cmd->cmd == LC_SEGMENT) {
        struct segment_command *seg32 = (struct segment_command *)seg;
        seg32->vmaddr = 0xFFFFC000;
        seg32->vmsize = 0x4000;
    }
    dlb_write_bytes(obj_file, offset, sizeofseg, seg);
}

static void dlb_patch_dyldinfo(FILE *file,
                               off_t offset,
                               struct dyld_info_command *dyldinfo) {
    if (dyldinfo->rebase_off != 0) {
        for (int i = 0; i < (int)dyldinfo->rebase_size; i++) {
            uint8_t *bytes =
                dlb_load_bytes(file, offset + dyldinfo->rebase_off + i, sizeof(uint8_t));
            if ((*bytes & REBASE_OPCODE_MASK) ==
                REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB) {
                // __PAGEZERO is remapped (not removed), so segment indices are
                // unchanged and the opcodes must NOT be shifted. Decrementing
                // id shifts a valid __DATA(2) reference to __TEXT(1).
                free(bytes);
                break;
            }
            free(bytes);
        }
    }
    if (dyldinfo->bind_off != 0) {
        for (int i = 0; i < (int)dyldinfo->bind_size; i++) {
            uint8_t *bytes =
                dlb_load_bytes(file, offset + dyldinfo->bind_off + i, sizeof(uint8_t));
            switch (*bytes & BIND_OPCODE_MASK) {
                case BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB:
                    // __PAGEZERO remap keeps segment indices intact; do not
                    // shift __DATA(2) -> __TEXT(1) (non-writable).
                    dlb_write_bytes(file, offset + dyldinfo->bind_off + i,
                                    sizeof(uint8_t), bytes);
                    {
                        uint8_t *probe = dlb_load_bytes(file, offset + dyldinfo->bind_off + i, sizeof(uint8_t));
                        while (*probe != BIND_OPCODE_DO_BIND) {
                            i += 1;
                            free(probe);
                            probe = dlb_load_bytes(file, offset + dyldinfo->bind_off + i, sizeof(uint8_t));
                        }
                        free(probe);
                    }
                    break;
                case BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM:
                    while (*bytes != 0) {
                        i += 1;
                        free(bytes);
                        bytes = dlb_load_bytes(file, offset + dyldinfo->bind_off + i, sizeof(uint8_t));
                    }
                    break;
                case BIND_OPCODE_ADD_ADDR_ULEB:
                    while (*bytes != BIND_OPCODE_DO_BIND) {
                        i += 1;
                        free(bytes);
                        bytes = dlb_load_bytes(file, offset + dyldinfo->bind_off + i, sizeof(uint8_t));
                    }
                    break;
                default:
                    break;
            }
            free(bytes);
        }
    }
    if (dyldinfo->lazy_bind_off != 0) {
        for (int i = 0; i < (int)dyldinfo->lazy_bind_size; i++) {
            uint8_t *bytes =
                dlb_load_bytes(file, offset + dyldinfo->lazy_bind_off + i, sizeof(uint8_t));
            switch (*bytes & BIND_OPCODE_MASK) {
                case BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB:
                    // Segment indices unchanged (__PAGEZERO only remapped).
                    dlb_write_bytes(file, offset + dyldinfo->lazy_bind_off + i,
                                    sizeof(uint8_t), bytes);
                    {
                        uint8_t *probe = dlb_load_bytes(file, offset + dyldinfo->lazy_bind_off + i, sizeof(uint8_t));
                        while (*probe != BIND_OPCODE_DO_BIND) {
                            i += 1;
                            free(probe);
                            probe = dlb_load_bytes(file, offset + dyldinfo->lazy_bind_off + i, sizeof(uint8_t));
                        }
                        free(probe);
                    }
                    break;
                case BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM:
                    while (*bytes != 0) {
                        i += 1;
                        free(bytes);
                        bytes = dlb_load_bytes(file, offset + dyldinfo->lazy_bind_off + i, sizeof(uint8_t));
                    }
                    break;
                case BIND_OPCODE_ADD_ADDR_ULEB:
                    while (*bytes != BIND_OPCODE_DO_BIND) {
                        i += 1;
                        free(bytes);
                        bytes = dlb_load_bytes(file, offset + dyldinfo->lazy_bind_off + i, sizeof(uint8_t));
                    }
                    break;
                default:
                    break;
            }
            free(bytes);
        }
    }
    if (dyldinfo->weak_bind_off != 0) {
        for (int i = 0; i < (int)dyldinfo->weak_bind_size; i++) {
            uint8_t *bytes =
                dlb_load_bytes(file, offset + dyldinfo->weak_bind_off + i, sizeof(uint8_t));
            switch (*bytes & BIND_OPCODE_MASK) {
                case BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB:
                    // Segment indices unchanged (__PAGEZERO only remapped).
                    dlb_write_bytes(file, offset + dyldinfo->weak_bind_off + i,
                                    sizeof(uint8_t), bytes);
                    {
                        uint8_t *probe = dlb_load_bytes(file, offset + dyldinfo->weak_bind_off + i, sizeof(uint8_t));
                        while (*probe != BIND_OPCODE_DO_BIND) {
                            i += 1;
                            free(probe);
                            probe = dlb_load_bytes(file, offset + dyldinfo->weak_bind_off + i, sizeof(uint8_t));
                        }
                        free(probe);
                    }
                    break;
                case BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM:
                    while (*bytes != 0) {
                        i += 1;
                        free(bytes);
                        bytes = dlb_load_bytes(file, offset + dyldinfo->weak_bind_off + i, sizeof(uint8_t));
                    }
                    break;
                case BIND_OPCODE_ADD_ADDR_ULEB:
                    while (*bytes != BIND_OPCODE_DO_BIND) {
                        i += 1;
                        free(bytes);
                        bytes = dlb_load_bytes(file, offset + dyldinfo->weak_bind_off + i, sizeof(uint8_t));
                    }
                    break;
                default:
                    break;
            }
            free(bytes);
        }
    }
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

    int rc = 0;
    size_t offset = 0;
    BOOL copied = false;
    int ncmds = 0;
    struct load_command *cmd = NULL;
    uint32_t *magic = dlb_load_bytes(file, offset, sizeof(uint32_t));

    if (*magic == 0xFEEDFACF) {
        struct mach_header_64 *mh64 = dlb_load_bytes(file, offset, sizeof(struct mach_header_64));
        off_t header_offset = offset;
        dlb_patch_mach_header(file, offset, mh64, true);
        offset += sizeof(struct mach_header_64);
        ncmds = mh64->ncmds;
        free(mh64);

        for (int i = 0; i < ncmds; i++) {
            cmd = dlb_load_bytes(file, offset, sizeof(struct load_command));
            if (cmd->cmd == LC_SEGMENT_64) {
                struct segment_command_64 *seg64 =
                    dlb_load_bytes(file, offset, sizeof(struct segment_command_64));
                if (!strcmp(seg64->segname, "__PAGEZERO")) {
                    dlb_patch_pagezero(file, offset, cmd, copied, seg64,
                                       sizeof(struct segment_command_64), saveto);
                }
                free(seg64);
            } else if (cmd->cmd == LC_DYLD_INFO_ONLY) {
                struct dyld_info_command *dyldinfo =
                    dlb_load_bytes(file, offset, sizeof(struct dyld_info_command));
                dlb_patch_dyldinfo(file, 0, dyldinfo);
                free(dyldinfo);
            }
            offset += cmd->cmdsize;
            free(cmd);
        }
        dlb_append_dylib_id_command(file, header_offset, offset, true, saveto);
    } else if (*magic == 0xFEEDFACE) {
        struct mach_header *mh = dlb_load_bytes(file, offset, sizeof(struct mach_header));
        off_t header_offset = offset;
        dlb_patch_mach_header(file, offset, mh, false);
        offset += sizeof(struct mach_header);
        ncmds = mh->ncmds;
        free(mh);

        for (int i = 0; i < ncmds; i++) {
            cmd = dlb_load_bytes(file, offset, sizeof(struct load_command));
            if (cmd->cmd == LC_SEGMENT) {
                struct segment_command *seg =
                    dlb_load_bytes(file, offset, sizeof(struct segment_command));
                if (!strcmp(seg->segname, "__PAGEZERO")) {
                    dlb_patch_pagezero(file, offset, cmd, copied, seg,
                                       sizeof(struct segment_command), saveto);
                }
                free(seg);
            } else if (cmd->cmd == LC_DYLD_INFO_ONLY) {
                struct dyld_info_command *dyldinfo =
                    dlb_load_bytes(file, offset, sizeof(struct dyld_info_command));
                dlb_patch_dyldinfo(file, 0, dyldinfo);
                free(dyldinfo);
            }
            offset += cmd->cmdsize;
            free(cmd);
        }
        dlb_append_dylib_id_command(file, header_offset, offset, false, saveto);
    } else if (*magic == 0xBEBAFECA) {
        size_t arch_offset = sizeof(struct fat_header);
        struct fat_header *fat = dlb_load_bytes(file, offset, sizeof(struct fat_header));
        struct fat_arch *arch = dlb_load_bytes(file, arch_offset, sizeof(struct fat_arch));
        int n = DLB_SWAP32(fat->nfat_arch);

        while (n-- > 0) {
            offset = DLB_SWAP32(arch->offset);
            free(magic);
            magic = dlb_load_bytes(file, offset, sizeof(uint32_t));

            if (*magic == 0xFEEDFACF) {
                struct mach_header_64 *mh64 =
                    dlb_load_bytes(file, offset, sizeof(struct mach_header_64));
                off_t header_offset = offset;
                dlb_patch_mach_header(file, offset, mh64, true);
                offset += sizeof(struct mach_header_64);
                ncmds = mh64->ncmds;
                free(mh64);

                for (int i = 0; i < ncmds; i++) {
                    cmd = dlb_load_bytes(file, offset, sizeof(struct load_command));
                    if (cmd->cmd == LC_SEGMENT_64) {
                        struct segment_command_64 *seg64 =
                            dlb_load_bytes(file, offset, sizeof(struct segment_command_64));
                        if (!strcmp(seg64->segname, "__PAGEZERO")) {
                            dlb_patch_pagezero(file, offset, cmd, copied, seg64,
                                               sizeof(struct segment_command_64), saveto);
                            copied = true;
                        }
                        free(seg64);
                    } else if (cmd->cmd == LC_DYLD_INFO_ONLY) {
                        struct dyld_info_command *dyldinfo =
                            dlb_load_bytes(file, offset, sizeof(struct dyld_info_command));
                        dlb_patch_dyldinfo(file, DLB_SWAP32(arch->offset), dyldinfo);
                        free(dyldinfo);
                    }
                    offset += cmd->cmdsize;
                    free(cmd);
                }
                dlb_append_dylib_id_command(file, header_offset, offset, true, saveto);
            } else if (*magic == 0xFEEDFACE) {
                struct mach_header *mh =
                    dlb_load_bytes(file, offset, sizeof(struct mach_header));
                off_t header_offset = offset;
                dlb_patch_mach_header(file, offset, mh, false);
                offset += sizeof(struct mach_header);
                ncmds = mh->ncmds;
                free(mh);

                for (int i = 0; i < ncmds; i++) {
                    cmd = dlb_load_bytes(file, offset, sizeof(struct load_command));
                    if (cmd->cmd == LC_SEGMENT) {
                        struct segment_command *seg =
                            dlb_load_bytes(file, offset, sizeof(struct segment_command));
                        if (!strcmp(seg->segname, "__PAGEZERO")) {
                            dlb_patch_pagezero(file, offset, cmd, copied, seg,
                                               sizeof(struct segment_command), saveto);
                            copied = true;
                        }
                        free(seg);
                    } else if (cmd->cmd == LC_DYLD_INFO_ONLY) {
                        struct dyld_info_command *dyldinfo =
                            dlb_load_bytes(file, offset, sizeof(struct dyld_info_command));
                        dlb_patch_dyldinfo(file, DLB_SWAP32(arch->offset), dyldinfo);
                        free(dyldinfo);
                    }
                    offset += cmd->cmdsize;
                    free(cmd);
                }
                dlb_append_dylib_id_command(file, header_offset, offset, false, saveto);
            } else {
                NSLog(@"[dylibify] unrecognised arch magic 0x%x", *magic);
            }
            arch_offset += sizeof(struct fat_arch);
            free(arch);
            arch = dlb_load_bytes(file, arch_offset, sizeof(struct fat_arch));
        }

        free(fat);
        free(arch);
    } else {
        NSLog(@"[dylibify] unrecognised magic 0x%x", *magic);
        rc = -1;
    }

    free(magic);
    fclose(file);
    return rc;
}
