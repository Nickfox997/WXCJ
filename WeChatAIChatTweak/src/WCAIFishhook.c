//
//  WCAIFishhook.c  —  精简 arm64 GOT 重绑定
//  只处理 __DATA / __DATA_CONST 下的 __got 与 __la_symbol_ptr。
//

#include "WCAIFishhook.h"
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/mman.h>
#include <dlfcn.h>

#define WCAI_SEG_DATA       "__DATA"
#define WCAI_SEG_DATA_CONST "__DATA_CONST"
#define WCAI_SEG_LINKEDIT   "__LINKEDIT"
#define WCAI_SEC_GOT        "__got"
#define WCAI_SEC_LAZY       "__la_symbol_ptr"

static int wcai_make_writable(void *addr, size_t size) {
    uintptr_t ps = (uintptr_t)sysconf(_SC_PAGESIZE);
    uintptr_t start = (uintptr_t)addr & ~(ps - 1);
    uintptr_t end   = ((uintptr_t)addr + size + ps - 1) & ~(ps - 1);
    return mprotect((void *)start, end - start, PROT_READ | PROT_WRITE);
}

int wcai_rebind_symbol(const char *name, void *replacement, void **outOriginal) {
    if (!name || !replacement) return 0;
    int total = 0;
    void *orig = NULL;

    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header *mh = _dyld_get_image_header(i);
        if (!mh || mh->magic != MH_MAGIC_64) continue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct mach_header_64 *header = (const struct mach_header_64 *)mh;

        const struct symtab_command   *symtab   = NULL;
        const struct dysymtab_command *dysymtab = NULL;
        const struct segment_command_64 *linkedit = NULL;

        const struct load_command *cmd = (const void *)(header + 1);
        for (uint32_t j = 0; j < header->ncmds; j++) {
            if (cmd->cmd == LC_SYMTAB)        symtab   = (const void *)cmd;
            else if (cmd->cmd == LC_DYSYMTAB) dysymtab = (const void *)cmd;
            else if (cmd->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const void *)cmd;
                if (strcmp(seg->segname, WCAI_SEG_LINKEDIT) == 0) linkedit = seg;
            }
            cmd = (const void *)((const char *)cmd + cmd->cmdsize);
        }
        if (!symtab || !dysymtab || !linkedit) continue;

        const intptr_t leBase = (intptr_t)linkedit->vmaddr + slide;
        const struct nlist_64 *symbols = (const void *)(leBase + symtab->symoff);
        const char *strings            = (const void *)(leBase + symtab->stroff);
        const uint32_t *indirect       = (const void *)(leBase + dysymtab->indirectsymoff);
        const uint32_t nindirect       = dysymtab->nindirectsyms;

        cmd = (const void *)(header + 1);
        for (uint32_t j = 0; j < header->ncmds; j++) {
            if (cmd->cmd != LC_SEGMENT_64) {
                cmd = (const void *)((const char *)cmd + cmd->cmdsize);
                continue;
            }
            const struct segment_command_64 *seg = (const void *)cmd;
            if (strcmp(seg->segname, WCAI_SEG_DATA) != 0 &&
                strcmp(seg->segname, WCAI_SEG_DATA_CONST) != 0) {
                cmd = (const void *)((const char *)cmd + cmd->cmdsize);
                continue;
            }

            const struct section_64 *sect = (const void *)(seg + 1);
            for (uint32_t k = 0; k < seg->nsects; k++, sect++) {
                if (strcmp(sect->sectname, WCAI_SEC_GOT) != 0 &&
                    strcmp(sect->sectname, WCAI_SEC_LAZY) != 0) continue;

                uint32_t nSlots = (uint32_t)(sect->size / sizeof(void *));
                void **slots = (void **)(sect->addr + slide);
                if (wcai_make_writable(slots, sect->size) != 0) continue;

                for (uint32_t s = 0; s < nSlots; s++) {
                    uint32_t idx = sect->reserved1 + s;
                    if (idx >= nindirect) break;
                    uint32_t symIdx = indirect[idx];
                    if (symIdx == INDIRECT_SYMBOL_LOCAL || symIdx == INDIRECT_SYMBOL_ABS) continue;

                    const struct nlist_64 *sym = &symbols[symIdx];
                    if (sym->n_un.n_strx == 0) continue;
                    const char *sname = strings + sym->n_un.n_strx;
                    if (!sname || sname[0] == '\0') continue;
                    if (sname[0] == '_') sname++;          // 去掉前导下划线
                    if (strcmp(sname, name) != 0) continue;

                    if (!orig) orig = slots[s];
                    slots[s] = replacement;
                    total++;
                }
            }
            cmd = (const void *)((const char *)cmd + cmd->cmdsize);
        }
    }

    if (outOriginal) *outOriginal = orig;
    return total;
}
