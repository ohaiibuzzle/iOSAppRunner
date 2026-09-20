//
//  utils.h
//  BaseiOSApp
//
//  Created by Venti on 22/2/26.
//

@import Foundation;

#define PrivClass(name) ((Class)objc_lookUpClass(#name))
#define ASM(...) __asm__(#__VA_ARGS__)

const char **_CFGetProgname(void);
const char **_CFGetProcessPath(void);
uint64_t aarch64_get_tbnz_jump_address(uint32_t instruction, uint64_t pc);
uint64_t aarch64_emulate_adrp(uint32_t instruction, uint64_t pc);
bool aarch64_emulate_add_imm(uint32_t instruction, uint32_t *dst, uint32_t *src, uint32_t *imm);
uint64_t aarch64_emulate_adrp_add(uint32_t instruction, uint32_t addInstruction, uint64_t pc);
uint64_t aarch64_emulate_adrp_ldr(uint32_t instruction, uint32_t ldrInstruction, uint64_t pc);
kern_return_t builtin_vm_protect(mach_port_name_t task, mach_vm_address_t address, mach_vm_size_t size, boolean_t set_max, vm_prot_t new_prot);

