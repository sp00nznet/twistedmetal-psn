# Progress Log — twistedmetal-psn

## Phase overview

| Phase | Description | Status |
|---|---|---|
| 0. Recon | Identify what the package actually is | ✅ |
| 1. Extract | Unpack the PSN PKG | ✅ |
| 2. Target | Find the real recomp target | ✅ — `ps1_netemu.self` |
| 3. Decrypt | Firmware SELF → ELF | ✅ |
| 4. Disasm/find | OPD + heuristic function discovery | ✅ — 3,512 functions |
| 5. NID resolve | lib.stub tables → library/function names | ✅ — 12 libs, 103 funcs |
| 6. Lift PPU | `ppu_lifter` → C++ | ✅ — 3,530 functions, 0 unhandled instructions |
| 7. Lift SPU | 2 embedded SPU ELFs → C | ✅ — 1,429 + 637 functions |
| 8. Shared harness | Build on ps3recomp's boot harness | ✅ — `tmpsn.exe`, linked first try |
| 9. First boot | Enter the recompiled CRT | ✅ — the emulator's own banner prints |
| 10. Graphics | `sys_rsx_*` → live NV4097 → D3D12 | ✅ — FIFO drains, buffers registered, 60 fps |
| 10b. Raw SPU | `sys_raw_spu_*` + `0xE0000000` MMIO | ⬜ — blocked here |
| 11. BIOS | `ps1_rom.bin` loads | ✅ |
| 12. Disc | `EBOOT.PBP` mounts, PS1 executable loads | ⬜ |
| 13. Render | Twisted Metal on screen | ⬜ |
| 14. Input / audio / VMC | | ⬜ |

## Detailed log

### 2026-09-01 — Kickoff, recon, and one surprise

**Phase 0/1 — What is this thing (COMPLETE)**

`G:\recomp\ps3games\tmpsn` held one file: `Twisted Metal PSN [NPUI-94304].rar`, a RAR
inside a RAR containing two packages — `(PS1) - Twisted-Metal_Full.pkg` (75 MB, retail) and
`(PS1) - Twisted-Metal_Crack.pkg` (1.1 MB, non-finalized, replaces `ISO.BIN.EDAT` with a
version 16 bytes larger).

`pkg_extract.py` asserted out: *"could not decrypt file table with either keystream."*
The header said why — `pkg_type = 0x0002`, i.e. PSP/PSVita keying, with a `\x7Fext`
extended header and `key_type = 1` at `0xE4`.

Fixing it took two goes, because a PSOne Classic package is **mixed-key**:

1. First attempt: add the PSP key (`07F2C682 90B50D2C 33818D70 9B60E62B`) as a third
   whole-package keystream candidate. Still failed — half the filenames came out as
   garbage.
2. The actual rule: the entry structs are PSP-keyed, but each entry's **name and payload**
   pick their key from **bit 28 of the entry flags** — set (`0x9…`) means PSP key, clear
   (`0x8…`) means the usual PS3 `2E7B71D7…` key. Two of the sixteen entries
   (`CONTENT/DOCUMENT.DAT`, `CONTENT/EBOOT.PBP`) are on the PSP key; the rest are on the
   PS3 one. A plain PS3 package never sets bit 28, so the same rule is a no-op there.

Contents: `PARAM.SFO` says `CATEGORY=1P`, `TITLE_ID=SCUS94304`, `PS3_SYSTEM_VER=01.7000`.
`CATEGORY=1P` is a **PSOne Classic**.

**Phase 2 — The surprise (COMPLETE)**

There is no PS3 executable in the package. Not an `EBOOT.BIN`, not a SELF, nothing. The
payload is `USRDIR/CONTENT/EBOOT.PBP` — a PSP-format PBP whose `DATA.PSAR` at `0x18000`
(68.6 MB) is the PS1 disc image — plus `USRDIR/ISO.BIN.EDAT`, the DRM half.

So the thing to recompile is the **PS3 firmware's PS1 emulator**. Three candidates in
`dev_flash/ps1emu/`: `ps1_emu.self` (842 KB, backwards-compat hardware path),
`ps1_netemu.self` (922 KB, the one PSN classics use), `ps1_newemu.self` (811 KB, later
revision). Target: `ps1_netemu.self`.

