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
| 12c. Header | read, streamed and hashed | ✅ — guest SHA-1 matches Python byte for byte |
| 12d. Body | disc body opens (`EBOOT.PBP`) | ✅ — header signature verifies |
| 12e. Boot | firmware boots the PS1 title | ✅ — `North American Title detected!` |
| 12f. SPUs | all SPU cores run without stalling | ✅ — Lr event + usbd receive |
| 12g. Core | R3000/GTE core runs | ⬜ — blocked: event queue id 0 |
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

**Where the mount actually stops (same day, after the comparison).** Of the seven writes
to `cdrom_obj + 0x70D8`, five reset it to 0; the two that make it positive are both in
`func_000EFBA8`, the CD-ROM streaming reader, and both sit behind one gate:

```
000F002C:  bl    0xA8088            ; func_000A8088 is memcmp(a, b, n)
000F0038:  bne   cr7, 0xF09B8       ; mismatch -> error path, count stays 0
000F004C:  stw   r0, 0x70D8(r30)    ; match    -> count = 1
```

with `r3 = r27` (the reader's own first argument), `r4 = *(TOC-0x7A34) = 0x175610 =
"PSISOIMG0000"`, `r5 = 12`. The whole disc path turns on a 12-byte magic comparison, and
our decrypted file begins with exactly those bytes -- so the open question is what lands in
that buffer, not whether the plaintext is right.

One correction worth carrying forward: `*(TOC-0x7A38) = 0x76B004` looked like the reader's
ring buffer and is not. Watching it showed `67452301 EFCDAB89 98BADCFE 10325476 C3D2E1F0`
-- the SHA-1 initial constants. It is a SHA-1 context; there is an integrity-hash step in
this path too.

Also confirmed: the `sys_semaphore_wait` ESRCH spin is gone since the `cellAdecOpen` fix,
so this is genuinely the next failure rather than the previous one resurfacing.

**The package form, checked against a second title.** `2Xtreme [NPUI-94508]` from
`X:/Roms/PS3/PSN` has the identical layout, including an `ISO.BIN.EDAT` of **exactly** the
same 1,049,920 bytes. So that size is what this package form always is, not a truncation,
and the emulator is expected to cope with it. Both titles also ship a separate `_Crack.pkg`
whose only payload is a license-type-3 `ISO.BIN.EDAT`.

| | Twisted Metal [NPUI-94304] | 2Xtreme [NPUI-94508] |
|---|---|---|
| `USRDIR/ISO.BIN.EDAT` | 1,049,920 | 1,049,920 |
| `USRDIR/CONTENT/EBOOT.PBP` | 68,727,509 | 59,461,367 |
| `USRDIR/CONTENT/DOCUMENT.DAT` | 5,105,104 | 1,859,880 |

The two halves carry different things. `EBOOT.PBP`'s `DATA.PSAR` (at 0x18000) also begins
`PSISOIMG0000`, but its payload from 0x400 is `\0PGD` -- PSP **PGD**-encrypted, the POPS
path. The decrypted `ISO.BIN.EDAT` has that same region in the clear: the serial
`_SCUS_94304` at 0x400 and a valid CD TOC at 0x800 (points A0/A1/A2 -- first track 1, last
track 9, i.e. a data track plus eight CD-DA tracks). So the EDAT is the PS3-side header and
index; the PSAR is the bulk data, under a second and different encryption.

## 2026-09-02 — The disc path is correct; one signature gate remains

Traced the mount failure to its exact instruction, and in doing so proved the whole disc
chain correct.

**Two earlier readings were wrong and are corrected.** The `PSISOIMG0000` compare *passes* --
a watch on `cdrom_obj + 0x70D8` shows `func_000EFBA8` writing the track count at `0xF004C`,
the match branch. And the exit is via `0x111BC8`, not `0x110E50`: the reader returns `-1` and
`0x1111AC` branches straight into `ExitPS1(3)`.

**The two-file design, confirmed from the binary.** `func_000EFBA8` builds *both*
`/USRDIR/ISO.BIN.EDAT` and `/USRDIR/CONTENT/EBOOT.PBP`. Diffing the decrypted EDAT against
`DATA.PSAR` shows only 29% of the first megabyte matching, with the PSAR being `\0PGD`
ciphertext from 0x400 on while the EDAT holds the same region in the clear. So
`ISO.BIN.EDAT` is Sony's *decrypted, signed* copy of the PSAR header; the PS3 never runs PGD
and streams the body from the PBP. The subsystem names itself: `pspi/pspi.c`.

**Proof that our side is right.** The reader consumes the whole header (position climbs in
0x1000 steps to exactly 0x100000, then 0x100028 for a 40-byte trailer) and hashes it. The
digest the guest computes is `6c55da7ff8eb8c09df8d5269dca4444b561097aa` -- byte for byte what
Python computes over `dec[0:0x100000]`. That one comparison validates the EDAT decryption,
the block-key derivation, the ring buffer's ordering and the lifted SHA-1 at once.

**Where it stops.** At `0xF132C`, immediately after `SHA1_Final`, the emulator reads the
40-byte trailer and calls `func_00010D24(sig, hash, key@0x175510, 2)` -- an ECDSA verify over
curve 2 of a table at `0x15F7F0`. On success it closes the EDAT and opens `EBOOT.PBP` at
`0xF1590`; that instruction is the only one in the image that points the open-path field at
the PBP buffer, and a watch confirms it never runs. The verify fails, so the disc body is
never opened.

Ruled out: not a stubbed dependency (the verify calls only real code, no import trampolines);
not the hash input; and not our carry arithmetic on review (`adde`, `subfe`, `addc`, `subfc`,
`addze` all lift correctly, that path having already had one such bug found and fixed).

Left deliberately undone: patching the check out. It is an integrity check on content we did
not author, and disabling it would prove nothing about whether the recompilation is correct.

Tooling: added `LBP_WW_MAX` (raise the 64-hit cap) and `LBP_WW_CHAIN` (dump the guest caller
chain on every hit, not just the first) to the store watchpoint -- which is how the teardown's
nine call sites were narrowed to the one at `0xF0930`. Also repaired a stray NUL byte that an
earlier scripted edit had left in `README.md`.

Detail: [`docs/disc-body.md`](docs/disc-body.md).

## 2026-09-02 (later) -- the signature is valid; the bug is ours

Recovered the ECDSA curve and verified the disc header's signature offline. **It passes.**

The curve is not in the ELF -- `*(TOC-0x6B0C)` points at `0x15F7F0` but nothing there parses
as a curve, because the table is built at runtime. So it came out of the guest's own memory:
`func_000109C4` copies six 20-byte fields into a 144-byte context (4-zero-padded to 24 bytes
each by `func_000108F0`), and replaying those stack writes in order -- before the struct is
reused as scratch -- gives them directly:

    p  = ffffffffffffffff00000001ffffffffffffffff
    a  = ffffffffffffffff00000001fffffffffffffffc   (a = p-3)
    b  = a68bedc33418029c1d3ce33b9a321fccbb9e0f0b
    Gx = 128ec4256487fd8fdf64e2437bc0a1f6d5afde2c
    Gy = 5958557eb1db001260425524dbc379d5ac5f4adf
    n  = fffffffffffffffeffffb5ae3c523e63944f2127

Table order is `p, a, b, N, Gx, Gy` -- the classic PS3 `curve_t`. Both the generator and the
public key at `0x175510` lie on the curve and `n*G` is the point at infinity, so it is fully
determined. Against it, `X.x mod n == r` exactly: the header is authentic and Sony-signed.

**So `func_00010D24` returns the wrong answer on correct data -- a ps3recomp lifter bug.**
That inverts yesterday's guess, and it also explains the crack correctly: an EDAT is only a
container, so re-wrapping the same plaintext under a free klicensee leaves the signature
intact. It has to, since cracked PSOne Classics ran on real consoles and this check is
unconditional.

Narrowed but not yet found. The fault is inside `func_001584A0`'s subtree (29 functions,
reached by direct call). Ruled out: no unlifted instructions anywhere in those 29 (56 other
functions in the image do have `TODO: .word` slots; none here); no stubbed imports, the
subtree is entirely image-internal; and every rare instruction in it checked correct against
PowerISA -- `addic` (twice in the whole image, once here), `sld`/`sld.`, `srd`, `cmpld` (50
uses), `divdu`, `mulld`, `mfcr` (38 uses), `mtcrf`, `subfic`, `sradi`, `neg`, `addze`,
`subfe`, `subfc`, `stdx` (the image's only one), `ldx`, including 64-bit widths and XER[CA]
carry-outs. Record-form CR0 comes from a generic wrapper, so `addic.`/`sld.` are covered, and
the CR nibble order is consistent across compares, that wrapper and `mfcr`.

Next is a differential harness rather than more reading: call the lifted `func_001584A0` with
the known inputs and bisect the 29-function tree against the intermediates computed in Python
(`w`, `u1`, `u2`, `u1*G`, `u2*Q`, `X`). Watching guest memory did not locate those values --
the bignum scratch is not in the reader's frame nor the window below it.

Detail: [`docs/disc-body.md`](docs/disc-body.md).

## 2026-09-02 (later still) -- the ECDSA bug, bisected to one stale limb

Built `src/ecdsa_probe.c`: `ECDSA_PROBE=1` drives `func_001584A0` directly with the exact
argument shape `func_00010D24` uses, through the generated `function_table`. Sub-second and
deterministic instead of a 40-second boot, and it reproduces what the real path does.

Bisected every stage against Python. The modular inverse `w`, both modular multiplies `u1`
and `u2`, and all three ECDSA range checks are **exact** -- a great deal of bignum arithmetic
working perfectly. Only the point arithmetic fails, and the Jacobian point the scalar
multiply returns is not on the curve, while its inputs (`G`, `Q`, the curve) are byte-exact.

Every wrong value has the same signature: limb 2 of a 4-limb bignum holds a pointer. Traced
with a store watch to `func_0015ABEC`, a leaf conversion using the PPC64 red zone: its inputs
are correct, its output is not, and the loop at `loc_0015AF68` (which shifts the limb array
down by one, `buf[i] = buf[i+1]`) propagates a stale top limb into limb 2. The copy at
`0x15B0AC` then hands it to the caller and it flows through the whole multiply.

Ruled out along the way: no unlifted instructions in any of the 29 subtree functions; no
stubbed imports; every rare instruction checked against PowerISA (`addic`, `sld.`, `cmpld`,
`divdu`, `mulld`, `mfcr`, `mtcrf`, `subfic`, `sradi`, `addze`, `subfe`, `subfc`, `stdx`,
`ldx`); the MD-form rotate decode hand-checked against the encoding; record-form CR0 and the
CR nibble order; the conditional-return forms; and the red zone, which is legitimate since
the function makes no calls.

**Runtime fix worth keeping:** `vm_write64` was never hooked into the `LBP_WW` store watch --
only 8/16/32-bit stores were. Every bignum limb and 64-bit struct field is written with `std`,
so a watch on one reported nothing and read as "nobody writes this", which is why several
earlier hunts for these values came up empty.

Detail: [`docs/disc-body.md`](docs/disc-body.md).

## 2026-09-02 (evening) -- THE DISC MOUNTS

The ECDSA bug is a **lifter bug**, found and fixed. `func_0015ABEC` is a Montgomery multiply
(its third argument is `2^384 mod p` = R-squared for R = 2^192, and `n' = 1` is correct since
`p` is congruent to -1 mod 2^64). At `0x15AED4` the guest does `ld r25, -0x78(r1)` -- a real
load of the high word of a two-word product temp -- and the lifter rewrote it to the cached
value of r25 at function entry, i.e. the CALLER's r25, a pointer. That went straight into the
carry chain.

Three conditions let the callee-save rewrite misfire, each individually reasonable: no `stdu`
(it is a PPC64 leaf keeping locals in the protected zone below r1); `_write_counts` saw no
write to -0x78 because the body writes it THROUGH a pointer (`addi r5,r1,-128` then
`std r9,0x8(r30)`); and `_off_escapes` matched only the exact taken offset -0x80. The prologue
saves r25 at -0x38, so the offsets never matched -- the register did.

Fix in `ppu_lifter.py`: attribute stores made through a frame pointer to the slot they land
on, by tracking registers holding `r1+off` across the zero-extend and register-move idioms.
Two broader fixes were tried first and both regressed `GPUCoreInit`, so the fix had to be
exact -- the heuristic is load-bearing elsewhere.

Result: the probe returns 0 (VALID), and the boot runs past every wall it has ever hit --
`title: 0xc0546d88U, "SCUS_943.04"`, `North American Title detected!`,
`boot from /dev_hdd0/game/NPUI94304`. `ExitPS1(): code=3` and `CoreBoot() failed` are gone,
`EBOOT.PBP` is opened for the first time, and every earlier milestone still passes.

Next: the PS1 core start-up. SPU 4 parks on a channel read at `pc=0x0A5E8` and the PPU spins
on `0xD0009F90` -- the R3000/GTE core waiting for work.

Detail: [`docs/disc-body.md`](docs/disc-body.md).

## 2026-09-02 (night) -- three stalls between the boot and the PS1 core

**The lost-reservation event had no producer.** SPU 4 parked forever at `rdch ch=0` with
evmask=0x400 -- `SPU_RdEventStat` waiting on `MFC_LLR_LOST_EVENT`, the standard "GETLLAR, arm
Lr, block until another processor writes the line" idiom. The runtime tracked reservations for
PUTLLC but never set the 0x400 bit; only 0x1 and 0x2 were ever produced. `spu_resv_lost_poll()`
compares the reserved line against the snapshot GETLLAR already takes -- one memcmp per 10 ms
poll on a blocked SPU, nothing on the PPU store path. 23 multi-second `ch-wait` stalls -> 0.

**`sys_usbd_receive_event` (540) returned instead of blocking.** 384,339 calls in a 45-second
run -- one thread spinning a core flat out. Identified from RPCS3's table and corroborated by
the guest loop's shape (dispatches event types, forwards 1/2 with `sys_event_port_send` = 138).
On hardware it sleeps until an event is queued; our stub returned CELL_OK instantly with the
out-params untouched, so the guest read type 0 and looped. Now reports "no event" explicitly
and sleeps 20 ms: 384,339 -> 2,203 calls, and every HOTREAD/ch-wait spin went to zero.

**A bare `/USRDIR/` resolved to the vfs root.** The flOw flattening in `sys_fs.c` sent
`/USRDIR/CONFIG` to `<vfs>/USRDIR/CONFIG`; this title has a full `/dev_hdd0/game/<ID>` tree.
`PS3_USRDIR_BASE` overrides it (opt-in, so flattened trees are unaffected) and run.sh points it
at the install tree. `save config file: /USRDIR/CONFIG` / `failed` is now a successful open.

Also: the window caption is now set explicitly via `PS3_TITLE` in run.sh, so it names this
title instead of inheriting a name from whichever port seeded the shared runtime.

Next: `tid=2` parks on `sys_event_queue_receive` with **queue id 0**, an uninitialised handle --
the same shape as the old `sys_semaphore_wait(id 0)` spin. The waiter is `func_0001A5D8`.

Detail: [`docs/ps1-core.md`](docs/ps1-core.md).

## 2026-09-03 -- THE PS1 CORE RUNS: the opcode dispatch table was never lifted

The R3000 executes, the PS1 GPU issues draw packets, and the emulator no longer exits.

**The cause was not the cycle budget.** Yesterday's note called the blocker a cycle budget of
0 at `+0x120`. That was a symptom read as a cause. A budget of 0 is *normal*: the interpreter
immediately calls `func_00105FA8`, which fires the due events and returns `next_due - now` as
the new budget. Poking the budget nonzero changed nothing --- which was the clue.

**What it actually was.** Tracing the interpreter's two exits showed one guest instruction
executed, then nothing:

```
[dbg] R3000 enter #1 pc=BFC00000 budget=00000000
[dbg] R3000 bctr  #1 ctr=001070E4 pc=BFC00004 insn=401A7800 budget=FFFFFFF7
```

`0x401A7800` is `mfc0 $k0,$15`, the PS1 BIOS's first instruction, fetched byte-reversed from
the right BIOS offset (`0xBFC00000 & 0x1FFFFFFF + 0xE0400000` wraps to 0). The fetch, the
i-cache cycle penalty at `0x107A74` and the PC advance were all correct. Only the dispatch
went nowhere: `0x1070E4` is inside `func_001066A8`'s range but was **not a label, not a
function, and not in the function table**, so `ps3_indirect_call` silently found nothing,
the interpreter returned, and the main loop at `0xB3E68` saw a status other than 5 and tore
the emulator down.

The dispatcher is a 128-entry jump table at `0x1B37D4` reached by
`lwzx r5, r19, r11; mtctr r5; bctr` at `0x1067D4`. `discover_jump_tables` missed it twice
over --- `JT_DEBUG=0x1067D4` named both:

1. `r_base=None`. The base load `lwz r19,-0x79CC(r2)` is at `0x106744`, **36** instructions
   before the `bctr`, outside the fixed 30-instruction window.
2. With the base supplied, `entry[0] raw=0x0 -> valid=False` and the decoder broke on the
   first invalid entry: **0 targets**. Index 0 is an opcode the table never dispatches.

Both fixed in `ppu_lifter.py` (function-bounded base scan clamped at the preceding `blr`;
leading null slots skipped, bounded at 4). 67 dispatchers / 654 case targets -> **68 / 718**,
with 127 targets decoded for this table.

