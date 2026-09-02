# Raw SPU: five cores, no kernel in the path

**Status: working.** All five raw SPUs the emulator asks for come up, load their images,
handshake with the PPU and take commands. `ps1_netemu` gets through its whole subsystem
bring-up — fonts, audio (port open + mixing thread), pad, memory card, CD-ROM thread, NP,
ATRAC decoder — and idles at 60 fps.

## Why SPURS could not serve this

Every ps3recomp port so far runs SPU code through the SPURS workload layer: the title
hands an image to `cellSpurs`, the runtime fingerprints it, finds the lifted entry and
dispatches. There is a **call** to intercept.

A raw SPU has none. lv2 hands the process a physical SPU, maps its local store and
problem-state registers into the address space, and steps out:

```
0xE0000000 + n*0x100000 + 0x00000   local store    (256 KB)
0xE0000000 + n*0x100000 + 0x40000   problem state  (registers)
```

After that the PPU drives it with ordinary loads and stores:

```c
*(u32*)(base + 0x44034) = start_pc;              // SPU_NPC
*(u32*)(base + 0x4401C) = 1;                     // SPU_RunCntl  -> it starts
while (!(*(u32*)(base + 0x44014) & 0xFF)) ;      // poll SPU_MBox_Status
u32 reply = *(u32*)(base + 0x44004);             // SPU_Out_MBox
```

So **the loads and stores are the interface**. `runtime/spu/spu_raw.c` hooks
`vm_write32` / `vm_read32` for the problem-state half of each window; local store stays on
the plain-memory fast path, since it is the bulk of the traffic and needs no side effects.

## Local store is real guest memory

The one structural change this needed. `spu_context.ls` was a 256 KB array inside the
context; a raw SPU's local store cannot be a private copy, because the PPU writes the
SPU's code and its command buffers into the window *while the SPU is running*. Copy-in /
copy-out would race every frame.

`ls` is now a pointer — `ls_store` for every other context, `vm_base + window` for a raw
SPU. Every `ctx->ls[i]`, `&ctx->ls[i]` and `ctx->ls + n` in the runtime still compiles and
still means the same thing, so no other path changed. Endianness needs no care: local
store is raw bytes and both sides are big-endian.

## Four things were missing, in order

Each one hid the next.

**1. `sys_raw_spu_create` and friends.** Straightforward once the numbers were read off the
call sites: 150 `create_interrupt_tag`, 151/152 `set/get_int_mask`, 153/154
`set/get_int_stat`, 160 `create`, 161 `destroy`, 163 `read_puint_mb`. Syscall 163 was
identified from its use — the interrupt thread does
`get_int_stat(id,2,&st); if (st & 1) { 163(id,&v); set_int_stat(id,2,1); }`, which is the
read half of a class-2 mailbox interrupt.

**2. `sys_raw_spu_image_load` — the one that actually mattered.** With the syscalls in,
the SPU started and stopped after **two instructions** at pc 0. Local store was all zeros:
`nonzero lines=0/4096`. Nothing had loaded the image.

The load is **not a syscall** — libsysutil exports it, and the stub NID logged one line and
returned success. It was sitting in plain view in the trace between the import and the run:

```
[hle] unresolved NID 0xB995662E     = sys_raw_spu_image_load
[hle] unresolved NID 0xE0DA8EFD     = sys_spu_image_close
```

Both were identified by computing NIDs for candidate names against the two values. With
`image_load` implemented — walk the descriptor's segment array, COPY or FILL each into the
window, set NPC — local store came up at `84992 bytes, 1324/4096 nonzero lines`.

**3. The SPU images had been lifted at the wrong base.** They then ran *the wrong
instructions*. `spu_lifter.py` has two modes, and the difference is silent:

| invocation | what happens |
|---|---|
| `spu_lifter.py img.elf --functions f.json` | reads the ELF as a **raw image at base 0** — the ELF header becomes the first instructions and every function lands at its **file offset** |
| `spu_lifter.py img.elf --auto-functions img.elf` | parses the ELF, so functions land at their **local-store address** |

This image has `p_offset 0x100` / `p_vaddr 0x80`, so everything was off by 0x80 — the
lifted `spu_func_00000100` held the code from LS 0x80. It compiled, linked and ran
straight into the wrong instructions. The tell was the entry: LS 0x100 is
`ila $r8, 0x3FFD0` (a stack-pointer setup, i.e. a real `_start`), but the lifted function
began `ila $r2, 0xC6D0`.

