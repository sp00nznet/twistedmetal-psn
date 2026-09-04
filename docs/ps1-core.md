# Starting the PS1 core

With the disc mounted, the firmware boots the title and three separate stalls showed up
between it and the R3000 actually running. Two are fixed; the third is the current wall.

## 1. The lost-reservation event was never raised

SPU 4 (the GPU core -- SPUs 0-3 share the 84,992-byte R3000/GTE image, SPU 4 has its own
58,208-byte one) parked forever:

```
[ch-block] spu=4 pc=0x0A5E8 op=rdch ch=0 evstat=0x0 evmask=0x400
[ch-wait]  spu=4 pc=0x0A5E8 ch=0 waited=46000ms
```

Channel 0 is `SPU_RdEventStat` and mask `0x400` is `MFC_LLR_LOST_EVENT`. That is the standard
SPU "wait until another processor touches this variable" idiom: `GETLLAR` the 128-byte line,
arm the Lr event, then block on the event status until the reservation is lost.

The runtime had reservations (`resv_ea`, `resv_valid`, `resv_line[128]`, used by `PUTLLC`) but
**no producer for the 0x400 bit at all** -- only `0x1` (tag status) and `0x2` (stall-and-notify)
were ever set. So the SPU blocked forever while the PPU waited on the SPU.

`spu_resv_lost_poll()` in `runtime/spu/spu_channels.c` supplies it. Losing a reservation means
the line changed, and `GETLLAR` already snapshots it, so it compares against that snapshot
instead of hooking every store -- one 128-byte `memcmp` per 10 ms poll on an already-blocked
SPU, and nothing on the PPU store path. `ch-wait` went from 23 multi-second stalls to zero.

## 2. `sys_usbd_receive_event` returned instead of blocking

The single hottest thing in the process, by two orders of magnitude:

```
384339 [sc] 540
[sc] 540(0x0, 0xD0009F90, 0xD0009F98, 0xD0009FA0) -> 0x0 tid=3
```

Syscall 540 is `sys_usbd_receive_event` (RPCS3's table names it; the shape agrees -- the guest
loop dispatches on the event type, ends the thread on 4, handles 3 locally, and forwards 1 and
2 with `sys_event_port_send`, which is syscall 138 in the standard table). `ps1_netemu` starts
a USB daemon thread, which only got this far once `_sys_malloc` worked.

On hardware and in RPCS3 the call **sleeps** until an event is queued. The unimplemented stub
returned `CELL_OK` immediately with the out-params untouched, so the guest read event type 0
and went straight round again -- one thread burning a core flat out and starving the SPUs.
`0xD0009F90` is that thread's `r1+0x70`, which is what the `[HOTREAD64] spinning` line was
reporting.

Implemented in `lv2_register.c`: report "no event" explicitly (the stub left the guest reading
its own stack, which only happened to be zero) and sleep 20 ms. 384,339 calls became 2,203,
and every `HOTREAD`/`ch-wait` spin in the run went to zero.

## 3. A bare `/USRDIR/` resolved to the VFS root

Long-standing and finally in the way. `sys_fs.c` mapped anything containing `USRDIR/` straight
to `<vfs root>/USRDIR/...` -- a flattening added for flOw, whose assets really do live there.
This title is installed as a full `/dev_hdd0/game/NPUI94304/` tree, so `/USRDIR/CONFIG` missed:

```
save config file: /USRDIR/CONFIG
failed
```

`PS3_USRDIR_BASE` now overrides the base for those paths, opt-in so flattened trees keep the
old behaviour, and `tools/run.sh` points it at the install tree. The config file opens and the
`failed` is gone.

## Where it stops now

The three fixes above moved the wall a long way. There are now **no spins at all** -- no
`HOTREAD`, no `ch-wait`, no busy syscall -- 30,784 frames render in a 150-second run, the
audio thread services 20,032 real events on its queue, and the config file saves. But
`packets[seen=0]`: the guest issues no draw commands, and the game does not start.

The reason is one line in the log:

```
[spu-raw] spu4 stopped: halted=1 pc=0x3FFB0 lr=0x000C8 steps=8288 stop_code=0x0
```

**SPU 4 -- the GPU core -- runs away and halts.** The image is 58,208 bytes, so `0x3FFB0` is
far past the end of it, in zero-filled local store; an all-zero word decodes as `stop 0`,
which is the `halted=1 stop_code=0x0`. It branched into empty LS.

This is progress, not a regression: before the lost-reservation fix, SPU 4 blocked forever at
`0x0A5E8` and never got here. That wait loop is now confirmed correct end to end --

```
0A5E8: il   $r15, 1024              ; the Lr mask, 0x400
0A5EC: rdch $r14, SPU_RdEventStat   ; blocks until the reservation is lost
0A5F0: and  $r13, $r14, $r15
0A614: wrch SPU_WrEventAck, $r22    ; ack it
0A61C..30: MFC_LSA / EAL / Size=128 / TagID / Cmd=0xD0   ; re-issue GETLLAR
0A634: rdch $r2, MFC_RdAtomicStat
```

-- wait, acknowledge, re-reserve, loop, exactly as the hardware protocol says. SPU 4 takes
that path three times and then runs on for 8,288 instructions before dying.

Two observations for whoever picks this up:

- **The step count varies between runs** (8,297 / 8,288 / 8,288), so the runaway is
  timing-dependent. That points at a synchronisation problem -- a DMA or channel result read
  at the wrong moment -- rather than a deterministic mistranslation, which would fail at the
  same instruction every time.
- **SPUs 0-3 (the R3000/GTE cores, sharing the 84,992-byte image) are idle on `rdch ch=29`
  (`SPU_RdInMbox`) at `pc=0x011A0`**, waiting for the PPU to hand them work. That is the
  right place for them to be parked before the game starts; they are almost certainly
  waiting on the GPU core that just died.

## An open oddity

`user_memory_size= 0/0 <0>` prints right after `boot from`, where the same run reported
`201326592/268435456 <67108864>` earlier. Both print sites disassemble to `li r11, 352; sc`
(`sys_memory_get_user_memory_size`) -- but **syscall 352 never appears in a full syscall
trace, and our handler never logs**, in either case. So the values are not coming from where
the disassembly says they are, and that is unresolved. It may be harmless (a second pool that
legitimately reads zero) or it may be the same missing initialisation seen from another side.
Worth settling before trusting anything else about the PS1 core memory setup.

## The event queue the gcm thread waits on

`tid=2` is `_gcm_intr_thread`, and it receives on **queue id 0** -- ESRCH, 20k times. The id
comes from `*(obj + 0x12D0)` where `obj` is `func_000120E4`'s return, which is null because
`*(0x2D80B4)` is never written. Exactly one instruction writes that field
(`0x1200C`, in `func_00011FF4`, which selects one of four 28-byte entries), reached from one
real call site (`0x12A24` in `func_0001299C`, which rejects an index of -1 with
`0x802100FF`). A watch confirms the field is never written in a whole run.

This is not what stops the game -- graphics run at 58 fps regardless -- so it is filed rather
than chased.

## Narrowing the GPU-core halt

`SPU_DUMP_MISS=1` names the destination of a bad branch but not its origin, and with a
trampoline dispatcher there is no host frame left to walk back to. `spu_channels.c` now keeps
a per-thread ring of the last eight PCs it actually dispatched and prints it with the miss --
one store per dispatch, no allocation.

```
[spu] img=2 branched into unlifted LS 0x3FFB0 (lr=0x000C8) -- ending the job
      last dispatched PCs (oldest first): 0x00000 0x00000 0x0A200 0x09E10 0x09FD4 0x09FD4 0x09DD4 0x09E00
      LS[0x3FFB0]: 00002000 00002000 00002000 00002000 00000000 00000000 00000000 00000000
```

Three things follow, and the first corrects the note above.

- **`0x3FFB0` is inside the stack, not past the image.** The CRT entry at LS `0xE0` is
  `ila $r8, 0x3FFD0` and builds the stack pointer from it, so `0x3FFB0` is an ordinary stack
  slot `0x20` below the initial frame. Calling it "far past the end of local store" was wrong.
- **The word there is `stop 0x2000`**, four times over, which is exactly why branching to it
  ends the job. Those bytes are **zero in the static image**, so the value appears at runtime.
- **The last dispatched function is `0x09E00`**, whose lifted body is seven lines with two
  exits, both to valid lifted functions -- so it is not the one that computed the target.
  Trampoline hops bypass the dispatcher, so the ring only records indirect branches and the
  immediate predecessor is still invisible.

Three ways that word could have been written, all measured, all ruled out:

| candidate | measurement | result |
|---|---|---|
| PPU store into the LS window | `LBP_WW=0xE043FFA0 LBP_WW_LEN=0x60` | 0 writes |
| SPU quadword store | `LBP_SPU_WATCH=0x3FFB0` | 21 accesses, all zeros, from `pc=0x100`/`0x16C` |
| MFC DMA from the GPU core | `SPU_DMATRACE=2` | 17 transfers, none above `0x1ED80` |

One trap worth writing down: **`SPU_DMATRACE` takes an image number, not a boolean.**
`SPU_DMATRACE=1` traces image 1 and says nothing at all about image 2, which cost a round of
"DMA is ruled out" before the flag was read properly.

So either a lifted store path writes local store without going through `spu_ls_write128`
(which is what the watch hooks), or -- more likely on this evidence -- **the memory is fine
and the branch is wrong**: `0x2000` at `0x3FFB0` is a legitimately spilled register, and the
fault is an indirect branch taken through a register that should hold a code address and does
not.

That is the thread to pull next, and it wants the ring extended into `SPU_DRAIN` so the
immediate predecessor of the bad branch is visible rather than the last dispatcher-resolved
one.

## It was never a runaway: the GPU core exits cleanly

Extending the PC ring into `SPU_DRAIN` (so trampoline hops are recorded, not just
dispatcher-resolved indirect branches) gave the immediate predecessor:

```
last dispatched PCs (oldest first): 0x0C42C 0x09CD8 0x09CDC 0x0CD3C 0x0CD50 0x0CFE0 0x000D0 0x3FFB0
```

`0x000D0` is inside the CRT, and the whole block reads as one thing:

```
000C0: ori  $r80, $r3, 0        ; r80 = exit status
000C4: brsl $r0, 0xD050         ; atexit/cleanup
000C8: andi $r80, $r80, 255     ; status & 0xFF
000CC: iohl $r80, 0x2000        ; r80 = 0x2000 | status  -- a `stop` OPCODE
000D0: stqd $r80, 0x10($r1)     ; assemble it onto the stack
000D4: sync
000D8: ai   $r3, $r1, 16        ; r3 = &that word
000DC: bi   $r3                 ; branch to it, and execute it
```

**This is the standard SPU `exit()`**: build a `stop <status>` instruction in memory and jump
to it. So `0x00002000` at `0x3FFB0` was never corruption -- it is the instruction the CRT had
just written -- and branching to a stack address with no lifted code is exactly what a correct
exit looks like from the dispatcher's point of view.

The guard reported it as `branched into unlifted LS 0x3FFB0 -- ending the job` with
`stop_code=0x0`, which reads as a runaway. That sent a long chase after phantom memory
corruption: three separate measurements (PPU stores, SPU quadword stores, image-2 DMA) all
correctly found nothing, because there was nothing to find.

`spu_channels.c` now decodes the target word before blaming the branch. A `stop` is opcode 0
in the top 11 bits, so it is unambiguous:

```
[spu] img=2 exit: synthesised stop 0x2000 at LS 0x3FFB0
[spu-raw] spu4 stopped: halted=1 pc=0x3FFB0 steps=8288 stop_code=0x2000
```

`stop_code` is now `0x2000` rather than `0x0`, and since the low byte carries the status,
**SPU 4 exits with status 0** -- a clean, deliberate exit. This idiom is universal SPU CRT
behaviour, so every port gets a truthful log line out of it.

## The actual question

The GPU core is not crashing; it is *finishing*. `0x0CFE0` is `il $r3, 0` followed by a frame
teardown and `bi $r0` -- a function returning 0 -- and that return lands in the CRT exit stub.
Its `main` returned.

So the open question is no longer "what corrupted the stack" but **why the GPU core's main
loop terminates after ~8,288 instructions, and what is supposed to restart it**. The PPU
starts SPU 4 exactly once (one `spu4 START` per run) and never writes `RUNCNTL_RUN` again.
`raw_spu_start()` clears `started` on stop, so a restart would be honoured if the PPU asked
for one.

Two directions from here, in order:

1. Follow the return chain `0x0C42C -> 0x09CD8/0x09CDC -> 0x0CD3C -> 0x0CD50 -> 0x0CFE0` and
   find the condition that ends the loop. A GPU core that exits with status 0 after a fixed
   amount of work is usually waiting on something it decided it would never get.
2. Check whether the PPU is meant to see the stop and restart the core. The runtime sets
   `SPU_STATUS_STOPPED_BY_STOP | (stop_code << 16)`, so the status register reads correctly;
   what is not yet established is whether `gpuio.cc: gpuCmdInterruptHandlerThread` (tid=5)
   ever polls it.

## The blocker: raw-SPU interrupts are never delivered

Tracing where every PPU thread is parked (last completed syscall per tid) finishes the
picture:

| tid | thread | parked after |
|---|---|---|
| 1 | main | `sc 91` |
| 2 | `_gcm_intr_thread` | `sc 130(queue 0)` -> ESRCH |
| 3 | `libusbd_callback_thread` | `sc 540` (now sleeping, see above) |
| 5 | **`gpuio.cc: gpuCmdInterruptHandlerThread`** | **`sc 88` = `sys_interrupt_thread_eoi`** |
| 6 | `_xSPUWaveOut` | `sc 130(queue 3)` -- working, 20k real events |
| 7 | **`spu.c: SPUCxInterruptHandlerThread`** | **`sc 88` = `sys_interrupt_thread_eoi`** |
| 8 | `_xcdrom_thread` | `sc 94` |
| 9 | `xPadThread` | `sc 130(queue 2)` |
| 10 | `_xMcThread` | `sc 94` |
| 11 | `_PSPiStorageThread` | `sc 94` |

The two threads whose whole job is servicing the SPUs -- the GPU command handler and the SPU
class-2 handler -- are both sitting in `sys_interrupt_thread_eoi`, waiting for an interrupt
that never arrives. And `sys_interrupt_thread_establish` (84) and `eoi` (88) are both stubs:
nothing in `runtime/syscalls/` implements them.

That single gap explains every symptom at once:

```
[spu-raw] R spu0 OUT_MBOX      <- once
[spu-raw] R spu1 OUT_MBOX      <- once
[spu-raw] R spu2 OUT_MBOX      <- once
[spu-raw] R spu3 OUT_MBOX      <- once
[spu-raw] R spu4 OUT_MBOX      <- once
```

Five reads of the outbound mailbox, one per SPU, during init -- and **not one write to
`IN_MBOX` in the entire run**. The handshake is one-way. Each SPU announces itself, the PPU
collects the five messages while it is still polling, and from then on the PPU expects to be
*interrupted* when an SPU wants something. It never is, so it never replies. SPUs 0-3 park on
`rdch ch=29` (`SPU_RdInMbox`) forever, and SPU 4 -- which does
`wrch SPU_WrOutMbox` at `0x0CD1C`, calls `0x8800`, then tests `brnz $r80` at `0x0CD2C` --
takes the `r80 == 0` branch, zeroes `0x1D580..0x2F700`, returns 0, and exits.

So SPU 4 is not failing. It asked the PPU a question, got no answer, and shut down tidily.

## What the runtime already has, and what is missing

Present:

- `s->intrtag` and `s->int_stat` per raw SPU.
- `raw_out_mbox_hook()` sets `int_stat |= 1` on a `WrOutIntrMbox` -- the class-2 mailbox
  interrupt.
- `sys_raw_spu_get_int_stat` (154) and `set_int_stat` (153, write-1-to-clear) so the PPU can
  read and acknowledge.

Missing -- and this is the work:

1. **`sys_interrupt_thread_establish` (84)**: record which PPU thread services which interrupt
   tag, instead of returning success and forgetting.
2. **Delivery**: when a raw SPU raises `int_stat` (an out-interrupt mailbox write, or a stop),
   wake the thread established for that tag.
3. **`sys_interrupt_thread_eoi` (88)**: park the handler until the next interrupt rather than
   returning immediately.

That is the mechanism `ps1_netemu` is built on: the SPU writes its interrupt mailbox, the PPU
handler wakes, reads `OUT_MBOX`, and replies through `IN_MBOX`. Until it exists, the R3000
cores have no way to be given work, and nothing the disc path does can reach the screen.

Worth saying plainly: this is the *third* time on this title that a "stub that returns
CELL_OK" has been the whole blocker -- after `_sys_malloc` and `sys_usbd_receive_event`. A
syscall that succeeds without doing anything is much harder to find than one that fails.

## Implementing raw-SPU interrupts

`runtime/spu/spu_intr.inc` (included by `spu_raw.c`, where the tags live) implements the three
missing pieces:

- **`sys_interrupt_thread_establish` (84)** binds a tag to the PPU thread that services it.
- **Delivery** is **level-triggered**: `int_stat & int_mask` for the SPU the tag encodes
  (`0x52000000 | id<<8 | class`). An edge-triggered flag was tried first and lost every
  interrupt, because all five SPUs write their ready mailbox during init and the two handlers
  are established *afterwards* -- the edge fires with nothing bound. Reading the level cannot
  lose that, and it matches the hardware, where the PPU clears the condition explicitly with
  `sys_raw_spu_set_int_stat` (153, write-1-to-clear).
- **`sys_interrupt_thread_eoi` (88)** returns, and `ppu_host_thread_proc` re-invokes the
  handler's entry on the next interrupt. lv2's own eoi does not return -- it re-enters the
  thread at its entry -- and both of ps1_netemu's handlers end in `blr` immediately after
  their `sc 88`, so a return *is* the end of one pass. Without the re-entry loop each handler
  ran exactly once.

Getting the class-2 bit meanings right mattered. Per CBEA, `0x1` is the SPU **interrupt**
mailbox (`SPU_WrOutIntrMbox`), `0x2` is **stop-and-signal**, and `0x10` is the plain outbound
mailbox threshold. ps1_netemu unmasks `0x3`. Briefly mapping a plain `WrOutMbox` onto `0x1`
made the handler run and then call `sys_raw_spu_read_puint_mb` (163) for a message that was
never in the privileged mailbox -- the plain mailbox is deliberately *not* an interrupt source
here, and the PPU polls it instead.

**`stop`-and-signal is what actually matters.** A raw SPU asks the PPU for something by
stopping with a code: the PPU takes the class-2 interrupt, reads the code, services it and
restarts the SPU. `spu_raw.c` now raises `0x2` when a raw SPU stops.

## What that changed

The init handshake was already working and visible:

```
[spu-raw] spu0 out mbox = 0x00015010    [spu-raw] R spu0 OUT_MBOX -> 0x00015010
... x4 (the R3000/GTE cores) ...
[spu-raw] spu4 out mbox = 0x0000E500    [spu-raw] R spu4 OUT_MBOX -> 0x0000E500
```

What was missing is what happens next. With stop-and-signal delivered:

```
918  save config file: /USRDIR/CONFIG
1118 [spu-raw] spu4 stopped: stop_code=0x2000
1462 [intr] deliver tag 0x52000402 -> thread 7
1488 R3000Exit(): PS1_EXIT_STOP
```

**The emulator now reaches the R3000 lifecycle**, which it never did before. It is told the
core stopped, and it responds -- correctly -- by shutting the R3000 down. So the interrupt
path works end to end; what is wrong is that SPU 4 stops at all.

## Where it stands

The remaining question is the one from before, now with the notification path proven: SPU 4
writes its ready message, the PPU reads it, and then the core still takes the teardown branch
at `0x0CD2C` (`brnz $r80` with `r80 == 0`), zeroes `0x1D580..0x2F700` and stops with
`0x2000`. `r80` is a callee-saved register set by a caller -- nothing in `0x0C800..0x0CD20`
writes it -- so the next step is to find which caller supplies it and what it is supposed to
contain.

