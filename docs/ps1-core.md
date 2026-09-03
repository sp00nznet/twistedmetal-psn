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
