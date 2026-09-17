//
//  SceneLifecycleHook.m
//  iOSAppRunner
//
//  Under Mac Catalyst, UIKit's own runtime-issue evaluator
//  (_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption in
//  UIKitCore) terminates the process outright if the current app has no
//  UIApplicationSceneManifest — even for apps (Instagram, confirmed) that
//  run fine as classic non-scene apps on real iOS with the exact same
//  missing manifest.
//
//  macOS 27 update: the function's gate structure shifted. The fatal decision
//  now lives inside the block literal invoked from the +104 path (bl at +120,
//  before the old +0x44 gate ever executes): the block reads a flag byte via
//  `adrp x8,<page>; ldrb w8,[x8,#0xaeb]; tbz w8,#0,<fatal-path>`, and the
//  fatal path ends in `brk #0` after logging "UIScene life cycle is required
//  for apps built with this SDK". Patching the old +0x44 `tbnz` is therefore
//  too late on this build.
//  Instead we force the *first* gate, at +0x14:
//    `adrp x8,<page>; ldrb w8,[x8,#0xae8]; tbnz w8,#0,<+96 early return>`
//  — the "already handled, tolerate" check — into an unconditional branch.
//  The outer function then returns before either block literal is invoked,
//  so the fatal evaluator never runs. Patching that *data* byte to 1 still
//  does NOT work: it gets silently recomputed back to 0 before the next
//  read. Patching the `tbnz` *instruction* to an unconditional branch
//
//

#import "SceneLifecycleHook.h"
#import "../litehook/src/litehook.h"
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <libkern/OSCacheControl.h>
#import <string.h>

#if TARGET_OS_MACCATALYST

// litehook_unprotect/litehook_protect exist in litehook.c but aren't part
// of the public header; they're real linkable symbols there.
// litehook_protect sets R-X, which is exactly what a code-page write needs
// to be restored to. litehook_unprotect sets RW+VM_PROT_COPY, required to
// get a writable, private (copy-on-write) view of a dyld-shared-cache page.
extern kern_return_t litehook_unprotect(vm_address_t addr, vm_size_t size);
extern kern_return_t litehook_protect(vm_address_t addr, vm_size_t size);

// _UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption's opening
// (macOS 27.0, verified live under lldb):
//   pacibsp
//   stp x29, x30, [sp, #-0x10]!
//   mov x29, sp
//   adrp x8, <page>              <- position-dependent; wildcarded below
//   ldrb w8, [x8, #0xae8]
//   tbnz w8, #0x0, <+96>         <- gate 1, the one we patch
// The ldrb is a register+immediate load (no PC-relative addressing) and the
// tbnz's imm14 is a fixed function-relative distance, so their encodings are
// identical regardless of where in memory the function lands — together with
// the fixed prologue this is specific enough to be a reliable anchor inside
// UIKitCore's __TEXT.
static const uint32_t kSigWord0 = 0xd503237f; // pacibsp
static const uint32_t kSigWord1 = 0xa9bf7bfd; // stp x29, x30, [sp, #-0x10]!
static const uint32_t kSigWord2 = 0x910003fd; // mov x29, sp
// word[3] (adrp) is a wildcard.
static const uint32_t kSigWord4 = 0x396ba108; // ldrb w8, [x8, #0xae8]
static const uint32_t kSigWord5 = 0x37000268; // tbnz w8, #0x0, <+96>

// Function-relative offset (in words) of the gate-1 `tbnz w8,#0,<+96>`
// we're patching, confirmed via live disassembly against the function's
// own entry point (this is a fixed property of the compiled function, not
// of any particular launch's ASLR slide). 
static const size_t kTbnzWordOffset = 0x14 / 4;
// The unconditional branch we replace it with: `b` to the same target the
// tbnz already jumps to (function offset +0x60), encoded relative to the
// tbnz's own address: opcode 0x14000000 | ((0x60-0x14)/4).
static const uint32_t kUnconditionalBranch = 0x14000000 | ((0x60 - 0x14) / 4);

static bool findUIKitCoreText(const uint32_t **outStart, size_t *outWords) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path || !strstr(path, "/UIKitCore")) continue;

        const mach_header_u *header = (const mach_header_u *)_dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        if (!header) continue;

        uint32_t off = 0;
        const uint8_t *cmdPtr = (const uint8_t *)header + sizeof(mach_header_u);
        for (uint32_t c = 0; c < header->ncmds; c++) {
            const struct load_command *lc = (const struct load_command *)(cmdPtr + off);
            if (lc->cmd == LC_SEGMENT_U) {
                const segment_command_u *seg = (const segment_command_u *)lc;
                if (!strcmp(seg->segname, "__TEXT")) {
                    *outStart = (const uint32_t *)(uintptr_t)((uint64_t)seg->vmaddr + (uint64_t)slide);
                    *outWords = (size_t)(seg->vmsize / sizeof(uint32_t));
                    return true;
                }
            }
            off += lc->cmdsize;
        }
    }
    return false;
}

static const uint32_t *findGateSignature(void) {
    const uint32_t *base = NULL;
    size_t words = 0;
    if (!findUIKitCoreText(&base, &words) || words < kTbnzWordOffset + 1) {
        return NULL;
    }
    for (size_t i = 0; i + 6 <= words; i++) {
        if (base[i] == kSigWord0 && base[i + 1] == kSigWord1 &&
            base[i + 2] == kSigWord2 && base[i + 4] == kSigWord4 &&
            base[i + 5] == kSigWord5) {
            return &base[i];
        }
    }
    return NULL;
}

void SceneLifecycleHooksInit(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        const uint32_t *funcStart = findGateSignature();
        if (!funcStart) {
            NSLog(@"[SceneLifecycleHook] could not locate gate signature in UIKitCore __TEXT");
            return;
        }

        uint32_t *tbnzAddr = (uint32_t *)&funcStart[kTbnzWordOffset];
        vm_address_t page = (vm_address_t)((uintptr_t)tbnzAddr & ~0xFFFULL);

        kern_return_t kr = litehook_unprotect(page, 0x1000);
        if (kr != KERN_SUCCESS) {
            NSLog(@"[SceneLifecycleHook] unprotect failed: %d", kr);
            return;
        }

        *tbnzAddr = kUnconditionalBranch;

        kr = litehook_protect(page, 0x1000);
        if (kr != KERN_SUCCESS) {
            NSLog(@"[SceneLifecycleHook] re-protect failed: %d", kr);
        }
        sys_icache_invalidate(tbnzAddr, sizeof(uint32_t));

        NSLog(@"[SceneLifecycleHook] patched scene-lifecycle gate at %p", tbnzAddr);
    });
}

#else

void SceneLifecycleHooksInit(void) {
    // Only relevant under Mac Catalyst; Designed-for-iPad already tolerates
    // guests with no scene manifest natively.
}

#endif
