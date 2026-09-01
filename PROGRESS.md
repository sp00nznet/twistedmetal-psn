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
| 6. Lift PPU | `ppu_lifter` → C++ | 🔄 |
| 7. Lift SPU | 2 embedded SPU ELFs → C | ⬜ |
| 8. Shared harness | Build on ps3recomp's boot harness | ⬜ |
| 9. First boot | Enter the recompiled CRT | ⬜ |
| 10. Graphics | `sys_rsx_*` → live NV4097 → D3D12 | ⬜ |
| 11. BIOS | `ps1_rom.bin` executes | ⬜ |
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

## Next steps

1. PPU lift, then reconcile the lifter's symbol sets and get it compiling.
2. Lift both SPU modules and register them.
3. `sys_rsx_*` in the runtime, wired to `rsx_live_draw`.
4. First boot: the emulator's own CRT, then `CoreInit()` / `GPUCoreInit()`.