Also still open, and cosmetic: two `sys_interrupt_thread_disestablish() failed` lines during
teardown. Syscall 89 (`_sys_interrupt_thread_disestablish`, per RPCS3's table) is now
implemented and unbinds the tag, but the guest evidently reaches it by another number, so the
stub still answers. Harmless -- it happens after `R3000Exit` -- but worth pinning down.

## Past the interrupts: the R3000 has nothing to run

With interrupts delivering, the failure moved up a layer. The emulator no longer wedges -- it
boots, runs briefly, and **shuts itself down**. Tracing that shutdown gives a clean chain.

### The exit is a deliberate decision, not a crash

`TTY_BT` on the config save puts it in the PPU CRT (`0x10230`/`0x10354`), so saving the config
is an *atexit* handler: `main` returned. The decision is at `0xB3E60`:

```
bl 0xB671C
bl 0xB66E0          ; -> status
cmpwi r3, 5   -> 0xB3E58   keep running
cmpwi r3, 4   -> 0xB3C30   other path
otherwise:
bl 0xB2280          ; save config      <- the atexit-looking print
bl 0xB6650          ; teardown, ending in R3000Exit()
```

`func_000B66E0` returns whatever `func_001066A8` returns, and `func_001066A8` is the **R3000
interpreter**: it takes the same state block `R3000Exit` uses (`*(TOC-0x79FC)`), reads the PC
from `+0x108`, adds the PS1 RAM base from `*(TOC-0x79D4)`, and fetches with
`lwbrx r29, r0, r9` -- a byte-reversed load, i.e. a little-endian PS1 instruction. Status 5
means "keep interpreting".

So the emulator is asking its R3000 core to run, the core returns something other than
"continue", and it shuts down. `R3000Exit(): PS1_EXIT_STOP` is the *consequence*, not the
cause -- `func_00105E18` only sets an "already exited" flag at `+0x110`.

### Why: the disc body is opened and never read

```
line 703  [sys_fs] open OK: ...USRDIR/CONTENT/EBOOT.PBP
          (no reads)
line 918  save config file: /USRDIR/CONFIG        <- the exit path
```

Watching the open-file size at `cdrom_obj + 0x70A0` shows the file switch itself works
perfectly:

```
0x00100028   the decrypted EDAT   (1,048,616)
0x0418B2D5   EBOOT.PBP            (68,727,509)
0x00000000   closed again
```

So `pspi.c` verifies the header, closes the EDAT, opens the PBP, records its real size -- and
then closes it without streaming a byte. Everything up to and including the file switch is
correct; the read that should follow never happens.

The code right after the switch (`0xF15D0`) reads 40 bytes and then walks a track table at
`0xF16B0`: `r22 * 0xB3C80` per entry, bounded by the track count at `+0x70D8`, validating BCD
MSF digits (`nibble > 9` and `high*10+low > 99` both branch to the `0xF0930` teardown). That
also finally explains the `0xB3C80` constant from the very first mount investigation: it is
the **per-track stride in the track table**, not a byte count, which is why reading that many
bytes never made sense.

### Where to pick up

The next measurement is which of those checks rejects the PBP -- the 40-byte read at
`0xF15F0`, the track-count bound at `0xF16AC`, or one of the three BCD gates at
`0xF16DC`/`0xF16E8`/`0xF1700`. All three BCD gates jump to `0xF0930`, which is the teardown
whose call site the PC-history ring already names, so a store watch on `+0x70D8` plus the
existing miss dump should settle it in one run.

Worth carrying forward: the PS1 RAM base is `*(TOC-0x79D4)` and the R3000 PC is at
`+0x108` of `*(TOC-0x79FC)`. Watching those two directly is the fastest way to confirm
"nothing was ever loaded" independently of the disc path.

## The R3000 never executes an instruction, and why

Three earlier conclusions in this file were wrong and are corrected here. The disc path, the
BIOS load and the core setup are all **fine**; the emulator stops for a much narrower reason.

### Corrections

- **`EBOOT.PBP` is not closed early.** Ordering the `+0x70A0` (open-file size) writes against
  the log shows `0x100028` (the EDAT) -> `0x418B2D5` (the PBP, 68,727,509) at line 845, and
  the close at line 1123 -- *after* the config save at line 1109. The PBP stays open right up
  to shutdown; the close is teardown.
- **`func_000F1CE0` clearing the track count is also teardown.** It is reached from `0x110DDC`,
  which unmounts and then calls `sc 601` (`sys_storage_close`) -- the disc-eject path.
- **The BIOS is loaded.** A store watch showed only zeros there, but that watch only sees
  `vm_write*`, and a file read lands via `memcpy` into `vm_base` -- invisible to it. Reading
  the buffer directly at the moment the emulator polls:

```
BIOS[0x970B80] = 00781A40 ...        R3000pc = BFC00000
```

  `0x00781A40` byte-reversed is `0x401A7800` = `mfc0 $k0, $15`, which is exactly the first
  instruction of the PS1 BIOS. The BIOS is in place and the PC is at the reset vector.

### What actually happens

The emulator's main loop at `0xB3E60` polls `func_000B66E0`, keeps running on status 5, and
otherwise saves the config and tears down. Instrumenting that call site:

```
[dbg] emu poll #1 -> status 0   BIOS[0x970B80]=00781A40 ...  R3000pc=BFC00000
[dbg]   reason(+0x138)=-1  exited(+0x110)=0  +0x10C=00000004 +0x120=00000000
```

**The loop runs exactly once.** The PC is unchanged at `0xBFC00000` afterwards, so the
interpreter executed **zero** instructions, and `+0x138` is still the `-1` it is initialised to
at entry, so it never reached any of its exit-reason paths.

The reason is `+0x120 = 0`. `func_001066A8` loads `r28 = *(r23+0x120)` and decrements it per
instruction (`subf r28, r7, r28`), so it is the budget of cycles until the next scheduled
event. At zero the loop ends before it starts.

### Where the zero comes from

`func_00105E68(delay, callback, arg)` is the event scheduler: it takes the running cycle count
from `+0x124`, the remaining budget from `+0x120`, and schedules a callback `delay` cycles
ahead, shortening `+0x120` when the new event is sooner. Watching `+0x120` with call sites:

```
0x76C1A0 <- 0x100   func_00105E68  lr=0x000C29E0
0x76C1A0 <- 0x40    func_00105E68  lr=0x0010ED78
0x76C1A0 <- 0x0     func_00105E68  lr=0x0010ED98   <- last
```

The last one is `func_0010EA58` at `0x10ED94`, which schedules two events back to back --
`func_00105E68(64, *(TOC-0x7974), 0)` then `func_00105E68(0, *(TOC-0x797C), 0)` -- storing the
handles at `+0x13C` and `+0x234`. The second schedules an event **due immediately**, which
pins the budget at zero.

### Resolved: neither reading. The dispatch table was never lifted.

Reading 1 was closer, but the mechanism was not the event dispatch --- and **the budget was
never the problem at all**. A budget of 0 is *normal*: `func_001066A8` runs down its budget,
falls through at `0x1068DC`, and calls `func_00105FA8`, which fires every due event and
returns `next_due - now` as the new budget (`0x106078` writes `+0x124 = due`, `0x106094`
returns the difference). If reason (`+0x138`) is still `-1` it branches back to `0x106834`
and keeps running. Poking the budget to `0x1000` changed nothing, which was the clue.

What actually happened is that the interpreter never got as far as the budget check. Its
opcode dispatch is a jump table, and that table was never lifted.

**The trace.** `func_001066A8` has exactly two exits in the lifted output: a `bctr` tail
dispatch and a plain return. Logging both showed the `bctr` taken once and the return never
reached:

```
[dbg] R3000 enter #1 pc=BFC00000 cost(+0x114)=00000001 budget(+0x120)=00000000
[dbg] R3000 bctr  #1 ctr=001070E4 pc=BFC00004 insn=401A7800 budget=FFFFFFF7
```

Everything before the dispatch is correct:

- **Fetch.** `0xBFC00000` is not in main RAM, so `0x1066D4`/`0x106740` divert to `0x108314`,
  which computes `(pc & 0x1FFFFFFF) + 0xE0400000` --- for the reset vector that wraps to
  **0**, the right BIOS offset --- and `lwbrx` reads `0x401A7800`, byte-reversed
  `mfc0 $k0,$15`. That is the PS1 BIOS's first instruction.
- **The block-cache miss at `0x107A74` is not an error path.** It is the i-cache cycle
  penalty: it recomputes the per-instruction cost into `r7`, updates `+0x128`, stores the tag,
  and falls back into the main flow at `0x106794` (`b 0x106794`). Hence `budget = 0 - 9`.
- **PC advance.** `0x106794 add r26,r26,r27`. The in-memory PC at `+0x108` is only written
  back on exit, which is why it still read `0xBFC00000` afterwards --- that had misled an
  earlier reading.

**The dispatch went nowhere.** `0x1070E4` lies inside `func_001066A8`'s range
(`0x106748`--`0x108348`) but was **not a label, not a separate function, and not in the
generated function table**, so `ps3_indirect_call` matched nothing and returned silently.
`func_001066A8` then fell out, and the main loop --- `bl 0xB67A0; bl 0xB671C; bl 0xB66E0;
cmpwi r3,5; beq` at `0xB3E58`--`0xB3E74` --- saw a status other than 5 and tore the emulator
down. (The return value is `*(+0x110)`, the pending-exit code set by `func_00105DA4`; no
caller of it passes 5, because 5 is produced on the *normal* path, not the exit path.)

**The table.** `lwzx r5, r19, r11; mtctr r5; bctr` at `0x1067C8`--`0x1067D4`, with
`r19 = *(TOC-0x79CC)` and the index `(insn >> 26)` folded with the function field and masked
to `0x1FC` --- a 128-entry table, found in the image at **`0x1B37D4`**. `JT_DEBUG=0x1067D4`
named both reasons ps3recomp dropped it:

```
rC=r5                                     <- mtctr found
lwzx=r5, r19, r11                         <- table load found
disp=None disp2=None r_base=None          <- base NOT found
```

1. The base load `lwz r19,-0x79CC(r2)` is at `0x106744`, **36** instructions before the
   `bctr`, outside the detector's fixed 30-instruction window.
2. With the base supplied it got `table_base=0x1B37D0 count=256` and then
   `entry[0] raw=0x0 -> valid=False`, breaking on the first invalid entry for **0 targets**.
   Index 0 is an opcode this table never dispatches; the 127 real handlers start at index 1.

Both fixed in `ppu_lifter.py`: the base walk now scans the enclosing function bounded by the
nearest preceding `blr` (the guard the two-level-base path already used), and leading null
slots are skipped, bounded at 4. The dispatcher now decodes **127 targets**, and the image
went from 67 dispatchers / 654 case targets to 68 / 718.

One consequence worth noting: with the table known, the `bctr` lifts to
`switch ((uint32_t)ctx->ctr) { case 0x001070E4u: goto loc_001070E4; ... }`, so the interpreter
loops **inside** one C call instead of returning per instruction. `func_001066A8` is now
entered once and stays there --- which is why the in-memory PC at `+0x108` still reads the
reset vector while the core is running.

### What that changed

```
title: 0xc0546d88U, "SCUS_943.04" P
North American Title detected!
boot from /dev_hdd0/game/NPUI94304[1] 0
[RSX null] set_render_target(format=0x9090148, 720x512)
[RSX] DRAW_ARRAYS prim=8 first=0 count=4
[fps] 205.2
```

`ExitPS1`, `CoreBoot() failed` and `R3000Exit` are all gone. 720x512 is the PS1 framebuffer.
GPU packets went 0 -> 6 and `clears[guest]` 0 -> 6, with both shaders compiled.

### How far the R3000 gets

```
[dbg] R3000 disp 1     pc=BFC00004
[dbg] R3000 disp 3     pc=BFC00010
[dbg] R3000 disp 10    pc=BFC02038
[dbg] R3000 disp 100   pc=BFC02094
[dbg] R3000 disp 1000  pc=BFC022A4
[dbg] R3000 disp 10000 pc=BFC4B844
```

The reset sequence matches `ps1_rom.bin` byte for byte:

```
BFC00000  mfc0  $k0, $15          <- dispatch 1
BFC00004  nop                     <- short-circuited, no dispatch
BFC00008  sltiu $1, $k0, 0x59     <- dispatch 2
BFC0000C  bne   $1, $0, 0xBFC00024  <- dispatch 3
BFC00010  nop                     <- short-circuited
```

Only three of the five dispatch, because `nop` is caught before the `bctr` --- `cmpwi cr7,
r29, 0; beq cr7, 0x107978` at `0x1067B8`. That accounts exactly for the 1/2/3 PCs, and was
briefly misread as "the core stops after three instructions" (the measurement came from a
binary whose relink had failed on a file lock; the current build reaches `0xBFC4B844`).

By 40,000 it is at `0xBFC58820` and stops, inside a BIOS **word-copy loop** --- an ordinary
`memcpy`, not a poll:

```
BFC5881C  lw    $t8, 0($a0)
BFC58820  addiu $a0, $a0, 4
BFC58824  sltu  $at, $a0, $v0
BFC58828  addiu $a1, $a1, 4
BFC5882C  bne   $at, $zero, 0xBFC5881C
BFC58830  sw    $t8, -4($a1)      ; delay slot
```

The interpreter neither returns nor takes the switch's `default` arm, so it is blocked
*inside*. And the rate matters: ~40,000 instructions over ~100 s of wall clock, against a
33 MHz PS1. That is far too slow to be the copy itself, and points at the interpreter getting
very small budget slices with a millisecond-scale wait per slice.

### Resolved: SPU 4's deadlock was `rchcnt` lying, not a missing writer

The audio core (image 2) parked at `pc=0x0A5E8`, and the SPU code names the event outright:

```
0A5E8  il    $r15, 1024              ; 0x400 = MFC_LLR_LOST_EVENT
0A5EC  rdch  $r14, SPU_RdEventStat
0A5F0  and   $r13, $r14, $r15
0A5F4  brz   $r13, 0x893C            ; not the lost bit -> back to work
```

Every gate in the runtime's producer passed:

```
[ch-wait] spu=4 pc=0x0A5E8 ch=0 waited=26000ms evstat=0x0 evmask=0x400 resv[valid=1 ea=0x002DEF80]
```

mask `0x400`, reservation valid, EA non-zero --- so `spu_resv_lost_poll` ran on every blocked
read and found the reserved line unchanged. A store watch
(`LBP_WW=0x2DEF80 LBP_WW_LEN=0x80`) agreed: the only writes to that line are zeros from an
initialiser at `guest-fn=0x000A7FB4`.

**That was the symptom.** The right question was not who breaks the reservation but how the
SPU entered a blocking read at all, and the answer is four instructions earlier:

```
08934  rchcnt $r12, SPU_RdEventStat   ; is an event pending?
08938  brnz   $r12, 0xA5E8            ; yes -> commit to the blocking rdch
0893C  il     $r30, 8960              ; no  -> carry on working
```

It is a **guarded** read. `spu_rchcnt` had no case for `SPU_RdEventStat` and fell through to
`default: return 1`, so it always answered "an event is pending". `rdch` then blocked
correctly, because `(event_status & event_mask)` really was 0. `rchcnt` and `rdch` disagreed,
and the SPU was lured into a read it could never complete. On hardware it would have fallen
through to `0x893C` and kept working --- the line at `0x2DEF80` was never meant to change,
which is exactly what the store watch was telling us.

The fix is one case, reusing the condition `spu_ch_ready` already applies so the two agree by
construction:

```c
case SPU_RdEventStat:
    spu_resv_lost_poll(ctx);
    return (ctx->event_status & ctx->event_mask) != 0;
```

`ch-wait` stalls went from 26+ seconds of blocking to **zero**. The check is behavioural:
`grep -c ch-wait` on a run log should stay at 0.

A note for whoever meets the next one of these: `default: return 1` is a reasonable default
for a channel whose count is genuinely always ready, and it is exactly wrong for any channel
whose `rdch` can block. Those two properties have to be decided together.

### Resolved: the RSX interrupt queue was never published

The chain from the stalled R3000 to its cause, and the fix.

**1. The main thread blocks on a flip.** With the guest call site added to the log
(`[WAIT tid=1] semaphore_wait(sem=1 timeout=0 cia=0x00000000 lr=0x00113EB4)`), the call is
`bl 0x3030C` at `0x113EB0`, sitting in a double-buffer flip:

```
00113E84  lwz    r29, 0x1C8(r27)     ; buffer index
00113E90  addi   r29, r29, 1         ; bump it
00113E94  bl     0x142BC             ; queue the work
00113EA0  rlwinm r29, r29, 0, 31, 31 ; index &= 1
00113EB0  bl     0x3030C             ; wait for completion  <-- blocks here
```

Semaphore 1 is created `init=0 max=1` and, over a whole run, was waited on **once** and posted
**zero** times; every other semaphore had matching posts.

**2. Nothing posts it, because gcm's interrupt thread exits at once.**
`_gcm_intr_thread` (OPD `0x1B7768` -> code `0x1A584`) reads its queue id and blocks:

```
0001A5E0  bl   0x120E4          ; get the gcm context  (NOT the thread arg --
0001A5EC  rldicl r9, r3, 0, 32  ;  the thread arg really is 0, `li r5,0` at 0x1A4A4)
0001A628  lwz  r3, 0x12D0(r9)   ; queue id
0001A62C  sc                    ; 130 = sys_event_queue_receive
```

**3. Where `+0x12D0` comes from.** `func_000120E4` returns `*(base->[0x7C] + 0x10)` with
`base = *(TOC-0x6B00) = 0x2D8038`. A store watch settled two things at once: `0x2D80B4`
(= `base+0x7C`) **is** written --- `0x2D8044`, by `cellGcmInit` at `0x1299C`, before the
thread is even created --- and `*(0x2D8054) = 0x20031000` is the context. So the guest side
was fine; an earlier note in this repo that `0x2D80B4` "is never written" was wrong.

`0x20031000` is our own `RSX_DRIVER_INFO_EA`, and `+0x12D0` in it is
`RsxDriverInfo::handler_queue` --- confirmed field-for-field against RPCS3's struct
(`Emu/Cell/lv2/sys_rsx.h`), where `sys_rsx_context_allocate` creates an event queue and
stores its id there. **We never did.** So the thread received on queue **0**, returned at
once, and exited --- and no gcm ISR meant no flip handler, no post, and a parked main thread.

**The fix** (`libs/video/sys_rsx.c`): create the queue in `rsx_driver_info_init`, publish its
id at `+0x12D0`, and drive it. Events are filtered through the handler mask the guest
publishes at `+0x12C0` exactly as `rsx::thread::send_event` does --- sending an unmasked event
is not merely wasteful, because gcm's ISR dispatches on the flag bits and a bit it never asked
for reaches a handler slot it never filled in.

The producer has to be a **vblank ticker of its own**, not the flip packet, because the
deadlock is circular: the main thread cannot issue the flip packet that would otherwise be the
event source while it is parked waiting for that very flip. (The run confirms it --- the only
attribute packets that ever appear are `0x101` and `0x10A`; `0x102`/`0x103` never arrive.)

**Result**, same run, same build:

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

### Next

Whether the R3000 now runs to the intro video, and whether the PS1 GPU starts issuing its own
packets (still 6, all from the emulator front-end). The vblank tick is a plain 60 Hz timer
rather than a real vblank off the present loop --- fine for breaking the deadlock, worth tying
to the swap if timing ever matters.

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

## The PS1 is running game code in main RAM, and the I/O map is complete

Two things established, and one of my own suspicions killed.

### The R3000's live program counter

The state block's pc at `+0x108` is useless --- the interpreter loads it on entry and writes it
back only in its epilogue, and it never returns. It keeps the live pc in **r26**, and it calls
`sys_ppu_thread_yield` from inside its own loop millions of times, so the guest context arriving
at that syscall carries r26 for free (`PS1_R3000_PC=1`):

```
 20000 yields:  0x80037000 38.7%   0xBFC58000 38.4%   0x001A4000 15.2%
200000 yields:  0x80037000 33.4%   0x00037000 29.2%   0x00001000 11.7%
400000 yields:  0x0003E000 33.2%   0x00001000  4.6%   0x00000000  3.0%
```

**The BIOS region disappears after the first report.** `0xBFCxxxxx` is BIOS ROM; from the second
report on it is all main RAM --- `0x00030000..0x0003E000`, the kernel/exception area at
`0x0000..0x1000`, and `0x80037000`, the KSEG0 mirror of `0x00037000`. The hot bucket also
*moves* between reports.

So the PS1 has left the BIOS, is executing code loaded into main RAM, and is **progressing
rather than spinning**. That kills two readings that were live in this document: *"the BIOS gets
stuck after the logo"* and *"the R3000's billion instructions are a wait loop"*.

### And the I/O registration map is complete

With no drawing commands reaching the ring, the obvious guess was that PS1 games send display
lists by **DMA** rather than by GP0 stores, and that the GPU DMA channel had no handler.
Scanning for inline `lis 0x1f80 / ori` immediates found no `0x10A0` --- which looked like
confirmation.

**Wrong instrument, and the same mistake yet again: an absent immediate is not an absent
registration.** Enumerating the actual callers of the I/O registrar `func_000C23E0` and reading
each base and size gives the real map:

| base | size | covers |
|---|---|---|
| `0x1F801040` | `0x10` | pad |
| `0x1F801050` | `0x10` | SIO |
| `0x1F801070` | `0x10` | I_STAT / I_MASK |
| **`0x1F801080`** | **`0x80`** | **all DMA channels + DPCR + DICR** |
| `0x1F8010B0` | `0x10` | DMA3 again (narrower, redundant) |
| `0x1F801100` / `0x1F801110` / `0x1F801120` | `0x10` | timers 0, 1, 2 |
| `0x1F801800` | `0x10` | CD-ROM |
| `0x1F801810` | `0x10` | GP0 **and GP1** |
| `0x1F801820` | `0x10` | MDEC |
| `0x1F801C00` | `0x400` | SPU |

`0x1F801080` with size `0x80` spans `0x1080..0x10FF` --- **every** DMA channel including DMA2
(GPU) at `0x10A0`, plus DPCR and DICR. GP0's 16-byte window likewise covers GP1 at `0x1814`.
Nothing is missing.

### So where it stands

The PS1 runs game code. Every I/O window has a handler. And still only type-8 sync packets reach
the GP0 ring.

Two possibilities remain:

1. **the program has not reached its drawing code yet** --- still loading, which the progression
   `0xBFC58000` -> `0x00037000` -> `0x0003E000` is consistent with
2. **the I/O dispatch inside `func_000C26E4` does not find these registrations** --- the
   registrations are proven present, so this would be a lookup or range-check fault

Rule out (1) first, because it is cheap: watch whether the hot pc bucket keeps moving over a
longer run, or settles. Only then read the dispatch.

## The PS1 returns to the BIOS and stays there

Ruling out "the program has not reached its drawing code yet" turned into a positive result.
`PS1_R3000_PC=1` over 1.2 million interpreter yields, hottest 4 KB pc bucket per report:

```
  20000   0x80037000 49.0%   0xBFC58000 32.4%   0x001A4000  8.7%
 200000   0x80037000 36.6%   0x00037000 25.8%   0x00001000 11.6%
 400000   0x0003E000 32.0%   0x00001000  4.8%   0x00000000  3.0%
 600000   0xBFC50000 32.1%   0x0003E000  1.2%   0xBFC4C000  0.0%
 800000   0xBFC50000  6.9%   0xBFC53000  6.8%   0x00000000  4.3%
1000000   0xBFC53000  8.1%   0xBFC58000  4.0%   0x00000000  3.4%
1200000   0xBFC53000  5.8%   0xBFC58000  5.0%   0x00000000  2.2%
```

The shape is unambiguous. Four phases:

1. **boot** in BIOS ROM (`0xBFC58000`) with early RAM code
2. **game code in main RAM** --- `0x00037000`, `0x00031000`, plus the kernel/exception area at
   `0x0000..0x1000`
3. **further into RAM** --- `0x0003E000` becomes the hot bucket
4. **back into BIOS ROM** at `0xBFC50000`, and it **stays** in `0xBFC50000..0xBFC58000` for the
   remaining two thirds of the run

So the PS1 does reach its own code, and it does not stop there --- it calls back into the BIOS
and does not come out. That is what a game does when it asks the BIOS to load its next stage
from CD, and it fits everything else: the title/intro assets are already sitting in VRAM (car
sprites, vehicle art, title letters), and no drawing command has been issued since.

### This reframes the question, and more usefully than before

It is **not** "why does the GP0 handler never fire". The PS1 simply is not drawing, because it
is inside a BIOS routine waiting for something. What to identify is what lives at
`0xBFC50000..0xBFC58000` in this firmware's PS1 BIOS image, and what it polls.

**The CD-ROM is the first candidate.** The game had just finished loading its title assets;
`0x1F801800` and DMA3 are both registered; and the syscall histogram shows real storage traffic
(540: 3,265 calls, 604: 281) rather than none --- so the path is live but may not be completing.

### What this supersedes

Three earlier readings in these notes are now wrong:

| earlier claim | what the pc trace shows |
|---|---|
| "the BIOS gets stuck after the logo" | it gets much further, into game code, *then* returns |
| "the billion instructions are a wait loop" | the pc migrates through four distinct phases |
| "the remaining question is the GP0 dispatch" | the dispatch is never reached because nothing is drawn |

The last one matters most: several sections above were investigating a dispatch that was never
going to fire, because the question was one layer too low.

## ROOT CAUSE: the PS1 BIOS is spinning in a three-event `TestEvent` poll loop

Refining the pc probe from 4 KB to 64-byte buckets names the loop. Steady-state hot spots:

```
pc~0xBFC53840  4.4%      pc~0x00001EC0  1.9%
pc~0xBFC58B40  4.0%      pc~0x00000080  1.8%    (PS1 general exception vector)
pc~0xBFC53880  3.4%      pc~0xBFC51940  1.6%
```

`0xBFC58B60` is a PS1 BIOS syscall trampoline, in the classic form:

```
BFC58B60  addiu $t2, $zero, 0xb0
BFC58B64  jr    $t2
BFC58B68  addiu $t1, $zero, 0xb       ; B-table function 0x0B = TestEvent
```

and `0xBFC53840` calls it three times, over three different event descriptors:

```
BFC53850  lw   $a0, -0x4de4($a0)      ; event 1 (kernel data, 0xA001xxxx)
BFC53854  jal  0xbfc58b60             ; TestEvent
BFC5385C  bne  $v0, $s1, 0xbfc5386c
BFC53870  lw   $a0, -0x4dd8($a0)      ; event 2
BFC53874  jal  0xbfc58b60             ; TestEvent
BFC5387C  beq  $v0, $s1, 0xbfc5365c
BFC53888  lw   $a0, -0x4ddc($a0)      ; event 3
BFC5388C  jal  0xbfc58b60             ; TestEvent
```

**Three kernel events, polled in a loop, forever.** The neighbouring hot bucket `0xBFC58B40` is
the same trampoline block (its entries are `$t1` = `0x0C` EnableEvent, `9` CloseEvent, `0x0B`
TestEvent), and `0x00000080` being hot is the PS1 general exception vector --- interrupts are
being taken normally, so the machine is healthy and simply **waiting**.

### The complete chain

```
the PS1 boots the BIOS, loads the game, runs its own code in main RAM
  -> the game calls a BIOS service
     -> the BIOS parks polling three kernel events with TestEvent
        -> those events are never delivered
           -> the game never resumes, so it never draws again
              -> only type-8 sync packets reach the GP0 ring
                 -> the GPU SPUs idle in their poll loop
                    -> the display framebuffer never receives an image
```

The question this document spent several sections on --- *"why does the GP0 handler never
fire?"* --- was **two layers too low.** The handler is registered correctly and the dispatch is
fine; nothing is being drawn to dispatch.

### The CD-ROM is the strongest candidate

Stated as a candidate, not a conclusion:

* three events polled together is the shape of the BIOS CD driver's wait (complete /
  data-ready / error)
* the game had just finished loading its title and intro assets into VRAM --- car sprites,
  vehicle art, title letters --- so a *further* read is exactly what it would do next
* the storage path is live but may not be completing (syscall 540: 3,265 calls, 604: 281)

Confirming it means reading which event **classes** those three descriptors hold. Those are
runtime values in PS1 kernel RAM around `0xA000B21C`, so it is a memory read rather than a
disassembly --- and the PS1 CD event class is `0xF0000003`.

### The three descriptors are all zero

