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