**What that bought.** No more `ExitPS1` / `CoreBoot() failed` / `R3000Exit`. Instead:

```
title: 0xc0546d88U, "SCUS_943.04" P
North American Title detected!
boot from /dev_hdd0/game/NPUI94304[1] 0
[RSX null] set_render_target(format=0x9090148, 720x512)
[RSX] DRAW_ARRAYS prim=8 first=0 count=4
[fps] 205.2
```

720x512 is the PS1 framebuffer. GPU packets went 0 -> 6, `clears[guest]` 0 -> 6, and both
vertex and pixel shaders compiled.

**How far the R3000 gets.**

```
[dbg] R3000 disp 1     pc=BFC00004
[dbg] R3000 disp 3     pc=BFC00010
[dbg] R3000 disp 10    pc=BFC02038
[dbg] R3000 disp 100   pc=BFC02094
[dbg] R3000 disp 1000  pc=BFC022A4
[dbg] R3000 disp 10000 pc=BFC4B844
```

The reset sequence matches the BIOS byte for byte --- `mfc0 $k0,$15`, `nop`,
`sltiu $1,$k0,0x59`, `bne $1,$0,0xBFC00024` --- and only three of those five dispatch,
because `nop` is short-circuited before the `bctr` (`cmpwi cr7,r29,0; beq cr7,0x107978` at
`0x1067B8`). By 10,000 instructions it is at `0xBFC4B844`, deep in BIOS init.

By 40,000 it is at `0xBFC58820` and stops there, inside a BIOS **word-copy loop** --- an
ordinary `memcpy`, not a poll:

```
BFC5881C  lw    $t8, 0($a0)
BFC58820  addiu $a0, $a0, 4
BFC58824  sltu  $at, $a0, $v0
BFC58828  addiu $a1, $a1, 4
BFC5882C  bne   $at, $zero, 0xBFC5881C
BFC58830  sw    $t8, -4($a1)      ; delay slot
```

Note the rate: ~40,000 instructions over ~100 s of wall clock, against a 33 MHz PS1. The
interpreter neither returns nor takes the switch's `default` arm, so it is blocked *inside*.
Whether the slowness causes the stop or shares a cause with it is not yet established.

**The other half: SPU 4 is deadlocked on a reservation nobody breaks.** The audio core parks
at `pc=0x0A5E8`. Disassembling it names the event outright:

```
0A5E8  il    $r15, 1024              ; 0x400 = MFC_LLR_LOST_EVENT
0A5EC  rdch  $r14, SPU_RdEventStat
0A5F0  and   $r13, $r14, $r15
0A5F4  brz   $r13, 0x893C            ; not lost yet -> go round again
```

The runtime's producer for that bit already exists (`spu_resv_lost_poll`), and every gate it
checks passes:

```
[ch-wait] spu=4 pc=0x0A5E8 ch=0 waited=26000ms evstat=0x0 evmask=0x400 resv[valid=1 ea=0x002DEF80]
```

mask `0x400`, reservation valid, EA non-zero --- so the poll runs every time and finds the
reserved 128-byte line **unchanged**. Nobody writes `0x2DEF80`.

Ruled out: the audio event chain. `cellAudioPortOpen` -> `CreateNotifyEventQueue` (id 3, key
`0x8000000000000001`) -> `SetNotifyEventQueue` -> `PortStart` all succeed, the mixing thread
starts, and `_xSPUWaveOut` (tid 6) *cycles* on that queue rather than sleeping on it. So the
PPU side of audio is alive; it simply never touches the line SPU 4 reserved.

Also added: the `[ch-wait]` heartbeat now prints `evstat`/`evmask` and the reservation state,
which is what turned this from "an SPU is stuck" into a named event and address in one run.

Also repaired: two literal NUL bytes in this file where the PGD magic should have been the
escaped text --- the same scripted-edit damage previously fixed in README.md.

Detail: [`docs/ps1-core.md`](docs/ps1-core.md).

## 2026-09-03 (later) -- SPU 4's deadlock: `rchcnt` and `rdch` disagreed

The audio SPU parked at `pc=0x0A5E8` on `rdch SPU_RdEventStat` waiting for
`MFC_LLR_LOST_EVENT` (`0x400`), and every gate in our producer passed --- mask `0x400`,
reservation valid, EA `0x2DEF80`. The obvious reading was "nobody breaks the reservation",
and a store watch seemed to confirm it: the only writes to that line are zeros from an
initialiser at `guest-fn=0x000A7FB4`.

That reading was the symptom. The question worth asking was not *who breaks the reservation*
but **how the SPU got into a blocking read at all**, and the answer is a few instructions
earlier:

```
08934  rchcnt $r12, SPU_RdEventStat   ; is an event pending?
08938  brnz   $r12, 0xA5E8            ; yes -> commit to the blocking rdch
0893C  il     $r30, 8960              ; no  -> carry on working
```

It is a *guarded* read: the SPU asks first and only blocks if told an event is waiting.
`spu_rchcnt` had **no case** for `SPU_RdEventStat`, so it fell through to `default: return 1`
and always said yes. `rdch` then correctly blocked, because `(event_status & event_mask)` was
genuinely 0. The two disagreed, and the SPU was lured into a read it could never complete. On
hardware it would have fallen through to `0x893C` and kept working; the line at `0x2DEF80`
was never meant to change.

One case fixes it, with the same condition `spu_ch_ready` already uses (lost-reservation poll
included, so the two agree by construction):

```c
case SPU_RdEventStat:
    spu_resv_lost_poll(ctx);
    return (ctx->event_status & ctx->event_mask) != 0;
```

`ch-wait` stalls: 26+ seconds of blocking -> **zero**. The check is behavioural and cheap to
re-run: `grep -c ch-wait` on any run log should stay at 0.

That leaves interpreter throughput as the single open question.

## 2026-09-03 (evening) -- the RSX interrupt queue was never published

The R3000's stall at ~42,000 instructions traced three levels away from the interpreter, and
the fix unblocks the main guest thread.

**The chain.** The main thread parks on a flip:

```
[WAIT tid=1] semaphore_wait(sem=1 timeout=0 cia=0x00000000 lr=0x00113EB4)
```

Thread 1 is the thread running the R3000. `lr` puts the call at `bl 0x3030C` (`0x113EB0`),
inside a double-buffer flip -- bump the index at `+0x1C8`, queue the work, wait. Semaphore 1
is created `init=0 max=1`, waited on **once**, posted **zero** times; every other semaphore
balanced.

Nothing posts it because `_gcm_intr_thread` exits at once. It reads its queue id from
`*(context + 0x12D0)` and blocks there. Two readings had to be corrected on the way:

* the thread argument really is 0 (`li r5, 0` at `0x1A4A4`), but that is irrelevant --- the
  context comes from `bl 0x120E4` *before* r3 is used, which I first misread as the arg;
* an older note here said `0x2D80B4` is never written. It **is**: a store watch caught
  `0x2D80B4 <- 0x2D8044` from `cellGcmInit` at `0x1299C`, before the thread is even created,
  and `*(0x2D8054) = 0x20031000` is the context. The guest side was fine.

`0x20031000` is our own `RSX_DRIVER_INFO_EA`, and `+0x12D0` there is
`RsxDriverInfo::handler_queue` -- confirmed field-for-field against RPCS3's struct, where
`sys_rsx_context_allocate` creates an event queue and stores its id. **We never did.** Queue
id 0, immediate return, dead thread, no flip handler, parked main thread, stopped PS1.

**The fix** (`libs/video/sys_rsx.c`): create the queue at driver-info init, publish the id at
`+0x12D0`, and drive it with a 60 Hz `SYS_RSX_EVENT_VBLANK` filtered through the handler mask
at `+0x12C0`. The producer must be an independent ticker, not the flip packet: the deadlock is
circular, and the run proves it -- the only attribute packets that ever appear are `0x101` and
`0x10A`, never `0x102`/`0x103`.

| | before | after |
|---|---|---|
| `_gcm_intr_thread` | exits immediately | stays alive on the queue |
| `semaphore_post(sem=1)` | 0 | **24** |
| main guest thread | parked forever | wakes, proceeds to storage syscalls |

**It did not, on its own, get the PS1 running.** Measured afterwards over a 150 s run:
the ISR thread stays alive, `sem 1` is posted, the main thread wakes and runs on --- and the
R3000 still does not pass **50,000** dispatches, essentially where it stopped before. The flip
semaphore was a real deadlock and is cleared; a second stall sits behind it, unfound.

Lead: `_gcm_intr_thread` receives on its queue only **once** and then blocks again, so the
vblank tick is probably filtered out by the handler mask at `+0x12C0` after the first event.
That mask is the first thing to check.

Everything inside the interpreter was cleared first: entered once and looping internally; the
event scheduler healthy over ~2,100 rounds; all 11 helper calls traced at 1553 enters / 1553
exits. It reaches a syscall at all through one of its 51 `DRAIN_TRAMPOLINE` sites.

Also corrected: the R3000 is not slow. It runs 1,000 instructions in 1 ms (~1 MIPS) right up
to the moment it parks.

Detail: [`docs/ps1-core.md`](docs/ps1-core.md).

## Next steps

1. **Measure how far the R3000 now gets**, and whether the PS1 GPU starts issuing its own
   packets (still 6 in the last run, all from the emulator front-end).
2. Tie the vblank tick to the present loop rather than a plain 60 Hz timer, if timing ever
   matters. It is marked `ponytail:` in `sys_rsx.c` with that ceiling named.
3. Still open: a bare `/USRDIR/` config path resolves to the VFS root and fails `EISDIR`
   (non-fatal); `cellAdecQueryAttr` (`0x7E4A4A49`) returns `CELL_OK` with its attr struct
   untouched; `user_memory_size= 0/0` prints from a site that disassembles to `li r11,352; sc`
   though syscall 352 never appears in a trace; attribute packets `0x300`/`0x301`/`0x302`
   (tiles, Z-cull) accepted and ignored.
4. `ps3recomp` still has uncommitted changes: both `ppu_lifter.py` jump-table fixes, the SPU
   `rchcnt SPU_RdEventStat` fix, the RSX ISR queue, and two diagnostics (`[ch-wait]` event
   state, `[WAIT] semaphore_wait` call site).

### The flip bit: `0x04`, not `0x02`

Publishing the queue was necessary but not sufficient --- the ISR thread still blocked, because
the events being sent were ones the guest never asked for. Watching the mask settled it:

```
[ww] 0x200322C0 <- 0x4   guest-fn=0x0001A330
[ww] 0x200322C0 <- 0x84  guest-fn=0x00019D88
```

`0x84`, and `rsx_send_event` filters by that mask (deliberately --- gcm's ISR dispatches on
the flag bits). A tick of `SYS_RSX_EVENT_VBLANK` (`0x02`) was filtered out entirely.

The ISR is a bit -> handler-slot table; reading it out of `ps1_netemu` directly (handler object
= `*(TOC-0x6AB4)`):

| bit | handler slot | |
|---|---|---|
| `0x0001` | `r14+0x0C` | |
| `0x0002` | `r14+0x10` | vblank |
| **`0x0004`** | **`r14+0x04`** | **registered** |
| `0x0008` / `0x0010` | dispatched inline | |
| `0x0020` / `0x0040` | `r14+0x24` / `r14+0x28` | |
| **`0x0080`** | **`r14+0x2C`** | **registered** --- user cmd, arg `driver_info+0x12CC` |
| `0x0400` / `0x0800` | `r14+0x14` / `r14+0x18` | |

So this firmware's libgcm hangs its flip callback off **bit 2**, not RPCS3's
`SYS_RSX_EVENT_FLIP_BASE` (`1 << 3`), and the only two handlers it ever registers are that and
user-cmd. Sending `0x04` alongside the vblank bit takes the ISR thread from **2** queue
interactions to **333**: it now receives and cycles instead of blocking forever.

**The PS1 still does not render.** GPU packets remain at 6, no new attribute packets appear,
and `sem 1` posts stay at 24. So the ISR mechanism is now correct and a third deadlock is
cleared, but something after it still holds the core. Where that is has not been found.

Measured after the flip-bit fix, same 50,000-dispatch probe: the R3000 still does **not**
reach 50,000 dispatches. So all three deadlocks cleared this session were real -- each is
verified by its own metric -- and none of them was what stops the core. What holds it is still
unknown.

What is now known to be *not* the cause, so the next reader does not re-run it:

* the interpreter itself --- entered once and looping internally, event scheduler healthy over
  ~2,100 rounds, all 11 helper calls traced at 1553 enters / 1553 exits;
* the opcode dispatch (the table is lifted, 127 targets, one `bctr`, fully covered);
* the audio SPU (`ch-wait` stalls are 0);
* the flip semaphore (`sem 1` is posted, the wait is satisfied, the main thread runs on);
* the gcm ISR thread (alive and cycling, 333 queue interactions);
* `sys_storage_send_device_command` (604) --- 10 calls early, then quiet; a BD-drive query
  that a PBP-backed title should not depend on.

The obvious next measurement is whether `func_001066A8` is *re-entered* after the main thread
passes the flip wait. It was entered exactly once before; if it is still once, the emulator's
main loop at `0xB3E58` has stopped calling it and the question moves up into that loop rather
than into the interpreter.

**And the decisive measurement.** With all three deadlocks cleared, `func_001066A8` is still
entered **exactly once** (`interp ENTER #1 pc=BFC00000`) and never returns. So the emulator's
main loop at `0xB3E58` is not failing to call it --- the call never comes back. The core runs
its ~42,000 instructions and then blocks *inside* the interpreter, exactly as before.

That reframes the remaining work. The block cannot be one of the 11 `bl` targets (all traced,
1553 enters / 1553 exits), and it is not the dispatch, so the likely path is the same one that
reached `sys_semaphore_wait` in the first place: one of the interpreter's **51
`DRAIN_TRAMPOLINE` sites**, which run deferred guest work on the calling thread. The flip wait
was the *first* such block; satisfying it evidently just moves the thread to a second one.

So the next probe is not another interpreter dissection --- it is to log **every blocking
syscall made by guest thread 1** (semaphores, event queues, lwmutex, timers) with its guest
`lr`, and read off the second wait the way the first one was read off. `[WAIT] semaphore_wait`
already carries `cia`/`lr`; the event-queue and lwmutex paths would need the same treatment.

### Correction: bit `0x04` is the GRAPHICS ERROR handler, not flip

Driving `0x04` was wrong, and the guest said so plainly once its own stdout was reconstructed
(it prints one character per line, so the text has to be reassembled):

```
[RSX dump analysis] unsupported error
graphics error 0 : 00000000 00000000 ...
undefined error message 00000000
```

followed by a full RSX state dump --- surfaces, textures, Z-cull --- **60 times a second**.
Slot `r14+0x04` is the graphics-error handler. RPCS3's header has
`SYS_RSX_EVENT_GRAPHICS_ERROR` commented out at `1 << 0`, which is what led me to assume bit 2
had to be something else; it does not follow that numbering.

So the mask `0x84` means this firmware registers a **graphics-error** handler and a
**user-command** handler --- and **no vblank and no flip handler at all**. That breaks the
chain I had drawn one link earlier than I thought: the flip semaphore is *not* posted by a gcm
handler, so "publish the queue, tick it, the flip completes" was wrong reasoning even though
the first half of it was right.

The ticker is removed. There is nothing a timer can legitimately send here.

**What survives, and is still correct:** publishing the queue id at `+0x12D0`. Without it the
ISR thread received on queue 0 and *exited outright*; with it the thread stays alive and
blocked on real events, which is what it should do. That is verified by its own metrics, and
they hold with the ticker gone:

| | no queue | queue published (no ticker) |
|---|---|---|
| `_gcm_intr_thread` | exits immediately | stays alive, blocked |
| `semaphore_post(sem=1)` | 0 | 24 |
| guest "graphics error" dumps | 0 | **0** (were flooding with the ticker) |

`rsx_send_event` stays, with its handler-mask filter, for whoever wires up a genuine flip or
user command.

**Still not rendering.** GPU packets remain at 6. The open question is unchanged and now
better posed: the main thread spins on `sys_ppu_thread_yield` (syscall 43) from inside the
interpreter rather than blocking on a wait, so it is polling a memory location, not sleeping
on a primitive. Finding *which* location is the next step.

### Correcting the "yield spin": thread 1 is polling, not deadlocked

The `sys_ppu_thread_yield` observation in the previous note was real but I overweighted it.
Counting the whole syscall trace, for **guest thread 1** (the one that runs the R3000):

| syscall | calls | |
|---|---|---|
| 141 `sys_timer_usleep` | **7,008** | `r3 = 0x1E` --- a **30 microsecond** sleep |
| 43 `sys_ppu_thread_yield` | 1,178 | |
| 818 / 802 / 94 / 93 / 801 / 817 | < 40 each | |
| | **8,397 total** | |

So the yield is ~14% of its traffic, not a hot spin, and the dominant behaviour is
`usleep(30us)` in a loop. That is a **poll**, and it means the main thread is alive and
running --- not blocked, not deadlocked. Whatever it is waiting on, it is waiting by
re-checking, so no missing wakeup will fix it; the condition itself is never becoming true.

(For contrast, the process-wide totals are dominated by other threads: 86,303 calls to
`sys_event_queue_receive` and 4,718 to `sys_usbd_receive_event` are the worker threads in
their normal idle state, not thread 1.)

