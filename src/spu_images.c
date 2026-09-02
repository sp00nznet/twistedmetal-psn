/* spu_images.c -- register the two lifted SPU modules.
 *
 * ps1_netemu drives its SPUs RAW (cell/xspu.cc: sys_raw_spu_create), not through
 * SPURS, so nothing dispatches these yet -- the runtime has no raw-SPU path. What
 * this file does today is call each image's recomp_register() so its
 * indirect-branch table is built under a distinct image id, and park both entries
 * in the shared workload registry under the FNV-1a-64 fingerprint of the exact ELF
 * bytes the guest hands to sys_raw_spu_load. When the raw-SPU syscalls land they
 * look the image up the same way cellSpurs already does.
 */
#include "spu_workload.h"

extern void spu_begin_image(int image_id);

extern void spu0_spu_func_00000100(spu_context*);
extern void spu0_spu_recomp_register(void);
extern void spu1_spu_func_000000E0(spu_context*);
extern void spu1_spu_recomp_register(void);

void tmpsn_spu_register_all(void)
{
    /* Embedded SPU ELF at vaddr 0x181100, 86,452 B, entry 0x100. */
    spu_begin_image(1); spu0_spu_recomp_register();
    spu_workload_register_img(0x5BCAF5D9B58AB103ULL, spu0_spu_func_00000100,
                              1, "ps1_netemu_spu0");

    /* Embedded SPU ELF at vaddr 0x19A200, 59,580 B, entry 0xE0. */
    spu_begin_image(2); spu1_spu_recomp_register();
    spu_workload_register_img(0x85B3AE0C8712C641ULL, spu1_spu_func_000000E0,
                              2, "ps1_netemu_spu1");
}

__attribute__((constructor)) static void tmpsn_spu_register_all_ctor(void)
{
    tmpsn_spu_register_all();
}
