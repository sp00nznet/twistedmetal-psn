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
| 10b. Raw SPU | `sys_raw_spu_*` + `0xE0000000` MMIO | ✅ — all 5 SPUs load, run and handshake |
| 11. BIOS | `ps1_rom.bin` loads | ✅ |
| 11b. Launch args | the nine the VSH passes a PSOne Classic | ✅ — title, region, target, manual read |
| 12. Disc | image opened (`ISO.BIN.EDAT`) | ✅ — unblocked by the `cellAdecOpen` ABI fix |
| 12b. NPDRM | EDAT decryption | ✅ — `PSISOIMG0000`, serial `_SCUS_94304` |
| 12c. Mount | image mounts with a non-zero track count | ⬜ — blocked here: `ExitPS1(): code=3` |
| 13. Render | Twisted Metal on screen | ⬜ |
| 14. Input / audio / VMC | | 🔄 — pad read served; audio + VMC threads up |

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

### What was next at that point (both since done)

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


### 2026-09-01 (evening) — Raw SPU: all five cores running

**Phase 10b — COMPLETE.** Every raw SPU the emulator asks for comes up: four running the
86 KB GPU core (the banner's `-sgpu-sli4` is literal — a four-way SPU GPU) and one running
the 59 KB second module. Each loads its image, starts at its ELF entry, writes its ready
word to the outbound mailbox, and takes command words back. `ps1_netemu` then completes its
whole subsystem bring-up — fonts, `cellAudio` port open + mixing thread, `cellPad` across
seven ports, `_xMcThread` (memory card), `_xcdrom_thread`, `sceNp`, `cellAdec` — and idles
at 60 fps.

Written as `ps3recomp/runtime/spu/spu_raw.c`. Full write-up in
[`docs/raw-spu.md`](docs/raw-spu.md); the short version is four failures, each hiding the
next.

**1. The syscalls.** Numbers read off the call sites: 150 `create_interrupt_tag`,
151/152 `set/get_int_mask`, 153/154 `set/get_int_stat`, 160 `create`, 161 `destroy`,
163 `read_puint_mb`. 163 was identified from how it is used rather than by name — the
interrupt thread does `get_int_stat(id,2,&st); if (st & 1) { 163(id,&v);
set_int_stat(id,2,1); }`, which is the read half of a class-2 mailbox interrupt.

**2. `sys_raw_spu_image_load` is not a syscall.** With every syscall implemented the SPU
started and stopped after **two instructions** at pc 0, with local store all zeros
(`nonzero lines=0/4096`). Nothing had loaded the image. libsysutil exports the load, so it
arrived as a NID and the stub logged one line and returned success. It was already in the
trace, between the import and the run:

```
[hle] unresolved NID 0xB995662E   = sys_raw_spu_image_load
[hle] unresolved NID 0xE0DA8EFD   = sys_spu_image_close
```

Both identified by computing NIDs for candidate names against those two values. Implementing
the load (walk the descriptor's segment array, COPY/FILL into the window, set NPC) brought
local store up to `84992 bytes, 1324/4096 nonzero lines`.

**3. Both SPU images had been lifted at the wrong base — my error, now a hard error.**
`spu_lifter.py` has two modes and the difference is silent: given an ELF positionally with
`--functions`, it reads the file as a **raw image at base 0**, so the ELF header becomes the
first instructions and every function lands at its **file offset**. This image is
`p_offset 0x100` / `p_vaddr 0x80`, so everything sat 0x80 low and the SPU executed the wrong
instructions — code that compiled, linked and ran. The tell was the entry: LS 0x100 is
`ila $r8, 0x3FFD0`, a stack-pointer setup and a plausible `_start`, but the lifted
`spu_func_00000100` began `ila $r2, 0xC6D0`. `--auto-functions` parses the ELF and lifts at
the load address. The lifter now refuses the ambiguous combination outright.

**4. A published register went stale and deadlocked both sides.** With correct code the SPU
booted, handshook (`out mbox = 0x00015010`), the PPU read it and sent one command word — and
then both waited forever. `SPU_MBox_Status` was being *published* into guest memory on MMIO
operations, but the SPU consumes its inbound mailbox on its own thread through the channel
layer, touching no MMIO path — so the published copy still read "0 free slots" after the SPU
had drained it. The PPU never sent a second word; the SPU waited for one. Derived registers
(`SPU_MBox_Status`, `SPU_Status`) are now computed on read.

**One structural change to the runtime.** `spu_context.ls` was a 256 KB array inside the
context. A raw SPU's local store cannot be a private copy: lv2 maps it into the process and
the PPU writes the SPU's code and command buffers there *while it runs*, so copy-in/copy-out
would race every frame. `ls` is now a pointer — `ls_store` for every other context,
`vm_base + window` for a raw SPU. Every `ctx->ls[i]` / `&ctx->ls[i]` / `ctx->ls + n` in the
runtime still compiles and means the same thing.

**A fingerprint footnote.** `spu_workload_fingerprint()` says FNV-1a-64 but its offset basis
is `1469598103934665603` — one digit short of the real `14695981039346656037`. The
constants in `src/spu_images.c` had been computed with the canonical basis and matched
nothing. It is only a hash and every shipped port is already keyed to it, so match it rather
than "fix" it; but it does mean those constants cannot be reproduced by a stock FNV-1a-64.

**Measured:**

```
[spu-raw] create -> raw spu 0, window 0xE0000000
[spu-raw] image_load spu0: 3 segments, 84992 bytes into LS, NPC=0x00100
[spu-raw] spu0 START pc=0x00100 ls=guest:0xE0000000 image=1 nonzero lines=1324/4096
[spu-raw] spu0 out mbox = 0x00015010      R spu0 OUT_MBOX -> 0x00015010
[spu-raw] W spu0 +0x4400C = 0x40600000    W spu0 +0x4400C = 0x00D70E80
   ... spu1, spu2, spu3 identically ...
[spu-raw] create -> raw spu 4, window 0xE0400000
[spu-raw] image_load spu4: 3 segments, 58208 bytes into LS, NPC=0x000E0
[spu-raw] spu4 out mbox = 0x0000E500
[spu-raw] W spu4 +0x5C00C = 0x60000000 / 0x60000800 / 0x60001000 ...   (SigNotify2)
App:Fonts Initialize Lv1 pass!
[cellAudio] PortOpen(nChannel=2, nBlock=8) / Mixing thread started
[fps] 60.0
```

The screen is still black, and `groups[seen=0 exec=0]` says why: no geometry has reached
the renderer. The emulator has not loaded the disc.


### 2026-09-01 (late) — Input served; the real blocker located

Two fixes, and a diagnosis that changes what "stuck" means here.

**The unnamed pad read, served without knowing its name.** `sys_io` imports six
functions; five compute cleanly from their names, and the sixth — `0x3733EA3C` — matched
none of ~120 candidate libpad/libkb/libmouse spellings against the (verified) NID
algorithm. It is *not* `cellPadGetData`, which is `0x8B72CDA1` and is not imported at all.

The name was not needed; the call site gives the contract. `ps1_netemu`'s pad poll
(`func_000EB784`) is

```
cellPadGetInfo2(&info2);                       // 0x15E8AC, named
for (port = 0; port <= 6; port++)
    if (info2.port_status[port] & 1)
        UNNAMED(port, &slot[port].extra, &slot[port].data);
if (slot[port].data.len) { ...consume... }
```

and the prologue pins the layout: `addi r27,r1,276` … stride 136, with each call passing
`r4 = r5 + 132`. A 136-byte per-port slot of `{ CellPadData data; u32 extra; }`. That the
132-byte half really is a `CellPadData` is not a guess — `sizeof(CellPadData)` is
`4 + 2*CELL_PAD_MAX_CODES` = 132 exactly, the guest `memcpy`s 132 bytes out of it, and it
gates on the first word, which is `.len`. Confirmed at runtime: the two pointers came in
0x84 = 132 apart.

Served from the runtime's own `cellPadGetData` in `src/hle_overrides.c` — kept in the port
rather than `libs/input/cellPad.c`, because the mapping rests on one firmware module's
call site rather than a known libpad export.

**`cellGame` was reporting a placeholder title id.** The harness reads it from
`<vfs>/PS3_GAME/PARAM.SFO`; our layout only had the package's SFO under
`dev_hdd0/game/NPUI94304/`, so it kept `BLES00000` and every `/dev_hdd0/game/<id>` path it
built pointed at a title that does not exist. `tools/run.sh` stages the file now.

Worth recording, because it breaks an assumption the harness makes: for a **PSOne Classic**
the SFO's `TITLE_ID` is the **PS1 serial** (`SCUS94304`), while the content directory is
named from the *content id* (`NPUI94304`). "Title id == directory name" holds for ordinary
PS3 titles and not for this category.

**The diagnosis: it is not stuck — it thinks it is already running.** Reading the main
thread's loop (it sits at `lr=0x000B1434` forever):

```
func_000B13F8:  func_00105D74()                 ; exit_flag = 0
  loop:         cellSysutilCheckCallback()
                if (func_00105D84() != 0)       ; exit_flag still 0
                    { sys_timer_usleep(16666); goto loop; }
                ...shutdown path...
```

`func_00105D84` reads one word and reports "still zero"; the only writer that sets it is
`func_00105E18`, which prints `R3000Exit(): PS1_EXIT_STOP` first. So this is the
*game-is-running* loop, and the emulator will sit in it until the PS1 CPU halts. It
believes it has a disc and is emulating one.

It has just never been told which. **Nothing in the whole run ever opens `EBOOT.PBP`.**

The lead is `argv`. The emulator imports **no `cellGame` at all** — twelve libraries, none
of them `cellGame` — so its content path cannot come from `cellGameContentPermit`. On
hardware the VSH launches `ps1_netemu` with the path on the command line, and the emulator
does echo what it receives (`argc=%d` and `argv[%d]=%s` at `0x170F48`/`0x170F58`, printed
during boot). The harness hardcodes one argument,
`argv[0] = /dev_bdvd/PS3_GAME/USRDIR/EBOOT.BIN` (`YDKJ_BOOTPATH` overrides it) — correct
for a disc title, meaningless to this one.

Two details to settle before guessing at contents: the emulator's argv walker reads
**32-bit** pointers (`lwz r5,0(r9)` / `addi r9,r9,4`) where the harness writes 64-bit
slots, and nobody has established what the VSH actually passes for a PSOne Classic.

**State after this round:** 5 raw SPUs running, graphics stack up, pad served, all
subsystems initialised, ~32 fps (down from 60 — the five SPU host threads now cost real
CPU). Six NIDs remain unresolved and none has yet been shown to matter: `0x1DFCCE99`
(cellSysutil, called once with r3=2 just before the main loop), `0x26090058`
(`sys_prx_load_module`, soft-fails harmlessly), `0x56DFE179`, `0x7E4A4A49`, `0xBDB18F83`,
`0xFDBF6AC5`.


### 2026-09-01 (night) — The launch arguments; RPCS3's source as the oracle

A full RPCS3 **source** tree turned out to be sitting at `tools/rpcs3-caner/`. That
changed the character of this round: three things that had been reverse-engineered from
call sites got confirmed outright, and the one thing that could not be reverse-engineered
— what the VSH passes on the command line — was simply written down there.

**The nine arguments.** `Emu/System.cpp`, `m_cat == "1P"`:

```
argv[0]  /dev_flash/ps1emu/ps1_newemu.self   the emulator self
argv[1]  <PS1 serial>_mc1.VM1                virtual memory card 1
argv[2]  <PS1 serial>_mc2.VM1                virtual memory card 2
argv[3]  0082                                region target
argv[4]  1600                                resolution scale ("purely a guess")
argv[5]  /dev_hdd0/game/<content dir>         the game folder -- NOT the serial
argv[6]  1
argv[7]  2                                   full screen?
argv[8]  1                                   smoothing?
```

plus two 128 KB zero-filled memory-card files under `/dev_hdd0/savedata/vmc/`.

Note the naming split, the same wrinkle that bit `cellGame` earlier: argv[1]/[2] are named
from the **PS1 serial** (`SCUS94304`), argv[5] from the **content id** (`NPUI94304`).

`ppu_loader.cpp` wrote exactly one argument — fine for a disc title, nowhere near enough
here. It now honours `PS3_ARGV=<a1>;<a2>;...` and builds the layout lv2 really uses:
64-bit big-endian pointer slots, NULL-terminated, then a NULL envp, each string 16-byte
aligned after the slots — verified against RPCS3's `ppu_load_exe`. For a single argument
the bytes are identical to what it produced before, so no other port moves.

Two Git-Bash traps: MSYS rewrites POSIX-looking paths in *environment values* handed to a
native binary, so `YDKJ_BOOTPATH=/dev_flash/...` arrived as `C:/Program Files/Git/...`.
`MSYS2_ENV_CONV_EXCL="*"` stops that — and then stops it for the *host* paths too, so
`PS3_HDD0_ROOT` arrived as `/g/recomp/...` and every lookup missed. `tools/run.sh` now
converts host paths explicitly with `cygpath -m` rather than relying on a heuristic that
has to guess which kind each value is.

**And it works.** The emulator reads all nine and acts on every one that matters:

```
argc=9   argv[0]=/dev_flash/ps1emu/ps1_netemu.self   argv[5]=/dev_hdd0/game/NPUI94304
g_strTitle NPUI94304
[sys_fs] open OK: .../dev_hdd0/game/NPUI94304/USRDIR/CONTENT/DOCUMENT.DAT
TITLE ID : SCUS94304
InitMenuManual OK!! PageNum = 30
target: /dev_hdd0/game/NPUI94304<0>
REGION NUM = 0x00000082 code=A          <- 0x82 straight out of argv[3]="0082"
```

It has found the package, read the 30-page manual out of `DOCUMENT.DAT`, taken its region
from argv[3] (it was `0x81` before), and set its disc target.

**Three earlier identifications confirmed.** `sys_io_3733EA3C` exists in RPCS3 with the
*exact* signature derived here from the call site — `(u32 port_no, vm::ptr<u32>
device_type, vm::ptr<CellPadData> data)` — commented "Used by the ps1 emulator built into
the firmware", forwarding to `cellPadGetDataExtra`, which is what ours does. And RPCS3's
NID name table gives `0xB995662E` = `sys_raw_spu_image_load` and `0xE0DA8EFD` =
`sys_spu_image_close`, both as guessed last round.

**Two real bugs found and fixed.**

`_sys_malloc` / `_sys_free` / `_sys_memalign` / `_sys_realloc` were missing from
`sysPrxForUser` entirely. An unimplemented import is not neutral: the generic stub returns
`CELL_OK` with `r3` holding whatever was already there, i.e. a garbage pointer the caller
then writes through. `cellUsbdInit` failed on it; with the allocator in (forwarding to the
same bump allocator the `sys_heap_*` family uses) it initialises and creates its threads.
RPCS3's table confirms `0xBDB18F83` is `_sys_malloc`.

`PS3_SCTRACE` was printing the **return value in the first argument's column** for every
*implemented* syscall — it passed `ctx->gpr[3]` after dispatch had already overwritten it.
The first argument is the object id across most of lv2, which is the entire reason to read
a syscall trace; the first pass at the CD-ROM thread was read completely wrong because of
it (an ESRCH result looked like an ESRCH-shaped *handle*). Everything below depended on
fixing this first.

**Where it stops now, precisely.** It has the game and never opens `EBOOT.PBP`.
`_xcdrom_thread` starts and spins **158,738 times** on `sys_semaphore_wait` with **id 0**:

```
[sc] 47(0x8, 0x3E8, ...)            -> 0            set_priority
[sc] 90(0x76A760, 0xD0022CB0, 0, 1) -> 0            sys_semaphore_create
[sc] 92(0x4, 0x30D40, ...)          -> 0            wait(id 4, 200 ms)  -- fine
[sc] 93(0x0, ...)                   -> 0x80010005   ESRCH
[sc] 94(0x0, 0x1, ...)              -> 0x80010005   ESRCH
[sc] 92(0x0, 0x0, ...)              -> 0x80010005   ESRCH   x158,738
```

The two ids it uses live at `+0x70B8`/`+0x70BC` of its object (`lwz r3,0x70BC(r26)` at
`0xEFEA0`, `lwz r3,0x70B8(r26)` at `0xEFECC`). The code that creates such a pair is at
`0x10FFC8`/`0x10FFF4` (`addi r3,r31,56` / `+60` — the same two words seen through a
different base). It runs twice, for two *other* instances, and never for this one: a
construction step upstream was skipped.

Ruled out along the way:

- **Not a missing file.** The only failing opens in an entire run are four `SCE-PS3-*.ccd`
  font probes, each of which falls back to its `.TTF` and succeeds.
- **Not the argv.** All nine arrive and visibly change behaviour.
- **Not `ps1_newemu` vs `ps1_netemu`.** RPCS3 launches `newemu`; its import table is a
  strict *subset* of `netemu`'s (7 fewer — five `cellAudio`, two `sysPrxForUser`), so they
  are the same codebase and handle argv the same way.
- **Not the allocator.** `_sys_malloc` is in now and `cellUsbdInit` succeeds.

Also worth recording: syscalls **90-94 are the semaphore family** (`create`, `destroy`,
`wait`, `trywait`, `post`), which is what the emulator uses for CD-ROM command handoff.
The first read of that trace mistook them for the event-queue family because our own table
puts event queues at 128+; the numbers in the table are right, the reading was not.


### 2026-09-01 (late night) — The disc opens: one wrong function signature

`_xcdrom_thread` was spinning 158,738 times on `sys_semaphore_wait` with id 0. Four steps
from there to the cause, each one narrowing the search rather than guessing:

**1. Which object?** Added `SEM_BADID=1` to `sys_semaphore.c`: on a wait/post against an id
that was never created, report the caller and every pointer-shaped register once per
(id, lr). The id itself says nothing — where the guest *read* it from is the diagnosis.
It gave `r26 = 0x00764000`, `r31 = 0x003B4000`; the code computes `addis r26, r31, 0x3B`,
so the missing ids live at `0x76B0B8`/`0x76B0BC` of a TOC-global object.

**2. Which creator?** That is a `+0`/`+4` pair. Of the ten `sys_semaphore_create` sites in
the image exactly one creates such a pair — `0xED5D4`/`0xED600`, inside `func_000ED3CC`,
which reads the same TOC global (`-0x7AEC`), does `addis r30, r9, 0x3B` and memsets
0x3B8000 bytes. The CD-ROM object's constructor.

**3. Did it run?** The runtime's `[sem] create` line already prints the guest LR, and
semaphore **id=8** carried `lr=0x000ED4D8` — the return address of the `bl` at `0xED4D4`,
inside that constructor. So it ran and cleared its first three gates
(`sys_net_initialize_network_ex`, `sceNpInit`, `cellAdecQueryAttr`). The bail had to be in
the ~0x30 instructions between that create and the pair.

**4. Which of the two exits?** That span has exactly two: `cellAdecOpen` returning non-zero,
and a `memalign(128, 0x40000)` returning null. The log answered it — `[cellAdec]
Open(codecType=5)` appeared but the `Open -> handle=` line that follows a success did not.

**The bug.** `cellAdecOpen` takes **four** arguments, `(type, res, cb, handle)`. Ours took
five, splitting the guest's `CellAdecCb` struct into separate `cbFunc` and `cbArg`
parameters — `cb` is a *pointer* to `{ u32 cbFunc; u32 cbArg; }`, not two registers. That
pushed `handle` off `r6` onto `r7`, which held whatever was left there, so the null check
failed and **every** `cellAdecOpen` returned `CELL_ADEC_ERROR_ARG`. The call site says the
same thing outright: `r5 = r1+128`, and the two words written there just before the call
(`stw r11,0x80(r1)` / `stw r25,0x84(r1)`) are a two-field struct built on the stack. RPCS3
has the four-argument form at `Modules/cellAdec.cpp:1577`.

`ps1_netemu` opens a decoder for CD-DA / XA-ADPCM audio *inside its CD-ROM constructor*,
so one wrong parameter list meant no disc — and it presented three subsystems away, as a
thread spinning on a semaphore that was never created.

**With it fixed, the disc opens:**

```
[cellAdec] Open(codecType=5, cb=0xD0022C80, handle=0x0076A700)
[cellAdec] Open -> handle=0
slot1 = NULL / slot2 = NULL
load config file: /USRDIR/    -> EISDIR, "failed"   (non-fatal, see below)
[hle] unresolved NID 0xAD218FAF                      <- sceNpDrmIsAvailable
[sys_fs] open OK: .../NPUI94304/USRDIR/ISO.BIN.EDAT  <- the disc
ExitPS1(): code=3 <0>
cell/host.c: 625: CoreBoot() failed
```

**The new wall is NPDRM.** `ISO.BIN.EDAT` is an encrypted EDAT. On lv2,
`sceNpDrmIsAvailable(klicensee, path)` primes the kernel to decrypt that path
*transparently*, so the following `cellFsOpen` returns plaintext. Ours is unimplemented,
returns `CELL_OK`, and the plain open hands the emulator ciphertext — it reads a garbage
header and exits with code 3.

Confirmed by substitution rather than assumed: the archive's second package carries a
DRM-free `ISO.BIN.EDAT` (NPD **version 3, license type 3** — the free form — against
retail's version 1 / type 2, which is bound to a console key). Swapping it in changes
nothing, because nothing decrypts *either* form yet.


### 2026-09-02 — NPDRM: the disc decrypts

`ISO.BIN.EDAT` now comes back as `PSISOIMG0000` with the PS1 serial `_SCUS_94304` in its
header, transparently, through the ordinary filesystem path.

**Where it belongs.** The guest never decrypts an EDAT itself: it calls
`sceNpDrmIsAvailable(klicensee, path)`, the kernel notes the path, and every later
`cellFsOpen`/read returns plaintext. So this is a filesystem concern, not a guest one —
`libs/filesystem/edat.c` decrypts a file beginning `NPD\0` once into a `<name>.dec` cache
and opens that in its place. Path substitution rather than a read hook, which is why every
read/seek/stat path above it stays unchanged and `sceNpDrmIsAvailable` can remain a no-op.

**The format.** NPD header, then EDAT header (flags, block size, file size), then one
0x10-byte CMAC per block at 0x100, then the encrypted blocks. Per block the key is
`dev_hash[0..0xB]` (zeros for NPD version ≤ 1) plus the big-endian block index, AES-ECB
encrypted under the file key; that result is both the AES-CBC key for the data and the
AES-CMAC key for the block hash. IV is the NPD digest, or zeros for version ≤ 1.

**The file says which key it wants.** `dev_hash` is `CMAC(klic ^ NP_OMAC_KEY_2)` over the
header's own first 0x60 bytes, so rather than branching on content type, `edat.c` tries the
published candidates and keeps the one that verifies. For a PSOne Classic that is
**`NP_PSX_KEY`**.

**A verified klicensee is not a decryptable file.** The retail `ISO.BIN.EDAT` is license
type 2: `NP_PSX_KEY` verifies against its `dev_hash` and then every block hash fails,
because the *data* is under the RIF key from a per-console RAP. That cost a round of
debugging, so the code now says exactly that instead of reporting a hash mismatch. The
archive's second package carries the same file as license type 3, where the klicensee *is*
the file key — that one decrypts, and it is what `vfs/` should hold.

**Three checks, because silently-wrong crypto is the expensive failure here.**
`edat_selftest()` verifies AES-128 against FIPS-197 (both directions) and AES-CMAC against
RFC 4493 before anything is decrypted; the `dev_hash` CMAC picks the klicensee; and every
block's CMAC is checked, stopping the whole decryption and deleting the partial cache on a
mismatch rather than writing garbage. The third one earned its keep immediately — it caught
the NPD-version-1 rule (zero block-key seed, zero IV) by failing block 0 on the first
attempt instead of producing a megabyte of noise.

Scope: uncompressed EDATs with AES-CMAC block hashes. Compressed blocks, the 0x20/0x10
metadata layouts, encrypted-ERK files, debug data and RAP-bound license types are refused
by name rather than mis-handled. AES-128 and AES-CMAC are implemented in the file, so the
runtime still has no crypto dependency.

**Where it stops now.** The emulator opens the decrypted image and still exits `code=3`.
The exit is exact — at `0x110E20`:

```
bl 0xEE018                ; mount the image -- returns >= 0, so this SUCCEEDS
bl 0xED2E0                ; three instructions: return *(s32*)(cdrom_obj + 0x70D8)
cmpwi cr7, r3, 0
bgt  cr7, 0x110134        ; > 0 -> carry on
li   r3, 3 ; bl ExitPS1   ; otherwise give up
```

The image mounts; the track/sector count at `+0x70D8` stays zero.

The plaintext suggests why. It is 1,048,616 bytes with only **161 of its 2049 512-byte
blocks non-zero**: `PSISOIMG0000`, the serial `_SCUS_94304` at 0x400, a CD TOC at 0x800 —
and no 300 MB of disc. This package is the hybrid PSP/PS3 form, where the real image is the
68 MB `DATA.PSAR` inside `USRDIR/CONTENT/EBOOT.PBP`, and nothing in the run opens that file.

## Next steps

1. **Read `func_0000EE018`** (the mount) and find what it fills `cdrom_obj + 0x70D8` from,
   and whether it is meant to open `EBOOT.PBP` for the sector data. That is the last
   unknown between here and a PS1 executable running.
2. Then: R3000 execution and geometry.
3. Still open: a bare `/USRDIR/` config path resolves to the VFS root and fails `EISDIR`
   (non-fatal); `cellAdecQueryAttr` (`0x7E4A4A49`) returns `CELL_OK` with its attr struct
   untouched; `sys_interrupt_thread_establish` (84) / `eoi` (88) are stubs; attribute
   packets `0x300`/`0x301`/`0x302` (tiles, Z-cull) accepted and ignored.
