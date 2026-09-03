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
