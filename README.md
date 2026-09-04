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
| BIOS loaded, R3000 at reset vector | ✅ Done — `mfc0 $k0,$15` at `0xBFC00000` |
| R3000 starts executing | ✅ Done — the opcode dispatch table was never lifted; see below |
| Emulator front-end renders | ✅ Done — `DRAW_ARRAYS` at 720x512, shaders compiled, ~205 fps |
| R3000 executes the BIOS | ✅ Done — reset vector → `0xBFC4B844` by 10,000 instructions |
| **PS1 leaves the BIOS, runs game code** | ✅ **Done** — live pc moves to main RAM `0x30000..0x3E000` and keeps advancing |
| PS1 I/O handler map complete | ✅ Done — all 12 windows registered, including every DMA channel |
| RSX interrupt thread + flip handshake | ✅ Done — `handler_queue` published, user-command handler reached |
| R3000 runs continuously | 🟨 Partly — **1.1 billion instructions (~14 MIPS)** in a good run; some runs wedge early |
| Audio decoder reached and stable | ✅ Done — four `cellAdec` ABI faults fixed; `EndSeq` 4760 → 2 |
| RSX pipeline fed | ✅ Done — 22,029 packets, 22,029 groups executed, **zero** drops |
| PS1 GPU handoff (PPU → 4 SPUs) | 🟨 Partly — **21,206 packets consumed**, but the SPUs emit no pixels |
| **PS1 renders (BIOS boot screen in VRAM)** | ✅ **Done** — dumped and read: PlayStation logo + SCEA licence text |
| **PS1 game runs and loads its art** | ✅ **Done** — VRAM holds Twisted Metal car sprites and title letters |
| **Renderer produces a picture** | ✅ **Done** — 89% of the presented 1280x720 surface is drawn |
| Whole PS3-side render path verified | ✅ Done — draws, shader, constants, upload, readback all correct |
| PS1 display framebuffer placed correctly | ✅ Done — 320x240 block, native resolution, right position |
| PS1 CD events opened correctly | ✅ Done — `CdInit` runs; handles `F1000007..F100000B` all valid |
| PS1 CD interrupt raised + unmasked | ✅ Done — `I_STAT_or=0x0D`, `I_MASK_or=0x0D` (bits 0,2,3) |
| Intro video → menu → attract mode | ⬜ **BLOCKED** — **run variance**: identical runs diverge into 4 distinct behaviours; fix that first |
| Twisted Metal renders | ⬜ |

### The blocker

The PS1 core **runs**: disc decrypted, header signature verified, body opened, BIOS booting,
R3000 executing at about **1 MIPS**. Until this session it then stopped dead at ~42,000
instructions --- and the cause turned out to be three levels away from the interpreter.

1. **The main guest thread parked on a flip.**
   `[WAIT tid=1] semaphore_wait(sem=1 timeout=0 cia=0x00000000 lr=0x00113EB4)` --- thread 1 is
   the thread running the R3000. The call site `bl 0x3030C` at `0x113EB0` sits in a
   double-buffer flip. Semaphore 1 was waited on **once** and posted **zero** times.
2. **Nothing posted it, because gcm's interrupt thread exited immediately.**
   `_gcm_intr_thread` reads its event queue id from `*(context + 0x12D0)` and blocks on it.
3. **`+0x12D0` is `RsxDriverInfo::handler_queue`** --- confirmed against RPCS3's struct, where
   `sys_rsx_context_allocate` creates an event queue and stores its id there. **Ours never
   did**, so the thread received on queue 0, returned at once and died.

**Fixed** in `libs/video/sys_rsx.c`: create the queue, publish its id at `+0x12D0`, and drive
it with a 60 Hz vblank event filtered through the handler mask at `+0x12C0` (the same
filtering `rsx::thread::send_event` applies). The producer must be a ticker of its own, not
the flip packet, because the deadlock is circular --- the main thread cannot issue the flip
packet that would be the event source while it is parked waiting for that flip.

| | before | after |
|---|---|---|
| `_gcm_intr_thread` | exits immediately | stays alive on the queue |
| `semaphore_post(sem=1)` | 0 | **24** |
| main guest thread | parked forever | wakes, proceeds to storage syscalls |

