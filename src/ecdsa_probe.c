/* ecdsa_probe.c -- differential harness for the firmware's ECDSA verify.
 *
 * ps1_netemu will not open the disc body until it verifies a 40-byte ECDSA
 * signature over the SHA-1 of ISO.BIN.EDAT's 0x100000-byte header
 * (func_00010D24 at 0xF13C0). That signature is VALID -- checked offline
 * against the curve read out of the guest's own memory -- and our recompiled
 * copy still rejects it. See docs/disc-body.md.
 *
 * So the fault is in the lifted arithmetic, and this drives it in isolation
 * instead of waiting 40 seconds for a boot: it builds the exact arguments
 * func_00010D24 hands to func_001584A0 and calls that directly.
 *
 * The argument shape comes from func_00010D24's own prologue, which copies
 * each 20-byte value through func_000106B4 into a 24-byte slot (4 zero bytes
 * then the 20 big-endian bytes) at r31+112/136/160/184/352, then calls
 *
 *     func_001584A0(r, e, Q, curve)
 *
 * with r3 = &r (s follows at +24), r4 = &e, r5 = &Qx (Qy at +24) and
 * r6 = the 144-byte curve context = six of those slots, in the order
 * p, a, b, N, Gx, Gy.
 *
 * Building the context here rather than calling func_000109C4 is deliberate:
 * the curve table at 0x15F7F0 is populated at runtime, so going through the
 * guest's initialiser would make the probe depend on when it runs. These are
 * the values that initialiser produces, captured from the live context.
 *
 * Set ECDSA_PROBE=1 to run it. It piggybacks on sceNpDrmIsAvailable, which
 * the emulator calls once, just before opening the disc -- late enough that
 * guest memory and the heap are up.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ppu_context.h"

extern void  vm_write32(uint32_t addr, uint32_t val);
extern void  ps3_hle_register_ctx(uint32_t nid, const char* name,
                                  void (*fn)(ppu_context*));
extern void* _sys_malloc(uint32_t size);

/* The lifted functions are C++ symbols, so reach them the way the indirect-call
 * dispatcher does -- through the generated table, which has C linkage. That also
 * makes the probe address-driven, which is what bisecting the 29-function
 * subtree needs. */
typedef struct { uint64_t addr; void (*func)(ppu_context*); const char* name; } func_entry;
extern const func_entry function_table[];
extern const uint64_t  function_table_count;

static void (*lookup(uint64_t ea))(ppu_context*)
{
    for (uint64_t i = 0; i < function_table_count; i++)
        if (function_table[i].addr == ea) return function_table[i].func;
    return 0;
}

/* The verified inputs and the curve, from docs/disc-body.md. */
static const char* K_R  = "3df7e732dfd6834e25ac8284c5bce7b8451078d4";
static const char* K_S  = "01351fccdfb8684ed38f7acc54853fb5c49065f4";
static const char* K_E  = "6c55da7ff8eb8c09df8d5269dca4444b561097aa";
static const char* K_QX = "948da13e8cafd5ba0e90ce434461bb327fe7e080";
static const char* K_QY = "475eaa0ad3ad4f5b6247a7fda86df69790196773";
static const char* K_P  = "ffffffffffffffff00000001ffffffffffffffff";
static const char* K_A  = "ffffffffffffffff00000001fffffffffffffffc";
static const char* K_B  = "a68bedc33418029c1d3ce33b9a321fccbb9e0f0b";
static const char* K_N  = "fffffffffffffffeffffb5ae3c523e63944f2127";
static const char* K_GX = "128ec4256487fd8fdf64e2437bc0a1f6d5afde2c";
static const char* K_GY = "5958557eb1db001260425524dbc379d5ac5f4adf";