`spu_lifter.py` now refuses an ELF given positionally without `--auto-functions`,
`--offset` or `--base`, because the failure is otherwise invisible until an SPU executes
garbage.

**4. A published register went stale and deadlocked both sides.** With the code correct,
the SPU booted, wrote its ready word (`out mbox = 0x00015010`), the PPU read it and replied
with one command word — and then both waited forever.

`SPU_MBox_Status` was being *published* into guest memory whenever an MMIO operation
touched it. But the SPU consumes its inbound mailbox **on its own thread**, through the
channel layer, without passing through any MMIO path — so the published copy still said
"0 free slots" after the SPU had drained it. The PPU never wrote a second word; the SPU
waited for one.

Derived registers (`SPU_MBox_Status`, `SPU_Status`) are now computed **on read** rather
than read back from a published copy. `SPU_Out_MBox` was already read-side, because reading
it pops the mailbox and cannot be served out of memory at all.

## What it looks like working

```
[spu-raw] create -> raw spu 0, window 0xE0000000
[spu-raw] image_import src=0x00181100 len=86452 entry=0x00100 fp=0x5BCAF5D9B58AB103
          -> lifted entry registered
[spu-raw] image_load spu0: 3 segments, 84992 bytes into LS, NPC=0x00100
[spu-raw] W spu0 +0x4401C = 0x00000001          <- run control
[spu-raw] spu0 START pc=0x00100 ls=guest:0xE0000000 nonzero lines=1324/4096
[spu-raw] spu0 out mbox = 0x00015010            <- the SPU's ready handshake
[spu-raw] R spu0 OUT_MBOX -> 0x00015010         <- PPU reads it
[spu-raw] W spu0 +0x4400C = 0x40600000          <- PPU sends a command EA
[spu-raw] W spu0 +0x4400C = 0x00D70E80
...spu1, spu2, spu3 identically (the banner says -sgpu-sli4: a four-way SPU GPU)
[spu-raw] create -> raw spu 4, window 0xE0400000
[spu-raw] image_import src=0x0019A200 len=59580 entry=0x000E0 -> lifted entry registered
[spu-raw] image_load spu4: 3 segments, 58208 bytes into LS, NPC=0x000E0
[spu-raw] spu4 out mbox = 0x0000E500
[spu-raw] W spu4 +0x5C00C = 0x60000000          <- signal notification 2, streaming
[spu-raw] W spu4 +0x5C00C = 0x60000800             buffer addresses every 0x800
```

Both lifted SPU modules are in use: images 0–3 are the GPU core (the 86 KB image), image 4
is the second module (59 KB). The `0x5C00C` traffic is `SPU_RdSigNotify2` — the PPU
feeding the second core a stream of buffers.

## Fingerprints: not stock FNV-1a

`spu_workload_fingerprint()` is documented as FNV-1a-64 but its offset basis is
`1469598103934665603`, one digit short of the real `14695981039346656037`. It is only a
hash and every shipped port's registrations are already keyed to it, so
`src/spu_images.c` matches it rather than "fixing" it — but it does mean those constants
cannot be reproduced by a stock FNV-1a-64, which cost a debugging round here.

## What is still missing

- **No PS1 frame yet.** The emulator initialises fully and idles; it has not loaded the
  disc. `groups[seen=0 exec=0]` — no geometry has reached the renderer, so the window is
  still the clear colour.
- **The pad read is an unnamed NID.** `sys_io` imports six functions; five are
  `cellPadInit` / `End` / `SetPortSetting` / `GetInfo2` / `SetActDirect`, and the sixth,
  `0x3733EA3C`, is not `cellPadGetData` (`0x8B72CDA1`) and did not match ~120 candidate
  names. Its `xPadThread` polls it in a loop and gets nothing, so no input reaches the
  menu — which is a strong candidate for why the emulator never starts the game.
- **Interrupt delivery is registered but untested.** `sys_interrupt_thread_establish` (84)
  and `eoi` (88) are still stubs; the class-2 mailbox interrupt status is maintained, but
  nothing has needed to fire yet because the PPU polls.
