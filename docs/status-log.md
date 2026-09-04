# Status log --- how each blocker was found and fixed

Moved out of the README, which had grown to 706 lines. This is the running
account of the investigation in the order it happened, including the wrong
turns and the measurements that killed them. The deep detail lives in
[ps1-core.md](ps1-core.md) and [../PROGRESS.md](../PROGRESS.md).

## Milestones

| Milestone | Status |
|---|---|
| Extract the PSN PKG | ✅ Done — needed new mixed-key support, see [upstreamed.md](upstreamed.md) |
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
| R3000 runs continuously | ✅ **Done** — **4.2 billion instructions** in a 360 s run, ~14 MIPS, no plateau |
| Audio decoder reached and stable | ✅ Done — four `cellAdec` ABI faults fixed; `EndSeq` 4760 → 2 |
| RSX pipeline fed | ✅ Done — 22,029 packets, 22,029 groups executed, **zero** drops |
| PS1 GPU handoff (PPU → 4 SPUs) | ✅ Done — packets consumed **and rasterised**; the intro renders from PS1 VRAM |
| **PS1 renders (BIOS boot screen in VRAM)** | ✅ **Done** — dumped and read: PlayStation logo + SCEA licence text |
| **PS1 game runs and loads its art** | ✅ **Done** — VRAM holds Twisted Metal car sprites and title letters |
| **Renderer produces a picture** | ✅ **Done** — 89% of the presented 1280x720 surface is drawn |
| Whole PS3-side render path verified | ✅ Done — draws, shader, constants, upload, readback all correct |
| PS1 display framebuffer placed correctly | ✅ Done — 320x240 block, native resolution, right position |
| PS1 CD events opened correctly | ✅ Done — `CdInit` runs; handles `F1000007..F100000B` all valid |
| PS1 CD interrupt raised + unmasked | ✅ Done — `I_STAT_or=0x0D`, `I_MASK_or=0x0D` (bits 0,2,3) |
| Init ordering deterministic | ✅ Done — 15 markers, identical sequence in 3 runs; no init race |
| **Bug 1**: PPU/SPU deadlock | ✅ **FIXED** — `GETLLAR` read guest memory twice; a PPU store between the two reads left the SPU stale and its reservation fresh |
| **Bug 2**: CD wait | 🔁 **Withdrawn** — the CD loop is left; the census that supported this no longer reproduces |
| Intro logos render | ✅ **Done** — both Sony title cards, photographed at t=75s and t=90s |
| Main menu renders and responds | ✅ **Done** — reproduced unattended via `PAD_SCRIPT`; background art correct, inner panel black |
| **Intro FMV plays** | ✅ **Done** — full colour, full screen, undriven |
| 3D on top of the menu | ✅ **Done** — `DrawEdge` reaches VRAM; car-select model renders |
| **Attract mode** | ✅ **Done** — 3D gameplay demo: night city, cars, explosions, HUD |
| **Bug 6**: MDEC writes the pattern | ✅ **FIXED** — `vmsumshs`, `vsumsws`, `vmulesh` were silent no-ops in the lifter; `vsraw`, `vrlw`, `vmulosh`, `vmax`/`vmin` had byte-reversed lanes |
| Polygon rasteriser works | ✅ **Done** — `DrawEdge` 0 → **88,040** entries/SPU once driven off the title screen; the 2D phase simply had no polygons |
| **Bug 3**: menu inner panel is black | ✅ **Fixed by the VMX work** — the panel is MDEC video; car select renders |
| **Bug 4**: core reset at 2^32 cycles | ⬜ Counter wrap at ~4.27B; benign so far — the run continues after it |
| **Bug 5**: the movie’s pixel source is a pattern | ✅ **FIXED** — same defect as Bug 6: MDEC emitted the pattern because its VMX was mis-lifted |
| Twisted Metal renders | ✅ **Done** — intro FMV, title screen, attract-mode 3D gameplay |


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


## A second title: Twisted Metal 2

Confirmation that the target was the right one. `ps1_netemu` is the emulator, so a
second PSOne Classic needs no code at all --- unpack its package into
`vfs/dev_hdd0/game/<content>/` and name it:

```sh
PS1_CONTENT=NPUI94306 PS1_SERIAL=SCUS94306 ./tools/run.sh
```

It boots, decrypts its own disc, plays the SingleTrac logo movie and its intro,
and reaches the *World Tour* title screen. 1.65 billion R3000 instructions,
VRAM at 149,943 non-zero words. The VMX/MDEC fix carries straight over --- its
FMV decodes on the first try.

`tools/run.sh` is now content-aware: `PS1_SERIAL`/`PS1_CONTENT` pick the disc, the
window title follows, and `vfs/PS3_GAME/PARAM.SFO` is **refreshed when it does not
match** the title being launched. That last part matters --- it is shared state, and
a stale SFO points `cellGame` (and every path built from it) at the previous game.

### The one thing that did not just work: EDAT licence type 2

The first attempt failed at the disc:

```
[edat] license type 2: header klicensee is NP_PSX_KEY, but the DATA is encrypted
       with the RIF key from a per-console RAP, which this runtime does not have
cell/host.c: 625: CoreBoot() failed
```

`ISO.BIN.EDAT` comes in more than one licence flavour. Type 1 and 3 derive their
key from a klicensee the runtime can compute; **type 2 is bound to a per-console
RAP**, and ps3recomp's EDAT path has no RIF/RAP support, so the disc cannot be
decrypted and `CoreBoot()` gives up.

That is a **runtime capability gap, not a title-specific bug** --- and it is worth
recording as a feature request rather than a workaround: implementing RIF/RAP
handling would let a type-2 package be used with the buyer's own RAP, which is the
correct way to run one. Until then a type-2 disc image needs a licence the runtime
can actually process.

Diagnosis was immediate because the message names the cause outright --- the EDAT
work documented in [npdrm.md](npdrm.md) had already made that path legible.