The one PPU spin that *was* worth reading is at `0xD19A0`, and it is a raw-SPU mailbox wait:

```
addis  r30, r11, 0xE004      ; SPU window + 0x40000
addi   r0,  r30, 16404       ; +0x4014 = SPU_Mbox_Stat
lwz    r9,  0x0(r31)
rlwinm r0,  r9, 0, 16, 23    ; mask 0x0000FF00 = In_Mbox FREE SLOTS
bne    -> proceed
li     r11, 43 ; sc          ; else yield and re-read
```

The runtime already answers that register correctly --- `in_free` is computed live from
`SPU_RAW_IN_MBOX_DEPTH - ch_in_mbox.count` on every MMIO read, with a comment explaining why a
published copy would go stale --- so this is not the blocker either, and it is ruled out.

**Where that leaves it.** The 55 `sys_timer_usleep` call sites cluster around
`0x1101D8`-`0x111AB8`, which is the disc/streaming region (`0x110E50` and `0x111BC8` are the
two old `ExitPS1(3)` sites). The next step is to identify *which* of those the main thread is
sitting in and what it re-reads each pass --- one probe on the guest `lr` at syscall 141 would
name it, the same way the `lr` on `sys_semaphore_wait` named the flip wait.

### The blocker, located: a `cellGcmFinish` fence wait on `ctrl->ref`

Chasing the poll to its source, entirely with existing diagnostics (no rebuilds beyond adding
the guest `lr` to the syscall trace).

**1. Name the poll site.** The syscall trace mapped a *host* backtrace to the nearest guest
function, which is why it kept reporting a bogus `func_00013040+0x9FF1`. Adding `ctx->lr` --
authoritative, and what named the flip wait -- gives it immediately:

```
8207  glr=0x00019928      <- the poll
 232  glr=0x00032D54
   1  glr=0x00116518
```

**2. Read the loop** at `0x000198F4`:

```
000198F4  (r3 = obj, r4 = expected)
00019918  bl 0x16D18            ; writes the fence command
00019920  bl 0x1989C
00019924  bl 0x15394            ; r3 = the object          <- lr = 0x19928
0001992C  lwz r0, 0x8(r3)
00019934  cmpw cr7, r31, r0     ; expected == *(obj+8) ?
00019938  beq -> done
0001993C  li r3, 30 ; li r11, 141 ; sc    ; usleep(30us)
00019948  lwz r29, 0x8(r30)     ; re-read
00019950  bne -> loop
```

**3. Resolve the object.** `func_00015394` returns `*(TOC-0x6AD8)->[0x10]`, and a store watch
gives the value: `0x002D8384 <- 0x20002000`. That is
`GCM_CONTROL_GUEST_ADDR` (`VM_HLE_INJECT_BASE + 0x2000`) -- **exactly** the address our runtime
uses -- and `+0x08` of `CellGcmControl` is **`ref`**.

So this is the classic `cellGcmSetReferenceCommand` / `cellGcmFinish` handshake: write a fence
into the FIFO, then spin until `ctrl->ref` equals it.

**4. Where it breaks.** `GCM_DRAINDBG` and `GCM_REFLOG`:

```
[DRAIN] getoff=00002184 put=00002184 ref=00000002 ctx.current=00000000
[refq] drained fence 0xFFFFFFFF at getoff=00001398
[refq] drained fence 0x0        at getoff=00001410
[refq] drained fence 0x1        at getoff=00001418
[refq] drained fence 0x2        at getoff=00001420
```

The FIFO is **fully drained** (`get == put`), so nothing is stuck in the pipe, and exactly four
fences were decoded -- the last at `0x1420`, while the guest went on to write commands out to
`0x2184`. `ref` sits at **2** and the guest is polling for something it never sees.

That is a much better-posed question than "the R3000 stalls": the emulator is not deadlocked on
a primitive and not starved of a wakeup -- it is waiting on a **fence value mismatch**.

**The single next step** is the expected value: `r4` at `func_000198F4`. One probe reading it
decides between the two remaining explanations:

* the guest wants a fence **> 2** that it wrote after `0x1420` and our FIFO walker did not
  decode as `SET_REFERENCE` (the words in that span decode to methods `0x60`/`0x64`/`0x68`/
  `0x1D84`/`0x1804`/`0x1EA4`, several of which the RSX layer already logs as "unknown method",
  so a mis-counted batch there is plausible); or
* the guest wants **1** (or `0`), which the one-fence-per-tick pacing published and moved past
  before this particular wait began -- the same equality-miss hazard the pacing was written to
  prevent, which would mean the window is still too short for this title.

### Correction: that `lr` was stale, and the fence wait completes

The previous entry identified `func_000198F4` as the poll site from an `lr` histogram. That
identification is **wrong**, and the reasoning is worth keeping because the trap is subtle.

**`lr` is only written by `bl`.** A spin loop that calls nothing keeps whatever return address
the last `bl` happened to leave. The loop at `0x1993C`-`0x19950` makes no calls, so *any*
`usleep` reached later without an intervening `bl` still reports `lr=0x00019928`. Every one of
the 8,207 samples shows that same value, and `cia` is `0x00000000` for this thread -- the
lifted code does not maintain it -- so there was nothing to cross-check against:

```
[WAIT] timer_usleep(30 us) lr=0x00019928 cia=0x00000000
```

**And the fence wait demonstrably completes.** The probe on `func_000198F4` shows it entered
**exactly once**, wanting `expected=0xFFFFFFFF`, at a moment when `ref=0` and `put=0x00001000`:

```
[dbg] fencewait #1 expected=0xFFFFFFFF ref=0x00000000 put=0x00001000
```

The fence `0xFFFFFFFF` is written into the FIFO at `getoff=0x1398`, i.e. *after* that `put`.
Fences `0`, `1`, `2` then follow at `0x1410`-`0x1420`, and `put` ends at `0x2184`. The guest is
single-threaded through this path, so it could not have written any of that while still parked
on the first fence. It waited, the read-driven publisher (`cellGcm_ref_on_poll`, hooked in
`vm_read32` on exactly `VM_HLE_INJECT_BASE + 0x2008`, paced ~200us, publishing *before* the
read) handed it `0xFFFFFFFF`, and it moved on.

So the `cellGcmFinish` handshake **works**, and it is not the blocker. The 8,207 `usleep(30us)`
calls belong to some other loop that has not executed a `bl` since.

**I had already flagged this exact trap** and failed to apply it: the `[sem] create ...
lr=0x00116CC0` earlier in this file points at a `bl 0xA7FB4` that is a `memset`, and I noted
then that the `lr` "is stale and should not be trusted". The `lr` on a *blocking* syscall was
trustworthy for `sys_semaphore_wait` only because that call site really is preceded by the
`bl` that reaches it.

**What is actually needed** to name a poll site is the guest PC at syscall time. Two options,
neither done: have the lifter maintain `ctx->cia` at `sc` sites (cheap, a store per syscall,
and it makes every `[WAIT]` line trustworthy), or capture the host return address and map it
through the function table properly -- what `PS3_SCTRACE`'s backtrace attempts and gets wrong
(it reported `func_00013040+0x9FF1`, an offset far past any real function).

Until one of those exists, **no `lr`-based attribution in this file should be trusted for a
loop that does not call out**, and that includes the fence-wait conclusion above it.

### Two theories collapsed; one real diagnostic gained

**The backtrace mapping was broken, and fixing it was worth doing.** `PS3_SCTRACE` resolved a
host stack frame by taking the greatest lifted-function entry below it and accepting the match
if within 128 KB -- it never checked the frame was actually *inside* that function, so frames
in runtime/CRT code resolved to whichever lifted function happened to precede them. That is
where `func_00013040+0x9FF1` came from. Sorting the table once gives every function a real
extent `[entry, next_entry)`, so a frame either lands in one or is skipped, and it now reports
a chain rather than the first hit. On the very first run it produced:

```
8187 from func_0014E75C+0xA0F5<-func_0014E75C+0x9AC7<-func_000198F4+0x320
 268 from func_0014E75C+0xA0F5<-func_0014E75C+0x9AC7<-func_00032D20+0x320
```

That is a real, checkable answer where the old code produced nonsense. **Kept.**

It also *reinstated* `func_000198F4` as the spinning caller -- so the previous entry's
correction ("the fence wait completes") was itself wrong. The probe showing it entered once,
plus 6,644 `usleep` calls attributed to it, means it is entered once and never leaves. The
fences `0`/`1`/`2` and `put=0x2184` must therefore come from another thread, which is the
assumption I should have tested instead of asserting the guest was single-threaded here.

**But the fence theory does not survive its own test.** If the waiter wants `0xFFFFFFFF` and
`ref` runs past it to `2`, then the read-driven publisher (`cellGcm_ref_on_poll`, hooked in
`vm_read32` on exactly `VM_HLE_INJECT_BASE + 0x2008`) should matter. It does not:

| | tid-1 `usleep` calls |
|---|---|
| `GCM_REFPOLL` default (on) | 6,891 |
| `GCM_REFPOLL=0` (ticker only) | 7,005 |

Identical. Turning read-driven publication off changes nothing, which means **the hook is not
firing on this waiter's reads at all** -- so whatever it polls, it is probably not
`0x20002008`. The chain of inference from `*(TOC-0x6AD8)->[0x10] = 0x20002000` to "it polls
`ctrl->ref`" has a gap in it: that field could be repointed after the write the store watch
caught.

I also tried making "no skip-past" a guarantee rather than a timing hope (hold each published
fence until a read has returned it, instead of trusting a ~200us gate against a poller whose
`usleep(30us)` costs ~12ms under load). It produced **no measured change**, and it lives in
runtime code shared with other ports that I cannot test here, so it is **reverted** rather than
left in on the strength of an argument.

**Honest position.** The blocker is not located. What is now solid: the guest thread that runs
the R3000 is spinning in `func_000198F4`, entered once, ~7,000 `usleep(30us)` per 90s run, and
the emulator is otherwise healthy (0 exits, 0 SPU stalls, 0 graphics errors). What is needed
next is to read what that loop actually compares -- `r31` and the address in `r30` at the
compare, captured *in the loop*, rather than inferred backwards from a TOC slot.

### Measured from inside the spin, and a caveat about my own evidence

Probing the loop body directly (rather than inferring from a TOC slot) settles what it polls:

```
[dbg] spin #1    expected(r31)=0xFFFFFFFF obj(r30)=0x20002000 *(obj+8)=0x00000000
[dbg] spin #3000 expected(r31)=0xFFFFFFFF obj(r30)=0x20002000 *(obj+8)=0x00000000
[dbg] spin #6000 expected(r31)=0xFFFFFFFF obj(r30)=0x20002000 *(obj+8)=0x00000000
[dbg] spin #9000 expected(r31)=0xFFFFFFFF obj(r30)=0x20002000 *(obj+8)=0x00000000
```

So it *is* `ctrl->ref` after all --- `obj` really is `0x20002000` --- and the previous entry's
"probably not `ctrl->ref`" was wrong. It wants `0xFFFFFFFF` and reads **`0x00000000`** on every
one of nine samples spread across a 90 s run. The value never changes.

Meanwhile the present thread's `[DRAIN]` line, reading the same `GCM_CONTROL_GUEST_ADDR + 8`,
reports `ref=FFFFFFFF` and later `ref=00000002`.

Two things ruled out as the explanation:

* **Not two different accessors.** `cellGcmSys.c` includes `ppu_memory.h`, so its `vm_read32`
  is the inline one going through `vm_translate(addr)` -- which is literally
  `return vm_base + addr`, identical to the loader's `vm_base + (uint32_t)a` that the lifted
  guest code links against.
* **Not a per-thread base.** `vm_base` has two definitions, `host_main.c` and `host_posix.c`,
  but they are platform-exclusive; one global, one mapping.

**And a caveat on my own evidence, which matters more than it looks.** `[DRAIN]` uses
`printf` -- stdout, block-buffered when redirected to a file -- while the spin probe uses
`fprintf(stderr)`, which is unbuffered. **The interleaving of those two in the log is not a
timeline.** So "the present thread saw FFFFFFFF while the guest thread saw 0" is not yet
established as simultaneous, and I should not have read it that way. What *is* established is
that the guest never observes anything but 0, across the whole run.

**The next probe, stated precisely so it cannot repeat this mistake:** print the ref value from
the publisher (`gcm_ref_publish_one`, right after its `vm_write32`) on **stderr**, so it shares
a stream and ordering with the spin probe. If the publisher reports writing `0xFFFFFFFF` while
the spin continues to read `0`, the write genuinely is not landing where the guest reads and
the mapping is the bug. If the publisher never reports writing it, then the fence queue is
being consumed by some other reader before the waiter ever gets a look, and the fix belongs in
the pacing after all.

### Resolved: the fence is published LATE, not skipped -- this is latency, not deadlock

Putting the publisher on **stderr** (the same stream as the spin probe, so ordering is real)
settles it in one run:

```
line  94  [dbg] spin #1     expected=0xFFFFFFFF  *(obj+8)=0x00000000
line 173  [dbg] spin #9000  expected=0xFFFFFFFF  *(obj+8)=0x00000000
line 229  [refpub] #1 wrote 0xFFFFFFFF -> readback 0xFFFFFFFF
line 311  [refpub] #2 wrote 0x00000000 -> readback 0x00000000
line 316  [refpub] #3 wrote 0x00000001
line 317  [refpub] #4 wrote 0x00000002
```

The guest polls **9,000+ times before the first fence is ever published**. The write itself is
fine -- the publisher reads back exactly what it wrote, so the store lands in the memory the
guest reads, and every "two different values for one address" worry was an artefact of
comparing a `printf`/stdout line against an `fprintf`/stderr one. And the spin probe stops at
`#9000` rather than continuing to `#12000`, which is what it would do if the loop exited
shortly after line 229 -- i.e. **the wait completes**, once the fence finally arrives.

So the correct description is: *every* fence wait costs seconds, because the FIFO walk that
decodes the fence runs far too late. That also explains the shape of everything measured
earlier -- ~7,000 `usleep(30us)` on the main thread per 90 s run, GPU packets stuck at 6 over
even a 300 s run, and the R3000 never getting past ~42,000 instructions. The emulator is not
deadlocked at any point; it is progressing at roughly one fence per several seconds.

**Corrections this forces on the previous entries**, all of which are wrong and should be read
with this one:

* "the condition it re-checks never becomes true" -- it does become true, late;
* "the hook is not firing on this waiter's reads, so it probably does not poll `ctrl->ref`" --
  it does poll `ctrl->ref`, and `GCM_REFPOLL` made no difference for the simpler reason that
  there was nothing queued to publish yet;
* "two different values for one address" -- an artefact of mixed stdout/stderr buffering.

**Next**, and it is a different question from the one I have been chasing: why is the first
FIFO walk so late? The walk runs on the present thread's 60 Hz tick and the kick event
(`cellGcm_fifo_kick_event`) exists precisely so a dry fence wait can demand one immediately.
Either that kick is not wired on this path or the present thread is not yet running when the
first wait begins. That is a startup-ordering question, and it is measurable the same way:
timestamp the first walk against the first spin.

### Calibration: what is measured here, and what was inference

I have corrected my own conclusion on this blocker five times in one session. That is itself
the most useful thing to record, so the next reader knows which lines to trust.

**Measured, reproducible, and safe to build on:**

* the fence-wait loop is `func_000198F4`, entered **once**, polling `*(0x20002000 + 8)` ---
  i.e. `CellGcmControl::ref` --- for `0xFFFFFFFF`, with `usleep(30us)` between reads;
* every sampled read returns `0x00000000` (9 samples, `#1`-`#6`, `#3000`, `#6000`, `#9000`);
* the probe stops at `#9000` and never reaches `#12000`, so the loop ends between those;
* the publisher writes correctly --- `[refpub] #1 wrote 0xFFFFFFFF -> readback 0xFFFFFFFF` ---
  and its first write appears at log line 229, after the spin samples at line 173;
* the flush is `func_0001989C`, which converts `ctx->current` via `func_00015ECC`
  (`cellGcmAddressToOffset`-shaped: it returns `0x802100FF` on failure) and stores the result
  to `put` at `0x000198DC`;
* the generic boot harness *does* walk the FIFO on a ~4 ms outer cadence and a 16 ms tick;
* `cellGcm_fifo_kick_event()` is called **only** from `lbp/main.cpp:269`. Nothing in the
  generic harness calls it, so `s_gcm_kick_ev` stays NULL for this port and the
  `if (dry && s_gcm_kick_ev) SetEvent(...)` kick in `cellGcm_ref_on_poll` never fires. That
  is a real gap between the two hosts, whatever its effect turns out to be.

**Inference I made and could not sustain**, listed so nobody re-derives them:

* that `put = 0x1000` at the wait's entry meant the guest had not flushed --- wrong: the flush
  (`bl 0x1989C`) runs at `0x19920`, *after* the probe point at function entry, so that reading
  proves nothing;
* that the wait "costs seconds" --- **never timestamped**. 9,000 iterations of a 30us QPC
  busy-wait is ~0.27 s, so the wait may well be sub-second and the "one fence per several
  seconds" framing in the entry above is unverified;
* earlier: that the value is skipped, that the poll site was elsewhere, that two threads saw
  different memory, that the hook was not firing. All wrong, each for a different reason.

