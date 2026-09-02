/* hle_overrides.c -- firmware imports this port implements itself.
 *
 * ps1_netemu imports six functions from sys_io. Five resolve by name through the
 * usual NID computation -- cellPadInit, cellPadEnd, cellPadSetPortSetting,
 * cellPadGetInfo2, cellPadSetActDirect -- and the sixth, 0x3733EA3C, does not.
 * It is NOT cellPadGetData (0x8B72CDA1); that one is not imported at all. Roughly
 * 120 candidate libpad/libkb/libmouse spellings were tried against the (verified)
 * NID algorithm and none matched, so this is a libpad entry point whose name is
 * not in any list we have.
 *
 * The name is not needed. The CONTRACT is, and the call site gives it exactly.
 * ps1_netemu's pad poll (func_000EB784) is:
 *
 *     cellPadGetInfo2(&info2);                       // 0x15E8AC, named
 *     ...
 *     for (port = 0; port <= 6; port++)
 *         if (info2.port_status[port] & 1)
 *             UNNAMED(port, &slot[port].extra, &slot[port].data);
 *     if (slot[port].data.len) { ...consume... }
 *
 * with the two pointer arguments derived like this (from the prologue):
 *
 *     addi r27, r1, 276     addi r26, r1, 412     ... stride 136
 *     port 0: r4 = r1+408 = r27+132, r5 = r27
 *     port 1: r4 = r1+544 = r26+132, r5 = r26
 *
 * i.e. a 136-byte per-port slot laid out { CellPadData data; u32 extra; }, with
 * r5 = &data and r4 = &extra. That the 132-byte half is a CellPadData is not a
 * guess: sizeof(CellPadData) is 4 + 2*CELL_PAD_MAX_CODES = 132 exactly, the guest
 * memcpy's 132 bytes out of it (0xEB994), and it gates on the first word being
 * non-zero -- which is CellPadData.len.
 *
 * So: r3 = port, r4 = u32* out, r5 = CellPadData*. Serve it from the runtime's
 * own cellPadGetData, which already reads the keyboard and any attached XInput
 * pad and writes CellPadData to guest memory big-endian.
 *
 * Kept in the port rather than libs/input/cellPad.c because the mapping rests on
 * one firmware module's call site, not on a known libpad export. If another
 * firmware target turns up importing the same NID, it should move.
 */
#include <stdint.h>
#include <stdio.h>

#include "ppu_context.h"
#include "cellPad.h"

extern void     vm_write32(unsigned long long addr, unsigned int val);
extern void     ps3_hle_register_ctx(uint32_t nid, const char* name,
                                     void (*fn)(ppu_context*));

/* Device type reported through the second argument. 0 is the standard pad; the
 * emulator only ever tests it against 0 on the paths that reach here. */
#define PAD_DEVICE_TYPE_STANDARD 0u

static void hle_sys_io_pad_read(ppu_context* ctx)
{
    uint32_t port     = (uint32_t)ctx->gpr[3];
    uint32_t extra_ea = (uint32_t)ctx->gpr[4];
    uint32_t data_ea  = (uint32_t)ctx->gpr[5];

    int32_t rc = (int32_t)cellPadGetData(port, (CellPadData*)(uintptr_t)data_ea);
    if (extra_ea) vm_write32(extra_ea, PAD_DEVICE_TYPE_STANDARD);

    { static int once = 0;
      if (!once++)
          fprintf(stderr, "[tmpsn] sys_io 0x3733EA3C served as a pad read "
                          "(port=%u data=0x%08X extra=0x%08X) -> %d\n",
                  port, data_ea, extra_ea, rc); }

    ctx->gpr[3] = (uint64_t)(int64_t)rc;
}

__attribute__((constructor)) static void tmpsn_hle_overrides(void)
{
    ps3_hle_register_ctx(0x3733EA3Cu, "sys_io:pad_read(0x3733EA3C)",
                         hle_sys_io_pad_read);
}
