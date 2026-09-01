# Graphics: the same renderer, one layer lower

**Status: done and working.** `cellGcmInit` succeeds, the FIFO drains real NV4097
methods, both display buffers are registered with the live engine, a guest clear
reaches the D3D12 backend, and the emulator gets through `InitMenu`. What is still
missing for a *picture* is the emulator core, which is blocked on raw SPU, not on
anything here.

## What the sister ports do

Simpsons Arcade, flOw and You Don't Know Jack all render through caner's
(canersaka) live NV4097 → D3D12 engine — `libs/video/rsx_live_draw.c` in
ps3recomp, switched on with `RSX_LIVE_DRAW=1`. The chain is:

```
game calls cellGcmSetDrawArrays(...)        (HLE, libs/video/cellGcmSys.c)
  -> writes NV methods into the guest FIFO ring
  -> the drain walks get..put on the present thread
     -> rsx_live_draw_method((subch << 13) | method, arg)
        -> rsx_dispatch_method  (register file, BEGIN/END/DRAW/FLIP)
           -> D3D12 PSO + draw into the flip surface
```

Two things make it work: ps3recomp's own `cellGcmSys` owns the FIFO, and
`gcm_io2ea()` can translate RSX IO offsets to guest EAs because `cellGcmInit` /
`cellGcmMapEaIoAddress` filled `s_ea_address_table`. Both require the guest to
*import* `cellGcmSys`.

## Why `ps1_netemu` doesn't get there for free

It is firmware. It **links libgcm statically** — the library's debug assertions
are still in the image (`CellGcmNv4097%s`, `cellGcmSetVertexDataArray(index = %d)
has an invalid offset`, `[GPU] cellGcmInit failed`) — and there is no
`cellGcmSys` import, nor the string anywhere in the file. Nothing to HLE.

## The syscall numbering — not what the tables say

The plan assumed RPCS3's numbering (668 `device_open` … 679 `attribute`). The
image disagrees, and the image wins. Reading each `li r11,N` / `sc` pair together
with the libgcm wrapper around it gives:

| # | syscall | how it was identified |
|---|---|---|
| 666 | `device_open` | never called by libgcm |
| 667 | `device_close` | never called by libgcm |
| 668 | `memory_allocate` | `(u32* handle, u64* addr, size, flags, …)` |
| 669 | `memory_free` | one arg, the handle, on the allocate-failure path |
| 670 | `context_allocate` | **four** out-pointers + handle + system mode |
| 671 | `context_free` | one arg, then 669 right after it — teardown pair |
| 672 | `context_iomap` | wrapper is `cellGcmMapEaIoAddress(ea, io, size)`, both 1MB-aligned |
| 673 | `context_iounmap` | `(ctx, io<<20, size<<20)` |
| 674 | `context_attribute` | `(ctx, packet_id, a3…a6)`; 23 call sites |
| 675 | `device_map` | `(u64* out, u64* out, dev_id)` with dev_id 8, and 9 as a probe |
| 676 | `device_unmap` | `(dev_id)` — issued 16 bytes after the dev_id 9 map |
| 677 | `attribute` | `(packet_id=514, …)` |

So the whole block sits **two lower** than assumed. Everything else in the plan
survived unchanged.

## The two facts that made it work

Both came out of the disassembly, not from guessing at struct layouts.

**1. `cellGcmInit`'s failure was a version check.** In the context-allocate
wrapper:

```
00012890: ld    r7, 0x88(r1)      ; lpar_driver_info (out-param slot)
00012898: lwz   r0, 0x0(r9)       ; *(u32*)driver_info
0001289C: cmpwi cr7, r0, 529      ; == 0x211 ?
000128A0: bne   cr7, 0x12948      ; ...or give up
```

So `*(u32*)lpar_driver_info` must be `0x211`.

**2. The control register is at `lpar_dma_control + 0x40`.**

```
00012B04: lwz  r3, 0x18(r9)       ; the stored lpar_dma_control
00012B08: addi r3, r3, 64
```

That is the whole trick: `context_allocate` returns
`cellGcm_control_guest_addr() - 0x40`, so the driver's own `put` writes land
exactly on the address the existing FIFO walker already reads. No second walker,
no shadow copy, no polling.

## …and the one that wasn't a graphics bug at all

With every RSX syscall implemented, `cellGcmInit` *still* failed — and never
reached a single one of them. Following the failure branch:

```
00116484: bl    0x11FB4           ; cellGcmInit(cmdSize=2MB, ioSize=4MB, ioAddr)
0011648C: cmpwi cr7, r3, 0
00116490: bne   cr7, 0x1175DC     ; -> "[GPU] cellGcmInit failed"
```

into `cellGcmInit` itself:

```
00012CE8: bl    0x125E0           ; device_map helper (ran fine)
00012CEC: bl    0x123B8           ; -> returns global+0x80
00012D00: bne   cr7, 0x12D30      ; must be NON-ZERO, else CELL_GCM_ERROR_FAILURE
```

and `global+0x80` is the out-param of **syscall 25**, called as
`get_sdk_version(getpid(), &out)`. It was an unimplemented stub returning
`CELL_OK` with the out-param untouched — SDK 0. Confirmed by what libgcm does
with the value next (`func_00012018`), a compatibility ladder:

| SDK version | RSX local memory |
|---|---|
| ≥ 2.20 | `0xF900000` (249 MB) |
| ≥ 2.00 | `0xF200000` (242 MB) |
| ≥ 1.90 | `0xEA00000` (234 MB) |
| ≥ 1.80 | `0xE800000` (232 MB) |
| else | `0xE000000` (224 MB) |

Those thresholds (`0x17FFFF`, `0x18FFFF`, `0x1FFFFF`, `0x21FFFF`) are
SDK-version-shaped, which is what identified the syscall. Implementing
`sys_process_get_sdk_version` (reporting 3.6.0) is what unblocked graphics —
a process syscall, not an RSX one.

## What the syscalls map onto

| lv2 syscall | routes to |
|---|---|
| `memory_allocate` (668) | `cellGcm_syscall_bringup()` → the local-VRAM base `cellGcmInit` picks |
| `context_allocate` (670) | control EA − 0x40, plus the driver-info / reports pages |
| `context_iomap` (672) | `populate_offset_table()` — the table `gcm_io2ea()` reads |
| `context_attribute` (674) `0x001` | `put`/`get` into the control register, walker resynced |
| `context_attribute` (674) `0x104` | `cellGcmSetDisplayBuffer()` → `rsx_live_draw_set_display_buffer()` |
| `device_map` (675) | a zeroed 4 KB page for dev_id 8; dev_id 9 reported absent |

The packet ids this image actually issues are `0x001 0x002 0x003 0x101 0x104
0x106 0x108 0x10A 0x202 0x300 0x301 0x302`. Only `0x001` and `0x104` matter for
pixels; the rest are accepted and logged once each rather than guessed at,
because a wrong guess writes plausible garbage into driver state instead of
failing loudly. `0x104`'s packing was read off `cellGcmSetDisplayBuffer`'s
prologue: `a3 = id & 0xFF`, `a4 = (width << 32) | height`,
`a5 = (pitch << 32) | offset` — and it comes out as
`id=0 offset=0x310000 pitch=5120 1280x720`, which is exactly right for a 1280×720
32-bit surface.

## Measured result

```
[sys_rsx] device_map(dev=8) -> 0x20030000
[cellGcmSys] Init(cmdSize=0x10000, ioSize=0x0, ioAddr=0x00000000)
[sys_rsx] memory_allocate(size=0xF900000 flags=0x80000) -> local=0xC0000000
[sys_rsx] context_allocate -> dma_control=0x20001FC0 (ctrl=0x20002000)
                              driver_info=0x20031000 reports=0x20038000 mode=0x820
[sys_rsx] iomap io=0x00000000 <- ea=0x40100000 size=0x400000
[sys_rsx] FIFO put=0x00001000 get=0x00001000
[RSX] method 0x0180..0x01B8 = 0xFEED0000/0xFEED0001   <- context DMA setup, from the guest FIFO
[cellGcmSys] SetDisplayBuffer(id=0, offset=0x310000, pitch=5120, 1280x720)
[live-draw]  display buffer 0 = loc0:0x00310000 pitch=5120 1280x720
[live-draw]  display buffer 1 = loc0:0x00694000 pitch=5120 1280x720
InitMenu Start c1d00000 / InitMenuManual / InitMenu End c36e2000
[fps] 60.0
```

`clears[guest=1]` and zero `no IO mapping` resyncs: the walker is following the
driver's `put` correctly and offsets resolve.

## What is left

- **Raw SPU.** `sys_raw_spu_create` (160) is a stub, so the imported SPU image
  never runs and the emulator core spins on the SPU status register at
  `0xE0044014`. That is the next blocker, and it is what will produce geometry.
- **A missing firmware font.** The menu asks for
  `/dev_flash/data/font/SCE-PS3-RD-R-LATIN2.ccd`, which is not in the installed
  dev_flash tree (only the `SCE-PS3-*.TTF` set is). Data availability, not code.
- **Unemulated attribute packets.** `0x101`, `0x10A`, `0x300`/`0x301`/`0x302`
  (tiles and Z-cull) are accepted and ignored. Tiling and Z-cull affect surface
  layout, so these will matter once real geometry is drawn.