Confirmed by the emulator's own strings — it looks for exactly the files this package
ships:

```
/USRDIR/CONTENT/EBOOT.PBP
/USRDIR/ISO.BIN.EDAT
/USRDIR/CONTENT/DOCUMENT.DAT
/dev_flash/ps1emu/%s          (ps1_rom.bin — the 512 KB PS1 BIOS)
PSISOIMG0000                  (the PSAR disc container magic)
```

This is a better deal than it first looks: one recompilation covers the entire PSOne
Classics catalogue, and the emulator is small — **3,512 functions**, fewer than The
Simpsons Arcade Game's 3,813.

**Phase 3 — Decrypt (COMPLETE)**

`rpcs3 --decrypt fw/ps1_netemu.self` → `fw/ps1_netemu.elf`, 2,913,992 B. Retail key
revision `0x1C`; no RAP, no per-title key. Parses cleanly with `elf_parser.py`: PPC64
big-endian `ET_EXEC`, entry `0x1B5690`, text PT_LOAD @ `0x10000` (`0x199368` B), data @
`0x1B0000` with a `0x1D9E1E8` memsz — ~31 MB of BSS, which is the PS1's RAM, VRAM, SPU RAM
and the emulator's caches.

**Phase 4 — Function discovery (COMPLETE)**

`find_functions.py` → **3,512** functions from 419,034 instructions, and it verified that
every one of the 3,286 `.opd` descriptor addresses is a function start.

**Phase 5 — NID resolution (COMPLETE)**

`prx_analyzer.py` needs a dynamic section; this is a fixed `ET_EXEC`, so the import tables
hang off `sys_proc_prx_param` instead. `elf_parser.py` already walks those, so the missing
piece was only the glue that turns them into the `imports.json` shape
`ppu_lifter --hle-stubs` wants — written as **`ps3recomp/tools/gen_imports.py`**, since
every port so far had done this by hand.

**103 imports across 12 libraries**, 86 named (83%):

```
sysPrxForUser 43   cellAdec       8   cellSysconfPs1emu 4   cellL10n      2
cellSysutil   14   cellPngDec     7   sceNp             3   cellRtcAlarm  2
cellAudio     11   sys_io         6   sys_net           2   cellGamePs1Emu 1
```

Everything else it needs, it loads at runtime through `sys_prx_load_module` — the strings
list `libadec`, `libat3dec`, `libaudio`, `libio`, `libl10n`, `libnet`, `libpngdec`,
`libsre`, `libsysutil`, `libsysutil_np`, `libsysutil_remoteplay`, `libsysutil_rtcalarm`,
`libsysutil_game_ps1emu`, `libsysutil_sysconf_ps1emu`.

**Phase 5b — SPU modules (COMPLETE)**

`extract_spu_images.py` found **2 embedded SPU ELFs** — 86,452 B at `0x181100` (entry
`0x100`) and 59,580 B at `0x19A200` (entry `0xE0`). Unlike Simpsons, where the SPURS job
images only existed in main memory at dispatch time and had to be captured with
`SPU_DUMP_MISS`, these are real ELFs sitting in the image. They lift statically. The
strings point at what they are: `cell/xspu.cc: 807: sys_raw_spu_create failed()` and
`GPUCoreInit()` — raw SPUs running the GPU (and probably GTE/SPU-audio) cores.

**Phase 6 — Graphics path, decided before writing any code**

The sister ports reach the live NV4097 → D3D12 engine through ps3recomp's **HLE
`cellGcmSys`**: `libs/video/cellGcmSys.c` walks the pushbuffer and calls
`rsx_live_draw_method()`. That only happens if the guest *imports* `cellGcmSys`.

`ps1_netemu` does not. There is no `cellGcmSys` in its import list and no such string
anywhere in the image, but there *is* a complete statically-linked libgcm — its debug
assertions are still in the binary (`cellGcmSetVertexDataArray(index = %d) has an invalid
offset`, `CellGcmNv4097%s`, `[GPU] cellGcmInit failed`). Being firmware, it links the
library and goes straight to the kernel.

Verified by scanning `.text` for `li r11,N` / `sc` pairs — all ten RSX syscalls are there:

```
668 sys_rsx_device_open x2      673 sys_rsx_context_free x3
669 sys_rsx_device_close x3     674 sys_rsx_context_iomap x24
670 sys_rsx_memory_allocate x1  675 sys_rsx_context_iounmap x2
671 sys_rsx_memory_free x2      676 sys_rsx_context_attribute x2
672 sys_rsx_context_allocate x3 677 sys_rsx_device_map x4
```

Plan: **same renderer, lower tap point.** Implement `sys_rsx_*` in the ps3recomp runtime
and drive the existing FIFO walker off the `sys_rsx_context_attribute` FIFO kick rather
than off `cellGcmFlush`. `rsx_live_draw.c`, the method decoder, the D3D12 backend and the
`RSX_LIVE_DRAW=1` switch are all untouched. `rsx_live_draw.h` already documents scanout
registration as coming *from* `sys_rsx_context_attribute(0x104)`, so the engine was written
expecting this layer to exist.

### 2026-09-01 (later) — Lifted, built, and booting

**Phases 6/7 — Lift (COMPLETE)**

PPU: `ppu_lifter.py` → **3,530 functions** (3,525 + 5 mid-function tail-entry wrappers),
`src/recomp/ppu_recomp_000.cpp` at 22.8 MB. 1,453 TODOs remain and **every one is a
`.word` data constant** — jump-table data and padding misclassified as code, never
executed. Zero real unhandled instructions; the missing-PPC-instruction patch Simpsons
upstreamed covers this image completely.

`--code-end 0x15F3AC`: the last `SHF_EXECINSTR` section ends there, and the 103-entry
`.lib.stub` trampoline table at `0x15E6CC`+`0xCE0` is the last of them. (Section names are
stripped in the decrypted firmware ELF, so the boundary comes from the flags, not the
names.)

SPU: both embedded ELFs lifted cleanly — **1,429 functions** from the 86 KB image (99.4%
byte coverage) and **637** from the 59 KB one (93.3%). Only `.word` data unsupported.

One correction along the way: `gen_imports.py` first dereferenced each `.lib.stub` entry
as an OPD. It is not one — the entry is already the trampoline's code address. The tell
was every "stub" coming out as `0x39800000`, which is not an address, it is `li r12,0`.

**Phase 8 — Build (COMPLETE)**

Configured against the shared harness and **linked first try**: `build/tmpsn.exe`, 10.2 MB.
No missing-symbol reconciliation pass was needed, unlike Simpsons.

`clang-cl` outside a VS developer prompt cannot find Microsoft's `rc.exe`, so the configure
also needs `-DCMAKE_RC_COMPILER="C:/Program Files/LLVM/bin/llvm-rc.exe"`.

**Phase 9 — First boot (COMPLETE)**

It runs its own code. Not a stub, not a trace — the recompiled emulator's startup:

```
PS1 emulator Build Date 20/01/30/13:20 -sgpu-sli4 [titledb:r11624]
argv[0]=/dev_bdvd/PS3_GAME/USRDIR/EBOOT.BIN
g_nUpconvertMode 0: g_bImageSmoothing 0
user_memory_size= 201326592/268435456 <67108864>
```

Then: 14 `sys_prx_load_module` calls (all soft-failed, all non-fatal), sysutil callback
registered, `cellVideoOut` negotiated to 1280x720 @ 59.94, `cellAudioOut` configured,
`[SPU] initialize(nspu=6, nrawspu=5)`, the PS1 BIOS opened, `REGION NUM = 0x00000081
code=A`, and SPU image 0 handed to `_sys_spu_image_import` — which correctly reports
`entry=0x00100 nsegs=3 machine=23`, i.e. the exact image we lifted as `spu0`.

The live NV4097 → D3D12 engine comes up on the way past and starts presenting:
`[rsx] live-draw engine up (D3D12); GDI present suppressed`. **Same renderer as the
sister ports, confirmed running.** It has nothing to draw yet.