**But this did not, on its own, get the PS1 running.** Measured after the fix over a 150 s
run: the ISR thread stays alive, `sem 1` is posted, the main thread wakes and runs on --- and
the R3000 still does not pass **50,000** dispatches, essentially where it stopped before. So
the flip semaphore was a real deadlock and is genuinely cleared, but a second stall sits
behind it that has not been found yet.

**A correction: bit `0x04` is the GRAPHICS ERROR handler, not flip.** I drove it for a while
on the assumption it was the flip callback. The guest said otherwise once its own stdout was
reconstructed (it prints one character at a time):

```
[RSX dump analysis] unsupported error
graphics error 0 : 00000000 ...
```

plus a full RSX state dump, 60 times a second. The mask `0x84` means this firmware registers a
graphics-error handler and a user-command handler and **no vblank or flip handler at all** ---
so the flip semaphore is not posted by a gcm handler, and that link of my chain was wrong. The
ticker is removed; there is nothing a timer can legitimately send.

**What survives and is correct:** publishing the queue id at `+0x12D0`. Without it the ISR
thread received on queue 0 and exited outright; with it the thread stays alive and blocked on
real events. Verified with the ticker gone: thread alive, `sem 1` posted 24x, and **zero**
graphics-error dumps.

**Quantified, with both probes on one QPC origin:** the first fence-spin `usleep` at
`t=223,341,983,195us`, `[refpub] #1` at `+0.41 s`, `[refpub] #2` at `+2.0 s`. Consecutive
spin polls are 43 us apart and `GCM_RATE=1` shows a steady **270 FIFO walks/sec**, so neither
the poll loop nor the walk is starved --- the ~2 s is the guest's own work between fences, and
the fence wait is a symptom.

**Then the tool that was missing all along --- which first lied, then answered.**
`PS3_SAMPLE=<ms>` samples thread RIPs. Its first result, "99.1% of guest CPU in one PPU
function", was an artefact: the function table holds **PPU functions only**, so SPU-lifted code
sat in the gaps and an `[entry, next_entry)` extent blamed the preceding PPU function. (That
the answer shifted from 5 threads to 4 when I tightened an unrelated bound should have been the
tell.) Switching to exact `.pdata` lookup was no better --- a startup self-check reports
`NO .pdata entry` for the lifted bodies, so that mode is blind to guest code and its `0` is a
silent failure.

The fix was merging `spu_channels.c`'s SPU registry into the map, so the gaps become real
entries:

```
[samp] map: 3530 PPU + 2066 SPU entries
[samp] 4964 samples, 428 in guest code (8.6%)
[samp]    47.7%  spu_LS_00001268  (204)
[samp]    26.2%  spu_LS_00000100  (112)
[samp]     6.1%  spu_LS_0000893C  (26)
[samp]     0.7%  func_00013040    (3)      <- the ONLY PPU code in the profile
[samp] host  89.1%  ntdll.dll     (4423)
```

**Essentially all guest execution is SPU code; the PPU is idle** --- three samples out of 4,964.
Consistent with every independent measurement (R3000 <50k instructions, packets at 6, main
thread in a fence wait), and the exact opposite of what the broken tool said.

`0x100` is image 1's entry point. The dominant hot spot, LS `0x1268`, is a spin on **local-store
state**:

```
0126C  lqr   $r8, 0x15010        ; load a quadword from LS 0x15010
01274  ceq   $r19, $r84, $r8     ; compare against r84
01294  cgti  $r35, $r85, 0
0129C  brz   $r35, 0x1268        ; loop while r85 <= 0
```

### Root cause: the R3000 blocks on a semaphore nothing ever posts

**It is a stop, not a crawl.** Timestamping dispatch and the scheduler from one clock:

```
[dbg] disp 10000 t=227640948860us
[dbg] disp 40000 t=227640971137us      <- 40,000 instructions in ~22 ms
[dbg] sched #2000 t=227640971108us     <- 2,000 rounds in ~30 ms
```

The R3000 runs at a healthy **~1.8 MIPS for ~30 ms**, executes its ~42,000 BIOS instructions,
and stops dead. (An earlier draft here said "~400 instr/sec" --- that came from dividing the
instruction count by the whole run length, which assumes it ran throughout. It did not.)

**The blocking call names itself.** `sc_trace` logs *after* a syscall returns, so a call that
never returns leaves no trace --- which is why this stayed invisible. Logging syscall **entry**
gives the main thread's last action:

```
[sc-enter] #9863 num=43 tid=1 lr=0x00106360      ; yield, returns
[sc-enter] #9864 num=92 tid=1 a3=0x1 lr=0x00113EB4
```

Syscall **92 is `sys_semaphore_wait`**, on **semaphore 1**, from `0x113EB0` --- the
double-buffer flip wait. No matching exit line: it never returns.

**And semaphore 1 is never posted** --- counted correctly across three runs, `sem=1 posts: 0`.
The posts that happen go to semaphores 4, 5, 6, 7, 9, 10.

An earlier claim here that this wait "completes" rested on `grep -c "semaphore_post(sem=1"`,
which also matches **`sem=10`** (~104 per run). That missing character class turned "never
posted" into "posted 24 times" and sent the investigation downstream for hours.

**The chain, every link measured:** the R3000 runs ~42,000 BIOS instructions in ~30 ms ->
reaches the flip wait and calls `sys_semaphore_wait(sem=1)` -> nothing posts it, so the call
never returns -> the main thread parks in `ntdll` -> GP0 is never written -> the GP0 handler
never fires -> the GPU SPUs starve and spin -> packets stay at 6.

**That question is now answered, and the fix is in** --- see below. The predicted shape was
right: it *is* a callback the runtime never invoked.

Everything inside the interpreter was cleared on the way there: it is entered once and loops
internally; the event scheduler runs ~2,100 rounds with its cycle total climbing normally; and
all 11 helper calls were traced with enter/exit breadcrumbs --- **1553 enters, 1553 exits**,
nothing blocking. The main thread can reach a syscall at all because the interpreter carries
**51 `DRAIN_TRAMPOLINE` sites**, which run deferred guest work on the calling thread.

Detail, including the store-watch evidence that corrected an earlier note in this repo
(`0x2D80B4` *is* written --- by `cellGcmInit`, before the thread is created), is in
[`docs/ps1-core.md`](docs/ps1-core.md).

### SOLVED: the missing link was `GCM_SET_USER_COMMAND` (FIFO method `0xEB00`)

Semaphore 1 is posted by ps1_netemu's **RSX user-command handler**, and the FIFO walker was
throwing that method away. Followed backwards from the blocked call:

* semaphore 1 lives at `obj+0x1CC`, `obj = *(TOC-0x7834)`, created `init=0 max=1`
* the only code that posts it is `func_00113AC8` --- a five-instruction leaf with **zero direct
  callers**, so it is reachable only as a callback
* its OPD (`0x1B62E0`) is loaded exactly once, at `0x117348`, and handed to `func_00019D88`:

```
00019DB4  ori  r0, r0, 0x80        ; driverInfo->handlers |= 0x80
00019DB8  stw  r0, 0x12c0(r3)
00019DC0  stw  r31, 0x2c(r9)       ; *(TOC-0x6AB4)->slot[0x2C] = handler
```

* bit `0x80` is **`SYS_RSX_EVENT_USER_CMD`**

And the guest writes the user command inline in the flip path at `0x114530`, immediately before
it blocks:

```
00114530  lis  r9, 4
00114538  ori  r9, r9, 0xeb00      ; header 0x0004EB00
0011453C  li   r0, 1               ; argument 1
00114550  bl   0x3030c             ; publish put
...
00114AB8  bl   0x113e64            ; -> sys_semaphore_wait(sem=1)
```

**Why it was invisible.** `GCM_SET_USER_COMMAND` is method `0xEB00`, which is wider than the
13-bit field the header decode keeps (`method = w & 0x1FFC`, `subch = (w >> 13) & 7`). So it
arrives as **subchannel 7, method `0x0B00`** --- straight into the 2D engine path, which
discards what it does not recognise. Nothing about it looked like a missing method; it looked
like a 2D method nobody had implemented yet.

The fix does what `sys_rsx_context_attribute`'s `0xFEF` case does: stash the argument at
`driverInfo+0x12CC` (`userCmdParam`), then send `USER_CMD`. The handler-mask filter already in
`rsx_send_event` does the rest --- the guest's mask settles to `0x84`, so the bit is wanted.

The note already sitting in `sys_rsx.c` turned out to be exactly right: *"rsx_send_event stays
for whoever wires those up (a genuine flip or user command)"*. This is the user command.

**Measured, same 90-second run before and after:**

