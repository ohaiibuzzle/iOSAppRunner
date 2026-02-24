//
//  LCDyld.m
//  BaseiOSApp
//
//  Created by Venti on 22/2/26.
//

#import "LCDyld.h"
#import "utils.h"
#import "FoundationPrivate.h"

static int (*orig_fcntl)(int fildes, int cmd, void *param) = 0;
int (*orig_dyld_fcntl)(int fildes, int cmd, void *param);
int (*orig_dyld_mmap)(int fildes, int cmd, void *param);

struct dyld_all_image_infos *_alt_dyld_get_all_image_infos(void) {
    static struct dyld_all_image_infos *result;
    if (result) {
        return result;
    }
    struct task_dyld_info dyld_info;
    mach_vm_address_t image_infos;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    kern_return_t ret;
    ret = task_info(mach_task_self_,
                    TASK_DYLD_INFO,
                    (task_info_t)&dyld_info,
                    &count);
    if (ret != KERN_SUCCESS) {
        return NULL;
    }
    image_infos = dyld_info.all_image_info_addr;
    result = (struct dyld_all_image_infos *)image_infos;
    return result;
}

static bool redirectFunction(char *name, void *patchAddr, void *target) {
    kern_return_t kr = litehook_hook_function(patchAddr, target);
    if (kr == KERN_SUCCESS) {
        NSLog(@"[DyldLVBypass] hook %s succeed!", name);
    } else {
        NSLog(@"[DyldLVBypass] hook %s failed: %d", name, kr);
    }
    return kr == KERN_SUCCESS;
}


char *searchDyldFunction(char *base, char *signature, int length) {
    char *patchAddr = NULL;
    for(int i=0; i < 0x80000; i+=4) {
        if (base[i] == signature[0] && memcmp(base+i, signature, length) == 0) {
            patchAddr = base + i;
            break;
        }
    }
    return patchAddr;
}

void searchDyldFunctions(void) {
    if(orig_dyld_fcntl && orig_dyld_mmap) return;
    
    // TODO: cache offset and litehook_find_dsc_symbol
    char *dyldBase = (char *)_alt_dyld_get_all_image_infos()->dyldImageLoadAddress;
    orig_dyld_fcntl = (void *)searchDyldFunction(dyldBase, fcntlSig, sizeof(fcntlSig));
    orig_dyld_mmap = (void *)searchDyldFunction(dyldBase, mmapSig, sizeof(mmapSig));
    
    // dopamine already hooked it, try to find its hook instead
    if(!orig_dyld_fcntl) {
        char* fcntlAddr = 0;
        // search all syscalls and see if the the instruction before it is a branch instruction
        for(int i=0; i < 0x80000; i+=4) {
            if (dyldBase[i] == syscallSig[0] && memcmp(dyldBase+i, syscallSig, 4) == 0) {
                char* syscallAddr = dyldBase + i;
                uint32_t* prev = (uint32_t*)(syscallAddr - 4);
                if(*prev >> 26 == 0x5) {
                    fcntlAddr = (char*)prev;
                    break;
                }
            }
        }
        
        if(fcntlAddr) {
            uint32_t* inst = (uint32_t*)fcntlAddr;
            int32_t offset = ((int32_t)((*inst)<<6))>>4;
            NSLog(@"[DyldLVBypass] Dopamine hook offset = %x", offset);
            orig_fcntl = (void*)((char*)fcntlAddr + offset);
            orig_dyld_fcntl = (void *)fcntlAddr;
        } else {
            NSLog(@"[DyldLVBypass] Dopamine hook not found");
        }
    }
}

static void* hooked_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset) {
    void *map = __mmap(addr, len, prot, flags, fd, offset);
    if (map == MAP_FAILED && fd && (prot & PROT_EXEC)) {
        map = __mmap(addr, len, PROT_READ | PROT_WRITE, flags | MAP_PRIVATE | MAP_ANON, 0, 0);
        void *memoryLoadedFile = __mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, offset);
        memcpy(map, memoryLoadedFile, len);
        munmap(memoryLoadedFile, len);
        mprotect(map, len, prot);
    }
    return map;
}

