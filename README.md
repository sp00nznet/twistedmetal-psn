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
*statically* and talks to the GPU through the kernel — twelve `sys_rsx_*` syscalls,
all identified by disassembling each `li r11,N` / `sc` pair with the libgcm wrapper
around it. (The numbering is two *lower* than the usual published table: `675` is
`device_map`, not `context_iounmap`.)

So we use **the same renderer, hooked one layer lower** — implemented in
`ps3recomp/libs/video/sys_rsx.c`. The engine, the method decoder, the D3D12 backend and
`RSX_LIVE_DRAW=1` are all unchanged; only the tap point moves. Two facts out of the
disassembly are what make it a bridge rather than a rewrite:

- `*(u32*)lpar_driver_info` must be `0x211` — `cellGcmInit`'s version handshake.
- the `put`/`get`/`ref` triple sits at `lpar_dma_control + 0x40`, so
  `context_allocate` returns *(the walker's control address − 0x40)* and the driver's
  own flushes land exactly where the existing FIFO walker already reads.

**And the thing that was actually failing wasn't graphics at all.** With every RSX
syscall implemented, `cellGcmInit` still failed — without reaching one of them. It
gives up when `sys_process_get_sdk_version` returns zero, and that syscall was an
unimplemented stub leaving its out-param untouched. libgcm sizes its RSX local heap
off that value on a compatibility ladder (≥2.20 → 249 MB, ≥2.00 → 242, ≥1.90 → 234,
≥1.80 → 232, else 224), which is how the syscall got identified in the first place.
Implementing it is what unblocked the GPU. Full derivation:
[`docs/graphics-path.md`](docs/graphics-path.md).

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

**It boots, the GPU is up, all five SPUs run, and it has found the game.** The
recompiled PS1 emulator runs its own startup, negotiates video and audio, loads the PS1
BIOS, brings RSX up through the kernel, drains its own command FIFO into the live
NV4097 → D3D12 engine, starts its five raw SPUs (four GPU cores — the banner says
`-sgpu-sli4` — plus the second module), completes its whole subsystem bring-up, and —
once given the nine command-line arguments the VSH passes a PSOne Classic — reads the
package: title, region, disc target, and the 30-page manual out of `DOCUMENT.DAT`. It
opens and DECRYPTS the disc image. It stops one step later, mounting it.

```
PS1 emulator Build Date 20/01/30/13:20 -sgpu-sli4 [titledb:r11624]
user_memory_size= 201326592/268435456 <67108864>
[cellVideoOut] GetResolution(id=2) -> 1280x720
[sys_fs] open OK: .../dev_flash/ps1emu/ps1_rom.bin
REGION NUM = 0x00000081 code=A
[sys_rsx] memory_allocate(size=0xF900000) -> local=0xC0000000
[sys_rsx] context_allocate -> dma_control=0x20001FC0 (ctrl=0x20002000)
[sys_rsx] iomap io=0x00000000 <- ea=0x40100000 size=0x400000
[cellGcmSys] SetDisplayBuffer(id=0, offset=0x310000, pitch=5120, 1280x720)
[live-draw] display buffer 0 = loc0:0x00310000 pitch=5120 1280x720
InitMenu Start c1d00000 / InitMenuManual / InitMenu End c36e2000
[spu-raw] image_load spu0: 3 segments, 84992 bytes into LS, NPC=0x00100
[spu-raw] spu0 START pc=0x00100 ls=guest:0xE0000000 nonzero lines=1324/4096
[spu-raw] spu0 out mbox = 0x00015010   <- the SPU's ready handshake
[spu-raw] W spu0 +0x4400C = 0x40600000 <- and the PPU's first command to it
App:Fonts Initialize Lv1 pass!
[cellAudio] PortOpen(nChannel=2, nBlock=8) / Mixing thread started
g_strTitle NPUI94304
[sys_fs] open OK: .../dev_hdd0/game/NPUI94304/USRDIR/CONTENT/DOCUMENT.DAT
TITLE ID : SCUS94304   /   InitMenuManual OK!! PageNum = 30
target: /dev_hdd0/game/NPUI94304<0>
REGION NUM = 0x00000082 code=A        <- 0x82 straight out of argv[3]="0082"
[fps] 60.0
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
| Live NV4097 → D3D12 engine comes up | ✅ Done — 60 fps, presenting |
| `sys_rsx_*` syscalls | ✅ Done — `cellGcmInit` succeeds, FIFO drains, buffers registered |
| `GPUCoreInit()` / `InitMenu` | ✅ Done |
| Raw SPU (`sys_raw_spu_*` + `0xE0000000` MMIO) | ✅ Done — all 5 SPUs load, run and handshake |
| Emulator subsystems (font/audio/pad/VMC/CD-ROM/NP) | ✅ Done — all initialise |
| Input (the pad read) | ✅ Done — confirmed against RPCS3's `sys_io_3733EA3C` |
| Launch arguments (the nine the VSH passes) | ✅ Done — title, region, disc target, manual all read |
| CD-ROM subsystem starts | ✅ Done — was one wrong function signature (`cellAdecOpen`) |
| Disc image opened (`ISO.BIN.EDAT`) | ✅ Done |
| Disc **decrypted** (NPDRM / EDAT) | ✅ Done — `PSISOIMG0000`, serial `_SCUS_94304` |
| Disc header read, streamed and hashed | ✅ Done — guest SHA-1 matches Python byte for byte |
| Disc body opens (`EBOOT.PBP`) | ✅ Done — header signature verifies, `EBOOT.PBP` opened |
| PS1 title boots | ✅ Done — `North American Title detected!`, `boot from /dev_hdd0/game/NPUI94304` |
| SPU cores run (no stalls) | ✅ Done — lost-reservation event + `sys_usbd_receive_event` |
| Raw-SPU interrupts delivered | ✅ Done — establish/eoi/stop-and-signal, level-triggered |
| PS1 core runs (R3000) | ⬜ **blocker** — `EBOOT.PBP` opens but is never read, so the R3000 has no code |
| Twisted Metal renders | ⬜ |

### The blocker

The disc decrypts, streams and hashes **correctly** — and then one signature check stops it:

```
[edat] ...ISO.BIN.EDAT: version=3 license=3 flags=0x00000000 block=0x4000 size=1048616
[edat] klicensee NP_PSX_KEY verified against dev_hash
[edat] decrypted 1048616 bytes -> ...ISO.BIN.EDAT.dec
[sys_fs] open OK: ...ISO.BIN.EDAT.dec
ExitPS1(): code=3 <0>
```

**How far it actually gets.** The `PSISOIMG0000` compare passes. The streaming reader
consumes the entire megabyte — the stream position climbs in `0x1000` steps to exactly
`0x100000`, then to `0x100028` after a 40-byte trailer — hashing as it goes. Watching the
digest the guest writes:

```
guest  SHA1(header) = 6c55da7ff8eb8c09df8d5269dca4444b561097aa
python SHA1(dec[0:0x100000]) = 6c55da7ff8eb8c09df8d5269dca4444b561097aa
```

Byte for byte. One comparison validates the whole chain: the EDAT decryption, the block-key
derivation, the ring buffer's ordering, and the lifted SHA-1 over a megabyte.

**The two-file design.** `ps1_netemu` builds *both* `/USRDIR/ISO.BIN.EDAT` and
`/USRDIR/CONTENT/EBOOT.PBP`. Comparing them shows why: the PSAR's header is `\0PGD`
ciphertext from `0x400` on, while the EDAT has the same region in the clear — serial
`_SCUS_94304`, a valid 9-track CD TOC, and the block index. `ISO.BIN.EDAT` is Sony's
**decrypted, signed** copy of the PSAR's `0x100000`-byte header; the PS3 never runs PGD and
streams the compressed body out of `EBOOT.PBP`. The strings name the subsystem: `pspi/pspi.c`.

**Where it stops.** At `0xF132C`, right after `SHA1_Final`:

```
r5 = *(TOC-0x7A1C) = 0x175510      ; a 40-byte public key
bl  0x10D24 (sig, hash, key, 2)    ; ECDSA verify, curve 2
beq cr7, 0xF14F4                   ; VERIFY OK -> close EDAT, open EBOOT.PBP
```

The branch is not taken, so `0xF1590` — the one instruction in the image that points the
open-path field at the `EBOOT.PBP` buffer — is never reached, and the reader returns `-1`
into `ExitPS1(3)`. **The disc body is never opened because the header signature does not
verify.** Detail: [`docs/disc-body.md`](docs/disc-body.md).

Ruled out: it is not a stubbed dependency (the verify calls only real code in the image, no
import trampolines), not the hash input, and not our carry arithmetic on review (`adde`,
`subfe`, `addc`, `subfc`, `addze` all lift correctly).

**The signature is valid — so the bug is ours.** The curve is built at runtime, not stored in
the ELF, so it was read out of the guest's own memory (`func_000109C4` copies six 20-byte
fields into a 144-byte context; replaying those writes in order, before the struct is reused
as scratch, gives them exactly). It is a 160-bit curve with `a = p-3`, the table in the
classic `p, a, b, N, Gx, Gy` order; both the generator and the public key lie on it and
`n*G` is the point at infinity. Verified offline against that curve, the header's signature
**passes** — `X.x mod n == r` exactly. So `ISO.BIN.EDAT` is authentic and Sony-signed, and
`func_00010D24` returns the wrong answer on correct data. That is a ps3recomp lifter bug, and
it is worth fixing properly: any title that checks a signature will hit it.

That also settles what the crack does, and it is the ordinary thing. An EDAT is only a
container, so re-wrapping the same plaintext under a free klicensee (license type 3 instead of
the retail type 2, which is bound to a per-console RAP) leaves Sony's signature intact. It has
to — cracked PSOne Classics ran on real consoles, and `ps1_netemu` runs this check
unconditionally.

Checked against a second title: `2Xtreme [NPUI-94508]` has the identical package layout,
with an `ISO.BIN.EDAT` of **exactly** the same 1,049,920 bytes — that size is what this form
always is, not a truncation.

Also open: a bare `/USRDIR/` config path resolves to the VFS root and fails `EISDIR`
(non-fatal — the emulator prints `failed` and continues); `cellAdecQueryAttr`
(`0x7E4A4A49`) still returns `CELL_OK` with its attr struct untouched;
`sys_interrupt_thread_establish` (84) and `eoi` (88) are stubs; and the
`0x300`/`0x301`/`0x302` attribute packets (tiles, Z-cull) are accepted but ignored.

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
- **`libs/video/sys_rsx.c` — new, the lv2 RSX syscalls.** Routes 666..677 into the state
  `cellGcmSys.c` already keeps, so a guest that talks to RSX through the kernel reaches
  the same live draw engine as one that imports `cellGcmSys`. See above.
- **`sys_process_get_sdk_version` (25).** Was a stub returning `CELL_OK` with the
  out-param untouched. Now reports SDK 3.6.0; `PS3_SDK_VERSION` overrides.
- **`runtime/ppu/ppu_loader.cpp` — `PS3_SCTRACE` now covers the stub path**, which it
  had skipped: it traced everything *except* the unimplemented syscalls, i.e. exactly
  the ones a trace is wanted for. Finding the RSX call contract needed this.
- **`libs/filesystem/edat.c` — new, NPDRM (EDAT/SDAT) decryption.** A file beginning
  `NPD\0` is decrypted once into a cache file and that is opened in its place, so every
  read/seek/stat path stays unchanged. Self-contained AES-128 + AES-CMAC (no new
  dependency), with the FIPS-197 and RFC 4493 vectors checked before first use and every
  block's CMAC verified. See [`docs/npdrm.md`](docs/npdrm.md).
- **`libs/codec/cellAdec.c` — `cellAdecOpen` had the wrong arity.** Five parameters where
  the real one takes four (the guest's `CellAdecCb` struct split in two), so `handle` was
  read from `r7` instead of `r6` and every open failed `ARG`. Confirmed against RPCS3.
- **`runtime/syscalls/sys_semaphore.c` — `SEM_BADID=1`.** On a wait/post against an id that
  was never created, report the caller and its pointer-shaped registers once per (id, lr).
  The id says nothing; where the guest *read* it from is the whole diagnosis.
- **`runtime/ppu/ppu_loader.cpp` — `PS3_ARGV`, multiple guest arguments.** It wrote
  exactly one, which is all a disc title needs and nowhere near enough for a firmware
  module launched by the VSH. Layout matches lv2 (64-bit BE pointer slots, NULL-terminated,
  NULL envp, strings 16-byte aligned), verified against RPCS3's `ppu_load_exe`, and is
  byte-identical to the old output for a single argument.
  See [`docs/boot-argv.md`](docs/boot-argv.md).
- **`sysPrxForUser` — `_sys_malloc` / `_sys_free` / `_sys_memalign` / `_sys_realloc`.**
  Missing entirely, so callers got the unresolved-NID stub: `CELL_OK` with a garbage
  pointer in `r3` that they then wrote through. `cellUsbdInit` failed on it.
- **`PS3_SCTRACE` printed the return value in the first argument's column** for every
  implemented syscall (it passed `ctx->gpr[3]` after dispatch had overwritten it). The
  first argument is the object id across most of lv2 — the whole reason to read the trace.
- **`runtime/spu/spu_raw.c` — new, raw SPUs.** The `0xE0000000` MMIO window plus
  `sys_raw_spu_*`, and `sys_raw_spu_image_load` — which is not a syscall, so its stub NID
  left local store full of zeros and the SPU "ran" straight into them. `spu_context.ls`
  became a pointer so a raw SPU's local store can BE the guest window rather than a copy
  the PPU races. See [`docs/raw-spu.md`](docs/raw-spu.md).
- **`tools/spu_lifter.py` — refuse an ELF passed as a raw image.** Given positionally with
  `--functions` and no `--base`, it lifts the ELF *header* as code and puts every function
  at its file offset instead of its local-store address. It compiles, links and runs the
  wrong instructions. Now an error naming `--auto-functions`.
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