Reading the three event descriptors the `TestEvent` loop loads --- PS1 kernel RAM `0x0000B21C`,
`B224` and `B228`, from `lui $a0,0xa001` + `lw $a0,-0x4de4($a0)` and its two siblings:

```
[ps1ev] ram=0x00770780  EvCB tbl=0xA000E028 size=448
[ps1ev]   slot 0xB21C handle=0x00000000
[ps1ev]   slot 0xB224 handle=0x00000000
[ps1ev]   slot 0xB228 handle=0x00000000
```

**The read is validated before the result is used** --- the whole lesson of this port applied
for once in the right order. The same probe pulls the PS1 kernel's event-table pointer from the
table-of-tables at `0x0120` and gets `0xA000E028` with size 448: a KSEG1 pointer and exactly 16
EvCB entries of `0x1C` bytes each. That is a correctly formed PS1 kernel structure, so both the
RAM base (`*(TOC-0x79D4)` = `0x00770780`) and the byte-swapped read are right.

The byte order matters and would have been easy to get wrong: the interpreter reads PS1 memory
with `lwbrx`, so PS1 RAM is stored **little-endian** in guest memory. A big-endian read here
would have produced plausible-looking nonsense.

So the zeros are a reading, not a broken probe. **The BIOS is polling three null event handles.**
`OpenEvent` was never called for them, or their storage was never filled --- and a `TestEvent`
loop over null handles can never succeed, which is exactly the forever-wait observed.

### Hedged where it needs to be

* the pc sample that named this loop was a 64-byte bucket (`0xBFC53840`), so the hot code is
  *that bucket* rather than provably these three instructions
* the read was taken at a fixed heartbeat, not at a proven steady state

What is solid: the EvCB table is valid, and those three kernel words are zero.

### The remaining work

Narrow, and independent of the hedge: **what should have written those three slots?** They are
BIOS kernel globals, so the writer is the BIOS routine that opens the events --- most plausibly
during CD driver init. Finding why it never ran, or ran and stored nothing, is the last step.

### CONFIRMED: they are `HwCdRom` events, and `CdInit` never ran

The three zero descriptors are **CD-ROM event handles**. Scanning the BIOS ROM for every access
to those kernel words finds exactly three writers, all storing a call's return value, at
`0xBFC52BF0` / `0xBFC52C30` / `0xBFC52C58`. The code around them:

```
BFC52BB0  lui   $a0, 0xf000
BFC52BB4  ori   $a0, $a0, 3        ; class = 0xF0000003 = HwCdRom
BFC52BB8  addiu $a1, $zero, 0x10   ; spec
BFC52BBC  addiu $a2, $zero, 0x2000 ; mode = EvMdNOINTR (poll, no callback)
BFC52BC0  jal   0xbfc58b30         ; OpenEvent
BFC52BD0  sw    $v0, -0x4de8($at)
...  repeated for spec 0x20, 0x40, 0x80, 0x8000  ...
BFC52C54  jal   0xbfc58b40         ; EnableEvent on each
BFC52C58  sw    $v0, -0x4dd8($at)
```

and the callee is confirmed by its own trampoline:

```
BFC58B30  addiu $t2, $zero, 0xb0
BFC58B34  jr    $t2
BFC58B38  addiu $t1, $zero, 8      ; B-table 0x08 = OpenEvent
```

`0xF0000003` is **`HwCdRom`**. So this routine --- entry ~`0xBFC52B9C`, with no direct `jal`
callers in the ROM, i.e. a BIOS service reached through the kernel jump tables, which makes it
`CdInit` / `_96_init` --- opens five `HwCdRom` events in `EvMdNOINTR` mode and enables them.

**And the handles are zero, which means that routine never ran.** A successful `OpenEvent`
returns `0xF1000000 | index`; a failure returns `-1`. Zero is neither, so this is not a failed
`OpenEvent` --- the store never executed.

### The complete root cause

```
the game calls a BIOS CD routine that waits on the HwCdRom events
  -> but CdInit never ran, so those handles are still zero
     -> TestEvent over null handles can never succeed
        -> the BIOS spins at 0xBFC53840 forever
           -> the game never resumes and never draws again
              -> only type-8 sync packets reach the GP0 ring
                 -> the GPU SPUs idle; the framebuffer stays as it was
```

### What this does *not* say

The PS1 clearly loaded the game off the disc --- it is executing game code in main RAM --- so CD
reads worked at least once. Either that path does not go through these events, or they were
opened and later closed. Stating that explicitly because the temptation here is to declare "the
CD is broken", and it demonstrably is not.

**The next step** is to determine whether `CdInit` is ever entered at all. That is a call-site
question in the emulator's BIOS-call dispatch --- the A/B/C jump tables at `0xA0`/`0xB0`/`0xC0`
--- rather than another guess.

### All five slots are zero: `CdInit` never ran at all

Reading every slot `CdInit` fills, not just the three the poll loop reads:

```
[ps1ev] ram=0x00770780  EvCB tbl=0xA000E028 size=448
[ps1ev]   slot 0xB218 handle=0x00000000
[ps1ev]   slot 0xB21C handle=0x00000000
[ps1ev]   slot 0xB220 handle=0x00000000
[ps1ev]   slot 0xB224 handle=0x00000000
[ps1ev]   slot 0xB228 handle=0x00000000
```

All five. The routine at `0xBFC52B9C` issues its five `OpenEvent` calls in a straight line with
no branches between them, so a partial run would leave a **mix** --- some handles set, some
zero. Five zeros means it never executed a single one.

That distinction was worth one more run: *"CdInit failed partway"* and *"CdInit was never
entered"* need completely different investigations, and only the second is consistent with this.

### The root cause, with nothing inferred on top of it

```
the BIOS routine that opens the HwCdRom events never runs
  -> all five handles stay zero
     -> the game's BIOS CD wait polls null handles with TestEvent
        -> it can never succeed, so the game never resumes
           -> nothing is drawn; only type-8 sync packets reach the GP0 ring
              -> the GPU SPUs idle and the framebuffer never updates
```

### Next

Find out whether `CdInit` is entered at all, and from where. It has no direct `jal` callers in
the ROM, so it is reached through the kernel's A/B/C jump tables at `0xA0`/`0xB0`/`0xC0` ---
which makes this a question about that dispatch, or about whether the game ever asks for it.
Both are answerable by watching the R3000's pc for entry to `0xBFC52B9C`, and the
`PS1_R3000_PC` probe already has the machinery.

### Store watch: the slots are written only by `memset`, always to zero

A store watch on the five `HwCdRom` handle slots (PS1 kernel `0xB218..0xB228` = guest
`0x0077B998`, watching `0x0077B990 +0x30`):

```
[ww] 0x0077B998 <- 0x0 (w4) guest-fn=0x000A7FB4
[ww] 0x0077B99C <- 0x0 (w4) guest-fn=0x000A7FB4
[ww] 0x0077B990 <- 0x0 (w4) guest-fn=0x000A7FB4
...  the same block again, repeatedly  ...
```

Every write is zero, every writer is `func_000A7FB4` --- **memset** --- and the burst repeats.
So PS1 kernel RAM around the event table is cleared over and over, and nothing ever writes a
real handle there. That closes the loop with the earlier read: all five slots are zero because
the only thing that ever touches them is a memset.

### Methodology, because I nearly published the opposite

The first run of this watch printed **nothing**, and I was about to record *"no writes at
all"* --- which would have pointed the whole investigation somewhere else.

Before writing it down I pointed the same watch at the R3000's instruction counter --- a field
I had watched climb past a billion, so it is certainly written. **That printed nothing either.**
The probe, not the system.

The fault was mine and trivial: the watch prints `[ww]` and I was grepping for `[WW]`. A
case-sensitive grep, and it would have become the tenth entry in the table above. The control
run cost sixty seconds and caught it.

That is the discipline this port has been paying for all session, working correctly for once:
**before concluding "X never happens", make X happen on purpose and check the probe reports
it.**

### Still open

Which routine issues the memset, and whether it is the emulator re-initialising the PS1 kernel
area *periodically* --- which would wipe any events `CdInit` had opened --- or simply the
one-time boot clear, observed repeatedly across the watch window. `LBP_WW_CHAIN` did not produce
a caller chain under the tag tried; finding the right one is the next step rather than another
guess.

### Uncapped: confirmed, and "repeatedly" corrected to "twice"

That store watch ran with `LBP_WW_MAX=40`, and memset bursts of 12 words could easily have
consumed the cap before any real handle write --- which would have made *"nothing ever writes a
real handle"* a cap artifact rather than a reading. Re-run uncapped:

```
total watch hits: 24
NON-ZERO writes:  (none)
distinct writers: 24  guest-fn=0x000A7FB4
```

24 hits in the entire run, every one from memset, every one zero. **The conclusion survives, and
this time it is established rather than assumed.**

It also corrects the previous section's own wording. It said the region is cleared "over and
over" and that the burst "repeats" --- but 24 hits over a `0x30` window is exactly **two** passes
of 12 words. The region is memset twice, during init, and never touched again. What looked like a
repeating pattern was two bursts read as many, from a truncated head of the log.

### Established, uncapped

```
the region is cleared twice at init and never written again
  -> all five HwCdRom handles are zero for the whole run
     -> CdInit never runs at all
        -> the game's BIOS CD wait polls null handles with TestEvent
           -> it can never succeed; the game never resumes or draws
```

Both of the last two findings needed a control or an uncapped re-run to stand, and in both cases
the check changed something: the first found the probe silent because of a case-sensitive grep,
this one narrowed "repeatedly" to "twice". Neither changed the conclusion --- which is the useful
outcome --- but neither was safe to publish without it.

## The event system works. One event is open, and it is `HwDMAC`, not `HwCdRom`.

Dumping the whole PS1 kernel EvCB table rather than just the five CD slots changes the target.

```
[ps1ev] EvCB[ 0] class=0xF0000009 status=0x00002000 spec=0x00000020
                 mode=0x00002000 func=0x00000000
[ps1ev] 1 of 16 EvCB entries in use
```

* **The event system is up and working.** One event is open. The table pointer was already known
  good (`0xA000E028`, 448 bytes = 16 entries of `0x1C`); now the contents confirm the kernel can
  and does open events.
* class `0xF0000009` is **`HwDMAC`**, not `0xF0000003` `HwCdRom`.
* status `0x2000` is enabled-and-waiting; mode `0x2000` is `EvMdNOINTR` and `func` is 0, so it is
  **polled** rather than callback-driven.
* spec `0x20` selects the DMA channel.

### This is a different fault from the one the last several sections converged on

"`CdInit` never ran" remains true, and the five CD handles really are zero --- but the party
actually blocked is waiting on a **DMA completion event**, and it *did* open that event properly.
It is not waiting because it failed to register; it is waiting because the event is never
delivered.

**And event delivery is our side of the line.** On real hardware a DMA completion raises IRQ3,
the BIOS ISR runs, and it calls `DeliverEvent(HwDMAC, spec)`. If the emulated DMA completes
without raising that interrupt --- or the interrupt is raised but never reaches `DeliverEvent`
--- an `EvMdNOINTR` waiter polls forever, which is exactly the observed shape.

### Which reframes the target usefully

Instead of chasing why the guest never calls `CdInit` (a guest control-flow puzzle with no
obvious handle), the question is whether **our DMA emulation raises the DMA interrupt, and
whether it reaches the BIOS handler.** That is a concrete, checkable gap in code we own, and the
DMA registers are already mapped (`0x1F801080 +0x80` covers every channel plus DPCR and DICR).

Being explicit that this supersedes my own framing twice over: the CD events are a red herring
for the actual stall, and the "`CdInit` never runs" finding --- while correct --- describes a
routine nobody is currently waiting for.

### CORRECTION: class `0xF0000009` is the SPU interrupt, not `HwDMAC`

The section above called the one open event `HwDMAC`, from memory of the PS1 event-class list.
Wrong --- and it did not need to be a guess, because the BIOS's own interrupt dispatcher states
the mapping. At `0xBFC046A0` it reads I_STAT and I_MASK (`$a2` = `0x1F801070`, +0 and +4), ANDs
them, and tests bits:

```
andi $t9, $t8, 4      ; I_STAT bit 2  (CDROM) -> ori $a0,$a0,3     class 3
andi $t3, $t2, 0x200  ; I_STAT bit 9  (SPU)   -> ori $a0,$a0,9     class 9
andi $t7, $t6, 2      ; I_STAT bit 1  (GPU)   -> ori $a0,$a0,2     class 2
andi $t1, $t0, 0x400  ; I_STAT bit 10 (PIO)   -> ori $a0,$a0,0xa   class A
```

Bit 2 mapping to class 3 independently confirms the earlier CD identification, since the CD
event registration used class `0xF0000003`.

PS1 I_STAT bit 9 is the **SPU interrupt**. So the single open, enabled, polled event this title
waits on is the **SPU interrupt event** --- not DMA.

Each dispatch site delivers with `$a1 = 0x1000` (`jal 0xb0001b28` is `DeliverEvent`, in the
kernel image at RAM `0x1B28`), while the open event's spec is `0x20`. Whether that is a genuine
mismatch or a second delivery site is **not established**, and is flagged rather than asserted.

### The target, again on something checkable

Does the SPU emulation ever raise I_STAT bit 9? The SPU register window is registered
(`0x1F801C00 +0x400`) and the BIOS clearly installs a handler for the interrupt. If bit 9 is
never set, an `EvMdNOINTR` waiter on class 9 polls forever --- the observed shape.

### Three guesses in a row, all corrected by reading the image

| I guessed | the image said |
|---|---|
| the framebuffer holds 24-bit data | six palette entries; reading as 24-bit shows no image |
| the stalled waiter is the CD driver | the only open event is not a CD event |
| class `0xF0000009` is `HwDMAC` | the BIOS dispatcher maps it to I_STAT bit 9 = SPU |

Each took a single disassembly to settle, and each had been stated from recall instead. That is
the cheapest lesson available in this port and it took three repeats to land.

## RETRACTION: the blocked waiter is the CD loop, not the SPU event

The two sections above claimed the party actually blocked is waiting on the SPU interrupt event,
on the strength of it being the only open event in the EvCB table. **That was a conflation of
two different facts and it is wrong.**

The loop the pc actually sits in closes back on itself:

```
BFC5384C  lui   $a0, 0xa001
BFC53850  lw    $a0, -0x4de4($a0)     ; CD event slot 0xB21C (zero)
BFC53854  jal   0xbfc58b60            ; TestEvent
...
BFC53888  lw    $a0, -0x4ddc($a0)     ; CD event slot 0xB224 (zero)
BFC5388C  jal   0xbfc58b60            ; TestEvent
BFC538A4  bgtz  $s0, 0xbfc5384c       ; <- branches back to the first one
```

`0xBFC5384C`, `0xBFC53880` and the `0xBFC58B40` trampoline block are exactly the three hottest
64-byte pc buckets, so **this** loop is where the R3000 is. It polls the CD handles, and those
are zero.

*"The only event open in the table"* and *"the event being waited on"* are not the same claim,
and I treated the first as the second. The single open event (class 9, I_STAT bit 9 = SPU) is
almost certainly a normal, healthy SPU init leftover and has nothing to do with the stall.

### The root cause reverts to this, and it was right before

```
BIOS CdInit never runs
  -> all five HwCdRom handles stay zero
     -> the BIOS CD wait loop at 0xBFC5384C polls null handles with TestEvent
        -> it can never succeed; the game never resumes or draws
```

### The pattern, which is now the main finding of the session

This is the **fourth consecutive** conclusion corrected, and this one was mine end to end ---
not a misremembered table but an unjustified inference laid on top of a good measurement. The
EvCB dump was worth doing and its result (one open event, class 9) is solid; what I built on it
was not.

**Every time I moved from "here is what I measured" to "therefore the cause is X" without
measuring X itself, X was wrong.** Four times in a row, each caught only by going back and
reading the code.

That is worth more to whoever picks this up than any single address in these notes: the
measurements in this document are reliable, and the causal claims connecting them should each be
re-derived before being trusted.

## `CdInit` is never entered --- measured, not inferred

"`CdInit` never ran" had been *deduced* from the fact that its five stores never land. Sound but
indirect, and indirect is exactly what produced the last four corrections. So it is now measured
directly: a flag per 64-byte bucket across the whole BIOS (`PS1_PC_CENSUS=1`).

```
[census] 4200000 samples, 55/8192 BIOS buckets ever executed;
         CdInit: BFC52B80=0 BFC52BC0=0 BFC52C00=0 BFC52C40=0
```

`CdInit` spans `0xBFC52B9C..0xBFC52C60`, which is those four buckets. **None is ever set**, across
4.2 million samples and roughly two minutes.

**Two independent measurements now agree** and neither leans on the other:

| measurement | result |
|---|---|
| uncapped store watch on its five slots | 24 hits, all memset, all zero --- its writes never happen |
| pc census over the BIOS | its four buckets are never executed |

### A second result, unlooked for and more useful than the first

**Only 55 of 8192 BIOS buckets are ever executed** --- about 3.5 KB of a 512 KB ROM --- and that
count is **constant from the first report onward**. The set does not grow.

So after boot the R3000 runs a tiny, fixed slice of the BIOS: the poll loop, its interrupt
handler, and nothing else. That is a considerably stronger statement than "the pc is hot at
`0xBFC53840`", because it rules out other BIOS work proceeding somewhere the top-N report was not
showing.

### The honest caveat

Sampling at yields cannot prove absence in general --- a short routine could execute entirely
between two samples. What makes it convincing here is scale plus corroboration: 4.2 million
samples, `CdInit` contains five `jal` calls into `OpenEvent` (each a substantial kernel routine),
and the store watch independently shows its writes never happen.

### Established twice over, by different means

```
BIOS CdInit is never entered
  -> all five HwCdRom handles stay zero
     -> the CD wait loop at 0xBFC5384C polls null handles with TestEvent
        -> it can never succeed; the game never resumes or draws
```

## IDENTIFIED: the stalled call is `CdReadSector`, A(0xA5)

The function the R3000 is stuck in is `0xBFC5361C`, and it is now identified **without relying
on a recalled table** --- which is what went wrong three times earlier in this session.

**Structural evidence.** It appears exactly once as a data word, at `0xBFC4FF24`, inside a
contiguous run of 181 code pointers based at `0xBFC4FC90`. That is the PS1 BIOS **A-table**
(`0xB4` entries), and `0xBFC4FF24` is entry index **`0xA5`**.

**Behavioural evidence**, which is what actually settles it:

```
BFC53638  move  $s5, $a1
BFC53640  move  $s3, $a0
BFC53644  move  $s4, $a2       ; three arguments
BFC5364C  move  $s6, $zero
BFC53650  addiu $s5, $s5, 0x96 ; +150 -- the PS1 CD data-area sector offset
BFC53654  addiu $s1, $zero, 1
BFC53658  slti  $v0, $s6, 0xa  ; retry counter, limit 10
```

Three arguments; the second is a logical sector converted to physical by adding 150 (the standard
two-second lead-in at 75 sectors/s); a ten-retry loop. That is
**`CdReadSector(count, sector, buffer)`**, and the two lines of evidence agree.

Its four direct callers (`0xBFC52E30`, `0xBFC52EE8`, `0xBFC53154`, `0xBFC53518`) are the BIOS's
own file-read paths, so the game may reach it either directly through A(0xA5) or via the BIOS
file API.

### The full picture, every link measured or read

```
ps1_netemu boots the game, and only 55 of 8192 BIOS buckets ever execute
  -> the BIOS's own CD init (CdInit, 0xBFC52B9C) is never entered
     -> its five HwCdRom event handles stay zero
        -> the game calls CdReadSector (A(0xA5)) to read a sector
           -> CdReadSector polls those null handles with TestEvent
              -> it can never succeed; it spins its 10-retry loop forever
                 -> the game never resumes, so it never draws
                    -> only type-8 sync packets reach the GP0 ring
                       -> the GPU SPUs idle; the framebuffer never updates
```

### The load-bearing new fact

**Only 55 of 8192 BIOS buckets ever execute** --- about 3.5 KB of a 512 KB ROM. A real PS1 boot
runs far more BIOS than that. So little running is consistent with ps1_netemu fast-booting the
executable and skipping the BIOS initialisation `CdReadSector` depends on.

Stated as *consistent with* rather than established. Whether ps1_netemu is **supposed** to run
that init, or supposed to intercept `CdReadSector` entirely, is the next thing to determine ---
and that is a question about the firmware's design, answerable by reading how ps1_netemu handles
A-table calls, rather than another guess about symptoms.

## RETRACTION: `CdInit` does execute in some runs --- run variance was the real problem

Extending the census to the BIOS call gates produced a result I was not looking for, and it
retracts the two sections above:

```
[census] 600000 samples, 86/8192 BIOS buckets ever executed;
         CdInit: BFC52B80=0 BFC52BC0=1 BFC52C00=0 BFC52C40=0
         A-gate=0 B-gate=0 C-gate=0 other-low=0
```

**`BFC52BC0=1`.** That bucket spans `0xBFC52BC0..0xBFC52BFF` and contains:

```
BFC52BC0  jal  0xbfc58b30      ; OpenEvent (2nd call)
BFC52BD0  sw   $v0, -0x4de8($at)
BFC52BE0  jal  0xbfc58b30      ; OpenEvent (3rd call)
BFC52BF0  sw   $v0, -0x4de4($at)
```

So `CdInit`'s `OpenEvent` calls and handle stores **do** execute. *"CdInit is never entered,
measured two ways"* is wrong.

### And the reason is the one I identified early and then kept forgetting

This run reached **86** BIOS buckets; the previous reached **55**, and printed seven census lines
against this one's single line. The two runs diverge in both how far they get and how much they
execute.

**Every "never happens" claim in this document was measured on one run, and the runs are not
equivalent.**

| claim | the run it was measured on |
|---|---|
| store watch shows only memset writes | a 55-bucket run, which plausibly never reached `CdInit` |
| all four/five handle slots are zero | a different run, read at a fixed heartbeat |
| `CdInit`'s buckets are never set | a third run |

None of them is wrong *about the run it observed*. All of them were written up as properties of
the port.

### The honest state, narrower than claimed

In at least some runs `CdInit` partially executes, and whether the CD handles end up valid is
**run-dependent**. Establishing anything further requires capturing the census, the handle read
and the store watch **in the same run** --- which is exactly the discipline that fixed the
VRAM-versus-surface comparison earlier in this document, and which I did not carry forward to
this question.

### Why this one matters more than the others

Sixth correction this session, and the only one whose cause is **general rather than local**:
single-run absence claims are not sound in this port. The variance was documented in these notes
*before* I started relying on single runs anyway.

Anyone continuing here should treat every unqualified "never" above as "not in the run I
sampled", and re-measure with all probes in one run before building on it.

## RETRACTION, seventh: the CD event handles are VALID. `CdInit` runs fine.

Reading the five handles from the **same report as the pc census** --- rather than from the
render heartbeat on another thread at another moment --- gives:

```
[census] 600000 samples, 79/8192 BIOS buckets ever executed;
         CdInit: BFC52B80=0 BFC52BC0=1 ...
         handles: F1000007 F1000008 F1000009 F100000A F100000B
```

Five well-formed PS1 event handles, `0xF1000000|index`, indices 7..0xB --- five consecutive EvCB
entries. **`CdInit` ran and opened all five `HwCdRom` events. It works.**

### What that invalidates in this document

* *"the three descriptors the BIOS polls are all ZERO"*
* *"all five `CdInit` slots are zero --- it never ran at all, not partially"*
* *"`CdInit` is never entered --- measured, not inferred"*
* *"the event system works: one event is open, and it is `HwDMAC`"* --- that read saw one entry
  because it ran *before* `CdInit` had opened the CD five
* the entire *"`CdInit` never runs"* root-cause chain built on top of them

Every one of those reads came from the **render heartbeat**, which runs on the present thread on
its own schedule and in practice fires **early**, before the guest reaches `CdInit`. The store
watch agreed with them for the same reason: it only ever saw the boot-time memset.

The fix was to read the handles from the same probe, at the same instant, as the census --- the
discipline the previous section identified as necessary, and which had already worked once in
this document for the VRAM-versus-surface comparison. **One run, one moment, all facts together.**

### The actual state

