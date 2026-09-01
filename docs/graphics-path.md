# Graphics: the same renderer, one layer lower

## What the sister ports do

Simpsons Arcade, flOw and You Don't Know Jack all render through the same engine —
caner's (canersaka) live NV4097 → D3D12 draw path, `libs/video/rsx_live_draw.c` in
ps3recomp, switched on with `RSX_LIVE_DRAW=1`.

They reach it because they **import `cellGcmSys`**. The chain is:

```
game calls cellGcmSetDrawArrays(...)        (HLE, libs/video/cellGcmSys.c)
  -> writes NV methods into the guest FIFO ring
  -> the drain walks get..put on the present thread
     -> rsx_live_draw_method((subch << 13) | method, arg)
        -> rsx_dispatch_method  (register file, BEGIN/END/DRAW/FLIP)
           -> D3D12 PSO + draw into the flip surface
  flip method 0xE944 -> rsx_live_draw_present(buffer_id) -> Present()
```

Two things make it work: ps3recomp's own `cellGcmSys` implementation owns the FIFO,
and `gcm_io2ea()` can translate RSX IO offsets to guest EAs because
`cellGcmInit` / `cellGcmMapEaIoAddress` filled `s_ea_address_table`.

## Why `ps1_netemu` doesn't get there for free

`ps1_netemu` is firmware. It **links libgcm statically** — the library's debug
assertions are still sitting in the image (`CellGcmNv4097%s`,
`cellGcmSetVertexDataArray(index = %d) has an invalid offset`, `[GPU] cellGcmInit
failed`) — and there is no `cellGcmSys` entry in its import table, nor the string
anywhere in the file. Nothing to HLE.

Instead the recompiled libgcm will do what the real one does: build the pushbuffer in
guest memory and go to the kernel. All ten RSX syscalls are present in `.text`
(found by scanning `li r11,N` / `sc` pairs):

| # | syscall | sites |
|---|---|---|
| 668 | `sys_rsx_device_open` | 2 |
| 669 | `sys_rsx_device_close` | 3 |
| 670 | `sys_rsx_memory_allocate` | 1 |
| 671 | `sys_rsx_memory_free` | 2 |
| 672 | `sys_rsx_context_allocate` | 3 |
| 673 | `sys_rsx_context_free` | 3 |
| 674 | `sys_rsx_context_iomap` | **24** |
| 675 | `sys_rsx_context_iounmap` | 2 |
| 676 | `sys_rsx_context_attribute` | 2 |
| 677 | `sys_rsx_device_map` | 4 |

Twenty-four `iomap` sites is the tell: that is the same IO↔EA mapping
`cellGcmMapEaIoAddress` performs, done directly.

## The plan

Move the tap point, keep the engine. Every piece downstream of
`rsx_live_draw_method()` stays byte-for-byte what the sister ports use, including
`RSX_LIVE_DRAW=1`.

| lv2 syscall | maps onto the existing HLE machinery |
|---|---|
| `sys_rsx_device_map` (677) | hand back the guest EA of the RSX control/label area the HLE already carves |
| `sys_rsx_memory_allocate` (670) | the local-VRAM carve `cellGcmInit` makes |
| `sys_rsx_context_allocate` (672) | allocate the FIFO ring + `CellGcmControl`, in **guest** memory |
| `sys_rsx_context_iomap` (674) | populate `s_ea_address_table` — the same table `gcm_io2ea()` reads |
| `sys_rsx_context_attribute` (676) `0x001` | FIFO put/get → run the existing drain over `get..put` |
| `sys_rsx_context_attribute` (676) `0x104` | display buffer → `rsx_live_draw_set_display_buffer()` |
| `sys_rsx_context_attribute` (676) `0x102` | flip → `rsx_live_draw_present()` |

`rsx_live_draw.h` already documents the display-buffer call as coming *from*
`sys_rsx_context_attribute(0x104)`, so the engine was written expecting this layer to
exist — it just was never needed by a title that used HLE `cellGcmSys`.

What this needs from `libs/video/cellGcmSys.c` is only that three internals become
callable from the syscall layer: the IO→EA table write, the FIFO drain, and the
present hook. No duplicate walker.

## Known unknowns

- **Which control-register layout the firmware libgcm expects.** The HLE path returns
  a host pointer from `cellGcmGetControlRegister` in some paths; the syscall path must
  keep `put`/`get`/`ref` in guest memory or the drain never sees a moving `put`.
- **Whether the emulator's GPU work is on the PPU at all.** `GPUCoreInit()` and
  `cell/xspu.cc` say a raw SPU is involved. If the SPU core builds the pushbuffer, the
  FIFO still lands in main memory and the drain still sees it — but the SPU has to be
  running first, which needs the raw-SPU syscalls (160/161/163/169) the runtime does
  not implement yet.