static int hooked___fcntl(int fildes, int cmd, void *param) {
    if (cmd == F_ADDFILESIGS_RETURN) {
#if !(TARGET_OS_MACCATALYST || TARGET_OS_SIMULATOR)
        // attempt to attach code signature on iOS only as the binaries may have been signed
        // on macOS, attaching on unsigned binaries without CS_DEBUGGED will crash
        orig_fcntl(fildes, cmd, param);
#endif
        fsignatures_t *fsig = (fsignatures_t*)param;
        // called to check that cert covers file.. so we'll make it cover everything ;)
        fsig->fs_file_start = 0xFFFFFFFF;
        return 0;
    }

    // Signature sanity check by dyld
    else if (cmd == F_CHECK_LV) {
        //orig_fcntl(fildes, cmd, param);
        // Just say everything is fine
        return 0;
    }
    
    // If for another command or file, we pass through
    return orig_fcntl(fildes, cmd, param);
}

void init_bypassDyldLibValidation(void) {
    static BOOL bypassed;
    if (bypassed) return;
    bypassed = YES;

    NSLog(@"[DyldLVBypass] init");
    
    // Modifying exec page during execution may cause SIGBUS, so ignore it now
    // Only comment this out if only one thread (main) is running
    //signal(SIGBUS, SIG_IGN);
    
    orig_fcntl = __fcntl;
    //redirectFunction("mmap", mmap, hooked_mmap);
    //redirectFunction("fcntl", fcntl, hooked_fcntl);
    
    searchDyldFunctions();
    redirectFunction("dyld_fcntl", orig_dyld_fcntl, hooked___fcntl);
    redirectFunction("dyld_mmap", orig_dyld_mmap, hooked_mmap);
}

void overwriteMainCFBundle(void) {
    // Overwrite CFBundleGetMainBundle
    uint32_t *pc = (uint32_t *)CFBundleGetMainBundle;
    void **mainBundleAddr = 0;
    while (true) {
        uint64_t addr = aarch64_get_tbnz_jump_address(*pc, (uint64_t)pc);
        if (addr) {
            // adrp <- pc-1
            // tbnz <- pc
            // ...
            // ldr  <- addr
            mainBundleAddr = (void **)aarch64_emulate_adrp_ldr(*(pc-1), *(uint32_t *)addr, (uint64_t)(pc-1));
            break;
        }
        ++pc;
    }
    assert(mainBundleAddr != NULL);
    *mainBundleAddr = (__bridge void *)NSBundle.mainBundle._cfBundle;
}

void overwriteMainNSBundle(NSBundle *newBundle) {
    // Overwrite NSBundle.mainBundle
    // iOS 16: x19 is _MergedGlobals
    // iOS 17: x19 is _MergedGlobals+4

    NSString *oldPath = NSBundle.mainBundle.executablePath;
    uint32_t *mainBundleImpl = (uint32_t *)method_getImplementation(class_getClassMethod(NSBundle.class, @selector(mainBundle)));
    for (int i = 0; i < 20; i++) {
        void **_MergedGlobals = (void **)aarch64_emulate_adrp_add(mainBundleImpl[i], mainBundleImpl[i+1], (uint64_t)&mainBundleImpl[i]);
        if (!_MergedGlobals) continue;

        // In iOS 17, adrp+add gives _MergedGlobals+4, so it uses ldur instruction instead of ldr
        if ((mainBundleImpl[i+4] & 0xFF000000) == 0xF8000000) {
            uint64_t ptr = (uint64_t)_MergedGlobals - 4;
            _MergedGlobals = (void **)ptr;
        }

        for (int mgIdx = 0; mgIdx < 20; mgIdx++) {
            if (_MergedGlobals[mgIdx] == (__bridge void *)NSBundle.mainBundle) {
                _MergedGlobals[mgIdx] = (__bridge void *)newBundle;
                break;
            }
        }
    }

    assert(![NSBundle.mainBundle.executablePath isEqualToString:oldPath]);
}
