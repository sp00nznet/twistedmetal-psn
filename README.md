# 🚗🔥 twistedmetal-psn — Static Recompilation

A static recompilation of **Twisted Metal (PSOne Classic, PS3/PSN)** into a native PC
executable — no emulator required — built on
[ps3recomp](https://github.com/sp00nznet/ps3recomp).

> **The twist:** this package contains no PS3 game code at all. It is a PS1 disc image in
> a wrapper, and the thing that runs it is a PS3 *firmware* module. So the recompilation
> target is **`ps1_netemu.self` — Sony's own PS1 emulator for the PS3** — and the PS1 game
> is just the data it eats. Recompile that once and every PSOne Classic in the catalogue
> runs, not only this one.

---

## 📺 What's in the box

`Twisted Metal PSN [NPUI-94304]` is a **PSOne Classic** (`PARAM.SFO: CATEGORY=1P`),
not a native PS3 title:

| | |
|---|---|
| **Title** | Twisted Metal |
| **PSN Content ID** | `UP9000-NPUI94304_00-0000000000000001` |
| **PS1 Title ID** | `SCUS94304` (SingleTrac / Sony, 1995) |
| **Package** | 75 MB retail PKG, `pkg_type=2` (PSP/PS1 keying) |
| **Payload** | `USRDIR/CONTENT/EBOOT.PBP` (68.7 MB) — `DATA.PSAR` @ `0x18000` holds the disc |
| | `USRDIR/ISO.BIN.EDAT` (1.0 MB) — NPD v1 type-2 EDAT, the DRM half |
| | `USRDIR/CONTENT/DOCUMENT.DAT` (5.1 MB) — PGD-encrypted manual |
| | `USRDIR/SAVEDATA/SCEVMC{0,1}.VMP` — blank virtual memory cards |
| **Runs under** | `/dev_flash/ps1emu/ps1_netemu.self` (PS3 firmware, 922 KB SELF) |

The guess was right: it is an emulator wrapped around an ISO. The emulator just isn't
*in* the package — it ships with the console.

## 🎯 The recompilation target

`ps1_netemu.self`, decrypted with `rpcs3 --decrypt` (retail key revision `0x1C`, no RAP):

| | |
|---|---|
| Decrypted ELF | 2,913,992 B — PPC64, big-endian, `ET_EXEC` |
| Entry | `0x1B5690` (OPD) |
| `.text`+`.rodata` | PT_LOAD @ `0x10000`, `0x199368` B |
| `.data`/BSS | PT_LOAD @ `0x1B0000`, filesz `0x126E68`, **memsz `0x1D9E1E8`** (~31 MB — PS1 RAM, VRAM, SPU RAM, caches) |
| Functions found | **3,512** (`find_functions.py`; every `.opd` descriptor verified as a function start) |
| Imports | **103 functions across 12 libraries**, 86 named (83%) |
| Embedded SPU ELFs | **2**, extracted statically — 86,452 B (entry `0x100`) and 59,580 B (entry `0xE0`) |
| Data it reads | `/dev_flash/ps1emu/ps1_rom.bin` (512 KB PS1 BIOS), `USRDIR/CONTENT/EBOOT.PBP`, `USRDIR/ISO.BIN.EDAT` |

**3,512 functions is small** — smaller than The Simpsons Arcade Game (3,813). This is a
tight, single-purpose emulator, not a game engine.

Internals visible in the strings: `cell/host.c`, `cell/xspu.cc`, `R3000Exit(): PS1_EXIT_STOP`,
`GPUCoreInit()`, `PSISOIMG0000`, a per-title compatibility table keyed by PS1 serial
(`SCES_000.08`, `SCES_016.95`, …), and a full statically-linked libgcm with its debug
assertions intact.

## 🖥️ Graphics — and why this one is different

The sister ports that render (**Simpsons Arcade**, **flOw**, **You Don't Know Jack**) all
reach caner's (canersaka) live NV4097 → D3D12 draw engine the same way: they *import*
`cellGcmSys`, ps3recomp's HLE implementation of it walks the pushbuffer, and
`rsx_live_draw_method()` gets fed. `RSX_LIVE_DRAW=1` and it draws.

**`ps1_netemu` imports no `cellGcmSys`.** Being a firmware module it links libgcm
*statically* and talks to the GPU through the kernel:

```
syscall 668 sys_rsx_device_open      672 sys_rsx_context_allocate   676 sys_rsx_context_attribute
        669 sys_rsx_device_close     673 sys_rsx_context_free       677 sys_rsx_device_map
        670 sys_rsx_memory_allocate  674 sys_rsx_context_iomap  (x24)
        671 sys_rsx_memory_free      675 sys_rsx_context_iounmap
```

*(all ten confirmed present by scanning `li r11,N` / `sc` pairs in `.text`.)*

So we use **the same renderer, hooked one layer lower**: implement `sys_rsx_*` in the
ps3recomp runtime and drive the existing FIFO walker from the `sys_rsx_context_attribute`
kick instead of from `cellGcmFlush`. The engine, the method decoder, the D3D12 backend and
`RSX_LIVE_DRAW=1` are all unchanged — only the tap point moves.

## 🛠️ Pipeline

```
  dev_flash ─► ps1_netemu.self ─► .elf ─► ppu_lifter ─► C++ ─┐
              (firmware SELF)   (decrypt)  (3,512 fns)       ├─► link ps3recomp ─► tmpsn.exe
                                2 SPU ELFs ─► spu_lifter ─►──┘        (harness + HLE)
                                                                              │
  PSN PKG ─► EBOOT.PBP + ISO.BIN.EDAT ─────────────────────────────► game data (fed, not lifted)
```

The PS1 disc is **never** decrypted by us: the recompiled emulator does its own
EDAT/PSAR handling, exactly as it does on hardware.

## 🎯 Status

**It boots.** The recompiled PS1 emulator runs its own startup, prints its build banner,
configures video and audio, loads the PS1 BIOS, reads its region, and gets as far as
handing an SPU image to a raw SPU. Two gaps stop it there.

```
PS1 emulator Build Date 20/01/30/13:20 -sgpu-sli4 [titledb:r11624]
user_memory_size= 201326592/268435456 <67108864>
[cellVideoOut] GetResolution(id=2) -> 1280x720
[sys_fs] open OK: .../dev_flash/ps1emu/ps1_rom.bin
REGION NUM = 0x00000081 code=A
[HLE] _sys_spu_image_import -> entry=0x00100 nsegs=3 machine=23 (SPU=23)
[rsx] live-draw engine up (D3D12); GDI present suppressed
```

| Milestone | Status |
|---|---|
| Extract the PSN PKG | ✅ Done — needed new mixed-key support, see below |
| Identify the real recomp target | ✅ Done — `ps1_netemu.self`, not a game EBOOT |
| Decrypt the firmware SELF → ELF | ✅ Done — `rpcs3 --decrypt`, key rev `0x1C` |
| Function discovery | ✅ Done — 3,512 |
| NID / import resolution | ✅ Done — 103 imports, 12 libs, 83% named |
| Extract the SPU modules | ✅ Done — 2 embedded ELFs, statically |
| PPU lift → C++ | ✅ Done — 3,530 functions, 23 MB, **0 unhandled instructions** |
| SPU lift → C | ✅ Done — 1,429 + 637 functions, both clean |
| Build on the shared ps3recomp harness | ✅ Done — `tmpsn.exe`, 10.2 MB, first try |
| First boot (recompiled CRT runs) | ✅ Done — the emulator's own banner prints |
| Video/audio out negotiated | ✅ Done — 1280x720 @ 59.94 |
| BIOS (`ps1_rom.bin`) loads | ✅ Done |
| Live NV4097 → D3D12 engine comes up | ✅ Done — presenting, nothing to draw yet |
| `sys_rsx_*` syscalls | ⬜ **blocker** — `cellGcmInit failed` → `GPUCoreInit(): failed` |
| Raw SPU (`sys_raw_spu_*` + `0xE0000000` MMIO) | ⬜ **blocker** — spins on the SPU status register |
| Disc mounts (`EBOOT.PBP` → `PSISOIMG0000`) | ⬜ |
| Twisted Metal renders | ⬜ |
| Input / audio / memory cards | ⬜ |

### The two blockers

1. **`sys_rsx_*` is unimplemented**, so the statically-linked libgcm's `cellGcmInit`
   returns failure and `GPUCoreInit()` gives up. The live draw engine is up and
   presenting frames — it just has no FIFO to walk. See
   [`docs/graphics-path.md`](docs/graphics-path.md) for the syscall→HLE mapping.
2. **No raw-SPU path.** `_sys_spu_image_import` already accepts SPU image 0 (the one at
   `0x181100` we lifted), but `sys_raw_spu_create` is a stub and nothing runs the image,
   so the emulator spins forever reading the SPU status register at `0xE0044014`.
   The lifted entries are registered and waiting in `src/spu_images.c`.

See [`PROGRESS.md`](PROGRESS.md) for the blow-by-blow.

## 🔧 Toolchain changes upstreamed to ps3recomp

- **`tools/pkg_extract.py` — mixed-key packages.** A PSOne Classic is `pkg_type=2` and
  uses *both* keys at once: entry structs and some payloads on the PSP key
  (`07F2C682…`), the rest on the usual PS3 key, chosen per entry by **bit 28 of the
  entry flags**. The old single-key autodetect asserted out on the file table. A plain
  PS3 package never sets bit 28, so the same rule leaves it on the PS3 key throughout.
- **`tools/gen_imports.py` — new.** Emits the `imports.json` that `ppu_lifter --hle-stubs`
  wants for an `ET_EXEC` image: `prx_analyzer` finds nothing without a dynamic section, so
  this walks the `sys_proc_prx_param` lib.stub tables (`elf_parser` already does) and
  names each NID from `nid_database`. Every port so far had been doing this by hand.
- **`runtime/syscalls/sys_fs.c` — `/dev_flash` served from a real firmware tree.**
  `ppu_fs.cpp` already had this branch (`$PS3_DEV_FLASH`); the raw-syscall half of the
  split filesystem did not, so a firmware path opened through `sys_fs` resolved under the
  game root and missed. `ps1_netemu` will not boot without
  `/dev_flash/ps1emu/ps1_rom.bin`.

## 📦 Building

Prereqs: Python 3.9+, CMake 3.20+, **clang-cl** + Ninja, and a sibling
[ps3recomp](https://github.com/sp00nznet/ps3recomp) checkout.

```bash
# 1. Supply your own firmware module and your own copy of the game:
#      fw/ps1_netemu.self     <- from your console's dev_flash/ps1emu/
#      fw/ps1_rom.bin         <- likewise
#      pkg/*.pkg              <- your own PSN download
#    then decrypt and unpack:
rpcs3 --decrypt fw/ps1_netemu.self
python ../ps3recomp/tools/pkg_extract.py pkg/*.pkg extracted

# 2. Lift PPU + SPU and generate the HLE NID table:
PS3RECOMP=../ps3recomp ./tools/relift.sh

# 3. Build (Release matters -- an unoptimised build of the generated TU runs ~3x slower).
#    llvm-rc: clang-cl outside a VS dev prompt cannot find Microsoft's rc.exe.
cmake -S . -B build -G Ninja       -DCMAKE_C_COMPILER="C:/Program Files/LLVM/bin/clang-cl.exe"       -DCMAKE_CXX_COMPILER="C:/Program Files/LLVM/bin/clang-cl.exe"       -DCMAKE_RC_COMPILER="C:/Program Files/LLVM/bin/llvm-rc.exe"
cmake --build build

# 4. Run with the live NV4097 -> D3D12 draw engine. tools/run.sh sets PS3_DEV_FLASH
#    (where /dev_flash/ps1emu/ps1_rom.bin comes from), PS3_HDD0_ROOT (where the
#    unpacked package lives) and RSX_LIVE_DRAW=1:
./tools/run.sh
```

## ⚖️ Legal

This repository contains **no copyrighted code, assets, binaries, firmware, or encryption
keys** — only analysis notes, configuration, and recompilation tooling. You must supply
your own legally obtained console firmware and your own copy of the game. `fw/`, `pkg/`,
`extracted/` and `vfs/` are git-ignored.

## 🔗 Related Projects

- [ps3recomp](https://github.com/sp00nznet/ps3recomp) — the PS3 HLE runtime this links against
- [simpsonsarcade-ps3](https://github.com/sp00nznet/simpsonsarcade-ps3) · [flOw](https://github.com/sp00nznet/flow) · [youdontknowjack](https://github.com/sp00nznet/youdontknowjack) — the sister ports that render
- [twistedmetal](https://github.com/sp00nznet/twistedmetal) — the *other* Twisted Metal, the 2012 PS3 disc game
- [RPCS3](https://github.com/RPCS3/rpcs3) — emulator whose HLE research (and `--decrypt`) makes this possible
