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

No spins, no stalled SPUs. `tid=2` parks on `sys_event_queue_receive` with **queue id 0** --
an uninitialised handle, the same shape as the `sys_semaphore_wait(id 0)` spin that the
`cellAdecOpen` fix cured:

```
[sc] 130(0x0, 0xD0004EE0, 0x0, 0x0) -> 0x80010005 (ESRCH) tid=2
[GSTACK:waitbt tid=2 q=0] sp=0xD0004E30 cia=0x001B7768 lr=0x0001A5E4
```

The waiter is `func_0001A5D8`. Something upstream should have created that queue and stored
its id, and did not -- so the next step is the same one that worked for the semaphore: find the
creator, find what it bailed on.

Also worth noting for later: `user_memory_size= 0/0 <0>` is printed right after `boot from`,
where the earlier print in the same run reported `201326592/268435456`. That zero looks wrong
and may be the same missing initialisation seen from the other side.