```
CdInit runs; all five HwCdRom events are open and enabled
  -> CdReadSector (A(0xA5)) polls them with TestEvent
     -> they are never DELIVERED, so the poll never succeeds
        -> the game never resumes, never draws
```

Which puts the target back where it briefly was many sections ago, before the derail: **the
CD-ROM interrupt.** I_STAT bit 2 must set, the BIOS ISR must run, and it must call
`DeliverEvent(0xF0000003, spec)`. The events exist and are waiting; nothing fires them.

### The lesson, stated once more because it has now cost seven retractions

Reading two facts from two different probes on two different schedules is not one observation. It
produced: the VRAM/surface mismatch, the "all surfaces black" artifact, the "24-bit framebuffer"
hypothesis, the `HwDMAC` misidentification, the CD-handles-are-zero chain, and this. **Put every
probe that must be compared into one report at one instant, or do not compare them.**

## ROOT CAUSE, one report one instant: the CD interrupt never reaches the BIOS ISR

Applying the discipline the last two sections identified --- every fact that must be compared
read by the same probe at the same moment --- gives a single coherent picture:

```
[census] 600000 samples, 85/8192 BIOS buckets ever executed;
         CdInit: BFC52B80=0 BFC52BC0=1 BFC52C00=0 BFC52C40=0
                 BFC04680=0 BFC046A0=0
         handles: F1000007 F1000008 F1000009 F100000A F100000B
         ev[cls/status]: 3/2000 3/2000 3/2000 3/2000 3/2000
```

Four facts, one instant:

1. **`CdInit`'s `OpenEvent` block executes** (`BFC52BC0=1`).
2. **All five handles are valid** (`0xF1000000|7..0xB`).
3. **All five EvCBs are class 3 (`HwCdRom`) with status `0x2000`** --- `EvStACTIVE`, open and
   waiting. *None* is `0x4000` (`EvStALREADY`, delivered-not-yet-consumed).
4. **The BIOS interrupt dispatcher's CD branch never executes.** `0xBFC046A0` is where it reads
   I_STAT/I_MASK and tests bit 2 before calling `DeliverEvent(0xF0000003)`; that bucket is unset,
   as is the one before it.

So the CD event machinery is **entirely correct on the guest side** --- opened, enabled, waiting
--- and the PS1 CD-ROM interrupt never arrives to fire it. `CdReadSector` (A(0xA5)) polls five
events that nothing will ever deliver.

```
ps1_netemu never raises the PS1 CD interrupt (I_STAT bit 2)
  -> the BIOS interrupt dispatcher's CD branch never runs
     -> DeliverEvent(HwCdRom, ...) is never called
        -> all five events stay EvStACTIVE forever
           -> CdReadSector's TestEvent poll can never succeed
              -> the game never resumes, never draws
                 -> only type-8 sync packets reach the GP0 ring
```

### The caveat, and why it holds anyway

Sampling cannot prove absence: `BFC046A0=0` means no sample landed in that bucket, and the ISR is
short enough to be missed. What makes it sound here is that **fact 3 corroborates fact 4
independently** --- if the CD branch had ever run, `DeliverEvent` would have set an event to
`0x4000`, `CdReadSector` would have consumed it and progressed. It has not, in any run.

Two independent facts in the same report, agreeing. **That is the first root-cause claim in this
document built the way it should have been built from the start.**

### The target

The CD hardware emulation. `0x1F801800 +0x10` is registered as an I/O window, so something inside
ps1_netemu owns the CD controller, and completing a command must set I_STAT bit 2.

## The CD interrupt IS raised and unmasked --- it is never DELIVERED to the guest

Sampling and OR-ing the emulated I_STAT/I_MASK instead of store-watching them gives the complete
picture in one report:

```
[census] 600000 samples, 85/8192 BIOS buckets ever executed;
         CdInit: BFC52B80=0 BFC52BC0=1 ... BFC04680=0 BFC046A0=0
         handles: F1000007 F1000008 F1000009 F100000A F100000B
         I_STAT_or=0000000D I_MASK_or=0000000D
         ev[cls/status]: 3/2000 3/2000 3/2000 3/2000 3/2000
```

`I_STAT_or = 0x0D` is bits 0, 2 and 3: VBLANK, **CDROM** and DMA. `I_MASK_or = 0x0D` too. So the
CD interrupt bit **is** set, and it **is** enabled in the mask.

### That retracts the previous section

*"Only VBLANK is ever raised, never bit 2"* came from store-watched runs, and the watch costs a
check on every `vm_write32` --- watched runs reach 23 BIOS buckets against 79--87 unwatched, so
they never got far enough to touch the CD at all. **Same observer effect as the framebuffer dump,
third time in this port.** Sampling and OR-ing is free and answers the same question, which is
why it was the right instrument.

### What remains, and it is now precise

| fact | value |
|---|---|
| I_STAT bit 2 raised | yes (`I_STAT_or` has `0x4`) |
| I_MASK bit 2 enabled | yes (`I_MASK_or` has `0x4`) |
| BIOS dispatcher's CD branch executes | **no** (`0xBFC046A0` unset) |
| any CD event reaches `EvStALREADY` | **no** --- all five stay `0x2000` |

So the CD interrupt is asserted and unmasked, and the R3000 never takes it as an exception ---
or takes it and the handler never reaches the bit-2 test. Either way `DeliverEvent(HwCdRom)` is
never called, and `CdReadSector` polls five events that will never fire.

The two independent facts still agree: the dispatcher's CD bucket is unsampled **and** no event
ever leaves `EvStACTIVE`. If the branch had run even once, `DeliverEvent` would have moved an
event to `0x4000` and the poll would have consumed it.

### The target

**R3000 interrupt delivery, not the CD controller.** Something has to turn
`I_STAT & I_MASK != 0` into a MIPS interrupt exception on the emulated CPU, with Cop0 SR/CAUSE
set so the BIOS handler runs and dispatches. That is far narrower than the CD hardware, and it
sits squarely in the interpreter.

### On instruments

Eighth correction --- and the first time the instrument was chosen for **not perturbing the thing
it measures**. That is what finally made the whole picture visible in one report, after three
separate observer-effect artifacts (the framebuffer dump, the surface dumps, and this).

## RETRACTION, ninth: the interrupt path is complete, and I probed the wrong ISR copy

Two things, both caught **before** publishing this time.

### The interrupt path is fully implemented

*"The R3000 never takes the interrupt"* is wrong. The assert path in `func_001063AC` is only half
of it --- the interpreter's own `mtc0 $12` (Cop0 SR) handler re-checks:

```
00108168  stw    r9, 0xb0(r23)            ; SR = new value
0010816C  cmpwi  cr7, r0, 0               ; r0 = SR & 1 (IEc)
00108170  beq    cr7, 0x106888            ; disabled -> continue
00108174  and    r0, r10, r9              ; CAUSE & SR
00108178  rlwinm r9, r0, 0, 0x10, 0x17    ; (SR & CAUSE) >> 8 & 0xFF
0010817C  cmpwi  cr7, r9, 0
00108180  beq    cr7, 0x106888            ; nothing pending -> continue
00108194  stw    r0, 0x138(r23)           ; reason = 0
00108198  b      0x106800                 ; exit to take the interrupt
```

So a CD interrupt asserted while interrupts were masked is **not** lost --- writing SR to
re-enable them re-evaluates it. I was about to commit *"nothing re-checks, so the interrupt is
dropped"*; searching for other copies of the `SR & CAUSE` test found this one, plus copies at
`0x00106614`, `0x00106674` and `0x00105858`. The mechanism is present in every place it needs to
be.

### And my own measurement was invalid

The census probes `0xBFC04680`/`0xBFC046A0` --- the **BIOS ROM** copy of the interrupt
dispatcher. The PS1 kernel **copies its exception handler into low RAM** at boot, and the copy
that runs is the RAM one.

So *"BFC046A0=0, the ISR's CD branch never executes"* says nothing at all --- it was always going
to be zero. And `0x00000080`, the PS1 general exception vector in RAM, measured hot at 1.8% in an
earlier run, so exceptions **are** being taken and the handler **is** running.

**The specific lesson is new: probing a ROM address for code that runs from a RAM copy is
guaranteed to read zero.** The same trap applies to every BIOS-ROM bucket in the census --- "55
to 87 of 8192 ever executed" is a count of *ROM* execution only, and the kernel's RAM-resident
routines are invisible to it. Several conclusions in this document rest on that count.

### What survives

Exactly one fact, and it is still the right target:

**All five `HwCdRom` events stay `EvStACTIVE` (`0x2000`) and never reach `EvStALREADY`
(`0x4000`). `DeliverEvent` is not firing them.**

Everything built around it --- `CdInit` never running, the interrupt never raised, the interrupt
never taken, the ISR never dispatching --- has now been retracted in turn.

## THE ACTUAL OBSTACLE: run variance, not the CD, the GPU, or the events

Conditioning the R3000 register read on the pc actually being inside `CdReadSector`
(`0xBFC5361C..0xBFC538B0`) gives:

```
in_cdloop=0  ev[cls/status]: 3/2000 3/2000 3/2000 3/2000 3/2000
```

**Zero samples inside the loop** --- in a run where the five CD events exist and are
`EvStACTIVE`. But an earlier run measured **4.4% of samples at `0xBFC53840`**, which is inside
that exact range.

So *"the PS1 is stuck in the CD poll loop"* is also run-dependent. It is the tenth observation
this session that held for the run it was taken on and not in general.

### The pattern, stated as the conclusion it deserves

| run | BIOS ROM buckets | CD handles | in CD loop | VRAM non-zero |
|---|---|---|---|---|
| A | 23--24 | zero | --- | --- |
| B | 55 | zero | --- | 75,527 |
| C | 79--87 | `F1000007..B` | yes (4.4%) | --- |
| D | 85 | `F1000007..B` | **no (0)** | --- |

Same binary, same command line, no input. **Four materially different behaviours.**

Every root cause proposed and retracted in this document --- `CdInit` never runs, the interrupt
is never raised, the interrupt is never taken, the ISR never dispatches, the framebuffer is
24-bit, the waiter is the SPU event --- was a single-run observation generalised. Nine
retractions, one cause.

### So the next piece of work is not another diagnosis

It is either making the port deterministic, or characterising the variance well enough that a
measurement can be attributed to a run class. Until then every *"X never happens"* costs a lap
and yields a retraction, which is empirically what the last ten laps produced.

Concrete first steps, in order:

1. **Log a run-class fingerprint** at startup and on each census line --- thread creation order,
   the order the SPUs reach their first mailbox, whether `ISO.BIN.EDAT.dec` opened before or
   after `cellGcmInit`. The runs differ from early on; the divergence point is findable.
2. **Serialise the identified race.** The prime suspects are already documented in these notes:
   five raw SPUs racing their init handshake, and the RSX ISR queue being published
   (`sys_rsx.c`) concurrently with the guest's ISR thread starting.
3. **Only then** resume the CD event question --- with all probes in one run, each self-validated.

### The one instrument this session got right first time

`PS1_R3000_PC=1` + `PS1_PC_CENSUS=1` now latches the CD loop's registers **only** on samples
taken inside the loop, and prints `s1!=1, PROBE INVALID` if the register offset is ever wrong
(the loop sets `$s1 = 1`, so a correct read must show 1). It rejected its own first output. Every
probe in this port should have been built that way.

## Init ordering is DETERMINISTIC --- the variance is progress rate, not a race

The section above proposed serialising an init race as the next step. That was a guess, and
measuring it first says **there is no ordering race to serialise.**

Three runs, marker sequence extracted from the existing logs --- no code change needed:

```
 1  sys_rsx] gcm ISR queue          9  spu-raw] create -> raw spu 3
 2  spu-raw] create -> raw spu 0   10  spu-raw] spu3 START
 3  intr] tag 0x52000002           11  spu-raw] create -> raw spu 4
 4  spu-raw] spu0 START            12  intr] tag 0x52000402
 5  spu-raw] create -> raw spu 1   13  spu-raw] spu4 START
 6  spu-raw] spu1 START            14  cellAdec] Open(
 7  spu-raw] create -> raw spu 2   15  ISO.BIN.EDAT.dec
 8  spu-raw] spu2 START
```

**Byte-identical ordering in all three.** RSX ISR queue publication, all five raw SPU creations
and starts, both interrupt tag establishments, cellAdec Open and the disc open happen in the same
sequence every time. The only difference is that one run also reached a census line.

### So the four "distinct behaviours" are probably one trajectory sampled at different depths

| run | state | position |
|---|---|---|
| A | 23--24 buckets, no CD handles | earliest |
| B | 55 buckets, no handles, VRAM 75k | middle |
| C | 79--87 buckets, handles valid, in CD loop | late |
| D | 85 buckets, handles valid, not in loop | late, different instant |

Ordered that way it reads as **progress, not divergence**. And it makes the CD-loop finding
recoverable rather than refuted: `in_cdloop=0` in run D is consistent with sampling a late run at
a moment when the pc happened to be elsewhere, not with the loop being absent.

### Which also kills my own proposed next step

*"Serialise the SPU init handshake race"* and *"serialise the RSX ISR queue publication"* were
both named as prime suspects one section ago. **Neither is supported** --- those events are
ordered identically every run. Proposing them was the same error as everything else in this
document: a plausible mechanism asserted without measuring it. It took one zero-code measurement
to rule out.

### What is actually still open

Why runs advance at such different rates in the same wall-clock window, and whether the
frozen-instruction-count runs recorded earlier are a genuine stall or just the slow end of that
spread. That is answerable by plotting `+0x124` against wall time across several runs, and needs
no new instrumentation.

## TWO SEPARATE BUGS: an early hard stall (1 run in 3), and the CD wait in healthy runs

Plotting instructions retired (`+0x124`) against wall time across three runs finally separates
what this document has been conflating throughout:

```
run1  5.6M 16.4M 27.7M 39.0M ... 196.7M 208.0M    linear, no stall
run2  5.1M 13.2M 13.2M 13.2M ... 13.2M  13.2M     HARD STALL at 13.2M
run3  5.1M 15.8M 27.2M 38.5M ... 195.6M 206.9M    linear, no stall
```

Two clean classes, **not** a spectrum:

* **Class A (2 of 3)** --- continuous, ~11.3M instructions per 5-second heartbeat, dead steady in
  both runs, past 200M and still climbing at timeout. Never stalls.
* **Class B (1 of 3)** --- advances to ~13.2M then **freezes**: the same value for 17 consecutive
  heartbeats, about 85 seconds. A genuine deadlock, not slowness. That answers the question the
  previous section left open.

### And it reconciles every flipping measurement in this document

The stall at 13.2M lands **early** --- well before the point where `CdInit` runs and the CD
handles get filled. So:

| run class | what it looks like | which of my readings came from it |
|---|---|---|
| stalled (13.2M, 23--55 ROM buckets, handles zero) | deadlocked before reaching the CD code | *"the handles are zero"*, *"CdInit never runs"*, *"the events are never opened"* |
| healthy (200M+, 85 ROM buckets, handles `F1000007..B`) | reaches the CD wait | the `EvStACTIVE` events, the type-8-only GP0 ring |

I had been sampling both classes interchangeably and treating the results as one system.
**That is the single mechanical cause behind nine retractions, and it took one plot to see.**

### So there are two bugs, needing separate work

1. **An early hard deadlock at ~13.2M R3000 instructions**, reproducible in roughly one run in
   three. Diagnosable now: loop the run until the totals plateau, then inspect *that* process ---
   host stacks for every thread, the R3000 pc, the SPU channel states. Every probe needed already
   exists; what was missing was knowing which runs to point them at.
2. **In healthy runs, the game reaches `CdReadSector` and its five `HwCdRom` events never leave
   `EvStACTIVE`.** That is the real content of the earlier root-cause chain, and it stands ---
   but only for class A runs.

**Bug 1 first.** It is reproducible, it is a hard deadlock with a known signature to trigger on,
and until it is fixed a third of all measurements are taken from a dead process.

## Bug 1 caught in the act: the stalled run spins yield from a `bctr`-dispatched handler

Looped the run until a class-B stall was caught (attempt 3 of 6: 18 heartbeats, 2 distinct
totals, frozen at 14,407,680 instructions), then read the last syscall per thread from **that**
process:

```
tid=1  n=59443  num=43  lr=0x00106824  a4=0xFFFFFFFFFFFFFFFE
tid=3  n=29     num=540 lr=0x00000000
tid=6  n=272    num=130 a3=0x4   (flip thread, normal)
tid=8  n=6      num=92  a3=0x4 timeout=200000us
tid=9  n=250    num=130 a3=0x3   (normal)
```

Everything else is idle and healthy. **tid=1 --- the guest thread running the R3000 --- issues
`sys_ppu_thread_yield` 59,443 times while the instruction counter does not move.** That is the
stall, measured on a run *confirmed* to be stalled rather than assumed.

### Where it is, and why `lr` needs care

`lr=0x00106824` is the return address of `bl 0x105fa8` at `0x00106820`:

```
001067F8  li   r0, 0xb
001067FC  stw  r0, 0x138(r23)   ; reason = 0xB
00106820  bl   0x105fa8         ; the event scheduler
00106824  lwz  r4, 0x138(r23)   ; reason
00106830  bne- cr7, 0x106904    ; reason != -1 -> leave the interpreter
```

But `func_00105FA8` spans `0x105FA8..0x106098` and contains **no `bl` and no `sc`**, and there is
**no `sc` anywhere in the interpreter** (`0x1066A8..0x108348`) either. So the yield is executed by
neither the interpreter nor the scheduler.

The explanation is the dispatch mechanism: the interpreter reaches each R3000 opcode handler
through **`bctr`** (the jump table at `0x1B37D4` --- the same table whose absence was the first
bug fixed in this port). `bctr` does not write `lr`, so a handler inherits whatever the last `bl`
left there. **An opcode handler is issuing the yield**, with `lr` still pointing at the scheduler
call.

> **Worth recording independently of this bug:** in this interpreter, `lr` on a syscall names the
> last **call** the guest made --- never the code that made the syscall --- because every opcode
> handler is *jumped* to. Reading it as a caller address, which this document has done
> repeatedly, is wrong by construction.

### So Bug 1 is

An R3000 opcode handler, reached by `bctr`, yields repeatedly without retiring an instruction. It
is now **reproducible on demand** (roughly one run in three; the catch script loops until the
totals plateau) and isolated to a single thread in a process where nothing else is wedged.

Finding *which* handler needs the dispatched target, not `lr`: the jump-table index comes from
the opcode field of the instruction at the R3000 pc, and the pc lives in `r26` during the loop.
Capturing `ctr` or the table index at the yield would name it outright.

## BUG 1 CHARACTERISED: the R3000 is pinned on one `ADDIU`, budget never granted

Caught a genuine stall (plateau at 13,658,112 instructions, non-zero, first attempt) and read
the probes from **that** process:

```
[yieldop] 10800000 yields; ctr=0x000D2298; top R3000 opcodes: op09=200000
[census]  47/8192 BIOS buckets; handles all zero;
          I_STAT_or=00000001 I_MASK_or=00000009
          SR_or=00410405 CAUSE_or=00000420 line_or=1
totals    13658112 13658112 13658112 13658112
```

**Every yield is at R3000 opcode `0x09` --- `ADDIU`** --- 200,000 of 200,000 in every report,
across 10.8 million yields, with the instruction counter frozen. Not a mix, not a distribution:
one opcode, always.

That is not a wait for anything external. The interpreter is repeatedly looking at the same next
instruction --- a plain `ADDIU`, the simplest op there is --- and never executing it. Which points
straight at the budget gate in its outer loop:

```
001068DC  bgt  cr7, 0x106890   ; budget > 0 -> execute instructions
001067F8  li   r0, 0xb         ; else reason = 0xB
00106820  bl   0x105fa8        ; ask the scheduler for a new budget
                               ; -> yield, retry, forever
```

`func_00105FA8` is a leaf (no `bl`, no `sc`, `0x105FA8..0x106098`) that computes the budget from
the event list. In a stalled run it returns zero every time, so the interpreter livelocks on the
gate without ever retiring the instruction in front of it.

### So Bug 1 is

**In roughly one run in three, the R3000 event scheduler stops granting an instruction budget,
and the interpreter livelocks on the budget gate.**

"Budget 0" appeared in these notes many sections ago and was dismissed as a sampling artifact ---
*correctly at the time*, because it was measured on healthy runs where budget 0 is a normal
transient. On a confirmed stalled run it is the whole story. The same observation, worthless from
one run class and decisive from the other.

### A second difference, healthy versus stalled

```
healthy   SR_or=40410405   I_STAT_or=0000000D  (VBLANK|CDROM|DMA)
stalled   SR_or=00410405   I_STAT_or=00000001  (VBLANK only)
```

The stalled run never sets **SR bit 30** (`0x40000000`, Cop0 CU2 --- the GTE enable) and never
raises the CD interrupt. Whether the missing CU2 is cause or consequence is **not established**;
it is a clean discriminator either way, and the first structural difference found between the two
run classes.

`ctr=0x000D2298` is constant in both classes and is **not** an opcode handler (those live at
`0x106xxx`--`0x108xxx`). Like `lr`, `ctr` persists across `bctr`-free stretches, so it names some
earlier indirect call, not the yielding code. Recorded so the next reader does not chase it.

## BUG 1 ROOT CAUSE: an always-due event --- the scheduler never returns, it loops

Reading `func_00105FA8` in full (72 instructions, a leaf) corrects the section above and finishes
Bug 1.

```
00105FBC  lwzu r6, 0x540(r30)   ; r6 = event list head
00105FC0  lwz  r0, 0x124(r3)    ; total
00105FCC  subf r29, r4, r0      ; now = total - consumed
00105FD8  lwz  r9, 8(r7)        ; head event's DUE TIME
00105FE0  subf r3, r29, r9      ; time until due
00105FE8  bgt  cr7, 0x106070    ; > 0 -> return it as the budget
; else, from 0x105FF0: unlink the node, then
00106000  stw  r9, 0x124(r31)   ; total := the event's due time
00106008  stw  r28, 0x120(r31)  ; budget := 0
00106050  bctrl                 ; fire the event's callback
00106064  subf r3, r29, r9      ; recompute against the NEW head
0010606C  ble  cr7, 0x105ff0    ; still due -> loop and fire again
00106070  ...                   ; return r3 (always > 0 here)
```

**The scheduler cannot return zero.** It exits only via `0x106070`, and both paths there require
`r3 > 0`. So *"the scheduler stops granting a budget"* --- the previous section's conclusion ---
is not the mechanism. **It never returns at all.**

### The real mechanism

An event whose due time never advances past `now`. The loop at `0x105FF0..0x10606C` unlinks it,
sets total to its due time, fires its callback, re-reads the head, finds it still due, and goes
round again. Forever.

Which matches the measured signature point for point:

| measured | explained by |
|---|---|
| total **frozen** at 13,658,112 | `0x106000` assigns `total = due time` every iteration, pinning it to that event's timestamp |
| millions of yields | the callback at `0x106050` yields; the loop calls it without limit |
| every yield at the same opcode (`ADDIU`) | the pc never moves, so the instruction in front of the interpreter is always the same one |

The opcode was never the point --- it was a symptom of the pc being frozen.

### And it vindicates a hypothesis I refuted fifteen sections ago

*"An always-due event in the scheduler"* was proposed early in this document, then dismissed
with *"refuted by timestamps: ~1.8 MIPS for 30 ms then a hard stop"*. **That refutation used a
healthy run**, where the scheduler behaves normally.

The hypothesis was right for stalled runs the whole time, and the measurement that killed it came
from the wrong class of run. Same mistake as everything else here --- but this one cost the most,
because it discarded a correct answer and sent the investigation into the GPU, the CD and the
event system for twenty laps.

### What remains for Bug 1, and it is narrow

**Which event, and why does its due time not advance?** The node layout is now known from this
code:

```
+0x00  next        +0x0C  flag cleared on fire
+0x04  prev        +0x10  callback OPD
+0x08  due time
```

The list head is at `state+0x540`. Dumping the head node's due time and callback OPD on a caught
stall names the culprit outright, and the OPD maps straight to a function through the existing
lookup.

## IT BOOTS TO A PLAYABLE MENU --- and Bug 1 is a PPU/SPU deadlock, not an event

Two things changed at once: the port got a lot further than these notes said,
and the stall that hides behind it is now measured on both sides.

### What it actually does now