**What an honest next step looks like.** Stop inferring from counts and orderings and put a
timestamp on both events in one stream: `QueryPerformanceCounter` at the first spin iteration
and at `[refpub] #1`, printed as microseconds since process start. That single number decides
whether there is a latency problem at all --- and until it exists, the "latency, not deadlock"
heading above should be read as a hypothesis, not a result.

### Quantified at last: the guest is slow between fences, not blocked by them

Timestamping both probes from the **same QPC origin** (`ps3_qpc_us()`, callable from any
translation unit, so two files can be compared directly) finally puts numbers on this:

| event | t (us) | delta |
|---|---|---|
| first fence-spin `usleep` | 223,341,983,195 | --- |
| `[refpub] #1` wrote `0xFFFFFFFF` | 223,342,388,746 | **+0.41 s** |
| `[refpub] #2` wrote `0x0` | 223,344,394,122 | **+2.0 s** |

And two supporting rates, both healthy:

* consecutive fence-spin `usleep` calls are **43 us** apart, so the poll loop is fine. (My
  earlier "~12 ms per usleep" was bad arithmetic --- dividing total run time by usleep count,
  which assumes the loop runs for the whole run. It does not.)
* `GCM_RATE=1` reports **270 FIFO walks/sec**, steady. The walk is not starved, and the
  missing `cellGcm_fifo_kick_event()` wiring noted above therefore costs far less than it
  looked like it might.

So the shape is: the *first* fence takes 0.41 s to appear, and each subsequent one about
**2 seconds** --- but not because publication is slow. Publication can run at up to one per
200 us read-driven and 60/s from the ticker, and the walk that feeds it runs 270 times a
second. A fence appears only once the guest has written and flushed it, so **the ~2 s is the
guest's own work between fences**, and the fence wait is a symptom of that, not its cause.

Which lands somewhere genuinely unexplained: the main guest thread spends ~2 s of wall clock
between consecutive fences, while the R3000 interpreter executes fewer than 50,000
instructions in 150 s and its ~7,000 `usleep` calls account for only ~0.3 s. The time is going
somewhere on that thread that none of the instrumentation used so far attributes.

**That makes the next step a profiling question, not an inference one** --- which is the right
note to end on, given how many inferences in this file turned out wrong. Sample the main guest
thread's host PC periodically and bucket it by lifted function (the runtime already has a
`[BLOCK]` profiler that does exactly this kind of attribution), and read off where the 2
seconds actually go. Do not reason forward from the fence again.

### The missing tool, and the first answer it gave

Every probe in this project reports where a thread **blocks** --- `[BLOCK]` times blocked
syscalls, `[WAIT]` names waits, `ch-wait` names SPU stalls. None of them can say where a
thread spends time while it is **running**, which is exactly the gap this session kept falling
into: the main guest thread burns ~2 s of wall clock between gcm fences while the R3000
executes <50k instructions and its `usleep` calls account for ~0.3 s. That missing time is
*busy* time, and no blocking probe can attribute it.

So `PS3_SAMPLE=<ms>` now exists in `ppu_loader.cpp`: a sampling profiler that suspends each
thread briefly, reads `RIP`, maps it to a lifted function **by extent** (the sorted
`[entry, next_entry)` table --- the same correction that made `sc_trace`'s backtrace
trustworthy), and buckets. First run:

```
[samp] sampling every 3 ms
[samp] 4960 samples, 446 in guest code (9.0%)
[samp]    99.1%  func_00022F28  (442)
[samp]     0.7%  func_0014E75C  (3)
[samp]     0.2%  func_00080304  (1)
```

Two things fall out immediately, neither of which any amount of reasoning had produced:

1. **Only 9% of process CPU is in guest code at all.** The other 91% is runtime/host --- the
   RSX backend and its D3D12 work. Whatever is slow, most of the machine's time is not being
   spent running the recompiled PPU.
2. **Of the guest time, 99.1% is in one function**, the body at `0x00022F3C` (the sampler
   attributes it to the preceding table entry `func_00022F28`). It ends `li r3,0; blr`, and
   has at least five callers clustered at `0x243EC`, `0x24590`, `0x24724`, `0x248A8`,
   `0x24A0C`.

Its inner loop is worth a look by whoever picks this up: it walks an index from 6668 to 7148
in steps of 32, calling `func_00022F30` --- which is literally `li r3,-1; rldicl; blr`, an
unconditional `0xFFFFFFFF` return --- and branches on `r3 != -1`, so that arm never runs. That
may be perfectly normal firmware (a lookup whose fast path is "absent"), or it may be a lifting
artefact worth checking against the ELF. It is the single highest-value thing to look at next,
and it was invisible for this entire session.

**The lesson worth keeping.** Ten-plus conclusions in this file were wrong, and every one came
from reasoning forward off a partial signal --- a stale `lr`, a mixed stdout/stderr ordering, a
count divided by the wrong denominator. The two things that actually produced answers were
both *measurements built for the question*: `ps3_qpc_us()` for comparable timing, and this
sampler for busy time. Build the instrument first.

### Retraction: the "99% in func_00022F28" result was my own tool lying

I hardened the sampler and it demolished its own previous answer. Three attribution modes, same
workload:

| attribution | guest samples | top guest function |
|---|---|---|
| extent `[entry, next_entry)` | 446 / 4960 (9.0%) | `func_00022F28` **99.1%**, 5 threads |
| extent, capped at `0x20000` | 338 / 4949 (6.8%) | `func_00022F28` 98.8%, **4** threads |
| exact, via `RtlLookupFunctionEntry` | **0 / 4931 (0.0%)** | **none** |

The extent heuristic was the problem, and I should have seen it before publishing a headline
off it. The function table holds **PPU functions only**, so SPU-lifted code and runtime code
sit in the gaps between entries; an uncapped `[entry, next_entry)` span silently swallows
whatever occupies the hole and blames the preceding PPU function. Capping at `0x20000` moved
the answer from "5 threads, 99%" to "4 threads, 98.8%" --- which should itself have been the
tell, since a real measurement does not shift its subject when you adjust an unrelated bound.
The four/five "busy" threads were the raw-SPU workers all along (four SPUs run image 1, one
runs image 2), running lifted **SPU** code that the PPU table cannot describe.

x64 Windows records exact function bounds in `.pdata`, and `RtlLookupFunctionEntry` returns the
true start for any RIP. Matching that start against the table **exactly** means a hit is
genuinely that lifted function and everything else misses cleanly. That is the mode now in
place.

**What survives, and what is now open.** The module-level split is unaffected by any of this
and is the trustworthy part:

```
[samp] 4931 samples
[samp] host  89.2%  ntdll.dll     (4399)     <- threads parked in kernel waits
[samp] host  10.5%  tmpsn.exe     (518)      <- runtime: RSX backend, SPU emulation
```

So the process is ~89% idle, and essentially all real work is host-side runtime code. That
matches everything else measured (GPU packets at 6, R3000 at <50k instructions, one thread
waiting on a fence) and it is the first *quantified* statement of it.

**A caveat I will not paper over**: exactly `0` guest samples is suspicious in its own right.
It could mean no lifted PPU code runs during the steady state --- consistent with 89% of
threads sitting in waits --- or it could mean `RtlLookupFunctionEntry` finds no `.pdata` entry
for the lifted bodies, in which case the exact mode misses *all* guest code by construction.
Those are very different conclusions and I have not distinguished them. The check is cheap:
call `RtlLookupFunctionEntry` on a known lifted function pointer straight out of
`function_table` at startup and print whether it resolves. Do that before trusting either
number.

And the self-check settles which reading was right --- **neither**:

```
[samp] pdata self-check: func_0014F6D0 at 00007FF7AEA52E50
       -> NO .pdata entry -- exact mode cannot see guest code
```

`RtlLookupFunctionEntry` finds no unwind record for the lifted bodies, so the exact mode
cannot attribute guest code **at all**. Its `0 / 4931` is not a measurement of anything; it is
the mode failing silently. So:

* extent mode **over**-attributes (SPU and runtime code in the gaps land on the preceding PPU
  function) --- its "99% in `func_00022F28`" is retracted;
* exact mode **under**-attributes to zero --- its "no guest code runs" is equally retracted.

The only numbers from this profiler worth keeping are the module-level ones, which neither
mode affects: **~89% `ntdll.dll`** (threads parked in kernel waits) and **~10% `tmpsn.exe`**
(runtime --- RSX backend and SPU emulation). The process is ~89% idle and what work there is
happens in host code. That is consistent with every other measurement and is the first
quantified version of it.

**To make the sampler actually work**, one of two things:

1. **Merge the SPU registry into the map.** The gaps that swallow samples are SPU-lifted
   bodies; `spu_channels.c`'s `s_registry` knows their host pointers. With both tables sorted
   together, `[entry, next_entry)` becomes meaningful and extent mode is correct rather than
   approximately correct. This is the smaller change and it fixes the actual cause.
2. **Get `.pdata` for the lifted TU** (an unwind-tables compile flag) and keep the exact mode.
   Cleaner in principle, but it means changing how a 22 MB generated translation unit is
   compiled, for a diagnostic.

Option 1 is the one to do. Until then `PS3_SAMPLE` is honest only at module granularity, and
the header comment in `ppu_loader.cpp` says so.

### The profiler, fixed --- and the first trustworthy answer

Merging `spu_channels.c`'s registry into the sampler's map was the fix. The gaps that used to
swallow samples are now real entries, so `[entry, next_entry)` describes one function:

```
[samp] map: 3530 PPU + 2066 SPU entries
[samp] 4964 samples, 428 in guest code (8.6%)
[samp]    47.7%  spu_LS_00001268  (204)
[samp]    26.2%  spu_LS_00000100  (112)
[samp]     6.1%  spu_LS_0000893C  (26)
[samp]     4.7%  spu_LS_00014BF0  (20)
[samp]     3.5%  spu_LS_00009BA8  (15)
[samp]     0.7%  func_00013040    (3)     <- the ONLY PPU code in the profile
[samp] host  89.1%  ntdll.dll     (4423)
```

**Essentially all guest execution is SPU code. The PPU is idle** --- three samples out of 4,964.
That is the opposite of what the broken tool said (99% in a PPU function), and it is consistent
with everything measured independently: the R3000 executes <50k instructions, GPU packets stay
at 6, and the main thread sits in a fence wait.

`0x00000100` is image 1's **entry point** (`NPC=0x00100` in the load log), and `0x0000893C` is
the audio SPU's loop already disassembled above. The dominant one, LS `0x1268` at 47.7%, is a
spin on **local-store state**:

```
01268  nor   $r20, $r7, $r7
0126C  lqr   $r8, 0x15010        ; load a quadword from LS 0x15010
01274  ceq   $r19, $r84, $r8     ; compare it against r84
01294  cgti  $r35, $r85, 0
0129C  brz   $r35, 0x1268        ; loop while r85 <= 0
```

So the four image-1 SPUs (the GPU cores) sit at their entry and in this loop, waiting on state
in their own local store --- which on hardware the PPU writes through the raw-SPU LS window
(`0xE0000000 + n*0x100000`). They are not deadlocked on a channel; they are polling memory that
nothing updates.

**That is the first concrete, validated statement of what the emulator is actually doing**, and
it points somewhere specific: what should write LS `0x15010` (and the state behind `r84`/`r85`)
on these SPUs, and why it never happens. Note it is *not* the same wait as the audio SPU's
`rchcnt SPU_RdEventStat` at `0x893C` --- that one was fixed earlier and shows only 6.1% here.

Worth stating plainly: this answer only exists because the tool was fixed after it produced a
confident wrong one. The measured/inferred distinction earlier in this file applies to
instruments too --- a profiler is not trustworthy because it is a profiler.

### The SPU/PPU handshake, and where it stops

With the profiler trustworthy, the protocol reads cleanly out of image 1.

**The SPU publishes its own buffer address and then polls it.** At `0x11A0`-`0x11D4`:

```
011A0  rchcnt $r4, MFC_WrTagUpdate     <- earlier logs show spu=0 parked exactly here
011A4  brz    $r4, 0x11A0
011B4  rdch   $r3, MFC_RdTagStat       ; wait out the DMA
011B8  ila    $r10, 0x15010            ; r10 = its LS buffer address
011D4  wrch   SPU_WrOutMbox, $r10      ; tell the PPU "write my work here"
```

and then spins on that address, which is the 47.7% hot spot:

```
0126C  lqr    $r8, 0x15010
01274  ceq    $r19, $r84, $r8
0129C  brz    $r35, 0x1268             ; loop while r85 <= 0
```

The SPU image references `0x15010` exactly twice --- the `ila` that publishes it and the `lqr`
that polls it. **It never writes it itself**, so the value can only come from outside.

**And the PPU writes it exactly once.** A store watch on the raw-SPU LS window
(`0xE0000000 + 0x15010` for SPU 0):

```
[ww] 0xE0015010 <- 0x100 (w4) guest-fn=0x0010F658     ... and nothing further
```

One 4-byte write, value `0x100`, and then silence for the rest of the run. Meanwhile the
profiler says the PPU is idle (3 samples out of 4,964) and the four image-1 SPUs burn
essentially all guest CPU spinning on that address.

So the shape of the remaining bug is: **the GPU SPUs are fed once and then starve.** They are
not blocked on a channel and not waiting on a missing interrupt --- they have a buffer, the PPU
filled it once, and nothing refills it. Worth noting `func_0010F640`, immediately before the
writer, stores the same register to four separate pointers --- exactly the shape of "write this
to all four image-1 SPUs" --- which is a good place to start reading.

**The next question is narrow and concrete**: what should call the `0x10F658` path repeatedly,
and why does it run once? Given the PPU is idle rather than blocked, the likely answer is a
producer that is never scheduled rather than one that is stuck --- and that is checkable by
watching the same LS address with the PPU-side caller logged, which the store watch already
does.

This is the first point in the whole investigation where the two sides of a handshake are both
identified, with the exact address they communicate through and a count of how many times it
actually happens.

### Located: only SPU 0's startup message is ever read

Two measurements close this, and they agree exactly.

**1. The guest never enables the plain-mailbox interrupt.** Logging what it passes to
`sys_raw_spu_set_int_mask`:

```
[spu-mask] spu0 class=2 mask=0x3
[spu-mask] spu4 class=2 mask=0x3
```

Mask `0x3` is interrupt-mailbox (`0x1`) | stop-and-signal (`0x2`). It does **not** include
`0x10`, the plain-mailbox threshold. The image-1 SPUs signal with a plain
`wrch SPU_WrOutMbox` at LS `0x11D4`, so that write raises no class-2 interrupt by design ---
the PPU is expected to **poll** the outbound mailboxes. And only spu0 and spu4 get a mask at
all; spu1/2/3 have no interrupt tag, so for them polling is the only mechanism there is.

**2. The PPU polls exactly one of them.** Logging the outbound-mailbox depth after each SPU
publishes its buffer address:

```
[spu-outmbox] spu=0 wrote 0x00015010 depth=0   <- consumed
[spu-outmbox] spu=1 wrote 0x00015010 depth=1   <- never read
[spu-outmbox] spu=2 wrote 0x00015010 depth=1   <- never read
[spu-outmbox] spu=3 wrote 0x00015010 depth=1   <- never read
[spu-outmbox] spu=4 wrote 0x0000E500 depth=1   <- never read
```

All five publish. **Only SPU 0's message is consumed**; the other four sit at depth 1 for the
rest of the run. That is exactly consistent with the store watch, which saw precisely one write
into a raw-SPU local store --- SPU 0's, at `0xE0015010` --- and none to the others.

So the chain is complete and every link is measured:

1. each image-1 SPU publishes its LS work buffer via the plain outbound mailbox and polls that
   buffer (the 47.7% + 26.2% hot spots);
2. the guest's class-2 mask excludes the plain-mailbox bit, so nothing interrupts the PPU ---
   by design; polling is the contract;
3. our PPU consumes SPU 0's message and never reads SPU 1-4's;
4. so SPU 0 gets its one buffer write and SPUs 1-3 get nothing, and all four spin forever;
5. with the GPU cores stalled, no PS1 GPU packets are produced, which is why the count has been
   pinned at 6 all along.

**The fix is in the PPU-side polling, not in the SPU emulation.** What to check first: whether
the guest's poll loop walks all five raw SPUs or stops after the first, and whether our
MMIO read of `SPU_Out_Mbox` (window `+0x4004`) is reachable for SPUs 1-4 at all --- note the
runtime only ever created interrupt tags for spu0 and spu4, so anything keyed off a tag will
skip 1-3 by construction.

### Correction: the mailbox handshake works. The feed is what happens once.

The previous entry claimed only SPU 0's startup message is ever read. **That was wrong**, and
the way it was wrong is worth recording: I read a per-write snapshot as a steady state.

Running the mailbox-depth probe and the raw-SPU MMIO trace together, on one stream, shows every
message consumed within a few lines of being written:

```
7809 [spu-raw]     R spu0 OUT_MBOX -> 0x00015010
7811 [spu-outmbox] spu=0 wrote 0x00015010 depth=0
7824 [spu-outmbox] spu=1 wrote 0x00015010 depth=1
7827 [spu-raw]     R spu1 OUT_MBOX -> 0x00015010     <- consumed
7840 [spu-outmbox] spu=2 wrote 0x00015010 depth=1
7843 [spu-raw]     R spu2 OUT_MBOX -> 0x00015010     <- consumed
7856 [spu-outmbox] spu=3 wrote 0x00015010 depth=1
7859 [spu-raw]     R spu3 OUT_MBOX -> 0x00015010     <- consumed
7888 [spu-outmbox] spu=4 wrote 0x0000E500 depth=1
7889 [spu-raw]     R spu4 OUT_MBOX -> 0x0000E500     <- consumed
```