static int nyb(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Write one 24-byte bignum slot: 4 zero bytes then the 20 bytes of `hex`.
 * Returns 0 on success. A malformed literal here would silently test the
 * wrong number, so it is checked rather than assumed. */
static int put_bn(uint32_t ea, const char* hex)
{
    uint8_t v[20];
    if (strlen(hex) != 40) return -1;
    for (int i = 0; i < 20; i++) {
        int hi = nyb(hex[2 * i]), lo = nyb(hex[2 * i + 1]);
        if (hi < 0 || lo < 0) return -1;
        v[i] = (uint8_t)((hi << 4) | lo);
    }
    vm_write32(ea, 0u);
    for (int i = 0; i < 5; i++)
        vm_write32(ea + 4u + (uint32_t)i * 4u,
                   ((uint32_t)v[i * 4] << 24) | ((uint32_t)v[i * 4 + 1] << 16) |
                   ((uint32_t)v[i * 4 + 2] << 8) | (uint32_t)v[i * 4 + 3]);
    return 0;
}

#define BN 24u

static void run_probe(ppu_context* caller)
{
    /* 0x40000 of guest scratch: the arguments, then a stack for the call.
     * func_001584A0 recurses a few levels deep through the point arithmetic,
     * so give it room rather than borrowing the caller's frame. */
    uint32_t base = (uint32_t)(uintptr_t)_sys_malloc(0x40000u);
    if (!base) { fprintf(stderr, "[ecdsa] no guest scratch\n"); return; }

    uint32_t sig = base;              /* r  at +0,  s  at +24 */
    uint32_t e   = base + 0x100u;     /* e */
    uint32_t q   = base + 0x200u;     /* Qx at +0,  Qy at +24 */
    uint32_t cv  = base + 0x300u;     /* p, a, b, N, Gx, Gy */

    int bad = 0;
    bad |= put_bn(sig,          K_R);
    bad |= put_bn(sig + BN,     K_S);
    bad |= put_bn(e,            K_E);
    bad |= put_bn(q,            K_QX);
    bad |= put_bn(q + BN,       K_QY);
    bad |= put_bn(cv + 0 * BN,  K_P);
    bad |= put_bn(cv + 1 * BN,  K_A);
    bad |= put_bn(cv + 2 * BN,  K_B);
    bad |= put_bn(cv + 3 * BN,  K_N);
    bad |= put_bn(cv + 4 * BN,  K_GX);
    bad |= put_bn(cv + 5 * BN,  K_GY);
    if (bad) { fprintf(stderr, "[ecdsa] bad constant literal\n"); return; }

    ppu_context c;
    memset(&c, 0, sizeof c);
    c.gpr[1] = (uint64_t)(base + 0x3F000u);   /* stack top, grows down */
    c.gpr[2] = caller->gpr[2];                /* the module's TOC */
    c.gpr[3] = (uint64_t)sig;
    c.gpr[4] = (uint64_t)e;
    c.gpr[5] = (uint64_t)q;
    c.gpr[6] = (uint64_t)cv;

    void (*fn)(ppu_context*) = lookup(0x001584A0ULL);
    if (!fn) { fprintf(stderr, "[ecdsa] func_001584A0 not in table\n"); return; }

    fprintf(stderr, "[ecdsa] calling func_001584A0(sig=0x%08X e=0x%08X "
                    "Q=0x%08X curve=0x%08X)\n", sig, e, q, cv);
    fn(&c);
    int32_t rc = (int32_t)c.gpr[3];
    fprintf(stderr, "[ecdsa] returned %d (0x%08X) -- expected 0 (VALID)%s\n",
            rc, (uint32_t)rc, rc == 0 ? "" : "  <== BUG REPRODUCED");
}

static void hle_np_drm_is_available(ppu_context* ctx)
{
    static int once = 0;
    if (!once++) {
        const char* e = getenv("ECDSA_PROBE");
        if (e && *e != '0') run_probe(ctx);
    }
    ctx->gpr[3] = 0;   /* CELL_OK, same as the unresolved-NID stub gave */
}

__attribute__((constructor)) static void tmpsn_ecdsa_probe(void)
{
    ps3_hle_register_ctx(0xAD218FAFu, "sceNpDrmIsAvailable(probe)",
                         hle_np_drm_is_available);
}