Screenshots taken from the running window (`tools/shotseq.sh`, 15 s apart):

```
t=15..60s   black --- the BIOS and the disc load
t=75s       "Produced by Sony Interactive Studios America.
             Published by Sony Computer Entertainment America."
t=90s       "Interactive Entertainment / Developed by..."
```

The emulated R3000 runs at roughly 14 MIPS against the PS1's 33, so the intro
arrives at about 0.4x wall speed. Everything that sampled the window earlier
than ~70 s saw black and concluded, wrongly, that nothing rendered.

Driven live from the keyboard, it goes considerably further than that: **the
intro logos play, the main menu appears and is navigable, and Enter advances
through several screens** before the picture goes black where a 3D scene should
be. No intro FMV plays at any point. So the shape of what is left is:

```
intro logos        WORKS
intro FMV          MISSING entirely
main menu (2D)     WORKS, and responds to input
3D on top of it    MISSING
deeper screens     advance, then go black
```

That is three separate problems, and only the first was in these notes.

### Bug 1, measured on both sides

**Retraction first.** The previous section says `func_00105FA8` loops forever
firing an always-due event. It does not. The scheduler fires the event ONCE and
the event's *callback* never returns. Every symptom attributed to the loop ---
total frozen, millions of yields, one opcode --- is produced by the callback.
The disassembly in that section is right; the conclusion is not. That makes
three published-then-retracted claims about this one bug.

The callback is `func_000D2298` (`ctr` = `0x000D2298` on every caught stall, and
`lr` = `0x00106824` is the scheduler's own return address --- the two fit
together only this way), and it spins:

```
000D22C0  lwz  r31, 0(r30)      ; r30 = *(TOC-0x7D4C) = 0x002DEF80
000D22C4  lwz  r0,  0x88(r30)
000D22D8  beq  cr7, 0xd22f4     ; equal -> done waiting
000D22E4  sc   (43 = yield)
000D22F0  bne  cr7, 0xd22e0     ; still unequal -> yield again
```

Read out of the live context rather than derived (`PS1_SPINWAIT=1`):

```
r30=002DEF80  w0=0000009F  w88=0000009E        one short, forever
```

`+0x00` is produced by the PPU; `+0x88` is consumed by an SPU.
`SPU_WATCHEA=2DF008` names the writer outright: **spu4**, cmd `0x22`, 128 bytes
to `ea=0x002DF000` from LS `pc=0x09BDC`.

And the other side, from `SPU_WHOPOLLS` (per-SPU polling with the channel state
each poll tests) at the same freeze:

```
spu0..3  pc=0x00F98  mask=0                     the GPU cores, idle and healthy
spu4     pc=0x09C84  ev[st=00000000 mask=00000400]  sig[0 0]  inmbox=0
         resv[v=1 ea=0x002DEF80 diff=0]
         ls[0x10880: ... 0000009E ...]          what spu4 BELIEVES it consumed
         line[0000009F ...]                     what spu4 CAN SEE was produced
         ch0=1.58e9  ch4=1.58e9
```

So:

| side | waiting for | has |
|---|---|---|
| PPU (`func_000D2298`) | spu4 to consume item `0x9F` | `0x9E` |
| spu4 | the line holding `0x9F` to change **again** | a reservation on it, snapshot already `0x9F` |

Both wait; neither moves. spu4 has polled `rchcnt` **1.58 billion** times.

### The SPU code, from the lifted image

`spu4` is the audio core (image 2 = the `spu1` lifted module). Its wait, read
straight out of `src/spu_gen/spu1/spu_recomp.c`:

```c
/* arm: mask Lr, then GETLLAR the line INTO THE MIRROR */
gpr[9] = 0x2300;                    /* LS destination = mirror base */
gpr[8] = 1024;                      /* 0x400 = MFC_LLR_LOST_EVENT */
wrch(SPU_WrEventMask, 0x400);
wrch(MFC_LSA, gpr[90] + 0x2300);
wrch(MFC_Cmd, 0xD0);                /* GETLLAR */
/* 0x8934: */ if (rchcnt(SPU_RdEventStat)) goto handle_lost;
/* 0x893C: */ produced = LS[gpr[90] + 0x2300];
              consumed = LS[gpr[90] + 0x2388];   /* +0x88 */
              if (produced == consumed) goto idle;   /* -> 0x9BA8 -> 0x9C84 */
              ... do the work, then PUT consumed at 0x09BDC ...
```

The mirror is at LS `0x10800` (`gpr[90]` = `0xE500`), which is also where the
3 KB `GET` at LS `pc=0x0CC88` lands. So the loop re-reads the mirror on every
pass, and GETLLAR refreshes it --- which is why the reservation snapshot holds
the fresh `0x9F`.

**The open question is now exactly one word wide:** the snapshot says `0x9F` and
`resv[diff=0]`, so memory and snapshot agree; yet the compare at `0x893C` keeps
taking the equal branch. Either the mirror word the compare reads is not the one
GETLLAR refreshed, or our GETLLAR updates the snapshot but not the local store.
Dumping LS `0x10800` at a freeze (`SPU_LSDUMP=10800`) separates those two, and
they need opposite fixes.

The suspicion to test alongside it: hardware **latches** reservation-lost as a
sticky event bit, while `spu_resv_lost_poll` **reconstructs** it by comparing the
line against a snapshot --- so a GETLLAR issued after the PPU's write silently
erases evidence hardware would have kept.

### What is NOT the cause, each checked before publishing

| ruled out | how |
|---|---|
| a lost signal to spu4 | `SPU_SIGSTAT`: SigNotify2 writes keep arriving through the freeze (107,520 and climbing) |
| a starved event queue | `PS3_EVQSTAT`: q4 pushed 125,842, **pending 0** --- the servicing thread runs the whole time |
| the RSX user command | only **4** in an entire run, all early; `0xEB00` is not the per-frame mechanism |
| `SPU_DMA_REPEAT_LIMIT` halting spu4 | that calls `spu_halt()` and logs a line; the line never appears |
| a dropped counter PUT | with `SPU_WATCHEA_EVERY=1` the sequence is monotonic `0x12 0x13 0x14 ...` with no gap |

The last one carries a warning: logging every hit changes the timing enough to
stop the freeze happening at all. Three observer effects in this port now.

### Rows in the milestone table that were wrong

- *"the SPUs emit no pixels"* --- they do; the intro renders.
- *"5 `HwCdRom` events never leave `EvStACTIVE`"* --- today's census reads
  classes 2 and 9 active and three slots at status `0x0000`, and `in_cdloop`
  stops advancing, i.e. the CD loop is **left**. Bug 2 as written is not
  supported by the current measurements and is withdrawn pending a fresh one.

### New diagnostics (all off by default)

| knob | what it answers |
|---|---|
| `PS1_SPINWAIT=1` | who is yielding: `lr`/`ctr`/`r2`/`r30` and both counter words |
| `SPU_WHOPOLLS=<n>` | per-SPU `rchcnt` tally, pc, event/signal/mailbox/reservation state, the reserved line |
| `SPU_LSDUMP=<hex>` | 8 words of that SPU's local store, beside the reserved line |
| `SPU_WATCHEA=<hex>` | every DMA covering one word, with the value after it |
| `SPU_WATCHEA_EVERY=<n>` | sampling stride for the above (default 64) |
| `SPU_SIGSTAT=<n>` | per-SPU signal-notification writes and last value |
| `PS3_EVQSTAT=<n>` | per-queue push count **and pending count** |
| `PS1_GP0HIST=1` | GP0 primitive classes in the last 64 ring packets --- polygons vs rectangles |
| `PS3_DEBUG=<file>` | live console into a running title: `threads`, `mem`, `poke32`, `stat`, `knobs` |

`SPU_CHHIST` sums every SPU into one histogram, which is the one shape that
cannot show a two-party deadlock; `SPU_WHOPOLLS` exists because of that.

### The GP0 ring carries real drawing commands now

An earlier note in this document says the ring only ever carries type-8 sync
packets. That is stale. Sampled from a live, interactive session:

```
[ring] pkt@0x00FC5680 type=11: 64000000 00000000 00000001 00000280 00078A80
                               00000000 00000000 00000000 43900000 3F800000
                               00000000 42400000
```

`0x64` is the GP0 opcode for a **textured rectangle, variable size, opaque,
texture-blended** --- the 2D the menu is made of --- and the payload carries
floats (`0x43900000` = 288.0, `0x3F800000` = 1.0, `0x42400000` = 48.0)
alongside the command. So the earlier "type 8 only" reading was taken from the
first three packets of a run, before the game drew anything.

Which sharpens the missing-3D question: PS1 polygons are GP0 `0x20..0x3F`
(`0x30` shaded triangle, `0x38` shaded quad, `0x2C` textured quad). If those
never appear in the ring, the geometry is lost upstream in the R3000; if they
appear and no pixels follow, it is the rasteriser or the composite.
`PS1_GP0HIST=1` histograms exactly those classes over the last 64 packets, which
is the next measurement to take against a black 3D screen.

## FIXED: the stall was a GETLLAR that read guest memory twice

One line, and the stall that has dominated this port is gone:

```c
-   memcpy(ls, mem, MFC_ATOMIC_LINE);
-   memcpy(ctx->resv_line, mem, MFC_ATOMIC_LINE);
+   memcpy(ls, mem, MFC_ATOMIC_LINE);
+   memcpy(ctx->resv_line, ls, MFC_ATOMIC_LINE);
```

`GETLLAR` copied guest memory **twice** --- once into the SPU's local store,
once into the reservation snapshot. A PPU store landing *between* the two reads
gives the SPU a **stale line** and a **fresh snapshot**, and then both halves of
the wait fail:

- the SPU compares its stale copy, finds `produced == consumed`, decides there
  is nothing to do, and sleeps on `MFC_LLR_LOST_EVENT`
- `spu_resv_lost_poll` compares memory against the snapshot --- which already
  holds the new value --- finds no difference, and never raises the event

Nobody wakes anybody. Hardware cannot reach that state: `GETLLAR` is a single
atomic 128-byte read, so the reserved data and the reservation come from the
same instant. Taking the snapshot from `ls` restores that property; a store that
lands after the read now leaves **both** stale, which is exactly what makes the
lost-reservation event fire.

### How it was cornered

Every wrong answer cost a build, so the order matters:

| step | result |
|---|---|
| `resv_line` writers, whole runtime | exactly **one** --- this GETLLAR |
| `SPU_LLARWATCH`: every GETLLAR on the line, at the moment it runs | correct: `lsa=0x10800`, and the word that lands equals memory |
| histogram of those GETLLARs' LSAs | **630,785** of them, `lsa=0x10800` every single time |
| `SPU_WATCHLSA`: DMAs writing LS `0x10800` | exactly **one** in a whole run, the 3 KB `GET` at startup |

So the snapshot and the local store are written by the same function, from the
same source, microseconds apart --- and still disagree. Only the gap *between*
the two reads was left.

One near-miss worth recording: reading `ctx->mfc_lsa` from a later poll showed
`0x1D580` and pointed at a wrong LSA. That was wrong --- by then the SPU has
issued other DMA and overwritten the field. Same compare-two-moments mistake as
the ten retractions above, caught this time *before* publishing.

### Verified

Before, a stalled run gives 18 heartbeats with 2--3 distinct instruction
totals --- a plateau. After:

```
run 1: 23 heartbeats, 23 distinct, total=1,677,230,592
run 2: 23 heartbeats, 23 distinct, total=1,759,231,488
long:  360 s unattended,           total=4,210,050,368
```

Every heartbeat a different total, ~14 MIPS sustained, both rendering
(`vram nonzero=186,727/262,144`). **The Twisted Metal title screen renders in
full colour**, and the game runs past it.

Two intermittent early failures remain, both predating this fix: over five short
runs, four reached ~635 M instructions in 45 s and one reached 108 M; a separate
class never starts the R3000 at all (`total=0`, VRAM zero, SPUs started).

## The green stripes are IN PS1 VRAM, not in the composite

Past the title screen the picture becomes green/magenta vertical stripes. The
composite was the obvious suspect and is innocent. Two experiments, both
negative, then the measurement that settled it.

**What changes at that moment** --- the emulator rebinds PS1 VRAM:

```
fmt=0xE2  1:0x400000  1024x512   15-bit A1R5G5B5 -- title screen, correct
fmt=0xE1  1:0x4003C0  2048x512   B8, same bytes  -- 24-bit display mode
```

with texel-space UVs `0..319` x `1..239` and `fp_const c0=(3,0,0,0)`: three
bytes per pixel, gathered from three consecutive B8 texels. That is how the PS1
emulator presents 24-bit colour, which is what PS1 FMV and this game's title
bitmap use.

**Ruled out:**

| tried | result |
|---|---|
| B8 decode forcing alpha to 255 instead of the byte | frames **byte-identical** --- alpha is not what drives the green |
| `YZ_RSX_FP_CONSTANT_MODE=literal` (bypasses the constant buffer) | identical stripes; confirmed `mode=literal` in the log |

**What settled it:** `LD_PLANE_DUMP` writes the bound B8 plane out as a PGM ---
PS1 VRAM exactly as the guest laid it down, no D3D involved. During the stripe
phase it contains:

```
bytes 0 .. ~620      a real image (the title art, legible)
bytes ~960 .. ~1920  THE STRIPE PATTERN, already there
```

The stripes are in VRAM. The renderer is faithfully displaying what the PS1
wrote. And the display window points at byte **0x3C0 = 960**, which at three
bytes per pixel is **x = 320** --- the *second* 320-wide framebuffer.

So: the PS1 fills buffer 0 correctly and displays buffer 1, which was never
filled. That is a double-buffer problem upstream of the renderer, and it
explains both symptoms at once --- the missing FMV and the striped screens
after the title.

An earlier note in this document called this "a 24-pixel-period pattern from a
six-entry palette" and treated it as a composite artifact. It was right about
the pattern and wrong about the place: 24 bytes is 8 pixels at 24-bit, i.e. one
DCT block, which is what an unfilled or half-decoded frame buffer looks like.

**Next measurement, and it is specific:** watch the destination of GP0 `0xA0`
(Copy Rectangle, CPU to VRAM) and the display-area register writes. If every
`0xA0` lands in one buffer while the display flips between two, the flip target
is never being written --- and that is the whole bug.

### Quantified: the 24-bit transfer fills exactly one third of each row

Offline analysis of the dumped plane, no further runs needed.

Non-zero byte density per 64-byte column block, sampled over 240 rows:

```
bytes    0.. 319   ~3800/3840   dense  -- real 24-bit image data
bytes  320.. 959   ~1500-1700   the pattern (2 of every 6 bytes)
bytes  960..1087   0            untouched
bytes 1088..1855   ~1275-1350   the pattern again
bytes 1856..2047   ~3835        dense
```

The pattern has a **period of 48 bytes** and its bytes read
`F8 00 00 00 00 F8` repeating --- and it is NOT a constant fill (only 14 of 239
rows match row 0). `0x00F8` is a 15-bit PS1 pixel. So those bytes are **older
16-bit content still sitting in VRAM**, read back as 24-bit triples, which is
what turns them into saturated red/blue columns and then green/magenta on
screen.

Reinterpreting buffer 0 as 320x240 24-bit RGB confirms it: the left ~104 pixels
are a real FMV frame (architecture and rubble, clearly legible), and the rest is
the pattern. 104 pixels x 3 bytes = ~312 bytes.

**So each row receives ~320 bytes of real data where a 320-pixel 24-bit row
needs 960 --- exactly one third.** The other two thirds are whatever the 15-bit
path left behind. Both remaining symptoms follow from that one number: the FMV
never appears because only a third of each row arrives, and the "stripes" are
stale 16-bit pixels, not a decode failure.

Where to look: the CPU-to-VRAM transfer path for 24-bit data. A 320-pixel
24-bit row is 960 bytes = 480 halfwords, and PS1 GP0 transfers are counted in
16-bit words --- a width taken in the wrong unit, or a destination advanced by
one byte per source halfword instead of three, produces exactly a one-third
fill.

### Who actually writes PS1 VRAM, and where it lives

Two corrections to long-standing notes, both from direct measurement.

**PS1 VRAM is at guest `0x40600000`.** It was assumed to be `0xC0400000` --
`cellGcmSys`'s `localAddress` (`0xC0000000`) plus the texture offset
`0x400000`. Watching that address caught no writes at all from either the PPU
store path or SPU DMA, which reads exactly like a finding and was simply the
wrong address. The heartbeat now prints the real EA once
(`[ps1] VRAM guest EA = 0x40600000`), so nobody derives it again.

**The GPU SPUs do write VRAM.** An earlier note recorded "spu1..3 writing only
bucket 0 and spu0 buckets 1..3, with nothing in bucket 4 -- where the composite
samples PS1 VRAM". Against the correct address, `SPU_WATCHEA` on one VRAM byte
returns 218 transfers in 120 s:

```
spu2  cmd=0x20 (PUT)  ea=0x40632000  size=256  lsa=0x24100  pc=0x002E0
spu0  cmd=0x40 (GET)  ea=0x40632030  size=48   lsa=0x1D5B0  pc=0x00598
spu0  cmd=0x20 (PUT)  ea=0x40632030  size=48   lsa=0x1D5B0  pc=0x004DC
```

spu2 writes 256-byte blocks; spu0 does 48-byte **read-modify-write** pairs --
and 48 bytes is exactly the period of the stripe pattern measured above.

The pixels in the striped region decode as PS1 15-bit values, and the run of
them at one address is `0x0000 -> 0x00F8 -> 0x83E0`. `0x83E0` is R=0, G=31, B=0
with bit 15 set: **pure green with the mask bit marked**. That is the green.

**A hypothesis tested and dropped:** the repeated GET/PUT of an unchanged
`0x83E0` looked like PS1 mask-bit (STP) rejection discarding every later write
to that region -- which would have been a clean explanation. It is not: the
value at that address *does* change across the run. The 48-byte block is simply
the rasteriser's granularity, and only some pixels inside it are covered by any
one primitive. Recorded because it was one step from being published as a cause.

**What is still open:** the region the 24-bit display window points at holds
about one third real image data and two thirds older 15-bit content. Both facts
are now measured; what is not established is whether the game intends an FMV
there at all. Buffer 0 reinterpreted as 24-bit RGB shows a genuine frame
(architecture and rubble) for its first ~104 pixels, so MDEC output does reach
VRAM -- partially. The next measurement is what fills the other two thirds:
`SPU_WATCHEA` on an address inside a *known-blank* span, with the transfer
geometry, says whether those bytes are written and skipped or never addressed.

### The one-third fill has an exact arithmetic signature

A 320-pixel 24-bit row is 960 bytes. PS1 CPU-to-VRAM transfers (GP0 `0xA0`)
count their width in **16-bit halfwords**, so that row is **480 halfwords**.

What lands is ~320 bytes = **160 halfwords**, and 160 = 320/2. That is the
halfword count for a 320-pixel *15-bit* row. So the width is being computed as
`pixels / 2` instead of `pixels * 3 / 2` --- correct for 16-bit, one third short
for 24-bit. The measured fill and that arithmetic agree to within a few bytes.

Two things this rules in and out:

- **Buffer 0 does not hold a complete frame.** Reinterpreted as 320x240 24-bit
  RGB it is coherent for ~104 pixels and pattern thereafter, so pointing the
  display window at buffer 0 instead of buffer 1 would not fix the picture. The
  blit is the bug, not the display offset --- which also means the experiment of
  overriding that offset is not worth running.
- **The transfer is not in the GP0 ring.** `PS1_GP0HIST` over the last 64
  packets counts zero words in the `0xA0..0xBF` class across every sample, so
  CPU-to-VRAM transfers are handled somewhere other than the ring the GPU SPUs
  consume --- and that is where the width is computed.

A method note: an automated detector written to find where the coherent region
ends reported byte 960 (a full row) in all five dumps, contradicting the image.
The detector was wrong --- it flagged bytes in a small value set, and `0x00` is
ordinary in dark image data. The visual measurement stands; the automated one is
discarded. Worth recording because it would have been the fourth confident
wrong answer in this document had it been believed.

### RETRACTION: the row is fully written, so "one third fill" was wrong

The commit above concluded that the 24-bit transfer writes ~320 of the 960 bytes
each row needs, with the tidy arithmetic `pixels/2` instead of `pixels*3/2`.
**That is not supported.** It came from looking at one plane dump, at one
moment, and reading where the coherent part of the picture ended.

Write coverage measured directly (`SPU_ROWCOV`, counts per 64-byte block over a
whole 2048-byte VRAM row):

```
writes per 64B block:  207 x20 blocks,  148 x10 blocks,  0 0
byte at block start:   83E0 x20,        0000 F800 00F8 ...,  0000
```

Blocks 0..19 are bytes 0..1279 --- **640 pixels, the full display width** ---
and every one is written ~207 times. The row is not one-third filled. It is
fully written, and the content is wrong: every pixel is `0x83E0`.

So the two symptoms are not "a short transfer". They are "the right amount of
the wrong pixel". That is a different bug and the halfword arithmetic above,
however neat, should be ignored.

### And it is not a byte-order bug either

The stored bytes are `83 E0`. As a little-endian PS1 halfword that is `0xE083`;
the RSX reads A1R5G5B5 big-endian as `0x83E0` = R=1, G=31, B=0, which is exactly
the green on screen. Tempting --- and wrong, for a reason worth writing down:

- **white is invariant under channel permutation** (all three fields are 31)
- **white is nearly invariant under a halfword byte swap** too: `0x7FFF`
  swapped is `0xFF7F` = B=31, G=27, R=31, still near-white

The BIOS boot screen (`PS1_FBDUMP`) renders its "Licensed by Sony Computer
Entertainment of America" line in **blue**, where hardware shows white. Neither
a permutation nor a byte swap can turn white into blue, so the stored values
genuinely have low R and G. The ordering door is closed.

### One local observation, explicitly not generalised

Pixel values in that text band are `0x1111`, `0x1100`, `0x0011`, `0x1001`,
`0x0100`, `0x1011` --- every one a combination of nibbles that are only 0 or 1,
which is what 4-bit indexed (CLUT4) glyph data looks like packed four pixels to
a halfword.

Tested for generality before believing it: the same property holds for only
**32%** of non-zero pixels sampled across `x >= 640`, and 12% below it. So this
says the BIOS font lives in that area as a 4-bit texture --- ordinary for PS1
VRAM --- and says nothing about VRAM as a whole. Recorded at its actual scope.

It does undercut one long-standing note here, that "every pixel the PS1 draws
lives at x >= 640 while columns 0..639 are black": `x >= 640` holds font and
texture data, and the row coverage above shows `x < 640` being written 207 times
per block. Which half the display window should be reading is now an open
question rather than a settled one.

### The renderer is faithful --- proven by reconstruction, not by elimination

The striped screen has now been reproduced **from the VRAM bytes alone**. Taking
the raw plane dump and sampling exactly what the guest's shader samples --- byte
`0x3C0` onward, three bytes per output pixel, 320 wide --- reconstructs the
on-screen picture pixel for pixel: same stripe period, same magenta dots, same
black band down the left. (Channel order differs from the screen because the
reconstruction assigns R,G,B directly and the guest's fragment program does its
own packing; the structure is identical.)

Two further facts from the same phase:

- **The image is static.** Eight window captures taken back to back during the
  striped phase are byte-identical, so this is not a double-buffer flicker with
  one good frame and one bad.
- **It is deterministic.** The same capture sizes recur across independent runs.

So the renderer displays precisely what the guest put in VRAM, at the offset the
guest asked for. Every remaining explanation on the PS3 side --- format, mip
level, constants, byte order, surface aliasing, display offset --- is closed.
The corruption is upstream, in what the PS1 side writes.

### Cherry-picked from the flOw port: a pitch-linear texture has no mip chain

`flow/live-draw` carries two renderer fixes that never reached this branch, and
one of them describes our symptom almost word for word: flOw's EULA rendered as
"banded olive stripes with a ghosted second copy of the page" because a
pitch-linear texture declared 11 mip levels, so the decoder walked
`off += pitch * mh` through whatever guest memory followed the base image and
the minified draw sampled that garbage. The fix is `if (linear) n_mips = 1;`,
and PS1 VRAM here is bound pitch-linear (`fmt 0xE2`/`0xE1` both carry
`TEX_FMT_LINEAR`).