`depth=1` was measured *at the instant of the write*, before the PPU's read three lines later.
The depth never being 0 in that log meant nothing at all. **All five SPUs publish and all five
are read**, and the counts confirm it: one `OUT_MBOX` read per SPU, five in total.

The second error was narrower but the same kind: the store watch only ever covered **SPU 0's**
local store (`0xE0015010`). SPUs 1-3 live in their own windows at `0xE0115010`, `0xE0215010`,
`0xE0315010`, and I never looked. Watching SPU 1:

```
[ww] 0xE0115010 <- 0x100 (w4) guest-fn=0x0010F658    ... and nothing further
```

Same value, same writer, same count. So the shape **is** real and now verified on two SPUs
rather than extrapolated from one: **every image-1 SPU is fed exactly once with `0x100`, and
never again.** What is not true is that the mailbox handshake is broken --- it works.

So the open question returns to where it was, but on firmer ground and with the neighbouring
explanations eliminated: `func_0010F640` broadcasts one value to four pointers from a table at
`*(TOC-0x7948)` --- the "kick all four GPU SPUs" path --- and it runs once. **What should drive
that repeatedly, and why does it run only once?** The mailbox side is ruled out; the SPUs have
their buffers and are polling them correctly.

A note on method, since this is the third time in this file the same mistake appears in a new
costume: a snapshot taken *at* an event says nothing about the state *after* it. Both wrong
conclusions here came from reading one-shot instrumentation as if it were a steady-state
measurement, and both were caught only by putting two probes on one stream and reading the
ordering. That is the cheap check, and it should come first.

### Structural correction: the SPU spin is downstream of the R3000, not a separate bug

Following the feed path to its origin closes the loop, and it reorganises the whole problem.

`func_0010F658` --- the command-packet sender --- is called **exactly once**, and the probe
names the caller:

```
[dbg] sendpkt #1 src=0x0FEFFA40 words=1 lr=0x00108588
```

`lr=0x108588` is the call at `0x108584`, in `func_001083AC` --- the init path. The other two
call sites (`0x10C5F0`, `0x10CA4C`) both live in `func_0010C48C`, which **never runs**. It has
no direct callers and no switch arm; its address lives in an OPD at `0x001B6158`
(`{code=0x0010C48C, toc=0x001C3D30}`), referenced from exactly one TOC slot, `TOC-0x79BC`.

Two sites load that slot. The one that matters is `0x108518`, inside the init that did run:

```
00108514  li   r7, 2
00108518  lwz  r6, -0x79BC(r2)     ; r6 = OPD of func_0010C48C
00108524  lis  r3, 0x1F80
0010852C  ori  r3, r3, 0x1810      ; r3 = 0x1F801810  -- PS1 GP0, the GPU command port
00108534  li   r4, 16
0010853C  bl   0xC23E0             ; register the handler
```

**`func_0010C48C` is the PS1 GPU register-write handler.** It is registered against
`0x1F801810` --- GP0, the PS1's GPU command port --- and it is what turns a guest GPU write into
command packets for the SPU cores. It never runs because **the R3000 never writes to GP0**,
because the R3000 is stuck in the BIOS after ~42,000 instructions.

So the chain runs the other way from how I have been reading it:

```
R3000 stalls in the BIOS
   -> never reaches game code, never writes GP0
      -> func_0010C48C (the GP0 handler) never fires
         -> no command packets after the single init one
            -> the four GPU SPUs spin on buffers that never change
               -> no PS1 GPU packets -> the packet count stays at 6
```

Everything I investigated after "the R3000 stalls" --- the fence wait, the mailbox handshake,
the LS feed, the SPU spin --- is **downstream** of that one stall. The SPU work produced two
genuine fixes (`rchcnt SPU_RdEventStat`, the RSX handler queue) and they were worth having, but
none of them could have started the game, because none of them was the cause.

**The root question is the one from the beginning, unchanged**: why does the R3000 stop after
~42,000 instructions of BIOS? What is known about it: the interpreter is entered exactly once
and never returns; it stops dispatching; all eleven of its `bl` targets return cleanly
(1553/1553); its opcode table is fully lifted; and the main thread afterwards sits in a
`cellGcmFinish` fence wait that *does* complete. What is not known is what it does between the
last dispatch and that wait.

The tool for that now exists and did not before: `PS3_SAMPLE` with the merged PPU+SPU map. A
profile taken **during the first second**, rather than in the steady state, would show whether
the interpreter is still executing when it stops dispatching --- which is the one thing every
probe so far has been too late to catch.

### ROOT CAUSE: the R3000 is idling in its wait loop, and nothing ever wakes it

Sampling per-thread and then reading the guest `lr` on the main thread's last syscalls closes
this completely. Every step below is measured except the last, which is read from the image.

**1. The main thread is blocked, not spinning.** Per-thread module breakdown:

```
[samp] tid 20596  guest=4  ntdll=430  other=0        <- the MAIN guest thread
[samp] tid 22272  guest=325 ntdll=0   other=...      <- an SPU worker, busy
[samp] tid 11040  guest=0   ntdll=430 other=0        <- an idle PPU thread
```

Four guest samples across the whole run --- the brief BIOS execution --- and everything else
parked in a kernel wait.

**2. Its last syscalls are yields from inside the interpreter.** With the guest `lr` now on the
syscall trace:

```
[sc] 43(...) tid=1 glr=0x001068F4   <- just after `bl 0x105FA8` at 0x1068F0
[sc] 43(...) tid=1 glr=0x00106824   <- just after `bl 0x105FA8` at 0x106820
[sc] 43(...) tid=1 glr=0x00106360   <- just after `bl 0x105FA8` at 0x10635C
```

Syscall 43 is `sys_ppu_thread_yield`, and all three return addresses are **inside
`func_001066A8`/`func_0010621C`** --- the R3000 interpreter and its helper.

**3. That third site is an idle loop.** In `func_0010621C`:

```
0010631C  stw r5, 0x120(r28)     ; store the scheduler's return into the CYCLE BUDGET
00106328  bl  0xC2778            ; yield
0010635C  bl  0x105FA8           ; event scheduler -> new budget in r3
00106360  lwz r0, 0x138(r28)     ; the exit-reason field
00106368  cmpwi cr7, r0, -1
0010636C  beq cr7, 0x10631C      ; still -1 -> go round again
```

The interpreter runs its ~42,000 BIOS instructions, enters this loop, and stays: schedule,
yield, check the reason, repeat. It is **waiting to be woken**, which is exactly why it stops
dispatching, why it never returns, and why the profiler finds it in `ntdll` rather than burning
CPU. Every symptom this investigation chased follows from this one state.

**4. Only one thing can wake it, and it is never called.** `+0x138` is written from one place
that stores a real reason --- `func_001058AC`:

```
001058B0  r0  = *(r11+0x138)     ; r11 = the R3000 state block
001058B8  cmpwi r0, -1
001058BC  bne -> skip            ; only set it if still unset
001058C0  stw r3, 0x138(r11)     ; reason = the argument
001058C4  ... then truncates the cycle accounting so the interpreter returns promptly
```

and it has **exactly one caller**, at `0x000C2730`, with `r3 = 7`:

```
000C2710  sld    r0, r0, r11     ; r0 = 1 << event_index
000C270C  ori    r9, r9, 0x1111  ; the "does not wake" mask
000C2718  and    r0, r0, r9
000C271C  li     r3, 7
000C2724  bgt    cr7, 0xC2730    ; index > 0x20 -> wake
000C272C  bne    cr6, 0xC2750    ; bit in the mask -> just record it, do NOT wake
000C2730  bl     0x1058AC        ; ** wake the R3000, reason 7 **
```

So the emulator wakes the R3000 only for events whose bit falls **outside** mask `0x1111`
(bits 0, 4, 8, 12). Events inside the mask are recorded and the R3000 keeps sleeping.

**The chain, complete:**

```
the emulator never delivers a waking event
  -> func_001058AC(7) is never called, +0x138 stays -1
     -> the R3000 idles in func_0010621C's loop, yielding forever
        -> no game code runs, so GP0 is never written
           -> the GP0 handler func_0010C48C never fires
              -> the GPU SPUs get no command packets and spin
                 -> no PS1 GPU output; the packet count stays at 6
```

**The next step is now specific**: instrument `0x000C2730`'s function to log every event index
it is called with, and see which arrive and which the `0x1111` mask suppresses. The BIOS at
this point is almost certainly waiting on the PS1 **vblank**, so if vblank's index is inside
that mask --- or if no event of any kind reaches this function --- that is the bug, and it sits
in the emulator's own timing/event plumbing rather than anywhere downstream.

### Correction, and the measured picture: an always-due event, not an idle wait

The previous entry said the R3000 "idles waiting to be woken" and that nothing wakes it. The
yielding is real, but the reason was inferred and the inference was wrong. Instrumenting the
scheduler's own queue settles it:

```
[dbg] sched #1     head=0x0076C6CC listhead=0x0076C5C0 has-events due=0x00000000 total=0x00000000
[dbg] sched #2     head=0x0076C6E0 listhead=0x0076C5C0 has-events due=0x00000040 total=0x00000040
[dbg] sched #1800  head=0x0076C6B8 listhead=0x0076C5C0 has-events due=0x00070500 total=0x00070500
[dbg] sched #2000  head=0x0076C6F4 listhead=0x0076C5C0 has-events due=0x0007CD00 total=0x0007CD00
```

The queue is **never empty** --- every sample reports `has-events` --- and **`due == total` on
every single one**. There is always an event due *right now*, and the head cycles between a
few slots (`0x76C6B8`, `0x76C6E0`, `0x76C6F4`) that are fired and immediately re-armed.

So the core is not parked waiting for an external wake. It is **thrashing**: `func_00105FA8`
computes the new budget as `next_due - now`, that is ~0 because an event is always due, the
interpreter gets a slice of roughly twenty instructions, calls `func_0010621C` to refill,
yields, and goes round again. Measured: ~4,799 refill calls and ~2,000 scheduler rounds for
~42,000 instructions --- about **20 instructions per round**, and the yield makes each round
cost a scheduler round-trip.

That is why every probe read as a stall: at ~400 instructions/second the BIOS makes no visible
progress, the PC sits in the same region for the whole run, and the thread spends its life in
`ntdll` inside the yield. **It was never stopped. It is running about five orders of magnitude
too slowly.**

**And this vindicates the very first diagnosis of this investigation, which I discarded.** The
session opened on "the cycle budget at `+0x120` is 0". I demoted that to a symptom on the
grounds that a zero budget is normal and the scheduler tops it up. Both halves of that were
true and the conclusion was still wrong: the budget is topped up, to ~0, every time, because an
event is perpetually due. The original observation was pointing at the right field.

**The concrete next step**, and it is where the session began: `func_0010EA58` schedules two
events back to back at `0x10ED74` (delay 64) and `0x10ED94` (**delay 0**). A delay-0 event
re-armed each time it fires produces exactly this signature. Log the delay argument to
`func_00105E68` per call and find which event re-arms at 0 --- then why. The scheduler and its
callers are small and now well understood, and the queue instrumentation to confirm a fix
already exists.

### ROOT CAUSE, measured end to end: semaphore 1 is never posted

Two corrections first, because both of my previous readings of this were wrong and for
instructive reasons.

**It is a stop, not a crawl.** Timestamping dispatch and the scheduler from one clock:

```
[dbg] disp 10000 t=227640948860us
[dbg] disp 40000 t=227640971137us      <- 40,000 instructions in ~22 ms
[dbg] sched #1    t=227640941404us
[dbg] sched #2000 t=227640971108us     <- 2,000 rounds in ~30 ms
```

The R3000 runs at a healthy **~1.8 MIPS for about 30 ms**, executes its ~42,000 BIOS
instructions, and then stops dead. The "always-due event throttles it to ~400 instr/sec"
entry above is **wrong** --- that rate came from dividing the instruction count by the whole
run length, which assumes it ran throughout. It did not.

**And the blocking call names itself.** `sc_trace` logs *after* a syscall returns, so a call
that never returns leaves no trace at all --- which is why the blocker stayed invisible.
Logging syscall **entry** (`PS3_SCENTER=1`) gives the last thing the main thread ever did:

```
[sc-enter] #9863 num=43 tid=1 lr=0x00106360     ; yield, returns
[sc-enter] #9864 num=92 tid=1 a3=0x1 lr=0x00113EB4
```

Syscall **92 is `sys_semaphore_wait`**, on **semaphore 1**, from `0x113EB0` --- the
double-buffer flip wait. There is no matching exit line. It never returns.

**And semaphore 1 is never posted.** Counted correctly across three independent runs:

```
scratch/sem2.log      sem=1 posts: 0
scratch/nogfxerr.log  sem=1 posts: 0
scratch/isr.log       sem=1 posts: 0
```

The posts that do happen go to semaphores 4, 5, 6, 7, 9 and 10 --- never 1.

**This also corrects an earlier claim in this file that the fence wait "completes".** That
rested on two mistakes: an unchecked assumption that the guest was single-threaded through
that path, and `grep -c "semaphore_post(sem=1"` --- which also matches **`sem=10`**, of which
there are ~104 per run. The "24 posts to sem 1" figure quoted earlier was that artifact. A
missing character class turned "never posted" into "posted 24 times" and sent the
investigation downstream for hours.

**The complete chain, every link measured:**

```
the R3000 runs ~42,000 BIOS instructions in ~30 ms at ~1.8 MIPS
  -> reaches the flip wait at 0x113EB0 and calls sys_semaphore_wait(sem=1)
     -> nothing ever posts semaphore 1, so the call never returns
        -> the main guest thread parks in ntdll for the rest of the run
           -> the R3000 executes nothing further, so GP0 is never written
              -> the GP0 handler func_0010C48C never fires
                 -> the GPU SPUs get no command packets and spin at LS 0x1268
                    -> no PS1 GPU output; the packet count stays at 6
```

**The next question is narrow and concrete:** what is supposed to post semaphore 1? It is
created `init=0 max=1` (a one-shot completion latch) and waited on exactly once. Find the
guest code that would post it --- the semaphore id is stored in some object, so a store watch
on that field will name the writer and the intended poster --- and determine why that path
never runs. Given the flip context, the likeliest answer is a completion callback the runtime
never invokes.

## SOLVED: semaphore 1 is posted by the RSX user-command handler

The previous section left one question: what is supposed to post semaphore 1? Answered, and the
predicted shape was right --- it is a callback the runtime never invoked.

### Following the semaphore back to its poster

Semaphore 1's id is written to `id_out=0x01620370` from `lr=0x00116CC0`. That resolves to a
static object: the creation site loads `r29` from `TOC-0x7834` (`= 0x016201A4`) and the id lands
at `obj+0x1CC`.

```
00116CE0  addi r3, r29, 0x1cc      ; &sem_id
00116CE4  addi r4, r1, 0xd8        ; attr {init=0, max=1}
00116CF0  li   r11, 0x5a           ; 90 sys_semaphore_create
00116CF4  sc
00116CF8  li   r11, 0x5d           ; 93 sys_semaphore_trywait  (drain to zero)
00116CFC  lwz  r3, 0x1cc(r29)
00116D00  sc
```

Scanning every `sc` in the image for syscall 94 (`sys_semaphore_post`) --- 68 sites --- exactly
one of them posts *this* field:

```
00113AC8  lwz  r9, -0x7834(r2)     ; the same object
00113ACC  mflr r0
00113AD0  li   r4, 1
00113AD8  li   r11, 0x5e           ; 94 sys_semaphore_post
00113ADC  lwz  r3, 0x1cc(r9)       ; the same semaphore
00113AE0  sc
00113AEC  blr
```

`func_00113AC8` is a five-instruction leaf. Scanning every `b`/`bl` in the image for it returns
**zero callers** --- so it can only be reached indirectly. Its OPD is at `0x1B62E0`
(`{code=0x113AC8, toc=0x1C3D30}`), the only word in the image holding that OPD address is
`0x1BC674` = `TOC-0x76BC`, and the only instruction that loads that slot is:

```
00117348  lwz  r3, -0x76bc(r2)     ; the poster's OPD
00117350  bl   0x19d88             ; register it
```

`func_00019D88` is the registration:

```
00019DA4  cmpwi cr7, r31, 0
00019DA8  beq   cr7, 0x19dd4       ; NULL handler -> clear the bit instead
00019DAC  lwz   r0, 0x12c0(r3)
00019DB4  ori   r0, r0, 0x80       ; driverInfo->handlers |= 0x80
00019DB8  stw   r0, 0x12c0(r3)
00019DC0  stw   r31, 0x2c(r9)      ; *(TOC-0x6AB4)->slot[0x2C] = handler
```

`0x12C0` is the `RsxDriverInfo` handler mask and bit `0x80` is `SYS_RSX_EVENT_USER_CMD`. It is
also the *only* one of the 16 writes to `+0x12C0` in the image that sets a bit --- consistent
with the note already in `sys_rsx.c` that the mask settles to `0x84`.

So: **the semaphore ps1_netemu's flip path blocks on is posted by its RSX user-command handler.**

### And the guest does issue the user command

`ori 0xEB00` appears at five addresses; one of them, `0x114538`, is in the same function as the
wait (`func_00113F08`, which spans `0x113F08..0x1160F4`), and it comes *before* it:

```
00114518  lwz  r11, 8(r28)         ; ctx->current
0011451C  lwz  r0, 4(r28)          ; ctx->end
00114528  bgt  cr7, 0x1156f4       ; out of room -> reserve
00114530  lis  r9, 4
00114538  ori  r9, r9, 0xeb00      ; header 0x0004EB00
0011453C  li   r0, 1               ; argument 1
00114544  stw  r0, 4(r10)
00114548  stw  r9, 0(r10)
00114550  bl   0x3030c             ; publish put
...
00114AB8  bl   0x113e64            ; -> sys_semaphore_wait(sem=1) at 0x113EC8
```

No ordering deadlock, then: the command is written and the put published *before* the wait. The
FIFO walker was simply dropping it.

### Why the walker dropped it

`GCM_SET_USER_COMMAND` is method `0xEB00`. The walker's header decode keeps 13 bits of method
and takes the next three as a subchannel:

```c
u32 count  = (w >> 18) & 0x7FF;
u32 method = w & 0x1FFCu;
u32 subch  = (w >> 13) & 7;
```

`0x0004EB00` therefore decodes as count 1, **subchannel 7, method `0x0B00`** --- which routes
into `gcm_2d_method`, whose default is to discard anything it does not recognise. That is why
this never showed up as a missing method: it looked like an unimplemented 2D method on a
subchannel nobody had claimed.

`libs/video/tests/test_user_command.c` pins this decode down, so widening the method mask fails
a test instead of silently returning the port to zero frames.

### The fix, and what it moved

`rsx_raise_user_cmd()` in `sys_rsx.c` does what `sys_rsx_context_attribute`'s `0xFEF` case does
in RPCS3: write the argument to `driverInfo+0x12CC` (`userCmdParam`), then `rsx_send_event`
`USER_CMD`. The existing handler-mask filter makes it safe.

The guest side then works unmodified, which is the useful confirmation --- its ISR
(`0x1A5D8`) receives on the queue we publish at `+0x12D0`, checks `data1 == 0`, tests bit
`0x80` of `data2`, reads `userCmdParam`, and calls the slot:

```
0001A62C  sc                       ; 130 sys_event_queue_receive
0001A634  mr   r18, r6             ; data2 = flags
0001A64C  cmpdi cr7, r5, 1         ; data1 == 1 -> exit the ISR loop
0001A654  cmpdi cr7, r5, 0         ; data1 != 0 -> ignore, loop
0001A65C  rlwinm r0, r6, 0, 0x18, 0x18   ; test bit 0x80
0001A668  lwz  r9, 0x2c(r14)       ; the handler we saw registered
0001A684  lwz  r3, 0x12cc(r11)     ; userCmdParam
0001A694  bctrl
```

and the runtime log shows exactly the payload it wants:

```
[usercmd] #1 arg=0x00000001 handlers=0x84 qid=1
[evt] q=1 receive RETURNED to tid=2: src=0x0 d1=0x0 d2=0x80 d3=0x0
```

**Measured, same 90-second run before and after:**

| | before | after |
|---|---|---|
| semaphore 1 posts | 0 | **835** |
| user-command raises | 0 | **836** |
| RSX FIFO packets seen | 6 | **5,628** |
| R3000 | stopped after ~42,000 instructions | **running** |
| furthest call reached | `sys_semaphore_wait` | **`cellAdecDecodeAu`** |

### A second logging artifact, in the same investigation

"sem=1 posts: 0" was partly an artifact. `sys_semaphore_post`'s log is capped at 40 lines unless
`SEMTID` is set --- and the posts counted summed to *exactly 40*:

```
24 sem=10   11 sem=9   2 sem=6   2 sem=4   1 sem=7      = 40
```

That was the cap, not the distribution. The root-cause conclusion held only because the wait
never returning was independent evidence; the number never supported it. With `SEMTID=1` the
same build shows 837 posts to sem 6, 836 to sem 7, 835 to sem 1.

This is the second time a logging artifact drove this investigation: the earlier one was
`grep -c "semaphore_post(sem=1"` also matching `sem=10`. **Counts from this log are only
trustworthy with `SEMTID=1`, and only with a `grep` pattern anchored past the digits.**

### Next: `cellAdec` is a stub, and the title now uses it

With the flip unblocked the title reaches its audio decoder and crashes:

```
[cellAdec] StartSeq(handle=0)
[cellAdec] DecodeAu(handle=0, addr=0x764D80, size=384)
[CRASH] code=0xC0000005 rip=00000000001B5F00
[CRASH] last HLE NID 0x1BC200F4 (cellAdecDecodeAu)
[CRASH] guest ctr=0x00000000 lr=0x000EE734 r3=0x00000000
```

A null `ctr` means the guest called through a function pointer the stub never filled in. This is
on the direct path to the intro videos: they have audio.

## cellAdec: four ABI faults, and the PS1 core running for the first time

With the user command wired up, ps1_netemu reaches its audio decoder --- and crashed there
instantly. Four separate faults, none of them visible from inside this codebase. Each was found
by reading the firmware's own code.

### 1. The callback was called as a host function pointer

`cbFunc` is a guest EA naming an OPD. It was stored in a host `CellAdecCbMsg` and called
directly:

```
[CRASH] code=0xC0000005 rip=00000000001B5F00
[CRASH] last HLE NID (cellAdecDecodeAu)
```

`0x1B5F00` is not a host address. It is the guest OPD --- and specifically the one whose code
word is `func_000ED918`, the title's own callback. Dispatching through `g_ps3_guest_caller`
fixes it; the host typedef is now a comment so nobody can call one again.

### 2. The PcmItem was handed out as a host pointer

`cellAdecGetPcmItem` did `*pcmItem = &s_adec[handle].lastPcm` --- a host address written into
guest memory. The guest dereferenced it and died (`rip 0x870D0E`, fault `0xCFFDFFF0`).

The layout is not a guess. The guest copies the whole item out with six 8-byte loads at
`0x000ED964`:

```
000ED958  lwz  r9, 0x70(r1)        ; the EA we wrote
000ED964  ld   r0,  0(r9)
000ED968  ld   r10, 8(r9)
000ED96C  ld   r8, 0x10(r9)
000ED970  ld   r7, 0x18(r9)
000ED988  ld   r0, 0x20(r9)
000ED984  ld   r10, 0x28(r9)
```

So it is 0x30 bytes, and `auInfo` sits at +0x18 rather than +0x14 --- it contains a `u64`, so
it is 8-aligned. That copy settles the padding question that reading RPCS3's struct alone
cannot.

**And that memory must not come from the guest's heap.** Taking 8 KB through `_sys_malloc` in
`cellAdecOpen` stalled the title before it even reached `cellAdecStartSeq`: ps1_netemu allocates
from the same bump allocator. It is a fixed reservation in the HLE inject window at `+0x40000`
instead, clear of the label/control/offset-table pages and sys_rsx's three.

### 3. The message types were swapped

`ERROR` is 2 and `SEQDONE` is 3, not the other way round --- so `cellAdecEndSeq`'s `SEQDONE`
arrived at the guest as `ERROR`. Confirmed twice: RPCS3 `Modules/cellAdec.h:304`, and the guest
callback itself, which branches only on `msgType == 1` (`PCMOUT`):

```
000ED918  cmpwi cr7, r4, 1
000ED928  addi  r4, r1, 0x70
000ED92C  beq   cr7, 0xed944     ; -> cellAdecGetPcmItem
000ED934  li    r3, 0            ; everything else: ignore
```

### 4. Every error code was invented --- and one was load-bearing

Ours were `0x80610201..207`. The real list is `FATAL/SEQ/ARG/BUSY/EMPTY = 0x80610001..5`.

The guest says so outright. Its audio thread drains the decoder after a format change:

```
000EE1FC  lwz   r0, 0x6764(r9)   ; current format
000EE208  cmpw  cr7, r30, r0     ; same as the new AU's? then skip
000EE220  bl    0x15f14c         ; cellAdecEndSeq
000EE230  bl    0x15f0ec         ; cellAdecGetPcm(handle, 0)
000EE238  cmpw  cr7, r3, r31     ; r31 = 0x80610005
```

`0x80610005` is the **only** cellAdec code this image ever compares against --- 8 sites, all the
same value. Returning `0x80610204` for `EMPTY` meant that loop never saw its terminator, so the
title re-ran the entire format-change path.

There is no `AU` or `PCM` code in the real list; both now alias a real one rather than staying
values no title can match.

### What it moved

Measured over a 100-second run:

| | before | after |
|---|---|---|
| `cellAdecEndSeq` calls | 4,760 | **2** (against 1 `StartSeq`, as intended) |
| crash | yes | **no** |
| RSX FIFO packets | 5,628 | **12,264** |
| live-draw groups executed | 0 | **12,264** |

The draw engine executing anything at all is new --- it had been fed nothing at all before.

`libs/codec/tests/test_adec_abi.c` pins the error codes and message types against the
firmware's own compared value, because neither can be checked by reading our own source. That
is exactly why both survived this long.

### The PS1 core now runs continuously

`PS1_PC=1` puts the R3000 state block (`0x76C080`) on the `[fps]` heartbeat:

```
[ps1] pc[...] exited=0 total=38813184
[ps1] pc[...] exited=0 total=1036797696
```

`+0x124` is instructions retired. It climbs past **a billion in 100 seconds** --- roughly
17 MIPS, continuously. Before the user-command fix it managed 42,000 and stopped.

**A trap worth recording, because it was nearly the next wrong conclusion.** `+0x108` reads
`0xBFC00000` --- the reset vector --- at every single sample. Hard-sampled, it is
`changes=0/20000`, and across 14 samples that is 280,000 reads without one different value,
while the instruction count climbs past a billion. That looks exactly like a **reset loop**: the
BIOS restarting forever.

It is not. The interpreter loads PC from `+0x108` on entry (`lwz r26, 0x108(r23)` at
`0x001066CC`) and writes it back only in its epilogue (`stw r26, 0x108(r23)` at `0x00106964`)
--- and it has not returned, because it is entered once and loops internally. `+0x108` is stale
from boot. The epilogue also does `ori r26, r26, 0x80` immediately before that store, so a
genuine exit there could not write `0xBFC00000` at all --- which is what ruled the reset-loop
reading out, rather than any amount of extra sampling.

Same shape as the two counting mistakes in the previous commits: **a field that is only written
at one boundary is not live state, and a constant is not evidence of being stuck.** The
distinct-value sampler is kept in the probe for exactly this reason --- one read cannot tell
"constant because dead" from "constant because stuck", and those need opposite fixes.

### Next: the PS1 GPU SPUs are waiting for a mailbox that never arrives

The RSX side is healthy --- 22,029 packets, 22,029 groups executed, **zero** drops of any kind,
2,877 real texture binds. But the window is black and the PS1 GPU cores are parked:

```
[ch-block] spu=2 pc=0x011A0 op=rdch ch=29 evstat=0x0 evmask=0x0
[ch-block] spu=3 pc=0x011A0 op=rdch ch=29 evstat=0x0 evmask=0x0
[ch-block] spu=4 pc=0x0CC88 op=rdch ch=29 evstat=0x0 evmask=0x0
```

Channel 29 is `SPU_RdInMbox`. All of the GPU SPUs are blocked waiting for the PPU to send them
an inbound mailbox message, and nothing does. Of the 22,029 RSX groups, 15,961 are clears ---
consistent with the PS3 side compositing an empty PS1 framebuffer every frame.

So the next question is the mirror of the last one: **what is supposed to write those SPUs'
inbound mailboxes?** `func_0010F658` is the SPU command-packet sender and `func_0010C48C` is the
PS1 GP0 handler (OPD `0x1B6158`, registered at `0x108518`). The chain to establish is whether
the R3000 reaches GP0 at all, and if it does, why the packet never leaves the PPU.

Note also that boot is racy: of five identical 100-second runs, one reached nothing at all while
the others reached `DecodeAu`. Worth pinning down before any timing-sensitive conclusion is
drawn from a single run.

## Where it stops now: the PS1 GPU handshake, measured end to end

The port no longer stalls at boot, and it no longer crashes. It runs, decodes audio, and feeds
the RSX cleanly --- and then wedges. This is the chain, every link measured.

### 1. The R3000 stops by spinning, not by blocking

`PS3_SCENTER=1`, last 400 syscalls before the freeze:

```
385  num=43  tid=1   lr=0x001068F4
  8  num=130 tid=6   lr=0x00113444     (flip thread, normal)
  6  num=130 tid=9   lr=0x000EBAF8     (normal)
```

Syscall 43 is `sys_ppu_thread_yield`, and `0x001068F4` is **inside the R3000 interpreter**
(`func_001066A8`, 0x1066A8..0x108348). The main thread is not blocked in a syscall at all --- it
is busy-waiting in the interpreter's own outer loop:

```
001068DC  bgt  cr7, 0x106890      ; budget > 0 -> go execute instructions
001068E0  li   r27, 4
001068E8  extsw r4, r28
001068F0  bl   0x105fa8           ; the event scheduler
001068F4  lwz  r4, 0x138(r23)     ; the reason field
001068FC  cmpwi cr7, r4, -1
00106900  beq+ cr7, 0x106834      ; still -1 -> loop
```

`func_00105FA8` returns the next instruction budget in r3. The interpreter takes it, finds it is
not greater than zero, calls the scheduler again, and yields --- forever. Meanwhile `+0x124`,
instructions retired, is frozen. So the loop is spinning *without executing any R3000
instructions*: the scheduler is returning a budget of zero permanently.

That is the same **budget-0 condition at +0x120** that once stopped this port at boot. It has
moved, not gone: it now happens after 18 million to a billion instructions rather than after
zero.

### 2. The GPU command ring stops at the same moment

`PS1_PC=1` reports the ring `func_0010F658` writes:

```
[ps1] ... total=18640128 ring[base=0x00D70E80 off=0x00002100]
[ps1] ... total=18640128 ring[base=0x00D70E80 off=0x00002100]     (x14, frozen)
```

`0x2100 / 0x100` = **33 packets produced, then nothing**, frozen on the same sample as the
instruction count. The base, `0x00D70E80`, is exactly the second word the PPU hands every GPU
SPU at startup --- which is what confirms this is the right ring rather than a plausible one.

### 3. The GPU SPUs are parked on their inbound mailbox

```
[ch-block] spu=2 pc=0x011A0 op=rdch ch=29 evstat=0x0 evmask=0x0
[ch-block] spu=3 pc=0x011A0 op=rdch ch=29 evstat=0x0 evmask=0x0
[ch-block] spu=4 pc=0x0CC88 op=rdch ch=29 evstat=0x0 evmask=0x0
```

Channel 29 is `SPU_RdInMbox`. And the complete inbound-mailbox history for the whole run is
three words per SPU, all at init:

```
W spu0 +0x4401C = 0x00000001    ; RUNCNTL: run
W spu0 +0x4400C = 0x40600000
W spu0 +0x4400C = 0x00D70E80    ; the ring base
W spu1 +0x4401C = 0x00000001
W spu1 +0x4400C = 0x40600000
W spu1 +0x4400C = 0x00D70E80
...                              ; the same for spu2, spu3
W spu0 +0x4400C = 0x00000000     ; one zero each, and then nothing at all
```

Against 5,695 writes to `spu4 +0x5C00C` (`SIG_NOTIFY2`) in the same run --- so the notification
machinery works; it is simply never used for the four GPU cores after startup.

### 4. And the kick that does happen is not a mailbox

`func_0010F658`'s tail, after it advances the write offset:

```
0010F6B0  sync
0010F6B4  lwz  r9, -0x7948(r2)    ; a table of four pointers
0010F6B8  stw  r0, 0(r6)          ; publish the new ring offset
0010F6BC  lwz  r7, 0xc(r9)
0010F6C0  lwz  r11, 0(r9)
0010F6C4  lwz  r10, 4(r9)
0010F6C8  lwz  r8, 8(r9)
0010F6CC  stw  r0, 0(r11)         ; mirror it to four addresses, one per SPU
0010F6D0  stw  r0, 0(r10)
0010F6D4  stw  r0, 0(r8)
0010F6D8  stw  r0, 0(r7)
```

Four plain stores into guest RAM, no mailbox and no signal. They are guest RAM rather than
mapped local store, and the SPU MMIO trace proves it: those stores executed 33 times and the
trace logged **no** local-store writes in the whole run, only the problem-state registers above.
So the SPUs are expected to DMA that word in themselves.

### The chain

```
33 GP0 batches reach func_0010F658 -> ring offset advances to 0x2100
  -> the four GPU SPUs are never sent a 4th inbound mailbox word
     -> they stay blocked in rdch ch=29 and consume nothing
        -> whatever PS1-side completion the scheduler is waiting on never arrives
           -> func_00105FA8 returns budget 0 forever
              -> the interpreter spins sys_ppu_thread_yield at 0x1068F0
                 -> +0x124 freezes; the PS1 framebuffer stays empty
                    -> 15,961 of 22,029 RSX groups are clears; the window is black
```

### What is worth being careful about here

The last link is inference, not measurement. "Whatever completion the scheduler is waiting on"
is exactly the kind of gap that produced three wrong conclusions earlier in this port, so it is
named as unmeasured rather than asserted. What *is* measured: the yield site, the frozen
instruction count, the frozen ring offset, the 33 packets, the complete mailbox history, and the
absence of any local-store write.

