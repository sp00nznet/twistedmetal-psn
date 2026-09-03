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