Applied by hand at both mip-count sites (the cherry-pick conflicted on
unrelated dump code). **It changed nothing visible** --- the captures are
byte-identical --- so these textures evidently declare one level already. Kept
anyway: it is the correct behaviour, it matches the sister port, and it removes
a real trap for any future pitch-linear texture that does declare a chain. Not
claimed as a fix for this symptom.

Worth noting for the next lap: `6428a66 rsx: decode R5G5B5A1, and let a decoded
texture be looked at` is also unmerged on this branch.

## The firmware carries a 349-title quirk table --- and Twisted Metal is in it

`ps1_netemu` ships a per-title compatibility table, and this game has its own
entry. Found by pulling readable strings out of the image, which also yields the
emulator's internal module and thread names.

### The table

349 sixteen-byte records at vaddr **`0x001B1E5C .. 0x001B341C`**:

```
+0x00  char*  PS1 disc serial, e.g. "SCUS_943.04"   (strings at 0x00172C08..0x00174198)
+0x04  u32    count of parameter pairs
+0x08  u32*   pointer to the parameter blob
+0x0C  u32    hash / checksum
```

Twisted Metal's record:

```
rec[319] @0x001B324C   SCUS_943.04
         count=00000001   params=0x00172624   hash=2C9D6E1E
   params: (2, 0x1C)      -- one pair: id 2, value 28
```

Neighbours for scale: `SCUS_943.09`, `SCUS_943.02`, `SCUS_943.01`,
`SCUS_943.56`, `SCUS_943.55` all carry count=1; `SLUS_000.42` carries 3. So the
blob is a list of (id, value) quirks and most titles need exactly one.

**Why this matters:** if the emulator looks a title up by the serial from its
disc and applies these quirks, then a lookup that fails leaves the title running
unpatched. Whether ours matches is not yet established --- the run passes
`SCUS94304` in argv while the table is keyed `SCUS_943.04`, which is the form
taken from the disc's own boot filename, so the comparison is presumably against
`SYSTEM.CNF` rather than argv. Confirming it is the next thing to do, and it is
cheap: a read watch on `0x001B324C` or on the string at `0x00173FC8` says
outright whether the lookup reaches this game's record.

The consumer was not located statically. The base is not held in any word of
the image, is not built by any `lis`, and is not formed by
`addis rX, r2, -2` + `addi` (all three searched), so it is reached some other
way --- a runtime read watch is the cheaper route than continuing to guess.

### The emulator's own names, free from the same strings

```
gpuio.cc: gpuCmdInterruptHandlerThread    gpusoft.cc      sgpu_spu.elf
gpu1InSpuIO / gpu1InSpuIO_Ptr             gpuStateEx      gpuVramEx
gpuCmdFetchBuffer                         spu.c           cell/xspu.cc
```

And the guest thread names, via `PS3_GUEST_PROF`:

```
tid=2  _gcm_intr_thread                tid=8   _xcdrom_thread
tid=5  gpuCmdInterruptHandlerThread    tid=9   xPadThread
tid=6  _xSPUWaveOut                    tid=10  _xMcThread
tid=7  SPUCxInterruptHandlerThread     tid=11  _PSPiStorageThread
```

Two of these settle open questions. **`_xSPUWaveOut` is tid 6** --- the thread
that receives on queue 4 and signals spu4 --- which confirms spu4 is the audio
core and that the GETLLAR deadlock fixed above lived in the *audio* pipeline.
And **`gpusoft.cc` exists**, so the firmware contains a software GPU path
alongside `sgpu_spu.elf`; whether it can be selected is unknown and worth
knowing, because it would sidestep the SPU rasteriser entirely.

`gpuCmdFetchBuffer` is almost certainly the GP0 ring these notes have been
calling "the ring", and `gpuVramEx` / `gpuStateEx` name the VRAM and GPU-state
structures --- useful handles for the next lap.

### CLOSED: the quirk lookup works --- it finds this game and reads its parameters

Measured with a new PPU read watch (`PPU_RWATCH=<hex>[,len]`), because a lookup
only *reads* and every existing watch in the runtime is a store watch:

```
PPU_RWATCH=1B324C,16   (Twisted Metal's record)
  [rwatch] n=1 read4 0x001B324C guest-fn=0x000BD428    <- serial pointer
  [rwatch] n=2 read4 0x001B3250 guest-fn=0x000BD428    <- parameter count
  [rwatch] n=3 read4 0x001B3254 guest-fn=0x000BD428    <- parameter pointer

PPU_RWATCH=172624,8    (its (2, 0x1C) parameter blob)
  [rwatch] n=1 read4 0x00172624 guest-fn=0x000BD428
  [rwatch] n=2 read4 0x00172628 guest-fn=0x000BD428
```

`func_000BD428` reads exactly the three record fields and then both words of the
parameter pair, once, at init. So:

- the emulator **does** identify this disc as `SCUS_943.04`
- it **does** read the quirk this title is listed with
- the argv-vs-`SYSTEM.CNF` serial-format worry was unfounded

The lookup is not the bug. It also confirms the record layout inferred from the
image was right, since precisely `+0x00`, `+0x04` and `+0x08` are the words read.

`func_000BD428` is the quirk consumer --- a large init routine (0x1D40-byte
stack frame) that works from `*(TOC-0x7E50)` = `0x0015F840` and
`*(TOC-0x7E4C)` = `0x002DC274`. What quirk id 2 with value 28 actually changes
is still unread; that means reading that function, which is a job of its own
rather than a measurement.

## The composite is one of seven Cg programs --- and the two measurements reconcile

### What the firmware says about its own display path

The `fp_*` names found earlier are not config keys. They are **Cg shader
names**, and there are seven of them:

```
CG_vpshader   CG_fpshader
CG_fp_gradient   CG_fp_orientation   CG_fp_mofix   CG_fp_smart
CG_fp_upscale    CG_fp_upscale_smart CG_fp_sharpen
```

with the uniform and attribute names beside them: `texture0`, `texture1`,
`hwidth`, `xyz`, `rgba`, `tex0`. So the emulator picks a display fragment
program from seven variants, and at least one variant takes **two** textures
plus a width uniform. `CG_fp_mofix` is presumably the movie path.

That mattered because it undercut the earlier "the renderer is faithful"
conclusion: that was proven by reconstructing the screen from **one** texture at
the offset measured on unit 0, which quietly assumed there was no second one.

**Measured (`LD_UNITS=1`, every enabled unit on any draw that samples PS1 VRAM,
once per distinct combination):**

```
draw sampling PS1 VRAM: u0[1:0x00400000 fmt=0xE2 1024x512 p=2048]
draw sampling PS1 VRAM: u0[1:0x004003C0 fmt=0xE1 2048x512 p=2048]
draw sampling PS1 VRAM: u0[1:0x00400000 fmt=0xE1 2048x512 p=2048]
```

**Only unit 0 is ever enabled.** So the two-texture variants are not the ones in
use here, and the reconstruction stands: the renderer reads the bytes the guest
points it at. The caveat is resolved in favour of the original conclusion.

It also turns up a third bind that had not been seen before: **24-bit at offset
0** as well as at `0x3C0`. So the emulator displays *both* 24-bit buffers, buffer
0 and buffer 1, alternately.

### Reconciling "one third coherent" with "the row is fully written"

Those two measurements looked contradictory and the second was used to retract
the first. Both are right; they were taken in **different display modes**:

| measurement | mode | result |
|---|---|---|
| plane dumps (`LD_PLANE_DUMP`, fires on a B8 decode) | **24-bit** | ~1/3 of the row coherent image, 2/3 pattern |
| row coverage (`SPU_ROWCOV`) | a **15-bit** phase | full 640-pixel width written, every pixel `0x83E0` |

So the retraction over-reached. What was genuinely unsupported was the
*explanation* --- the tidy `pixels/2` vs `pixels*3/2` halfword arithmetic --- and
the claim that the row was not fully **written**. The observation that only about
a third of a 24-bit row carries coherent image data was never contradicted,
because the measurement that "refuted" it was of a different mode entirely.

Recorded this way because it is the same error as the ten before it: comparing
two facts gathered at different moments, this time different *modes* rather than
different runs.

## THE SPU GPU SHIPS WITH SYMBOLS --- and the rasteriser never runs

### The symbol tables were there the whole time

Both SPU modules embedded in `ps1_netemu` carry a `.symtab`. The copies under
`analysis/spu/` are truncated exactly where their symtab begins (the extractor
keeps only the loadable image), which is why this went unnoticed --- read the
ELFs where they live instead, at firmware **file** offsets `0x171100` and
`0x18A200` (found by scanning for the ELF magic with `e_machine == 23`).
`scratch/spusyms.py` does it.

The GPU module's map, C++ names demangled by hand:

```
LS 0x00188   456 B  BlockClear(GpuBlockClearCmd const*)
LS 0x00350   776 B  Host2Local_Body(GpuH2LBodyCmd const*)
LS 0x00758   464 B  Host2Local(GpuH2LCmd const*)
LS 0x00928  1440 B  Local2Local(GpuL2LCmd const*)
LS 0x010F8 16148 B  main
LS 0x051E8  3668 B  DrawRect<3>(Code, int)
LS 0x06040  4232 B  DrawRect<2>(Code, int)
LS 0x070C8  4296 B  DrawRect<1>(Code, int)
LS 0x08190  1388 B  DrawRect<0>(Code, int)
LS 0x08700 .. 0x1493B  DrawEdge<0..3, 0..4>   -- 20 template variants
LS 0x14E10   512 B  gpuCmdFetchBuffer
LS 0x23580/0x23590/0x23800  _prepTxResult / _prepTxLoading / _prepClutLoading
```

That immediately names the two VRAM writers measured earlier from bare
addresses: `pc=0x002E0` is inside **`BlockClear`**, and `pc=0x004DC` /
`pc=0x00598` are inside **`Host2Local_Body`**. So the flat `0x83E0` field is a
block clear --- correct per-frame behaviour --- and the partial 24-bit picture is
the host-to-VRAM blit.

### The measurement that matters

`SPU_VRAMPC=1` buckets every DMA write into PS1 VRAM by the symbol its LS pc
falls in. One run, 3.74 million writes:

```
Host2Local_Body = 3,735,322   (170 MB)
BlockClear      =     4,532   (1 MB)
Local2Local     =       240   (150 KB)
DrawRect        =         0
DrawEdge        =         0
```

**The rasteriser never runs.** Not one write from `DrawRect` or `DrawEdge` in an
entire run, while 3.7 million come from the blit path. The PS1 GPU emulation is
moving memory and never drawing a primitive.

That single fact accounts for everything still missing:

| symptom | explanation |
|---|---|
| no 3D over the menu | no primitive is ever rasterised |
| the display area is one flat colour | `BlockClear` runs, nothing draws over it |
| screens go black deeper in | same, with a black clear colour |
| intro logos and title screen DO appear | they are `Host2Local_Body` blits, not geometry |

The last row is the tell: everything that works is a **transfer**, and everything
missing is a **draw**. Ten laps of chasing the composite were chasing the half of
the pipeline that already works.

### Where that points

`main` (LS 0x010F8) is the SPU's command dispatcher and `gpuCmdFetchBuffer`
(LS 0x14E10, 512 bytes) is the ring it reads --- the thing these notes have been
calling "the ring" all along, now with its real name. The question is now narrow:
does `main` receive draw commands and fail to dispatch them, or do draw commands
never arrive?

An old note here --- "of ten GP0 ring producers only `func_0010F5FC` (type 8,
sync) ever runs" --- points at the second, and it is testable directly:
instrument `main`'s dispatch, or count the packet types reaching
`gpuCmdFetchBuffer` against the types `DrawRect` / `DrawEdge` are reached from.

### CORRECTION: `DrawRect` does run --- and only `DrawEdge` never does

The section above says "the rasteriser never runs", inferred from VRAM *writes*.
Too strong. Counting **entries** instead of writes (`SPU_PCHIST=1`, one bucket
increment per trampoline hop, extents taken from the embedded `.symtab`):

```
spu0  main=4,282,665,386  H2L_Body=239,674,208  Local2Local=7,145,459
      BlockClear=9,792    DrawRect=955          DrawEdge=0
spu1  main=4,342,051,716  Local2Local=7,144,258
      BlockClear=9,792    DrawRect=955          DrawEdge=0
spu2  main=4,328,871,061  ... identical ...
spu3  main=4,380,463,921  ... identical ...
```

So:

- **`DrawRect` IS dispatched**, 955 times on every SPU.
- **`DrawEdge` is never entered at all** --- zero, on all four.

`DrawRect` running while writing no VRAM does not mean it draws nothing: the
symbol list includes `fbCacheData` and `tbCacheData`, so the rasteriser plausibly
composites into a local-store framebuffer cache that other code flushes
(`Local2Local` takes 7.1M hops). Attributing pixels by the DMA that carries them
therefore cannot see rasterised output at all. That is the flaw in the previous
section's reasoning, and it is the same shape as the earlier mistakes: a
measurement of one thing (writes) used to settle a question about another
(drawing).

The identical counts across spu0..3 are worth noting too --- `BlockClear=9792`,
`DrawRect=955` and `Local2Local~7.14M` match to the digit on all four, with only
`H2L_Body` concentrated on spu0. That is four cores each rasterising the same
command stream over its own slice of the screen, which is how the PS1 GPU is
parallelised here.

**What survives, and it is the important part:** `DrawEdge` --- the polygon
rasteriser, all 20 template variants --- is **never entered**. No polygon is ever
submitted for drawing. That is measured by entry count, not inferred from
writes, so it stands.

### Which raises a possibility this document has not considered

The title screen and menus are 2D. Twisted Metal draws polygons in *gameplay*
and in the *attract demo*, neither of which has been reached. So `DrawEdge=0`
may be the correct behaviour for the phase the emulator is actually in, and the
missing 3D may be a **consequence** of never reaching attract mode rather than
its cause.

That reverses the direction of the search. If it is right, the question is not
"why does nothing rasterise" but "why does the game never leave the title
screen" --- a game-logic or timing question (a CD read that never completes, a
timer that never fires, an input the attract timeout waits on) rather than a
rendering one. Distinguishing them is cheap: reach gameplay by driving the menus
with input and see whether `DrawEdge` starts being entered. If it does, the
renderer was never the problem.

## THE MAIN MENU RENDERS, AND THE POLYGON RASTERISER WORKS

The reversal in the section above was right. The renderer was never the problem.

`PAD_SCRIPT` (already in the runtime: `"<sec>:<mask>,..."`, masks packed as
`(DIGITAL2 << 8) | DIGITAL1`) drives the title without a human at the pad. One
script --- START at 105 s, then CROSS every ten seconds with a DOWN at 165 s ---
and the picture changes completely.

### The polygon rasteriser, before and after

Same build, same binary, `SPU_PCHIST=1` both times:

```
                    sitting at the title      driven with PAD_SCRIPT
DrawEdge                    0                 88,040 / 68,059 / 67,680 / 105,246
DrawRect                  955                 103,966
BlockClear              9,792                 2,403,747
```

`DrawEdge` --- the polygon rasteriser, zero entries across four SPUs for an
entire undriven run --- takes **tens of thousands** of entries as soon as the
game is driven off the title screen. So the earlier `DrawEdge=0` was **correct
behaviour for a 2D phase**, exactly as the previous section guessed, and the
whole "nothing rasterises" line of investigation was measuring a screen that
genuinely had no polygons on it.

### And the menu draws

`scratch/seq/t125.png` from the driven run: **the Twisted Metal main menu**, its
brick-wall background art rendering correctly, with the inner panel black where
the menu's content belongs. That is the screen described from a live session as
"clearly a menu, no 3D on top", now reproduced without a human and captured.

Sequence now demonstrated, unattended:

```
t=25..50    black          BIOS + disc load
t=75        intro cards    "Produced by Sony Interactive Studios America..."
t=100       title screen   full colour
t=125       MAIN MENU      background art correct, inner panel black
t=150..275  blank grey     the screen after the menu selection
```

### A performance claim caught before it was published

The driven runs end with the instruction counter at ~180-220 million against
~4.2 billion for an undriven run, which reads as a 20x collapse the moment 3D
rasterisation starts --- a tidy and completely wrong conclusion.

The counter **resets**. In both driven runs, at heartbeat 57 of 59:

```
seq run:     4,253,258,101 -> 30,636,406
pchist run:  4,285,016,511 -> 64,483,328
```

So the emulator runs to 4.25 billion at full speed, the PS1 core resets, and it
carries on at full speed. Dividing the post-reset counter by the whole run
duration produced the phantom slowdown. Rate before the reset is ~14 MIPS,
unchanged.

That the reset lands at the same point in both runs makes it **deterministic and
caused by the input script**, not random --- the last presses select something
that resets the core.

### What is left, stated precisely

| | |
|---|---|
| intro logos | render |
| title screen | renders, full colour |
| **main menu** | **renders** --- background art correct, inner panel black |
| intro FMV | still never plays |
| attract mode | not reached |
| after the menu | blank grey, then a deterministic core reset |

Two open threads, both narrow. **The black inner panel**: the menu background is
a blit and arrives; the panel is where content is drawn, and `DrawEdge` is now
active, so this is a drawing question that can be attacked with the symbol
buckets. **The deterministic reset**: it is reproducible from a fixed
`PAD_SCRIPT`, so bisecting the script says which press causes it.

## THE INTRO FMV IS PLAYING --- caught on screen, partially drawn

Every capture pass so far sampled the window every 15--35 s. At ~0.4x emulation
speed that is wide enough to miss an event that lasts seconds. `tools/burstseq.sh`
samples a window densely instead (every 4 s from t=58 to t=150), and it caught
the thing this port has been declared to be missing all session:

```
t=058   92 KB    intro card
t=062..078  500 KB   pattern
t=082..086  912 KB   pattern (full-screen)
t=090..118  1.99 MB  title screen
t=122   1.35 MB  <-- THE FMV: a decoded video frame, left third of the screen
t=126..146  500 KB   pattern
```

`scratch/burstseq/t122.png` is a real decoded video frame --- rubble and
architecture, clearly legible --- occupying the left ~104 of the 320-pixel display
width, with vertical colour fringing, and stale pattern across the remaining two
thirds. **The intro FMV is decoded and displayed. It is not missing; it is
partially drawn.**

So MDEC works, the CD delivers the stream, `Host2Local_Body` blits it, and the
composite shows it. What is wrong is the *extent* of each row.

### The width, from two independent directions

```
on screen        the image covers ~1/3 of the 320-px window   -> ~104 px
from the bytes   104 px x 3 bytes per pixel                    -> 312 of 960
```

Both agree, and 960 bytes is exactly a 320-pixel 24-bit row. **Each FMV row
receives about a third of its bytes.**

### Which means an earlier retraction here was itself wrong

This document retracted the "one third fill" observation on the strength of a
row-coverage measurement showing a row fully written. That row-coverage run was
in a **15-bit** phase --- already noted two sections above --- so it never
addressed the 24-bit case. The one-third observation stands, now confirmed
on-screen rather than from a single dump. What was genuinely wrong was only the
*explanation* offered for it (the `pixels/2` vs `pixels*3/2` arithmetic).

### Hypotheses tested and killed in this pass

| tested | result |
|---|---|
| the FMV frame is really 15-bit data shown as 24-bit (320 px x 2 B = 640 B, and 640/3 = 213 px, suspiciously close to what is on screen) | **dead** --- reinterpreting the same bytes as 15-bit, both endiannesses, gives psychedelic garbage while the 24-bit reading gives a clean image |
| only spu0 transfers, so the other three SPUs' slices are never written | **dead** --- `LS 0x150A0` holds each SPU's own index (0,1,2,3) and `Host2Local_Body` returns early unless it is 0. One transfer master is deliberate design |
| the frames were caught mid-blit by the dumper | **dead** --- the partial frame is what is *on screen*, in a window capture, not in a probe dump |

### Where the next lap starts, with real names

`Host2Local_Body` (LS 0x00350, 776 bytes) reads its command block at LS
`0x24210`. Measured during playback on spu0:

```
0x24210  0x000002A0 / 0x150 / 0xD8   varies per command
0x24214  0x000000F0  = 240           the row count -- a full PS1 frame height
0x24218  same as +0x00
0x2421C  0x00000030  = 48            matches the 48-byte DMA writes measured
0x24220  0x00000000                  the value clamped against at 0x350
0x24224  0x00000018  = 24
0x2422C  0x00000001
```

The height is right (240 rows), the DMA unit is right (48 bytes), and the
function clamps a per-command count against `LS 0x24220`. Reading that clamp
correctly out of the lifted SPU bit-ops (`cgt` / `selb` / `ai` / `ceqi`) is the
next job --- and it is code reading on a 776-byte function with its real name and
its inputs already measured, which is a far better position than any lap before
it.

## The core reset is a 32-bit counter wrap, not the input script

### Correction

The previous section called the post-menu core reset "deterministic and caused by
the input script, not random", on the evidence of two driven runs resetting at
the same point. An **undriven** 400 s run resets at the same point too:

```
seq run      (driven)    4,253,258,101 -> 30,636,406
pchist run   (driven)    4,285,016,511 -> 64,483,328
undriven                 4,271,258,880 -> 50,554,333
```

All three land just under **2^32 = 4,294,967,296**. The reset is a **32-bit wrap
of the R3000 instruction counter**, and input has nothing to do with it. Two
driven samples looked like a pattern; the third sample, from the other run class,
killed it. Eleventh instance of the same mistake in this document, and the first
one caught within a lap of making it.

`state+0x124` is the 32-bit counter the scheduler compares event due times
against (`func_00105FA8`, disassembled earlier). ~2^32 cycles is ~127 s of PS1
time, so every run of more than about two emulated minutes crosses it. Whether
`ps1_netemu` handles the wrap and this port breaks it, or the reset is the
emulator's own deliberate resynchronisation, is not yet established --- but it is
now a specific thing to look at, in a function already read.

### Attract mode does not start on its own

Same 400 s undriven run, `SPU_PCHIST=1`, sampling the window every 10 s from
t=120 to t=390:

```
26 captures, ALL 8342 bytes -- identical, blank
DrawEdge: absent from the histogram entirely (zero, all four SPUs)
DrawRect: 413,410     BlockClear: 11,655     H2L_Body: 798,687,868 (spu0)
```

So without input the sequence is:

```
intro cards -> title screen -> intro FMV (partial) -> BLANK, indefinitely
```

The screen goes blank after the FMV and never recovers, and no polygon is ever
drawn, so the attract demo never begins. VRAM still holds 151,084 non-zero words
and the guest keeps executing (79 heartbeats, counter still climbing after the
wrap), so this is not a hang of the emulator --- it is the title sitting on a
screen it never draws.

With input the sequence instead reaches the main menu, and there too the screen
goes blank after the selection. **Both paths end blank**, which points at one
mechanism rather than two.

## The blank screen is an absence of content, not a stuck flip

During the blank phase every composite bind is `1:0x004003C0 fmt=0xE1` --- 24-bit
buffer 1 --- while the content that exists, the decoded FMV frame, sits in buffer
0. That is exactly the shape of a display flip parked on the buffer the game is
not drawing into, so it was worth one line to test.

`LD_PS1_BUF0=1` (diagnostic, off by default) rewrites a bind at `0x4003C0` to
`0x400000`. Result:

```
without override   26 captures in the blank window, ALL 8342 bytes (blank)
with override       0 blank captures -- 11 pattern, 2 title screen, 1 new frame
```

**The blank frames disappear entirely.** So the display was indeed showing an
empty buffer. But what replaces them is the stale *pattern*, not a picture ---
buffer 0 in that phase holds stale content too. Neither buffer has anything
fresh in it.

So the flip is not the bug. **The game is drawing nothing at all after the FMV**,
in either buffer, which is the same conclusion `DrawEdge=0` reached from the
other end. The blank screen is a symptom of that, not a cause.

### And the FMV is a progressing sequence

Two distinct frames captured, at different points and from different buffers:

```
scratch/fmv_onscreen.png    (t=122, no override)  rubble and architecture
scratch/fmv_logo_reveal.png (t=130, buffer 0)     "W" and "M" carved in stone
```

The second is the **Twisted Metal logo reveal** --- the intro movie's title
shot. Different content in each, so the movie is *playing through*, not stuck on
one frame. Both show the same defect: a coherent third of the width, stale
pattern across the rest, and the coherent third sits at a different horizontal
position in each (consistent with looking at different buffers).