The next step is therefore narrow and does not depend on that inference: **find what writes a
GPU SPU's inbound mailbox after startup.** The init writes cannot be attributed from their `lr`
--- both reported values (`0x0010EF90`, `0x0010F25C`) are stale, because `lr` is only written by
`bl` and these are call-free store sequences, the same trap that once misattributed the flip
wait. They have to be found by their addressing pattern: the guest computes the full MMIO
address, so there is no store in the image with displacement `0x400C`, `0x4004`, `0x4014` or
`0x401C`.

One more thing to fix before drawing timing conclusions: **boot is racy.** Across identical
100-second runs the freeze point ranged from 18.6 million to 1.03 billion instructions, and one
run reached no cellAdec activity at all. Every run does eventually freeze, so the variance is in
*when*, not *whether* --- but any measurement taken from a single run needs that caveat
attached.

## CORRECTION: the PPU -> SPU GPU handoff works. The freeze is on our side.

The section above concluded that the four GPU SPUs "are never sent a 4th inbound mailbox word"
and therefore "consume nothing". **Both halves of that are wrong**, and the way they were wrong
is worth keeping, because it is the same mistake three times over in this port.

### The SPU is not waiting for a 4th mailbox word

Reading the lifted SPU code instead of inferring from a log line, `spu0_spu_func_000011A0` is:

```c
spu_wrch(ctx, SPU_WrOutMbox, 0x15010);        /* "ready; my poll word is at LS 0x15010" */
ctx->gpr[9] = spu_rdch(ctx, SPU_RdInMbox);    /* word 1 */
ctx->gpr[8] = spu_rdch(ctx, SPU_RdInMbox);    /* word 2 */
ctx->gpr[7] = spu_rdch(ctx, SPU_RdInMbox);    /* word 3 */
...
{ ctx->pc = 0x1268; ... }                     /* falls through to the steady-state loop */
```

It reads **exactly three** words, and the PPU sends exactly three (`0x40600000`, the ring base
`0x00D70E80`, then `0`). The handshake completes. The `[ch-block] ... pc=0x011A0 op=rdch ch=29`
lines were **init-time transients** --- the channel logger prints while a read waits, and those
reads were later satisfied. I read a snapshot of a transient state as the steady state.

### And the steady-state kick lands on all four SPUs

The loop the SPUs actually sit in is `0x1268`, and it is a poll, not a mailbox read:

```c
ctx->gpr[8]  = spu_ls_read128(ctx, 0x15010);      /* its own poll word   */
ctx->gpr[19] = spu_ceq(ctx->gpr[84], ctx->gpr[8]); /* vs. last consumed  */
if (...) { ctx->pc = 0x3140; ... }                 /* changed -> do work */
```

`0x15010` is the address it reported through the outbound mailbox. And `func_0010F658`'s four
stores write the new ring offset to exactly that address in each SPU's local store --- a raw
SPU's local store is aliased into guest memory (`s->ctx->ls = vm_base + s->base`), so those are
plain stores that need no MMIO hook. Which is why the SPU MMIO trace showed no local-store
writes: **there is nothing to log.** I read that absence as "the kick is lost".

Measured directly, reading the same bytes the SPU reads:

```
ring[base=0x00D70E80 off=0x00004300] spuLS[00004300 00004300 00004300 00004300]
```

67 packets published, and **all four GPU SPUs see the exact ring offset**. The PPU -> SPU GPU
handoff works.

### Three misreads, one shape

| what I concluded | what was actually true |
|---|---|
| SPUs blocked forever on `rdch ch=29` | a transient during init; the read completed |
| the kick is lost (no LS writes logged) | LS is aliased, so correct writes log nothing |
| SPUs never told about new packets | all four read the exact current offset |

Every one of them is **absence of evidence read as evidence of absence** --- a capped log, an
unhooked path, a transient snapshot. The same shape as the semaphore-post cap and the missing
`GetPcmItem` log line earlier in this port. The rule that would have caught all five: *before
concluding "X never happens", establish that X would have been visible if it did.*

### So where does it actually stop?

Not in the guest's GPU protocol. The freeze looks like it is on our side:

* the R3000 spins `sys_ppu_thread_yield` at `0x1068F0` on a permanently-zero budget
* `+0x124` (instructions retired) freezes
* the GPU ring freezes
* and in the last run the **`[fps]`/`[ps1]` heartbeat itself printed only once in 90 seconds**,
  where earlier runs printed 14 times --- so the D3D12 present thread stalled too

A guest-logic deadlock does not stop our own present thread. Everything stopping together
points at a **host-side stall** --- most plausibly a lock held across a blocking wait, where the
SPU channel wait and the FIFO drain / present path contend. That is a hypothesis, explicitly
labelled as one; the next step is to attach and get host stacks for all threads at the freeze
rather than to reason further about it.

The freeze point also varies enormously between identical runs --- 18.6M, 37.5M and 1.03 billion
instructions across three --- which is itself consistent with a race rather than a deterministic
protocol gap.

## The PS1 core renders. Here is the proof, and what is actually left.

Two corrections to the section above first, then the verified state of the whole pipeline.

### "The window is black" was an unfalsifiable assumption

`PrintWindow` on a D3D12 swapchain returns black whether the page is black or the capture
failed. Every screenshot taken in this port could not distinguish those, so none of them was
evidence of anything.

`PS1_FBDUMP=<path>` writes PS1 VRAM straight out of guest memory as a PPM --- 1024x512, 16-bit
1-5-5-5, pitch 2048, the format `[tex-refresh]` reports. No D3D, no window, no swapchain. What
came out:

**the PlayStation logo, "SCEA", "Licensed by Sony Computer Entertainment of America", and a block
of legal text.** That is the PS1 BIOS boot screen. The PS1 core renders correctly.

It also says where the picture is: **every non-black pixel is in columns 640..1023.** The region
at columns 0..639 is entirely black. The content is in one VRAM region and something is
presenting another --- a display-origin problem, not a rendering one.

### And the earlier GPU-handoff conclusion was wrong three ways

The previous section concluded the four GPU SPUs "are never sent a 4th inbound mailbox word" and
"consume nothing". Reading the lifted SPU code rather than inferring from a log line:
`spu0_spu_func_000011A0` writes its outbound mailbox once and reads **exactly three** inbound
words --- which the PPU sends --- then falls through to its steady-state loop at `0x1268`. That
loop is a *poll*, not a mailbox read: it compares its own local store at `0x15010` against the
last offset it consumed. `func_0010F658` writes the new ring offset to exactly that address in
each SPU's local store, and a raw SPU's local store is aliased into guest memory
(`s->ctx->ls = vm_base + s->base`), so those are plain stores that need no MMIO hook.

| what I concluded | what was actually true |
|---|---|
| SPUs blocked forever on `rdch ch=29` | a transient during init; the read completed |
| the kick is lost (no LS writes logged) | LS is aliased, so correct writes log nothing |
| SPUs never told about new packets | all four read the exact current offset |

All three are **absence of evidence read as evidence of absence** --- a capped log, an unhooked
path, a transient snapshot. With the semaphore-post cap and the missing `GetPcmItem` log line,
that is five in this port. The rule that would have caught every one: *before concluding "X never
happens", establish that X would have been visible if it did.*

### The verified pipeline

Every row measured, in good runs:

| stage | evidence |
|---|---|
| R3000 executes | `+0x124` reaches **1.1 billion** instructions, ~14 MIPS sustained |
| GP0 -> ring | ring offset reaches `0x6EF300` = **28,403 packets** |
| ring -> 4 GPU SPUs | `pub == done` on all four at every sample, to **21,206 packets consumed** |
| SPUs -> PS1 VRAM | non-zero words climb 0 -> 1,776 -> 7,127 -> **75,527** of 262,144 |
| VRAM content | the BIOS boot screen, dumped and read |
| VRAM -> RSX texture | `checks=640 unreadable=0 changed=6 span=1048576 1024x512 pitch=2048` |
| RSX draws | 12,887 packets, 12,887 groups executed, **zero** drops of any kind |
| surface content | 9,573 drops per run -> **0** (surfaces now keyed on size) |

The texture path deserves a note because it was the prime suspect. `[tex-refresh]` firing only 6
times in 90 seconds looked like a stale cache. `LD_FBDBG=1` settled it: the texture is bound and
hash-checked 640 times, always readable, over the full 1 MB span with the correct pitch, and it
refreshes exactly when the content changes --- which in that run was 6 times, because VRAM sat at
7,127 non-zero words throughout. The cache was working correctly on nearly static content. Three
candidate causes, separated by counting rather than by reasoning.

### What is actually left

**1. Nondeterminism, and it is now the dominant problem.** Across five identical runs:

```
VRAM non-zero words:   0        0        1,776    7,127    75,527
instructions retired:  6.8M     26.7M    31.5M    966M     1,097M
```

One run drew nothing at all in 150 seconds. Another ran 1.1 billion instructions and filled 29%
of VRAM. Some wedge; the wedge point ranges over two orders of magnitude. Until this is pinned
down, no single-run measurement of anything downstream means much --- which is exactly the trap
that produced the "budget 0 forever" and "present thread stalled" readings, both of which were
single wedged runs and both of which later runs refuted.

**2. The display origin.** The BIOS drew its boot screen at VRAM x>=640 and columns 0..639 are
black. Either the PS1 program set its display area there and the composite is sampling x=0, or
the content is in a back buffer that never became the front buffer. That is a narrow question
with a narrow answer: what texture coordinates does the composite quad use, and what does
ps1_netemu believe the PS1 display start is?

**3. The BIOS gets stuck after the logo.** VRAM stops changing once the boot screen is drawn.
The next thing a real PS1 BIOS does is read `SYSTEM.CNF` off the disc and boot the executable ---
so the CD-ROM path is the likely place it is waiting, and the syscall histogram does show storage
traffic (540: 3,265 calls, 604: 281) rather than none.

Order matters here: fix the nondeterminism first. The other two are only measurable once a run
behaves the same way twice.

## CORRECTION: the "nondeterminism" was mostly my own instrumentation

The section above named nondeterminism the dominant problem, on the strength of five runs
spanning 0 to 75,527 non-zero VRAM words. That spread was substantially an **observer effect**.

Two clean 60-second runs with no framebuffer dump:

```
run1 vram nonzero=75527  outmbox=5 inmbox_writes=0 chblock=9 intr_deliver=1
run2 vram nonzero=75527  outmbox=5 inmbox_writes=0 chblock=9 intr_deliver=2
```

**Identical, to the word.** Every run that reached only 0--7,127 was carrying the periodic
`PS1_FBDUMP`, which wrote a 1.5 MB PPM on every 5-second heartbeat. Measuring the thing was
changing it, and I then documented the measurement as a property of the system.

That is the sixth instance of the same family of error in this port, and the first one where the
probe itself was the cause rather than a capped log or an unhooked path. The dump is now
one-shot and gated on content (`PS1_FBDUMP_MIN`, default 20,000 non-zero words), which also
means it captures a drawn frame instead of whatever happened to be there at an arbitrary moment.

Wedges do still happen and are still worth chasing --- but they are not the every-run,
two-orders-of-magnitude spread the previous section claimed.

## And the game is running, not just the BIOS

The one-shot dump at 75,527 non-zero words contains **Twisted Metal's own assets**: car sprites,
wheels, vehicle art, and large stylised title letters --- with the BIOS boot screen still sitting
in the display-buffer region at the top right.

So the chain is longer than "the BIOS drew its logo": the PS1 booted, the game took over, and it
has loaded its title/intro textures into VRAM.

The garish green/magenta in those regions is **correct, not a fault**. The dump interprets every
16-bit word as 1-5-5-5 direct colour; those regions hold 4- and 8-bit CLUT-indexed texture data,
so they are supposed to look like noise when read as direct colour. Only the display-buffer
region is meaningfully viewable this way --- which is exactly where the BIOS text is legible.

### So what is left

The display-buffer region (columns 0..639) is still black while every drawn thing sits at
x >= 640. Two questions, in order:

1. **Where does the PS1 think its display area is?** The BIOS drew its boot screen at x >= 640,
   which is a normal place for a PS1 back buffer. If the program set its display start there and
   our composite samples x = 0, that alone is the black screen.

2. **What texture coordinates does the composite quad use?** The PS3 side binds all of VRAM as a
   single 1024x512 texture, so the visible region is selected entirely by the quad's UVs. Logging
   them for the draw that binds `1:0x00400000` answers question 1 directly.

Neither needs any more work on the PS1 side. Everything from the R3000 through the GPU SPUs to
VRAM is verified, and the game's own art is in memory.

## The display path, narrowed to one question

Two candidates ruled out by measurement, and one concrete bug of my own found and fixed.

### Ruled out: we are not presenting an empty or premature buffer

`LD_PRESENT_DBG=1` counts presents whose surface was cleared *after* its last draw --- the
signature of showing a wiped buffer:

```
[present] 0/1024 presents showed a surface cleared after its last draw (0.0%);
          target=6 0:0x310000 1280x720 draw_gen=3760 clear_gen=3759
```

**0% over 1024 presents**, draw generation always one ahead of clear. The presented surface
(slot 6, offset `0x310000`, 1280x720) is drawn every frame. So neither "wrong buffer, it is
empty" nor "right buffer, too early" is the explanation.

### Found and fixed: an ambiguity I introduced

Keying surfaces on size stopped 9,573 content drops per run, but the *sampling* side still
matched on `(location, offset)` alone and took the first hit. With several surfaces per offset
that is arbitrary, and `LD_ALIAS_DBG=1` showed the ambiguity directly:

```
[alias-miss] tex 1:0x00400000 fmt=0xE2 1024x512 target=1
  surf: [0]0:0x00000000 1280x720  [1]0:0x00000000 720x512  [2]0:0x00A20000 720x512 ...
```

Two surfaces at offset `0x0`. ps1_netemu composites the PS1 framebuffer into the 720x512 one and
upscales to a 1280x720 output; a pass sampling offset `0x0` was getting whichever sat earlier in
the table. Now it prefers the surface whose dimensions match the texture descriptor, and
otherwise the most recently drawn one.

**This did not change the visible output.** It is in because the choice it replaces is
indefensible once multiple surfaces per offset exist, not because it fixed anything observable.
Saying so explicitly, because this port has a history of me writing up a change as a fix on the
strength of a plausible mechanism rather than a measured effect.

### What that leaves

The `[alias-miss]` line above is itself the remaining clue: the PS1 VRAM texture
(`1:0x00400000`, 1024x512) is bound while rendering into **targets 1 and 7** --- the 720x512
surfaces at offsets `0x0` and `0x168000`. So the composite pass exists and runs; PS1 VRAM is
being sampled into a 720x512 buffer, which is then upscaled into the presented 1280x720 surface.

Every stage is therefore accounted for, and all of them run. The one thing still unmeasured is
**which part of that 1024x512 texture the composite quad samples** --- and the framebuffer dump
already showed that every drawn pixel lives at x >= 640 while columns 0..639 are black. If the
quad samples from x = 0, that is the whole story, and it is a texture-coordinate question, not a
pipeline one.

The next step is one log line: the vertex UVs of the draw that binds `1:0x00400000`.

## The renderer produces a picture. It draws the wrong data.

This section corrects the two before it, and both corrections come from the same
mistake made a seventh time.

### "All surfaces black" was an early-boot artifact

`LD_SURF_DUMP` fired at a frame number, so every dump was a snapshot of framebuffers the PS1 had
not drawn into yet. `nonblack=0` was the correct reading of an empty source. Gating the dump on
PS1 VRAM actually holding a drawn frame (`LD_SURF_DUMP_ON_VRAM=1`, `PS1_VRAM_READY=150000`)
instead:

```
slot=1 0:0x00000000 720x512  nonblack=72687
slot=2 0:0x00A20000 720x512  nonblack=326656    (89% of 368,640)
slot=5 0:0x01401C00 1280x720 nonblack=817920
slot=6 0:0x00310000 1280x720 nonblack=817920    (89% of 921,600, PRESENTED)
slot=8 0:0x00694000 1280x720 nonblack=817920
```

**The renderer produces a picture covering 89% of the presented surface.** Every "the screen is
black" claim in this repo applies to the first ten seconds of boot and to nothing else.

### Two experiments that made this reachable

Neither is a fix. Both replaced an argument with a measurement, and without them the artifact
above would still be sitting in the docs as a conclusion.

* **`LD_CLEAR_TEST=1`** clears to magenta. It proved the readback can see a non-black pixel
  (293,194 on a 720x512 surface) *before* anything was concluded from zeros.
* **`LD_FORCE_GREEN=1`** makes every fragment program return solid green. It filled every
  surface to exactly 368,640 (720x512) and 921,600 (1280x720) --- proof that the draws reach the
  GPU and write every pixel.

### What it draws is wrong

Both the 720x512 composite and the 1280x720 upscale come out as **uniform green with a regular
pattern of magenta and blue dots**. That is the signature of CLUT-indexed texture data read as
15-bit direct colour --- exactly how the asset regions of PS1 VRAM look in a `PS1_FBDUMP`.

So the composite samples plausible but wrong data, and everything around it is verified good:

| checked | result |
|---|---|
| the UVs | the guest's own: x=1..638, y=2..474 of the 1024x512 texture at `0x400000` |
| GPU state | viewport 0,0 720x512, scissor full, depth off, colour mask all, blend off, cull off |
| the decode | `remap=0xAA6C` forces no channel to zero; decoded non-black climbs 0 -> 3,135 as VRAM fills |
| the draws | reach the GPU and cover the surface (`LD_FORCE_GREEN`) |
| the readback | sees non-black when there is non-black (`LD_CLEAR_TEST`) |