**One real fix to get here:** `/dev_flash/ps1emu/ps1_rom.bin` missed. `ppu_fs.cpp` serves
`/dev_flash` from a real firmware tree via `$PS3_DEV_FLASH`, but `runtime/syscalls/sys_fs.c`
— the other half of the split filesystem — never got that branch, so the path resolved
under the game root instead. Adding it there fixes it for every port, not just this one.
(The runtime's built-in default still points at a `D:` path that doesn't exist on this
machine; `tools/run.sh` sets `PS3_DEV_FLASH` explicitly rather than churning a hardcode.)

**Where it stops, and why**

Two unimplemented kernel areas, both identified precisely:

1. **`sys_rsx_*`.** `cellGcmInit` fails → `cell/host.c: 235: GPUCoreInit(): failed`. The
   statically-linked libgcm has no HLE to land on; see `docs/graphics-path.md`.
2. **Raw SPU.** `sys_raw_spu_create` (160) is a stub, so nothing runs the imported image,
   and the emulator spins forever on `[HOTREAD] spinning on 0xE0044014` — the raw-SPU
   problem-state status register for SPU 0. Both lifted SPU entries are already registered
   in `src/spu_images.c`, waiting for a dispatcher.

## Next steps

1. `sys_rsx_*` in `runtime/syscalls/`, wired to the existing FIFO drain and
   `rsx_live_draw`. Unblocks graphics.
2. `sys_raw_spu_create/destroy/load` + the `0xE0000000` MMIO window, dispatching to the
   registered lifted images. Unblocks the emulator core.
3. Then: disc mount (`EBOOT.PBP` → `PSISOIMG0000`), input, audio, memory cards.


### 2026-09-01 (later still) — `sys_rsx_*`: graphics up

**Phase 10 — COMPLETE.** `cellGcmInit` succeeds, the FIFO drains real NV4097 methods
into caner's live engine, both display buffers are registered, a guest clear reaches
the D3D12 backend, `GPUCoreInit()` returns, and the emulator gets through `InitMenu`
at a steady 60 fps. Written as `ps3recomp/libs/video/sys_rsx.c` — a bridge into the
state `cellGcmSys.c` already keeps, not a second RSX. The walker, the method decoder,
the D3D12 backend and `RSX_LIVE_DRAW=1` are untouched.

**The syscall numbers are two lower than the published table.** The plan assumed
668 `device_open` … 679 `attribute`. The first RSX call the image makes is `675` with
`(u64* out, u64* out, 8)` — which is `device_map`'s signature, not `context_iounmap`'s.
Disassembling every `li r11,N` / `sc` pair together with its libgcm wrapper settled the
whole block: 666 `device_open`, 667 `device_close`, 668 `memory_allocate`,
669 `memory_free`, 670 `context_allocate`, 671 `context_free`, 672 `context_iomap`,
673 `context_iounmap`, 674 `context_attribute`, 675 `device_map`, 676 `device_unmap`,
677 `attribute`. Identification was structural, not by name: `670` is the one with
**four** out-pointers plus a handle and a mode (only `context_allocate` looks like
that); `675`/`676` are a map-then-immediately-unmap pair on `dev_id 9`, i.e. a
device-presence probe; `672`'s wrapper is `cellGcmMapEaIoAddress(ea, io, size)` with
both addresses 1MB-alignment-checked.

**Two facts read out of the image, not guessed.**

1. `cellGcmInit`'s version handshake:
   `ld r7,0x88(r1)` / `lwz r0,0x0(r9)` / `cmpwi r0,529` — `*(u32*)lpar_driver_info`
   must be `0x211`.
2. The control register lives at `lpar_dma_control + 0x40`:
   `lwz r3,0x18(r9)` / `addi r3,r3,64`. That is the whole trick — `context_allocate`
   returns `cellGcm_control_guest_addr() - 0x40`, so the driver's own `put` writes land
   on the address the existing walker already reads. No second walker, no shadow copy,
   no polling.

**Packet ids** for `context_attribute` came from `r4` at all 23 call sites:
`0x001 0x002 0x003 0x101 0x104 0x106 0x108 0x10A 0x202 0x300 0x301 0x302`. Only two
matter for pixels. `0x104`'s argument packing was read off `cellGcmSetDisplayBuffer`'s
prologue (`r3=id r4=offset r5=pitch r6=width r7=height` → `a3 = id & 0xFF`,
`a4 = (width<<32)|height`, `a5 = (pitch<<32)|offset`) and came out as
`id=0 offset=0x310000 pitch=5120 1280x720` — exactly right for a 720p 32-bit surface,
which is the confirmation. The rest are accepted and logged once each rather than
guessed at: a wrong guess writes plausible garbage into driver state instead of
failing loudly.