### Which ties the two remaining bugs together

The FMV plays, advances, and draws about a third of each row; then the game stops
drawing and never reaches attract mode. One playback path explains both: if the
machinery that blits the movie is malfunctioning, the machinery that decides the
movie has *finished* is a reasonable suspect for malfunctioning with it --- and a
title waiting on an end-of-stream that never arrives would sit exactly like this,
executing (the counter keeps climbing through 79 heartbeats) and drawing nothing.

That is a hypothesis, not a measurement, and it is written here as one. What is
measured: the FMV renders and advances; a third of each row arrives; after it the
game draws nothing; `DrawEdge` stays at zero; neither buffer receives fresh
content; and the guest never stops executing.

## The FMV rows are fully written --- the SOURCE data is two-thirds pattern

`SPU_ROWCOV` over a whole 2048-byte VRAM row, early (during the intro/FMV) and
late in the same run:

```
early   blocks 0..19 = 207 writes   blocks 20..29 = 148   blocks 30..31 = 0
late    blocks 0..19 = 413 writes   blocks 20..29 = 343   blocks 30..31 = 0

bytes, late:  0000 F800 00F8  0000 F800 00F8  ... across ALL of blocks 0..29
```

Three things follow, and one of them closes a thread that was about to be chased
into `Host2Local_Body`.

**1. The writes are not truncated.** Every block from 0 to 29 --- bytes 0..1919,
which covers both 320-pixel 24-bit buffers --- is written hundreds of times. There
is no short transfer and no early loop exit. So the clamp inside
`Host2Local_Body` (the `LS 0x24220` comparison this document was about to
decode) is not the bug, and the `pixels/2` arithmetic retracted earlier was
doubly wrong: not just the wrong explanation, but an explanation for something
that is not happening.

**2. Blocks 30--31 are never written at all**, i.e. VRAM x 960..1023. That is
outside the 960-pixel region the game uses, so it is correct.

**3. The source data is the problem.** Late in the run the whole row holds a
repeating **6-byte** pattern. At three bytes per pixel that is exactly two
pixels, alternating:

```
(00, F8, 00)  = green
(F8, 00, 00)  = red
```

Green and red alternating per pixel is precisely the green-with-magenta-dots
screen, and it is what the blit is being *given* to copy. The FMV frames that do
show a picture are the moments when about a third of the row carried real decoded
pixels and the rest still carried this pattern.

### So the FMV defect is upstream of the SPU entirely

`Host2Local_Body` faithfully copies what it is handed. Two thirds of what it is
handed is a fixed two-pixel pattern rather than decoded video. That puts the bug
in **MDEC decode** --- the PPU-side video decoder --- which produces roughly a
third of each frame and leaves the remainder as whatever the buffer held.

This is the fifth place this defect has been attributed to in these notes ---
composite, byte order, mip chain, display flip, SPU blit --- and each of the
previous four was closed by measurement. The pattern in the *source* is the first
explanation that accounts for the exact byte values, the exact period, the
partial frames, and the fully-striped frames all at once.

`ps1_netemu` has no `mdec` string anywhere in its image and no `mdec.c` among its
embedded source filenames, so the decoder lives inside one of the modules that do
have names (`gpuio.cc` being the obvious candidate) or in code with no
diagnostics at all. Finding it is the next job; the signature to look for is
whoever fills the staging buffer that `Host2Local_Body` reads.

### The blit is a read-modify-write whose merge contributes nothing

`Host2Local_Body` computes its buffer address as
`0x1D580 + (LS[0x24230] << 12)`, and the transfers measured earlier used
`lsa=0x1D5B0 / 0x1D760 / 0x1D780` --- all in that range. Watching every DMA that
touches LS `0x1D580` (`SPU_WATCHLSA=1D580`) shows what it is:

```
cmd=0x40 (GET) ea=0x4063C000    cmd=0x20 (PUT) ea=0x4066E000
cmd=0x40 (GET) ea=0x40670000    cmd=0x20 (PUT) ea=0x40646000
...
```

**VRAM addresses on both sides.** So LS `0x1D580` is a *destination read-back*
buffer, not the pixel source: the SPU reads VRAM into it, merges, and writes it
back. (spu4's entries at `ea=0x60000000` in the same watch are the audio ring ---
a different module sharing the LS offset, and a reminder to filter by SPU.)

Which explains a pairing this document noticed early and dismissed as
"rasteriser granularity":

```
spu0 cmd=0x40 GET ea=0x40632030 size=48   -- read destination
spu0 cmd=0x20 PUT ea=0x40632030 size=48   -- write it back
     value at the watched word: unchanged
```

Put beside the row coverage --- hundreds of writes per 64-byte block while the
bytes stay the same pattern --- these two say the same thing from different
angles: **the writes are writing the old bytes back.** The read-modify-write
runs, and for most of the row the merge contributes nothing.

So the pattern in VRAM is not something being *written*; it is pre-existing
content that never gets replaced. That is a better-supported statement than the
previous section's "the source data is two-thirds pattern", and it narrows the
question usefully: not "who writes the pattern" but **"why does the merge keep
the destination for two thirds of each row"** --- a mask, a coverage test, or a
source pointer that is short.

Two independent measurements support it (unchanged RMW values; static content
under hundreds of writes), which is worth more than either alone.

### RETRACTION: the merge does contribute --- the blit writes real data

The section immediately above concluded that "the writes are writing the old
bytes back" and that the read-modify-write's merge contributes nothing. **Wrong.**

A PUT copies local store to memory verbatim --- there is no merge inside the DMA
engine --- so the claim was testable directly by printing both sides at the
instant of the write. `SPU_H2LSRC=1` does that for every `Host2Local_Body` write
into PS1 VRAM (LS `0x00350..0x00757`, from the firmware symtab):

```
n=1  pc=0x004DC ea=0x406F1500 size=32  LS=0000DAD6...  VRAM=00000000...  differ
n=2  pc=0x004DC ea=0x40640500 size=128 LS=00000000...  VRAM=00000000...  IDENTICAL
n=7  pc=0x004DC ea=0x40642D00 size=128 LS=110011111110...  VRAM=0000...  differ
n=8  pc=0x004DC ea=0x40643500 size=128 LS=110010010011...  VRAM=0000...  differ
```

The local store holds **real data** and the destination is zero, so those writes
put new content into VRAM. The 16 "IDENTICAL" samples against 5 "differ" are all
**zeros over zeros** --- trivially identical, and no evidence of a broken merge
at all.

How the wrong conclusion happened, because it is the same mechanism as the eleven
before it: the earlier evidence was one watched word whose value stayed
`0x83E083E0` across several GET/PUT pairs, plus row coverage showing static
content under many writes. Both are true. Neither implies the merge does nothing
--- a write of the same value it already held looks identical to a write that
changed nothing, and I generalised from a handful of samples at one address.

Also visible in the same output, and worth keeping: the LS bytes are
`11 00 11 11 11 10 00 01 ...` --- every nibble 0 or 1. That is 4-bit indexed
(CLUT4) data, so these particular blits are **texture and font uploads**, not
movie frames. Attributing them to the FMV path was another over-reach.

**What is measured, and all that is measured:** `Host2Local_Body` copies real
data into VRAM correctly. The FMV renders and advances, with roughly a third of
each row carrying picture. After the movie the game draws nothing and attract
mode never starts. Where the remaining two thirds of a movie row comes from is
**not established**, and the four explanations offered for it in the sections
above --- short transfer, wrong source, stale content, dead merge --- have each
been closed by measurement.

## `Host2Local_Body` read as code --- the blit is correct

Read deliberately rather than probed, from the lifted source, with the firmware
symtab giving the extents. The whole function is four blocks: setup at `0x350`, a
pixel loop `0x3D8 -> 0x400 -> 0x42C -> 0x3D8`, a chunk-flush at `0x4DC`, and a
finish at `0x438`.

### The pixel loop

```c
0x3D8:  off   = x + x                       // x*2: 16-bit pixels
        src_q = LS[srcptr]                  // source quadword
        dst_q = LS[dstbase + off]           // DESTINATION quadword
        inner = inner - 1
0x400:  x     = (x + 1) & 1023              // wraps at the VRAM width
        s_hw  = rotqby(src_q, srcptr + 14)  // extract source halfword
        d_hw  = rotqby(dst_q, dstaddr + 14) // extract dest halfword
        test  = and(MASKCHK, d_hw)          // test a bit in the DESTINATION
        take  = ceqi(test, 0)
        merged= selb(d_hw, s_hw | MASKSET, take)
        LS[dstbase + off] = shufb(merged, dst_q, insert_mask)
        if (inner == 0) goto 0x4DC          // flush this chunk by DMA
        srcptr += 2
0x42C:  outer = outer - 1
        if (outer != -1) goto 0x3DB8 else goto 0x438
```

Three things fall out, and they all check out against measurements already taken:

**The chunk size is 24 pixels.** `inner` comes from `rotqbyi(LS[0x24220], 4)`,
i.e. word 1 of that quadword, measured as `0x18` = **24**. 24 pixels x 2 bytes =
**48 bytes**, which is exactly the DMA size seen in every `Host2Local_Body`
transfer from the very first trace. The granularity that this document once
called "the rasteriser's 48-byte read-modify-write" is simply the blit's chunk.

**The mask test is real but disabled.** `MASKCHK` is
`and(shlhi(rotqbyi(LS[0x150E0],12),15), 0xFFFF)` --- `shlhi(x,15)` leaves exactly
one bit, so it is `0x8000` when a flag byte is set and `0` when it is not. That
is the PS1 **STP / "check mask before draw"** bit, and `MASKSET` beside it is
"set mask on draw". Measured:

```
LS[0x150E0] = 00000000 00000100 00000000 00000000
              word3 -> MASKCHK = 0     word2 -> MASKSET = 0
```

Both zero, so `dest & 0 == 0` is always true and **every pixel takes the
source**. The mask-rejection hypothesis --- raised early, dropped on weak
evidence, and revived by this code --- is now dead on a measurement of the flag
the code actually reads.

**The x coordinate wraps at 1024**, which is correct for PS1 VRAM.

### So the blit is not the bug

It copies 24 pixels per chunk, unconditionally, wrapping correctly, and DMAs 48
bytes --- all of which match what was measured from the outside. The **extent** of
a transfer is set entirely by two counters it is handed:

```
outer = min(cmd[+0x10], LS[0x24220].word0) - 1      // rows / spans
inner = LS[0x24220].word1                            // = 24, pixels per chunk
```

and the pixel data itself is **inline in the command** (`srcptr` starts at
`cmd + 20`). So how much of a row gets written is decided by whoever builds the
command --- PPU-side --- not by the SPU.

That is the boundary this port has been circling all session, now placed by
reading rather than guessing: **everything from the command onward is correct.**
The remaining FMV question lives entirely on the PPU side of that handoff.

One caution recorded for whoever reads `LS[0x24220].word0` next: sampled at a
yield it reads **0**, which would make `outer = -1` and skip the loop entirely.
It cannot be 0 during an active transfer, since the loop demonstrably runs 239
million times --- the sample is simply taken between transfers. That is the
compare-two-moments trap this document has fallen into a dozen times; anyone
wanting that value must read it *inside* the transfer, not from a poll.

## MEASURED AT THE SOURCE: the movie's pixel data is the pattern

The retraction two sections above --- "the merge does contribute, the blit writes
real data" --- was measured on the **first ten** blits of a run. Those are
texture and font uploads (their bytes are CLUT4, every nibble 0 or 1). The movie
blits happen hundreds of thousands of writes later, and sampling *those* gives
the opposite answer.

`SPU_H2LSRC=1`, late samples, during the blank phase:

```
n=4400000 pc=0x004DC ea=0x40667EC0 size=48 LS=F800000000F8F800000000F8
                                           VRAM=F800000000F8F800000000F8 IDENTICAL
n=4600000 pc=0x004DC ea=0x40617DA0 size=48 LS=F800000000F8F800000000F8  IDENTICAL
n=4800000 pc=0x004DC ea=0x4063FC50 size=48 LS=F800000000F8F800000000F8  IDENTICAL
n=5000000 ...  n=5200000 ...  n=5400000 ...   all IDENTICAL
```

30 IDENTICAL against 5 "differ", and the 5 are the early texture uploads.

**The local store holds the pattern.** The blit copies it faithfully into VRAM,
which already contains the same bytes --- which is why the writes look like
no-ops and why the row never changes however many times it is written.

`F8 00 00 00 00 F8` repeating is a **6-byte period**: as 24-bit pixels that is
`(F8,00,00)` and `(00,00,F8)`, red and blue alternating, which is the
green-and-magenta screen after the composite's colour handling.

### Which places the defect exactly

The pixel data for a `Host2Local` command is **inline in the command**
(`srcptr = cmd + 20`, established by reading the function). So the command built
on the **PPU side** already carries the pattern. Everything from there on ---
the SPU blit, the DMA, VRAM, the texture bind, the composite --- is faithful, and
each has been separately measured to be so.

So the FMV defect is: **whatever fills the movie's CPU-to-VRAM command produces a
two-pixel repeating pattern instead of decoded video.** That is MDEC output, on
the PPU side, and it is the last unmeasured link in the chain.

### And the movie never stops

Phase-resolved write accounting (`SPU_VRAMPC` deltas between consecutive
reports, plus a per-buffer split) during the blank phase:

```
BlockClear        0 new          Host2Local_Body  20,000 new (all of them)
buf0 (0..959)     +450 KB        buf1 (960..1919) +175 KB      tex 0 KB
```

A 320x240 24-bit frame is 230 KB, so that is roughly two frames per window
landing in buffer 0 and most of one in buffer 1. **The movie is still streaming
through the entire "blank" phase**, into both display buffers, carrying the
pattern. The screen is not blank because nothing is happening --- it is blank
because what is being drawn is a flat pattern.

That also explains why attract mode never appears: the title is still inside
movie playback, feeding frames that carry no picture, and it has no reason to
move on.

### A value watch on the pattern word, and why its answer is not the answer

`FLOW_WVAL=F8000000` catches any 32-bit guest store of the pattern's first word
and prints the writing function. 208 hits, all of this shape:

```
[WVAL] write32 0x0076C088 = 0xF8000000
   r3=7C000000  r23=0076C080  r17/r18=00770780
   stack: func_001066A8 -> func_001056E4 -> func_000B66E0 -> func_000B3738 -> ...
```

**Read this carefully before believing it.** `r23 = 0x0076C080` is the R3000
state block and `0x0076C088` is state+0x08, which is MIPS register **`$v0`**
(register 2, at `reg*4`). `r3 = 0x7C000000` and the stored value is
`0xF8000000` --- exactly `r3 << 1`. So these are the interpreter writing the
result of an ordinary PS1 shift into a register file slot, and `func_001066A8`
at the top of the stack is the interpreter itself.

They are **not** stores of movie pixels into the command ring. The watch matches
on *value*, and this value occurs in ordinary PS1 arithmetic. Filtering by value
cannot find the ring writer; that needs a watch on the ring's *address*, and the
ring rotates, so it needs the ring base resolved live first
(`*(TOC-0x7918)` = `*(0x1BC418)`).

What it does add, weakly: the pattern word appears inside R3000 register traffic
in code reached through `func_000B66E0` / `func_000B3738`, so the PS1 side is
handling values of this shape rather than the pattern being injected wholesale by
the PS3 side. Consistent with the game reading MDEC output and getting constants
back, but not evidence for it.

## Where this port stands, and what the last link needs

The chain from disc to screen is now measured end to end, and every link but one
is confirmed faithful:

```
disc -> CD read           works (the FMV streams continuously)
MDEC output               *** the pattern enters here ***
PPU builds H2L command    carries the pattern inline at cmd+20
SPU Host2Local_Body       correct: 24 px/chunk, 48 B DMA, mask test off, x wraps
DMA to PS1 VRAM           correct: full row coverage measured
texture bind              correct: single unit, offsets and formats measured
composite / shaders       correct: screen reconstructed from VRAM bytes exactly
```

**The last link is MDEC**, the PS1 video decoder, on the PS3 side of the
emulator. `ps1_netemu` carries no `mdec` string, no `mdec.c` among its embedded
source filenames, and no symbols for it, so locating it means working from the
PS1 hardware interface inwards: the MDEC registers at `0x1F801820`/`0x1F801824`
and DMA channels 0 (MDEC-in) and 1 (MDEC-out), all of which appear in the PS1
I/O handler map already documented in this file.

That is a piece of work in its own right rather than another measurement, and it
is the honest boundary of this session.

### What the three goal elements need

| element | state | what it is waiting on |
|---|---|---|
| intro videos | frames render and advance; picture degrades to pattern | MDEC output |
| main menu | **renders**, reproducible unattended via `PAD_SCRIPT` | --- |
| attract mode | never begins | the title stays inside movie playback because the movie carries no picture, so the same MDEC defect |

Two of the three are reached. The third is blocked by the same single defect as
the first, which is a better position than "three separate unknowns" --- but it
is not the goal met, and it should not be written up as if it were.

## ATTRACT MODE: the blocker is that the intro movie never ends

Two experiments settle what attract mode is waiting on.

### 1. The rasteriser works in-game --- it is not a rendering problem

Driving past the movie with `PAD_SCRIPT` and letting the game run:

```
DrawEdge   93,556 / 70,631 / 69,953 / 118,461 entries across the four SPUs
DrawRect   106,885            BlockClear  2,778,210
```

and `SPU_VRAMPC` shows `DrawEdge` reaching VRAM too (4,527 writes, 70 KB). So
once the game is out of movie playback the polygon rasteriser runs and its pixels
land in VRAM. Whatever blocks attract mode, it is not the renderer.

### 2. Undriven, the movie never ends --- 560 s, the longest run attempted

```
DrawEdge     absent from the histogram entirely -- zero, all four SPUs
BlockClear   frozen at 11,655 -- not one frame clear in the whole run
H2L_Body     1,732,247,214 -> 1,732,714,734 between the last two reports
```

`H2L_Body` is still climbing after nine minutes of wall time; the movie is still
streaming. `BlockClear` frozen means **the game is not even clearing frames** ---
it is doing nothing but blitting movie frames, forever.

So the title never leaves intro playback. Attract mode follows the intro, so it
never begins. That is the whole blocker, stated as a measurement rather than an
inference.

### What that means together with the source measurement

The movie's pixel data is a two-pixel repeating pattern (measured in local store
at the blit). A title playing a movie that produces no picture, and never
reaching its end, is one situation and not two: whatever decides "the movie is
finished" is downstream of the same decode that is producing pattern instead of
frames.

**The sequence, as it actually stands:**

```
intro logos    render
title screen   renders, full colour
intro movie    frames render and advance, then degrade to pattern -- AND NEVER ENDS
attract mode   never begins, because playback never finishes
main menu      renders, but only reachable by pressing past the movie
```

Two of the three goal elements are reached. The third is blocked by movie
playback not terminating, which is the same defect as the first --- so the port
is one bug away from the sequence rather than three.

The next lap has a single target and it has not moved for several sections now:
**MDEC**, the PS1 video decoder on the PS3 side. No strings, no symbols, no
source filename in the image, so it has to be found from the PS1 hardware
interface inwards --- the MDEC registers at `0x1F801820` / `0x1F801824` and DMA
channels 0 and 1, all already mapped in the PS1 I/O handler table documented
earlier in this file.

### The disc is not being read during playback --- so it is a WAIT, not a stream

`PS3_FSTRACE=100` prints every hundredth disc read with its file offset. Over a
300 s run:

```
[fs] n=100 fd=7 off=32899072 size=65536 -> 65536
[fs] n=200 fd=7 off=3211264  size=65536 -> 65536
[fs] n=300 fd=7 off=7471104  size=65536 -> 65536
[fs] n=400 fd=7 off=14024704 size=65536 -> 65536

total traced: 4      (i.e. ~400 reads in the entire run, all early)
```

**Four hundred reads, then nothing for the rest of the run** --- while
`Host2Local_Body` climbs past 1.7 billion hops and keeps climbing. So the movie
is not streaming off the disc at all during the endless playback. No new data is
arriving, and the game is re-blitting what it already has, indefinitely.

That changes the character of the blocker. "The movie never ends" reads like a
stream that is too long or never terminates; it is not. **The game is waiting**
--- spinning in a playback loop, pushing the same frame data at VRAM, while
something it expects never arrives.

Which fits every other measurement:

| observed | consistent with a wait? |
|---|---|
| `H2L_Body` climbing forever | yes --- the loop keeps re-blitting its buffer |
| `BlockClear` frozen at 11,655 | yes --- a waiting loop does not start new frames |
| `DrawEdge` zero | yes --- no new geometry while waiting |
| pixel source is a fixed pattern | yes --- the buffer it re-blits was never filled with a decoded frame |
| the guest never stops executing | yes --- it is a spin, not a hang |
| disc reads stop | yes --- it is not waiting for *data*, it is waiting for an *event* |

So the question is no longer "why is the movie so long" or even "why is the
picture wrong", but: **which completion does the title wait on after it has read
its movie data?** MDEC decode-done and the MDEC-out DMA (channel 1) are the two
candidates on the PS1 side, and both are in the I/O handler map recorded earlier
in this document.

This is the same shape as the bug fixed at the top of this session --- a PPU/SPU
pair each waiting for the other, resolved by finding the one signal that never
fired. The instruments for that already exist here (`PS1_SPINWAIT`,
`SPU_WHOPOLLS`, `PPU_RWATCH`, `PS3_EVQSTAT`) and none of them has yet been
pointed at the R3000's view of MDEC.

### CORRECTION: the R3000 is not waiting --- it is looping in a decoder

The previous section concluded "the game is waiting -- spinning in a playback
loop while something it expects never arrives", from the fact that disc reads
stop. The disc observation is right; the conclusion drawn from it is not.

`PS1_R3000_PC` during the endless playback:

```
pc~0x801645C0  52669 (1.1%)     pc~0x80156C80  15361 (0.3%)
pc~0x8015F140  22395 (0.4%)     pc~0x80164F00  15213 (0.3%)
pc~0x80164600  19603 (0.4%)     pc~0x8015F180  12173 (0.2%)
```

No bucket takes more than **1.1%**. A spin pins one bucket at nearly 100% ---
that is exactly how the deadlock at the top of this session was found. The R3000
is spread across many addresses, i.e. **executing real code**, not waiting.

And the hot loop is legible. `[r3000mem]` at `0x80164F80`:

```
94E20004  lhu   $v0, 4($a3)          ; read a 16-bit code
24A50002  addiu $a1, $a1, 2
3043FFFF  andi  $v1, $v0, 0xFFFF
A4A20000  sh    $v0, 0($a1)          ; store it out
34027C1F  ori   $v0, $zero, 0x7C1F   ; compare against marker 0x7C1F
1062001C  beq   $v1, $v0, +0x1C
28627C20  slti  $v0, $v1, 0x7C20
10400005  beq   $v0, $zero, +5
1060FFBA  beq   $v1, $zero, -70      ; loop back
000414C2  srl   $v0, $a0, 19
080593F0  j     0x164FC0
3402FE00  ori   $v0, $zero, 0xFE00   ; compare against marker 0xFE00
1062FFDF  beq   $v1, $v0, -33        ; loop back
00041D82  srl   $v0, $a0, 22
```

A loop that reads 16-bit codes, writes them out, and tests each against two
terminator constants, with shifts of `$a0` by 19 and 22 (bit-field extraction
from a packed word). That is a **run-length / bitstream unpacker**, and the two
constants are meaningful:

- **`0xFE00`** is the PS1 MDEC **end-of-block** code.
- **`0x7C1F`** is 15-bit R=31 G=0 B=31 --- magenta, the conventional colour key.

Registers at the same instant: `$a3=0x8017E47C` (source), `$a1=0x801E6AFC`
(destination, incrementing by 2), `$s2=0x007FFFFF` (a 23-bit mask),
`$ra=0x80164824`.

**So the title is decoding, indefinitely.** The natural reading is a decoder
whose input never yields its terminator: it consumes, emits, and loops, which is
exactly what produces an ever-climbing blit count, no new frame clears, no
geometry, and a destination buffer that fills with a repeating two-pixel pattern
rather than a picture.