| | before | after |
|---|---|---|
| semaphore 1 posts | 0 | **835** |
| RSX FIFO packets seen | 6 | **5,628** |
| R3000 | stopped after ~42,000 instructions | **running** |
| furthest call reached | `sys_semaphore_wait` | **`cellAdecDecodeAu`** (decoding audio) |

**A measurement correction worth keeping.** "sem=1 posts: 0" was partly an artifact:
`sys_semaphore_post`'s log is capped at 40 lines unless `SEMTID` is set, and the posts counted
summed to *exactly 40* --- the cap, not the truth. The conclusion held only because the wait
never returning was independent evidence. That is the second logging artifact in this same
investigation, after the `grep -c "semaphore_post(sem=1"` that also matched `sem=10`. Counts
from this log are trustworthy only with `SEMTID=1`.

### `cellAdec` had four ABI faults — all fixed

Detailed in [`docs/ps1-core.md`](docs/ps1-core.md): the callback was invoked as a host function
pointer, the `PcmItem` was handed out as a host pointer (and must not be allocated from the
guest's heap), the message types were swapped, and every error code was invented. The last one
was load-bearing — the guest drains its decoder until `cellAdecGetPcm` returns `0x80610005`,
the only cellAdec code the image ever compares against, and we were returning `0x80610204`.
`cellAdecEndSeq` went from 4,760 calls to 2.

The PS1 core now executes **~1 billion instructions per 100 seconds (~17 MIPS) continuously**,
and the RSX pipeline runs clean: 22,029 packets, 22,029 groups executed, zero drops.

### The PS1 core renders --- proof, not inference

`PrintWindow` on a D3D12 swapchain returns black whether the page is black or the capture failed,
so every screenshot in this port was unfalsifiable. `PS1_FBDUMP=<path>` writes PS1 VRAM straight
out of guest memory as a PPM instead --- no D3D, no window. What came out:

**the PlayStation logo, "SCEA", "Licensed by Sony Computer Entertainment of America", and a block
of legal text --- the PS1 BIOS boot screen.**

It also locates the picture: every non-black pixel is in columns 640..1023, and columns 0..639
are entirely black. A display-origin problem, not a rendering one.

### The verified pipeline

| stage | evidence |
|---|---|
| R3000 executes | `+0x124` reaches **1.1 billion** instructions, ~14 MIPS |
| GP0 → ring | ring offset reaches `0x6EF300` = **28,403 packets** |
| ring → 4 GPU SPUs | `pub == done` on all four, **21,206 packets consumed** |
| SPUs → PS1 VRAM | non-zero words 0 → 1,776 → 7,127 → **75,527** of 262,144 |
| VRAM → RSX texture | 640 hash checks, 0 unreadable, full 1 MB span, correct pitch |
| RSX draws | 12,887 packets, 12,887 groups executed, **zero** drops |
| surface content | 9,573 drops per run → **0** |

An earlier claim here that the GPU SPUs "are never told about new packets" was wrong three
separate ways, all of them *absence of evidence read as evidence of absence*. The post-mortem is
in [`docs/ps1-core.md`](docs/ps1-core.md) and is worth reading before trusting any "X never
happens" claim in this repo.

### What is left, in order

**1. The display area.** Everything the PS1 draws sits at VRAM x≥640; columns 0..639 are black.
The PS3 side binds all of VRAM as one 1024x512 texture, so the visible region is chosen entirely
by the composite quad's texture coordinates — logging them for the draw that binds
`1:0x00400000` answers it directly.

*(An earlier claim here that nondeterminism was the dominant problem was largely an observer
effect: two clean runs both reach exactly 75,527 non-zero VRAM words, and every low reading came
from a run carrying a 1.5 MB-per-heartbeat framebuffer dump. Measuring it was changing it.)*

**2. The display origin.** The BIOS drew at VRAM x>=640; columns 0..639 are black. What texture
coordinates does the composite quad use, and what does ps1_netemu think the PS1 display start is?

**3. The BIOS stops after the logo.** Next a real PS1 BIOS reads `SYSTEM.CNF` off the disc, so
the CD-ROM path is the likely wait.

### The PS1 GPU handoff works --- verified

The four GPU SPUs poll their own local store at `0x15010` (the address each reports to the PPU
through its outbound mailbox at init), and `func_0010F658` writes the new ring offset there for
all four. A raw SPU's local store is aliased into guest memory, so those are plain stores.
Reading the same bytes the SPU reads:

```
ring[base=0x00D70E80 off=0x00004300] spuLS[00004300 00004300 00004300 00004300]
```

67 packets published, all four SPUs seeing the exact current offset. An earlier reading of this
as "the SPUs are never told" was wrong three separate ways --- all of them *absence of evidence
read as evidence of absence*. The post-mortem is in [`docs/ps1-core.md`](docs/ps1-core.md); it
is worth reading before trusting any "X never happens" claim in this repo.

### The blocker now: a whole-process freeze, and it looks like ours

Every run eventually wedges, at wildly varying points (18.6M, 37.5M and 1.03 billion
instructions across three identical runs):

* the R3000 spins `sys_ppu_thread_yield` at `0x1068F0` on a permanently-zero budget --- the same
  budget-0 condition at `+0x120` that once stopped this port at boot, moved rather than gone
* instructions retired (`+0x124`) freezes, and so does the GPU ring
* and in the last run the `[fps]` heartbeat printed **once in 90 seconds** where earlier runs
  printed 14 times --- so the D3D12 present thread stalled too

A guest-logic deadlock does not stop our own present thread. Everything stopping together points
at a host-side stall, most plausibly a lock held across a blocking wait between the SPU channel
wait and the FIFO drain / present path. That is a hypothesis, not a measurement; the next step is
host stacks for every thread at the freeze.
### What unblocked the core: the opcode dispatch table was never lifted

Worth writing down, because the symptom pointed nowhere near the cause.

The R3000 interpreter (`func_001066A8`) dispatches every guest MIPS instruction through a
128-entry jump table --- `lwzx r5, r19, r11; mtctr r5; bctr` at `0x1067D4`, table at
`0x1B37D4`. ps3recomp's `discover_jump_tables` missed it for two independent reasons: the
table base `lwz r19,-0x79CC(r2)` sits **36 instructions** before the `bctr`, outside a fixed
30-instruction window; and entry `[0]` is a **null slot** for an opcode the table never
dispatches, which made the decoder break on the first invalid entry for **0 targets**.

With the dispatcher dropped, the case targets stayed unlabelled and the `bctr` fell back to
the generic indirect-call dispatcher, which resolves function **entries** only. Every case is
a mid-function address, so the call did nothing:

```
[dbg] R3000 enter #1 pc=BFC00000 budget=00000000
[dbg] R3000 bctr  #1 ctr=001070E4 pc=BFC00004 insn=401A7800
```

`0x401A7800` is `mfc0 $k0,$15` --- the BIOS's first instruction, fetched byte-reversed from
the right offset. Fetch, i-cache cycle penalty and PC advance were all correct. Only the
dispatch went nowhere, so `func_001066A8` fell out and the main loop at `0xB3E68` saw a status
other than 5 and tore the emulator down.

Both fixes are in `ppu_lifter.py`; see
[Toolchain changes](#-toolchain-changes-upstreamed-to-ps3recomp). Together they took the image
from 67 dispatchers / 654 case targets to **68 / 718**.

**Two corrections worth recording.** The earlier note here blamed a cycle budget of 0 at
`+0x120`: that was a symptom read as a cause --- a budget of 0 is normal, and the scheduler
tops it up. And "the R3000 is orders of magnitude too slow" measured a *stall*, not a rate;
it runs at ~1 MIPS right up to the moment it parks.

### Also open

A bare `/USRDIR/` config path resolves to the VFS root and fails `EISDIR` (non-fatal --- the
emulator prints `failed` and continues); `cellAdecQueryAttr` (`0x7E4A4A49`) still returns
`CELL_OK` with its attr struct untouched; `user_memory_size= 0/0` prints from a site that
disassembles to `li r11,352; sc` though syscall 352 never appears in a trace; `_gcm_intr_thread`
receives on queue id 0; and the `0x300`/`0x301`/`0x302` attribute packets (tiles, Z-cull) are
accepted but ignored.

Historical detail on the disc chain --- the two-file design, the byte-exact SHA-1 proof, the
recovered curve and the ECDSA lifter bug that used to sit here --- is in
[`docs/disc-body.md`](docs/disc-body.md).

## 🔧 Toolchain changes upstreamed to ps3recomp

- **`libs/video/sys_rsx.c` --- the RSX interrupt queue was never published, and it deadlocked
  the guest.** `RsxDriverInfo::handler_queue` at `+0x12D0` is the event queue id libgcm's
  `_gcm_intr_thread` blocks on; on lv2 it is `sys_rsx_context_allocate` that creates the queue
  and stores the id there (confirmed field-for-field against RPCS3's struct). We zero-filled
  the driver-info page and never wrote it, so the thread received on queue **0**, returned
  immediately and exited --- taking gcm's flip handler with it. In ps1_netemu that parked the
  **main** guest thread on a flip semaphore, and since the main thread is the one running the
  R3000, the emulated PS1 stopped dead.

  Now the queue is created at driver-info init, its id published at `+0x12D0`, and a 60 Hz
  tick drives `SYS_RSX_EVENT_VBLANK` into it, filtered through the handler mask the guest
  publishes at `+0x12C0` --- the same filtering `rsx::thread::send_event` applies, and not
  optional: gcm's ISR dispatches on the flag bits, so an event bit it never asked for reaches
  a handler slot it never filled in. The tick has to be an independent producer rather than
  the flip packet, because the deadlock is circular: the parked main thread cannot issue the
  flip packet that would otherwise be the event source.

- **`runtime/spu/spu_channels.c` --- `rchcnt SPU_RdEventStat` lied, and it deadlocked an SPU.**
  `spu_rchcnt` had no case for that channel, so it fell through to `default: return 1`
  ("channel ready"). The SPU idiom is a *guarded* blocking read:

  ```
  08934  rchcnt $r12, SPU_RdEventStat   ; is an event pending?
  08938  brnz   $r12, 0xA5E8            ; yes -> commit to the blocking rdch
  0893C  il     $r30, 8960              ; no  -> carry on working
  ```

  Answering 1 unconditionally sent the SPU into a `rdch` that then parked forever, because
  `rdch` correctly blocks while `(event_status & event_mask) == 0`. `rchcnt` and `rdch`
  disagreed. ps1_netemu's audio SPU sat at `0x0A5E8` waiting for `MFC_LLR_LOST_EVENT` on a
  line nothing was ever going to touch --- a store watch confirmed `0x2DEF80` is only ever
  zero-initialised --- when on hardware it would simply have fallen through and kept working.
  Now the same condition as `spu_ch_ready`'s case, lost-reservation poll included, so the two
  agree by construction.

- **`tools/ppu_lifter.py` --- jump-table detection missed the biggest dispatcher in the
  image.** Two independent bugs, both found on `ps1_netemu`'s R3000 opcode table:
  - The **table-base search was window-limited.** `discover_jump_tables` looked for the
    `lwz rBase, disp(r2)` inside a fixed 30-instruction window before the `bctr`. Here the
    base load sits **36** instructions back, so the detector found the `mtctr` and the
    `lwzx` and then gave up. The base walk now scans the enclosing function, bounded by the
    nearest preceding `blr` --- the same guard the two-level-base path already used. Safe for
    the cases that already worked, because the walk stops at the *nearest* definition, so a
    base inside the old window still wins.
  - **A leading null slot truncated the table to nothing.** The decoder stopped at the first
    entry that failed validation. A dense opcode table has null slots for the codes it never
    dispatches, and this one's index 0 is exactly that, so a correct base still decoded
    **0 targets**. Leading holes are now skipped (bounded at 4, so a genuinely wrong base
    still fails fast); the first hole *after* real entries still ends the table.

  A dropped dispatcher is silent and expensive: the case targets never get labels, and the
  runtime `bctr` falls through to the generic indirect-call dispatcher, which resolves
  function **entries** only. Every jump-table case is a mid-function address, so the call
  does nothing at all. Across this image the fix went from 67 dispatchers / 654 case targets
  to **68 / 718**.

- **`tools/ppu_lifter.py` --- stores through a frame pointer were invisible.** A PPC64
  red-zone leaf keeps locals below `r1` with no `stdu`, and writes them through a copied
  pointer (`addi r5,r1,-128` -> `r31` -> `r30`, then `std r9,0x8(r30)`). `_write_counts`
  only saw literal `r1 + off` stores, so the slot looked untouched, was treated as a
  callee-save spill, and the matching `ld r25,-0x78(r1)` returned the *caller's* `r25`. In
  `ps1_netemu`'s Montgomery multiply that put a pointer into the carry chain, so every ECDSA
  signature the firmware checked came out wrong and no PSOne disc would mount. The lifter now
  tracks registers holding `r1 + off` through the zero-extend and register-move idioms and
  charges the store to the slot it lands on.

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