**The remaining question:** which VRAM region holds the *rendered* PS1 framebuffer? The
composite samples `0x400000` rows 2..474, and that is asset data. PS1 VRAM is 1024x512 with the
display buffer and the texture/CLUT pages sharing it, so a PS1_FBDUMP taken at
`PS1_VRAM_READY=150000` --- when non-zero words reach 182,968 of 262,144 and `first=+0x0` ---
read against the sampled rect will say directly whether the display buffer is somewhere else.

### The count of this mistake

Seven times now, one shape: **treating a measurement as a property of the system without first
establishing that the measurement could have seen the alternative.**

| # | what looked true | why it was not |
|---|---|---|
| 1 | sem 1 never posted | log capped at 40 lines |
| 2 | 24 posts to sem 1 | `grep` matched `sem=10` too |
| 3 | `GetPcmItem` never called | it had no log line |
| 4 | SPUs blocked forever on `rdch` | a transient during init |
| 5 | the SPU kick is lost | local store is aliased; correct writes log nothing |
| 6 | runs vary 0..75,527 VRAM words | my own 1.5 MB-per-heartbeat dump caused it |
| 7 | all surfaces black | dumped before the PS1 had drawn |

Two of the seven (6 and 7) were caused by the probe itself. The rule that catches all of them,
and the reason `LD_CLEAR_TEST` and `LD_FORCE_GREEN` exist: **before concluding "X never
happens", make X happen on purpose and check the probe reports it.**

## Located: the display framebuffer holds 24-bit data read as 15-bit

The composite shader was the prime suspect and is innocent. `hlsl_06` --- the only fragment
program that samples the 1024-wide PS1 VRAM texture --- looked like an arithmetic bit-unpacker:

```
r0 = sample(tex0, tc0 * (1/1024, 1/512))
r0 = r0 * fp_constants[0].x + fp_constants[0].y
r0 = floor(r0) / 8.0
r0 = sign-preserving truncate
r0 = r0 * fp_constants[1].x + fp_constants[1].y
```

The constants say otherwise:

```
[uvdbg] fp_const count=2 mode=B c0=(255.0 0.5 0 0) c1=(0.031373 -0.001961 0 0)
```

`0.031373` is `8/255` and `-0.001961` is `-0.5/255`, so per channel it computes
`trunc(floor(v*255 + 0.5)/8) * 8/255 - 0.5/255` --- an 8-bit channel rounded to **5 bits**. It
is a **colour-depth quantiser**, reducing the upscaled output to PS1 15-bit colour, and it
reproduces faithfully whatever it samples.

So the entire PS3 side is now verified correct, and what it samples really does contain the
pattern.

### The two halves of PS1 VRAM

Counting the dump at 186,988 non-zero words:

| region | non-zero | content |
|---|---|---|
| rows 0..245 (display area) | 157,800 | a regular stripe pattern |
| rows 246..511 (asset area) | 145,625 | **recognisable** --- car sprites, vehicle art, title letters |

The asset half is plainly correct PS1 texture data. The display half is a stripe with a
**three-pixel period**:

```
(0,57,197) (0,0,0) (246,0,0) (0,57,197) (0,0,0) (246,0,0) ...
```

A three-pixel period is the signature of **24-bit data read as 16-bit**: 6 bytes is 2 source
pixels and 3 destination pixels. The PS1's 24-bit display mode is its **MDEC / FMV path** ---
which is exactly the intro video this port is trying to reach.

### The reading, and what is actually measured

**Best-supported hypothesis:** the intro video is playing, into a 24-bit framebuffer, and
everything downstream of it treats that memory as 15-bit.

**What is measured**, and separated from the hypothesis on purpose:

* the three-pixel period, and the exact repeating triple
* the two VRAM regions and their non-zero counts
* that the asset half decodes to recognisable game art
* that the composite shader and its two constants are correct
* that the draws reach the GPU and cover the surface (`LD_FORCE_GREEN`)
* that the readback can see non-black pixels when there are any (`LD_CLEAR_TEST`)

### Where that leaves the port

Everything from the R3000 through the GPU SPUs, PS1 VRAM, the texture upload, the composite
shader, the draws and the presented surface is verified working. The remaining gap is a
**display-mode** one: 24-bit PS1 output needs unpacking three bytes per pixel rather than two,
and nothing in this path does that yet.

That is a well-bounded piece of work, and it is the last thing between here and a visible intro
video.

## REFUTED: the stripes are not 24-bit data. They are six palette entries.

The section above put forward "the intro video is playing into a 24-bit framebuffer and
everything downstream treats it as 15-bit" as the best-supported hypothesis. It is wrong. It was
labelled a hypothesis precisely so it could be killed, and two tests killed it.

**Re-reading as 24-bit produces no image.** Reconstructing the raw VRAM bytes and reading the
display region as 3-byte pixels gives a *different* regular stripe, not a picture. If the data
were 24-bit misread as 16-bit, reading it as 24-bit would have shown the frame.

**And the pixels are six palette entries, not image data.** The entire 320x240 display region
contains exactly six distinct 16-bit words:

```
0x0000  24315   black
0x00D7  22560   blue
0x7400  19200   red
0x00DF   4485   bright blue
0x7FFF   3315   white
0x7EE0   2925   orange
```

Six values. A decoded video frame has thousands; a memset has one. Rows are *near* period-3 but
not exactly --- 0 of 240 rows are exactly period-3 across their width --- so this is structured
output, not a fill.

### A methodology error worth naming

The VRAM dump and the surface dump compared in the previous section **came from different runs**,
and run content varies. That is not a small slip: it is the same class as the seven mistakes
tabulated above, and it made a mismatch look like a conclusion.

Capturing both on the same VRAM-ready gate in one run also corrected which surface matters: the
actual composite target is **slot 1 (offset `0x0`)**, not slot 2, and it holds content in a
**320x240 block** --- the PS1's native resolution, correctly placed and correctly sized.

### Where this actually leaves the port

The PS1's own 320x240 display framebuffer holds structured output drawn from a six-entry
palette, while the texture/CLUT half of VRAM decodes to recognisable game art --- car sprites,
vehicle art, title letters.

So asset upload works and the rasteriser runs, but **what it rasterises collapses to a handful of
palette entries in a repeating arrangement**. That is the signature of a texture or CLUT lookup
going wrong inside the lifted SPU GPU code.

That is the next area, and it is on the **PS1 side**, not the PS3 side. Everything from the R3000
through the GPU SPUs' packet consumption, PS1 VRAM, the texture upload, the composite shader and
its constants, the draws, and the presented surface remains verified.

### The count is now eight

| # | what looked true | why it was not |
|---|---|---|
| 1 | sem 1 never posted | log capped at 40 lines |
| 2 | 24 posts to sem 1 | `grep` matched `sem=10` too |
| 3 | `GetPcmItem` never called | it had no log line |
| 4 | SPUs blocked forever on `rdch` | a transient during init |
| 5 | the SPU kick is lost | local store is aliased; correct writes log nothing |
| 6 | runs vary 0..75,527 VRAM words | my own per-heartbeat dump caused it |
| 7 | all surfaces black | dumped before the PS1 had drawn |
| 8 | the framebuffer holds 24-bit data | six palette entries; reading it as 24-bit shows no image |

Number 8 is the first that was **published as an explicit hypothesis and then falsified on
purpose**, which is the only reason it lasted one commit instead of becoming load-bearing. The
two tests that did it are the same shape as `LD_CLEAR_TEST` and `LD_FORCE_GREEN`: make the
alternative happen and see whether it looks like the data.

### The pattern, characterised exactly

Looking at the PS1's 320x240 display region unstretched, it reads as strictly vertical stripes
with no vertical structure --- which would have been a very specific bug signature (the
destination Y being lost, so every write landing on one scanline). Checked before claiming it:

```
rows 0..239 identical to row 0        : 30 / 240
rows 260..511 identical to row 300    :  1 / 252     (asset region, for contrast)
row 0 exact horizontal period         : 24 pixels
```

So there *is* vertical variation --- only 30 of 240 rows repeat exactly --- and the eye-catching
uniformity is a **24-pixel horizontal period**, not a single repeated scanline. The asset region
varies normally, which independently confirms the VRAM read (pitch 2048) is correct.

**What this is:** a 24-pixel-period pattern drawn from a six-entry palette, filling the whole
320x240 display area, with limited vertical variation. Not a video frame, not a fill, not a lost
Y coordinate. It looks like a small texture tiled across the framebuffer, or a CLUT lookup that
collapses a real image onto a few entries at a fixed stride.

**The next area** is the lifted SPU GPU code's texture and CLUT addressing: a 24-pixel period
and six distinct output colours are what a wrong texture-page or CLUT base produces while the
rasteriser itself runs correctly --- and the rasteriser demonstrably does run, because the
framebuffer is the right size, in the right place, fully covered, and updating.

## The GPU SPUs consume commands and produce no pixels

The PS1 GPU cores rasterise into VRAM by **DMA**, not by store, so their MFC PUT destinations are
the only ground truth for what they actually produce. Logged (`SPU_PUTEA=1`):

```
[putea] spu1 cmd=0x20 ea=0x00000000E0015040 size=16 lsa=0x15080
[putea] spu2 cmd=0x20 ea=0x00000000E0015050 size=16 lsa=0x15080
[putea] spu3 cmd=0x20 ea=0x00000000E0015060 size=16 lsa=0x15080
[putea] spu0 cmd=0x20 ea=0x00000000E0115030 size=16 lsa=0x15080
[putea] spu0 cmd=0x20 ea=0x00000000E0215030 size=16 lsa=0x15080
[putea] spu0 cmd=0x20 ea=0x00000000E0315030 size=16 lsa=0x15080
```

`0xE0000000 + n*0x100000` is SPU *n*'s window. So spu1/2/3 write 16 bytes into **spu0's** local
store at `0x15040`/`50`/`60`, and spu0 writes into **spu1/2/3's** local store at `0x15030`. That
is a master/slave work-distribution handshake with spu0 as master --- and it is all they do.

Over a whole run the destination histogram (`SPU_PUTHIST=1`) shows every GPU-SPU write landing
in buckets 0..3, the other SPUs' windows, and nowhere else:

```
spu0 ea~0x100000 / 0x200000 / 0x300000     (equal counts)
spu1 ea~0x000000
spu2 ea~0x000000
spu3 ea~0x000000
spu0    sizes: <=16:29573 <=32:24 <=128:120 <=256:600
spu1..3 sizes: <=16:9856  <=256:600
```

Every non-empty bucket is printed, so the absence of a VRAM bucket is a reading rather than a
gap. For contrast, spu4 (audio) writes 2 KB blocks to `0x60000000` and spreads ~32 MB across
eight buckets --- that SPU is doing real work.

### This corrects an earlier conclusion

"`pub == done` on all four, 21,206 packets consumed" is true and was measured. But **consuming
ring offsets is not the same as rasterising into VRAM**, and this document treated the first as
evidence of the second. The SPUs advance their consumed pointer and exchange handshake messages;
nothing writes a framebuffer.

It also explains the display region: the 24-pixel-period, six-colour pattern is **not corrupted
rasteriser output**, because there is no rasteriser output at all. It comes from some other path
--- most likely ps1_netemu's own PPU-side code or an initial fill.

### Ninth instance, and a new sub-species

The first eight were *absence of evidence read as evidence of absence*. This one is different and
worth naming separately: **evidence of one thing read as evidence of a different thing further
down the chain.** The SPUs really did consume every packet. That says nothing about whether they
drew anything, and it was never checked until now.

### Where the port actually stands

Verified working: the R3000 (1.1 billion instructions, ~14 MIPS), the GP0 command ring, the GPU
SPUs' consumption of it, the texture upload, the composite shader and its constants, the draws,
the presented surface, and the readback.

The gap is now specific and upstream of everything the previous sections were investigating:
**the four GPU SPUs run, consume commands, talk to each other, and never emit a pixel.** The
question is what their handshake is waiting for before it starts producing --- the same shape of
question as the semaphore and the user command, both of which turned out to be one missing link
each.

## ROOT CAUSE: the GP0 ring carries only sync packets

Why the four GPU SPUs consume every packet and emit no pixels: **there is nothing to draw.**

`PS1_RINGDUMP=1` prints the last few packets. Every one is the same shape:

```
[ring] pkt@0x00D71480 type=8: 00000000 00000000 00000000 ... (11 more zeros)
[ring] pkt@0x00D71580 type=8: 00000001 00000000 00000000 ... (11 more zeros)
[ring] pkt@0x00D71680 type=8: 00000000 00000000 00000000 ... (11 more zeros)
```

Type 8, one payload word alternating 0/1, everything else zero. That is a vblank or
field/buffer-index toggle --- a **sync** packet. No geometry, no colours, no texture
coordinates, no GP0 opcodes.

### It identifies the producer by elimination

`func_0010F658` writes **type 3** (at `0x10F658`) and **type 2** (its variant at `0x10F6E0`).
Those are the drawing paths, reached from the PS1 GP0 handler `func_0010C48C` at `0x10C5F0` and
`0x10CA4C`. **Neither type appears in the ring.** A third producer emits type 8, and the drawing
producers never run.

### The chain, reduced

```
the R3000 executes 1.1 billion instructions at ~14 MIPS
  -> its GP0 writes never reach the emulated GPU
     -> only type-8 sync packets enter the ring
        -> the GPU SPUs consume them, exchange handshakes, and rasterise nothing
           -> PS1 VRAM's display region never receives an image
              -> the composite faithfully draws whatever is there instead
```

Everything downstream of the first arrow is verified: the ring advances, the SPUs consume in
step, the texture uploads, the composite shader and its two constants are correct, the draws
cover the surface, and the readback sees them.

This also finally disposes of the 24-pixel-period six-colour pattern. With no drawing commands,
nothing the GPU cores do can put an image in the display region --- so that pattern belongs to
some other path entirely and was never worth decoding. Three sections of this document spent
effort on it.

### Next

Does the R3000 write GP0 (`0x1F801810`) at all, and if it does, why does `func_0010C48C` not
turn that into type-2/3 packets? `func_000C26E4` is the PS1 I/O write handler and is the place
to look. This is the same shape of question as the semaphore and the user command --- each of
which turned out to be exactly one missing link.

### Confirmed from the other side: the SPUs are idle, not stalled

`PS3_SAMPLE=5`, independent of the ring contents:

```
[samp] --- report at t=4000ms ---
[samp] 1597 samples, 70 in guest code (4.4%)
[samp]    41.4%  spu_LS_00001268  (29)
[samp]    21.4%  spu_LS_00000100  (15)
[samp]     7.1%  spu_LS_00001290  (5)
```

`spu_LS_00001268` and `spu_LS_00001290` are the two halves of the GPU SPUs' steady-state poll
loop --- the one comparing its own local store at `0x15010` against the last ring offset it
consumed. Nearly half of all guest time is spent there.

So the SPUs are **idle, not stalled**. Not blocked on a channel, not waiting on a DMA, not stuck
mid-rasterisation: round the "is there new work?" loop, find a sync packet, round again. Two
independent measurements now agree --- the ring contents (type 8 only) and where the time goes.

*(The profiler's exact mode is blind here --- `pdata self-check: func_000C2368 -> NO .pdata
entry` --- so these are nearest-symbol attributions over a merged PPU+SPU map. Sound for SPU
local-store addresses, which are dense and unambiguous. `func_00013040` at 8.6% in the same
report is a mis-attribution to a one-instruction function and should be ignored; that heuristic
already misled this port once.)*

### The ten ring producers, and which one runs

Scanning for every load of the ring-offset pointer (`TOC-0x794C`, displacement `0x86B4`) finds
ten producer functions. Their packet types:

| producer | type | runs? |
|---|---|---|
| `func_0010F83C` | 1 | no |
| `func_0010F6E0` | 2 | no |
| `func_0010F658` | 3 | no --- the GP0 drawing path |
| `func_0010F7D0` | 4 | no |
| `func_0010F768` | 7 | no |
| **`func_0010F5FC`** | **8** | **yes --- the only one** |
| `func_0010F390` | 0xB | no |

`func_0010F5FC` has exactly one caller, `0x0010B23C`, and writes `r3` to `+0x10` --- which is
precisely the packet shape observed (`type=8`, one payload word alternating 0/1, rest zero).

And the GP0 registration is present and correct. At `0x108518`:

```
00108518  lwz  r6, -0x79bc(r2)     ; the GP0 handler OPD (func_0010C48C)
00108520  lwz  r5, -0x79c0(r2)
00108524  lis  r3, 0x1f80
0010852C  ori  r3, r3, 0x1810      ; 0x1F801810 -- GP0
00108534  li   r4, 0x10            ; a 16-byte window
0010853C  bl   0xc23e0             ; register it
```

So the handler is registered for GP0 with a 16-byte window, and it is wired to the type-3
producer (`func_0010F658` is called from `0x10C5F0` and `0x10CA4C`, both inside
`func_0010C48C`). The registration is fine; the handler simply never fires.

**Which puts the whole remaining question in one place:** does the R3000 store to `0x1F801810`,
and if it does, why does the I/O dispatch (`func_000C26E4`) not reach `func_0010C48C`?