That is a materially different bug shape from "waiting on an event", and it is
better supported --- the PC distribution rules the wait out directly. It also
brings the FMV defect and the attract-mode blocker together in one place: **the
same decoder loop both fails to produce a picture and fails to terminate.**

Recorded as a correction rather than an edit, because the wait framing was
published one section above and someone reading forward should see why it was
wrong: disc reads stopping means no new data is arriving, which is equally
consistent with a decoder chewing on data it already has.

### The decoder is table-driven, and its table is intact

`$a3 = 0x8017E47C` is the pointer the hot loop reads (`lhu $v0, 4($a3)`), and it
does **not** advance inside the loop --- so it is a table base, not a bitstream
cursor. PS1 `0x8017E47C` maps to guest `0x00770780 + 0x17E47C` =
**`0x008EEBFC`**, read live over the `PS3_DEBUG` console during playback:

```
0x008EEBFC  0A 00 FF 1B 01 00 00 00   0C 00 FF 1B 01 00 00 FE
0x008EEC0C  0C 00 FF 1B 01 00 00 FE   0D 00 FF 1B 01 00 01 00
0x008EEC1C  0D 00 FF 1B 01 00 FF 03   0A 00 FF 1B FF 03 00 00
...
0x008EEC6C  0D 00 02 04 1F 7C 00 00   07 00 02 04 00 00 00 00
```

Eight-byte records, little-endian, of the shape
`(u16 length, u16 mask, u16 a, u16 b)`:

```
(0x000A, 0x1BFF, 0x0001, 0x0000)     length 10
(0x000C, 0x1BFF, 0x0001, 0xFE00)     length 12  <- 0xFE00 present
(0x000D, 0x1BFF, 0x0001, 0x03FF)     length 13
(0x000D, 0x0402, 0x7C1F, 0x0000)     length 13  <- 0x7C1F present
```

First fields of 10, 12, 13 with bit masks are **Huffman code lengths** --- this is
a table-driven variable-length decoder, which is what the `srl $a0, 19` and
`srl $a0, 22` bit-field extractions in the loop are feeding.

**And both terminators the loop tests for are present in the table**: `0xFE00`
(MDEC end-of-block) and `0x7C1F` (the magenta key). So "the decoder never finds
its terminator because the table lacks it" --- the natural next guess after the
previous section --- is **dead**. The table is intact and contains exactly the
values the loop compares against.

That closes the fifth explanation for this defect in as many sections. What
remains unexplained is narrow and precise: a table-driven Huffman decoder, with a
valid table containing valid terminators, that nonetheless emits a repeating
two-pixel pattern and does not terminate. The remaining candidates are the
**bitstream it is reading** (wrong, empty, or not advancing) and the **bit-field
extraction** feeding the table lookup --- and the loop's own registers are the
place to look: `$a0` is the packed word being shifted, `$s2 = 0x007FFFFF` a
23-bit mask, `$a1` the output cursor at `0x801E6AFC`.

Watching `$a0` across iterations would say immediately whether the bitstream is
advancing. `PS1_R3000_PC`'s register dump already prints every GPR; it just needs
to be sampled inside this loop specifically rather than at yields, which is a
gate on `pc` in the range `0x80164F00..0x80165000`.

## THE BOUNDARY, FOUND: the R3000 feeds MDEC correctly and MDEC returns a pattern

Two measurements close this out, and they also correct the two commits before
them.

### The decode loop is not stuck, and not broken

`PS1_LOOPWATCH=80164F00` samples the R3000 register file only when the pc is
inside that 256-byte window:

```
n=1  pc=0x80164FDC a0=E9C48800 a1=801DFFB4 a3=8018C61C
n=2  pc=0x80164F90 a0=33409800 a1=801E012E a3=80180A9C
n=3  pc=0x80164FB0 a0=553F7600 a1=801E0402 a3=80182774
...
n=340000 pc=0x80164F28 a0=32F33900 a1=801D16BA a3=8017D714
```

`$a0` --- the packed bitstream word the `srl 19` / `srl 22` extractions read ---
**changes on every sample**. `$a1`, the output cursor, advances. `$a3` varies per
code, so it is a per-entry table pointer rather than a fixed base.

So the loop is **consuming a real bitstream and producing output**, continuously.
It is not an infinite loop and it is not waiting: both of the previous two
sections' framings were wrong, and for the same reason each time --- a loop that
runs forever looks identical to a loop that is stuck unless you watch its inputs
change.

### And its output is well-formed MDEC input

The output lands around PS1 `0x801E0400` = guest `0x00950B82`. Read live during
playback:

```
0x00950B80  02 04 01 00 02 04 FE 03 FB 07 01 00 01 00 01 00
0x00950BB0  00 FE 10 1B FE 03 01 00 FD 03 FF 03 FF 03 FF 03
0x00951010  FF 37 00 FE 18 10 01 00 FF 03 01 00 FF 17 00 FE
0x00951020  ED 13 FF 03 FF 03 FF 03 FF 1B 00 FE 5B 12 FF 07
```

`00 FE` little-endian is **`0xFE00` --- the MDEC end-of-block code** --- and it
recurs throughout, separating runs of 16-bit values. That is exactly the shape of
an MDEC input stream: run/level coefficient pairs, one `0xFE00` per block.

**So this loop is the software Huffman/RLE stage that produces MDEC *input*, not
MDEC output.** The PS1 pipeline is:

```
disc -> STR bitstream -> [R3000 software Huffman]  -> coefficient blocks
     -> [MDEC: IDCT + YUV->RGB]                    -> 24-bit pixels
     -> [blit to VRAM] -> display
```

and the measurement above verifies the **first** stage: the R3000 emits
well-formed blocks with correct terminators, continuously.

### Which places the defect exactly, with the input verified

Everything downstream of MDEC was already measured correct in earlier sections
--- the blit (read as code), the DMA, VRAM coverage, the texture bind, the
composite (reconstructed pixel-for-pixel). Now the stage **upstream** of MDEC is
verified correct too.

**The defect is MDEC itself** --- the IDCT and YUV-to-RGB stage --- which is
emulated on the PS3 side. It is handed valid coefficient blocks and returns a
two-pixel repeating pattern. That is why the FMV has no picture, and why the
title never leaves playback.

This is the same conclusion reached several sections ago by elimination, but it
now rests on a positive measurement of MDEC's input rather than on having ruled
out everything else. The two are worth different amounts.

### For whoever picks this up

`ps1_netemu` has no `mdec` string, no `mdec.c` among its embedded source
filenames and no symbol for it, so it must be found from the hardware interface
inwards. The handles now available:

- the coefficient stream is at PS1 `0x801E0000`-ish (guest `0x00950780`-ish) and
  is verifiably correct, so it can be used as a known-good input
- MDEC control and data registers are PS1 `0x1F801820` / `0x1F801824`
- MDEC-in is DMA channel 0, MDEC-out is DMA channel 1, both already in the PS1
  I/O handler map recorded earlier in this file
- `PPU_RWATCH` on the coefficient buffer names the PPC function that reads it ---
  which *is* the MDEC front end, whatever it is called

### Correction to the handles above: the coefficient buffer moves

The previous section offered "the coefficient stream is at PS1 `0x801E0000`-ish
(guest `0x00950780`-ish), so it serves as a known-good input". That address is
where it happened to be in one sample. `PPU_RWATCH=950B80,256` over a 250 s run
caught **no reads at all**.

The reason is in the loop's own register trace, one section above: the output
cursor `$a1` ranges over `0x801CExxx` to `0x801E7xxx` --- roughly **100 KB** ---
so a fixed 256-byte watch window almost never coincides with wherever the decoder
is currently writing. The buffer is a rotating pool, not a fixed address.

So the negative result says nothing about who reads the coefficients. Recorded
because the handle as written would send the next reader after a watch that
cannot fire, and because it is the same error as everything else here in a new
costume: a value sampled once, generalised into a constant.

**A watch that would work** has to follow the cursor rather than guess it: gate
on the PS1 pc being inside the decode loop, read `$a1` from the register file at
that moment, and arm the read watch on *that* address --- or widen the watch to
the whole `0x801C0000..0x801F0000` span if the volume is tolerable. Neither is
difficult; the point is that the fixed-address version is not the same
experiment.

## MDEC IS NAMED: `func_000E9A18` (write) and `func_000EA2F0` (read)

The last unmeasured link now has an address. Found without symbols or strings, by
going through the I/O registration this document already mapped.

### How it was found

The coefficient span is read only by `func_001066A8` --- the R3000 interpreter
itself (`PPU_RWATCH` over `0x00930780..0x00960780`, 24 hits, all the same
function). So the coefficients are consumed through the **emulated I/O path**,
not by a separate PPC routine reading PS1 RAM. That points at the registered
handler for the MDEC window, and the registration site is a single instruction
away:

```
000E8E90  lwz  r5, -0x7bc4(r2)     ; read handler OPD
000E8E94  lis  r3, 0x1f80
000E8E98  lwz  r6, -0x7bc0(r2)     ; write handler OPD
000E8EA8  ori  r3, r3, 0x1820      ; base = 0x1F801820  -- MDEC
000E8EAC  li   r4, 0x10            ; size
000E8ED4  bl   0xc23e0             ; the I/O registrar
```

Resolving the two OPDs:

```
MDEC read handler    TOC-0x7BC4 = 0x1BC16C -> OPD 0x001B5E10 -> func_000EA2F0
MDEC write handler   TOC-0x7BC0 = 0x1BC170 -> OPD 0x001B5DF8 -> func_000E9A18
```

### And it is a real implementation, not a stub

`func_000E9A18`:

```
000E9A18  rlwinm r3, r3, 0, 0x1c, 0x1d   ; addr & 0xC -> register offset
000E9A24  cmpwi  cr7, r3, 0
000E9A70  beq    cr7, 0xe9ad4            ; offset 0 -> MDEC0, data/command
000E9A74  cmpwi  cr7, r3, 4
000E9A78  beq    cr7, 0xe9c84            ; offset 4 -> MDEC1, control/status
000E9A7C  lwz    r29, -0x7b80(r2)        ; otherwise return
```

It masks the address to bits 28--29 for the register index, dispatches MDEC0 and
MDEC1 separately, saves fifteen registers and runs a 0xF0-byte frame. That is
substantial code --- MDEC is implemented, not stubbed, so the fault is inside its
data path rather than absent.

### The state of the whole chain

```
disc -> STR bitstream
     -> [R3000 software Huffman]      VERIFIED CORRECT (well-formed blocks, 0xFE00)
     -> [MDEC func_000E9A18 / func_000EA2F0]   *** returns a 2-pixel pattern ***
     -> [SPU Host2Local_Body]         VERIFIED CORRECT (read as code)
     -> [DMA to PS1 VRAM]             VERIFIED CORRECT (full row coverage)
     -> [texture bind]                VERIFIED CORRECT (single unit, formats)
     -> [composite]                   VERIFIED CORRECT (screen rebuilt from bytes)
```

Every stage either side of MDEC is positively verified. MDEC is handed valid
coefficient blocks and returns a repeating two-pixel pattern, which is why the
FMV has no picture and why the title never leaves playback and never reaches
attract mode.

### The next step, concretely

`0xE9AD4` is the MDEC0 path --- where coefficient writes land --- and `0xE9C84`
is MDEC1, control. `func_000EA2F0` is the read side, i.e. where decoded pixels
come back out. Both are ordinary PPC functions in the lifted tree, so they can be
read directly, and the input feeding them is already known good.

The specific question to answer first: does the MDEC0 path accumulate a full
block and run an IDCT, or does it return a constant/placeholder? A repeating
two-pixel output is what a colour conversion fed constant coefficients would
produce, so the DC-coefficient handling in `0xE9AD4` is the place to start.

### The MDEC0 path is event-driven --- and it uses the scheduler read at the top of this file

Disassembling the MDEC0 branch of `func_000E9A18`:

```
000E9AD4  lwz    r6, -0x7bc8(r2)        ; MDEC state struct
000E9ADC  lwz    r0, 0x810(r6)          ; status word
000E9AE0  rlwinm r0, r0, 0, 1, 1        ; isolate bit 30 (0x40000000)
000E9AE8  beq    cr7, 0xe9c6c           ; clear -> other path
000E9AEC  lwz    r7, 0x82c(r6)          ; an event node pointer
000E9AF0  lwz    r30, 0x814(r6)
000E9AF8  beq    cr7, 0xe9d24           ; null -> skip
000E9B00  lwz    r29, -0x7b80(r2)
000E9B04  stw    r3, 0x82c(r6)
000E9B08  lwz    r8, 4(r10)             ; ---- unlink r7 from its list ----
000E9B0C  lwz    r0, 0(r10)
000E9B18  stw    r0, 0(r11)
000E9B20  stw    r8, 4(r9)
000E9B24  lwz    r11, 0x544(r29)        ; ---- re-insert at the list tail ----
000E9B2C  stw    r11, 4(r10)
000E9B34  stw    r0, 0(r10)
000E9B3C  stw    r7, 0(r9)
000E9B40  stw    r7, 4(r11)
000E9B44  lwz    r7, 0x830(r6)          ; a SECOND node, identical treatment
```

`r29 = *(TOC-0x7B80)` and the list it links onto is at **`+0x544`**. The R3000
event list head is at **`state+0x540`**, and `+0x544` is its tail pointer ---
exactly the structure decoded from `func_00105FA8` at the very top of this
document, with nodes shaped

```
+0x00 next   +0x04 prev   +0x08 due time   +0x0C callback OPD   +0x10 arg
```

So **MDEC register writes schedule R3000 events**: the handler takes two
preallocated nodes from its own state (`+0x82C` and `+0x830`), unlinks each from
wherever it sits, and appends it to the scheduler's queue. Those are the MDEC
completion / DMA-interrupt events, and they are dispatched by the same
`func_00105FA8` loop whose `bctrl` at `0x106050` fires event callbacks --- the
loop that the GETLLAR deadlock fixed at the start of this session was found
inside.

That is a useful connection rather than a coincidence: the MDEC data path,
the event scheduler, and the callback that spins on spu4 are all one mechanism,
and this port already has the scheduler read instruction by instruction and the
node layout confirmed by live dumps.

**Where that leaves the next attempt.** `func_000E9A18` handles MDEC0 by
scheduling events; the actual coefficient consumption and IDCT must therefore
live either in the callback those nodes point at (`+0x0C` of each node, readable
live from `state+0x540` with the console) or behind the `0xE9C6C` / `0xE9D24`
branches taken when the status bit or a node pointer is clear. Dumping the two
nodes at MDEC-state `+0x82C` and `+0x830` names their callbacks outright, and
the machinery to do it --- `PS3_DEBUG`'s `mem`, plus the node layout --- is
already in place and used elsewhere in this file.

### The MDEC event nodes, and what one sample of them does and does not prove

`*(TOC-0x7BC8)` resolves to MDEC state **`0x002EB9D0`**, and `*(TOC-0x7B80)` to
**`0x0076C080`** --- the R3000 state block, which independently confirms the
`+0x544` in the disassembly really is that block's event-list tail.

So the two node pointers are at `0x002EC1FC` and `0x002EC200`. Read live, 200 s
into a run, mid-playback:

```
0x002EC1F0  00 00 00 00 00 00 00 C0 00 00 00 04 00 00 00 00
0x002EC200  00 00 00 00 00 00 0B 00 00 00 00 00 00 00 00 00
             ^^^ +0x82C = 00000000        ^^^ +0x830 = 00000000
```

**Both NULL**, and the handler branches on exactly that:

```
000E9AEC  lwz   r7, 0x82c(r6)
000E9AF4  cmpwi cr7, r7, 0
000E9AF8  beq   cr7, 0xe9d24        ; NULL -> skip
```

and `0xE9D24` turns out to be only

```
000E9D24  lwz r29, -0x7b80(r2)
000E9D28  b   0xe9b44               ; skip to the SECOND node's block
```

--- a skip, not an allocator. The second node is NULL too, so its block is
skipped as well. On this path, **nothing is scheduled.**

**What that does not prove.** The block being skipped *unlinks* a node and
*appends* it to the tail --- that is a **re-schedule** of an already-queued
event, not a first-time enqueue. So NULL most likely means "no MDEC event
currently in flight", which is unremarkable in itself, and the code that first
creates these events is elsewhere.

And it is **one sample**, taken at one instant. Sampling a pointer once and
concluding it is always null is precisely the error that has produced fourteen
retractions in this document. It is recorded here as an observation with its
caveat attached, not as a cause.

**What it is worth.** Both nodes null *during active movie playback* is at least
suggestive: if MDEC were mid-operation, one would expect an event pending. Making
that solid needs the pointers sampled repeatedly --- e.g. `PPU_RWATCH` on
`0x002EC1FC` to catch every read, or the console polled across the phase --- and
either would settle in one run whether MDEC ever has work in flight at all.

That is the next measurement, and it is a small one. The addresses, the state
struct, the handler, the branch targets and the event-list layout are all now
written down.

### The MDEC module, bounded --- four entry points, and it is running

`PPU_RWATCH=2EC1FC,8` catches every read of the two event-node pointers.
**146 hits in 240 s**, from three distinct functions:

```
func_000EA44C    72 reads
func_000EAA88    65 reads
func_000E9A18     9 reads     (the write handler, already identified)
```

Two things follow.

**MDEC is active.** The nodes are read continuously through playback, so the
event machinery is being exercised and the "both pointers NULL" reading from the
previous section was exactly what it was flagged as --- a sample taken between
operations, not evidence that scheduling never happens. Recording that caveat
rather than the conclusion was the right call: the follow-up measurement
contradicted the tempting reading, as it has fourteen times before in this file.

**And the module is bounded.** With the two handlers from the I/O registration
plus these, the MDEC implementation is:

```
func_000E9A18   MDEC register WRITE handler   (registered for 0x1F801820, size 0x10)
func_000EA2F0   MDEC register READ handler    (same registration)
func_000EA44C   reads the event nodes -- 72x
func_000EAA88   reads the event nodes -- 65x
```

a contiguous block of code from roughly `0x000E9A18` to `0x000EAB00`, in a
firmware with no `mdec` string, no `mdec.c` source name and no symbol for any of
it. That is the module the remaining defect lives in.

### Final state of this investigation

```
disc -> STR bitstream
     -> [R3000 software Huffman]         VERIFIED CORRECT
     -> [MDEC: E9A18 / EA2F0 / EA44C / EAA88]   *** 2-pixel pattern out ***
     -> [SPU Host2Local_Body]            VERIFIED CORRECT
     -> [DMA to PS1 VRAM]                VERIFIED CORRECT
     -> [texture bind]                   VERIFIED CORRECT
     -> [composite]                      VERIFIED CORRECT
```

The defect is inside a four-function module that is **running**, is handed
**verified-correct input**, and whose **entire output path is verified correct**.
It emits a repeating two-pixel pattern instead of decoded pixels, which is why
the intro movie shows no picture, why the title never leaves playback, and why
attract mode never begins.

Fixing it means reading the arithmetic in those four functions --- the IDCT and
the YUV-to-RGB conversion --- against the PS1 MDEC specification. That is
implementation work, not measurement, and it is where this stops.

### The MDEC handlers contain no arithmetic --- the decode runs through DMA

Checked before assuming: an IDCT is vector or float work, so if our lifting of a
vector instruction were wrong that would explain a constant output. It is not
that. Instruction mixes across `func_000E9A18`, `func_000EA2F0`,
`func_000EA44C`, `func_000EAA88` and their three callees
(`func_000D0C8C`, `func_000D02A4`, `func_000D060C`) contain **no vector, no
float, and no load/store-vector instructions at all** --- only integer loads,
stores, compares and branches.

So these functions are plumbing, and the callees say what kind:

```
000D02A4  slwi   r0, r3, 6        ; r3 * 64
000D02AC  slwi   r3, r3, 3        ; r3 * 8
000D02B4  subf   r0, r3, r0       ; -> r3 * 0x38, a per-channel stride
000D02B8  add    r0, r0, r9       ; + base from *(TOC-0x7D88)
000D02C0  lwz    r9, 0x20(r11)
000D02C4  cmpwi  cr7, r9, 1
000D02CC  lwz    r0, 0x30(r11)
000D02D0  cntlzw r10, r0
000D02D4  srwi   r10, r10, 5      ; -> boolean "is +0x30 zero"
```

A **DMA channel status query** over 0x38-byte per-channel records, called eight
times from the MDEC module. So the MDEC path is: register writes set up state and
schedule events, and the actual pixel movement happens through the **DMA
channels** --- MDEC-in on channel 0 and MDEC-out on channel 1, both already in
the PS1 I/O window map recorded earlier.

That is where the remaining work is, and it is worth being precise about what
kind of work: the firmware's MDEC is correct code that runs on real hardware, so
a two-pixel pattern coming out of it means **this port** mishandles something it
does --- most plausibly one of those DMA channels, since that is the mechanism
the handlers actually rely on and the one thing in the chain not yet verified.

The per-channel record base is `*(TOC-0x7D88)` and the fields the query reads are
`+0x20` (a mode/state) and `+0x30` (a count or busy flag). Dumping channel 0 and
channel 1 records during playback is a small measurement, and it is the one this
investigation would take next.

## PROVEN AT THE SOURCE: MDEC writes the pattern into PS1 RAM

The DMA channel records resolve from `*(TOC-0x7D88)` = `0x002DEDE8`, 0x38 bytes
per channel. Read twice during playback, both MDEC channels are **live**:

```
ch0 (MDEC-in)   +0x10: 001D61B4 -> 001E88B4     source, inside the coefficient range
ch1 (MDEC-out)  +0x10: 001F5530 -> 001F5230     destination
                +0x24/28/2C: 001B5DE8 / 001B5DE0 / 001B5E18   callback OPDs
```

Addresses advance between samples, so both channels are transferring. Channel 0's
source lies exactly in the range the Huffman stage writes to (`0x801Cxxxx` --
`0x801E7xxx` physical `0x1Cxxxx`--`0x1E7xxx`), which independently confirms the
coefficient buffer feeds MDEC-in.

Channel 1's destination is MDEC's **output**: PS1 `0x001F5530` = guest
`0x00965CB0`. Read live:

```
0x00965C00  F8 00 00 F8 00 FF FF FF 00 F8 00 00 F8 00 00 F8
0x00965C10  00 00 F8 00 00 F8 00 00 F8 00 FF 00 FF FF FF FF
0x00965C20  00 F8 00 00 F8 00 00 F8 00 00 F8 00 00 F8 00 00
```

As 24-bit triples: `(F8,00,00)` red, `(00,F8,00)` green, with occasional
`(FF,FF,FF)` white. **That is the pattern, in MDEC's own output buffer, before
any blit touches it.**

### The chain is now closed with a positive measurement at every stage

```
disc -> STR bitstream
     -> [R3000 software Huffman]   VERIFIED CORRECT   (well-formed blocks, 0xFE00)
     -> [DMA ch0 MDEC-in]          VERIFIED ACTIVE    (source advancing, in range)
     -> [MDEC]                     *** WRITES THE PATTERN ***  (measured here)
     -> [DMA ch1 MDEC-out]         VERIFIED ACTIVE    (destination advancing)
     -> [SPU Host2Local_Body]      VERIFIED CORRECT   (read as code)
     -> [DMA to PS1 VRAM]          VERIFIED CORRECT   (full row coverage)
     -> [texture bind]             VERIFIED CORRECT   (single unit, formats)
     -> [composite]                VERIFIED CORRECT   (screen rebuilt from bytes)
```

No stage is inferred any more. The defect is **inside MDEC**, proven by reading
its output buffer rather than by eliminating everything else.

### What the pattern says about the fault

Saturated primaries --- pure red, pure green, pure white --- are what a
YUV-to-RGB conversion produces when its inputs are extreme or constant: a
luma/chroma pair that never varies, or coefficients that clip. It is not noise
and it is not stale memory; it is arithmetic on wrong values.

That is the shape of the remaining bug, and it sits in the four-function MDEC
module (`func_000E9A18`, `func_000EA2F0`, `func_000EA44C`, `func_000EAA88`) whose
handlers contain no arithmetic themselves --- so the conversion happens in code
those functions reach through the DMA callbacks at channel-record `+0x24`,
`+0x28` and `+0x2C`: OPDs `0x001B5DE8`, `0x001B5DE0` and `0x001B5E18`.

Those three OPDs are the next thing to resolve, and resolving an OPD is one
lookup. That is where this investigation ends and the fix begins.