**And the thing that was actually failing was not graphics.** With all twelve syscalls
implemented, `cellGcmInit` *still* failed — and never reached one of them. Following the
branch: `GPUCoreInit` calls `cellGcmInit(cmdSize=2MB, ioSize=4MB, ioAddr)` at `0x11FB4`;
inside, after the `device_map` helper, it calls `func_000123B8` — three instructions
that return `global+0x80` — and bails with `CELL_GCM_ERROR_FAILURE` if it is zero.
`global+0x80` is the out-param of **syscall 25**, called as
`get_sdk_version(getpid(), &out)`, which was an unimplemented stub returning `CELL_OK`
with the out-param untouched: SDK 0.

What identified the syscall was what libgcm does with the value next — `func_00012018`
is a compatibility ladder that turns it into the RSX local-heap size:

| threshold | local memory |
|---|---|
| `> 0x21FFFF` (SDK ≥ 2.20) | `0xF900000` — 249 MB |
| `> 0x1FFFFF` (SDK ≥ 2.00) | `0xF200000` — 242 MB |
| `> 0x18FFFF` (SDK ≥ 1.90) | `0xEA00000` — 234 MB |
| `> 0x17FFFF` (SDK ≥ 1.80) | `0xE800000` — 232 MB |
| else | `0xE000000` — 224 MB |

SDK-version-shaped constants, one rung per firmware release that freed up more VRAM.
Implementing `sys_process_get_sdk_version` (reporting 3.6.0, `PS3_SDK_VERSION`
overrides) is what unblocked the GPU. A process syscall, not an RSX one.

**One supporting fix:** `PS3_SCTRACE` traced both *handled* syscall paths but not the
stub path — so it showed everything except the unimplemented syscalls, which are the
ones a trace is wanted for. Getting the RSX argument contract needed that trace.

**Measured:**

```
[sys_rsx] device_map(dev=8) -> 0x20030000
[cellGcmSys] Init(cmdSize=0x10000, ioSize=0x0, ioAddr=0x00000000)
[sys_rsx] memory_allocate(size=0xF900000 flags=0x80000) -> local=0xC0000000
[sys_rsx] context_allocate -> dma_control=0x20001FC0 (ctrl=0x20002000) mode=0x820
[sys_rsx] iomap io=0x00000000 <- ea=0x40100000 size=0x400000
[sys_rsx] FIFO put=0x00001000 get=0x00001000
[RSX] methods 0x0180..0x01B8 = 0xFEED0000/0xFEED0001    <- context DMA setup, from the FIFO
[cellGcmSys] SetDisplayBuffer(id=0, offset=0x310000, pitch=5120, 1280x720)
[live-draw]  display buffer 0 = loc0:0x00310000 pitch=5120 1280x720
[live-draw]  display buffer 1 = loc0:0x00694000 pitch=5120 1280x720
InitMenu Start c1d00000 / InitMenuManual / InitMenu End c36e2000
[fps] 60.0   clears[guest=1]   0 "no IO mapping" resyncs
```

The screen is still black, which is expected: `clears[guest=1]` is the only thing
drawn, because the emulator core has not started. No geometry exists yet.

## Next steps

1. **Raw SPU.** `sys_raw_spu_create` (160) + the `0xE0000000` MMIO problem-state window,
   dispatching to the lifted images registered in `src/spu_images.c`. This is the
   blocker for everything visible.
2. `/dev_flash/data/font/SCE-PS3-RD-R-LATIN2.ccd` is missing from the dev_flash tree
   (only the `.TTF` set is installed), so the menu has no font to render with.
3. Attribute packets `0x300`/`0x301`/`0x302` (tiles, Z-cull) are accepted and ignored;
   they affect surface layout and will matter once geometry is drawn.
4. Then: disc mount (`EBOOT.PBP` → `PSISOIMG0000`), input, audio, memory cards.
