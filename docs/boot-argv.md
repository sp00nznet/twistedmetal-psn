# What launches a PSOne Classic: the nine arguments

`ps1_netemu` imports **no `cellGame` at all**, so it cannot ask the system what it is
running. On hardware the VSH tells it, on the command line. The harness passed one
argument — correct for a disc title, meaningless to this one — so the emulator booted,
concluded it was emulating, and sat in its run loop with nothing to run.

RPCS3's source has the contract (`Emu/System.cpp`, `m_cat == "1P"`):

```
argv[0]  /dev_flash/ps1emu/ps1_newemu.self   the emulator self
argv[1]  <PS1 serial>_mc1.VM1                virtual memory card 1
argv[2]  <PS1 serial>_mc2.VM1                virtual memory card 2
argv[3]  0082                                region target
argv[4]  1600                                resolution scale (RPCS3 says "purely a guess")
argv[5]  /dev_hdd0/game/<content dir>         the game folder -- NOT the serial
argv[6]  1
argv[7]  2                                   full screen?
argv[8]  1                                   smoothing?
```

Both memory cards must already exist as 128 KB zero-filled files under
`/dev_hdd0/savedata/vmc/`; RPCS3 creates them the same way and lets the game format them.

Note the naming split, which is the same wrinkle that bit `cellGame`: **argv[1]/[2] are
named from the PS1 serial (`SCUS94304`) while argv[5] is named from the content id
(`NPUI94304`)**. For a PSOne Classic those are different strings.

## What it took on our side

`ppu_loader.cpp` wrote exactly one argument. It now honours `PS3_ARGV=<a1>;<a2>;...`,
building the layout lv2 really uses — 64-bit big-endian pointer slots, NULL-terminated,
then a NULL envp, with each string 16-byte aligned after the slots (verified against
RPCS3's `ppu_load_exe`). For a single argument the result is byte-identical to what it
produced before, so no other port moves.

Two Git-Bash traps on the way: MSYS rewrites POSIX-looking paths in **environment values**
handed to a native binary, so `YDKJ_BOOTPATH=/dev_flash/...` arrived as
`C:/Program Files/Git/dev_flash/...`. `MSYS2_ENV_CONV_EXCL="*"` stops that — but it stops
it for the *host* paths too, so `PS3_HDD0_ROOT` then arrived as `/g/recomp/...` and every
lookup missed. `tools/run.sh` converts the host paths explicitly with `cygpath -m` instead
of relying on a heuristic that has to guess which kind each value is.

## It works

The emulator reads all nine and acts on them:

```
argc=9
argv[0]=/dev_flash/ps1emu/ps1_netemu.self
argv[5]=/dev_hdd0/game/NPUI94304
...
g_strTitle NPUI94304
[sys_fs] open OK: .../vfs/dev_hdd0/game/NPUI94304/USRDIR/CONTENT/DOCUMENT.DAT
TITLE ID : SCUS94304
InitMenuManual OK!! PageNum = 30
target: /dev_hdd0/game/NPUI94304<0>
REGION NUM = 0x00000082 code=A        <- 0x82 straight out of argv[3]="0082"
```

It has found the package, read the 30-page manual out of `DOCUMENT.DAT`, taken the region
from `argv[3]` (it was `0x81` before), and set its disc target.

## Where it still stops

It never opens `EBOOT.PBP`. `_xcdrom_thread` starts and immediately spins:

```
[sc] 47(0x8, 0x3E8, ...)              -> 0        set_priority
[sc] 90(0x76A760, 0xD0022CB0, 0, 1)   -> 0        sys_semaphore_create
[sc] 92(0x4, 0x30D40, ...)            -> 0        sys_semaphore_wait(id 4, 200 ms)
[sc] 93(0x0, ...)                     -> 0x80010005  ESRCH
[sc] 94(0x0, 0x1, ...)                -> 0x80010005  ESRCH
[sc] 92(0x0, 0x0, ...)                -> 0x80010005  ESRCH   x158,738
```

It is waiting on **semaphore id 0** — a handle that was never filled in. The ids it reads
live at `+0x70B8` / `+0x70BC` of its object (`lwz r3,0x70BC(r26)` at `0xEFEA0`,
`lwz r3,0x70B8(r26)` at `0xEFECC`), and the code that creates such a pair is at
`0x10FFC8` / `0x10FFF4` (`addi r3,r31,56` / `addi r3,r31,60`, i.e. `+0x38`/`+0x3C` of the
same object seen through a different base). That creator runs — twice, for two other
instances — but never for this one, so some construction step upstream was skipped.

Ruled out already:

- **Not a missing file.** The only failing opens in a whole run are the four
  `SCE-PS3-*.ccd` font probes, each of which falls back to the `.TTF` and succeeds.
- **Not the argv.** All nine arrive and visibly change behaviour.
- **Not `ps1_newemu` vs `ps1_netemu`.** RPCS3 launches `newemu`; its import table is a
  strict *subset* of `netemu`'s (7 fewer: five `cellAudio`, two `sysPrxForUser`), so they
  are the same codebase and the argv handling is the same.
- **Not the allocator.** `_sys_malloc` was unimplemented and is now in (see below).

## Fixed on the way here

- **`_sys_malloc` / `_sys_free` / `_sys_memalign` / `_sys_realloc`** were missing from
  `sysPrxForUser` entirely, so every caller got the generic unresolved-NID stub: `CELL_OK`
  with `r3` left holding whatever happened to be there — a garbage pointer the caller then
  wrote through. `cellUsbdInit` failed on it; with the allocator in, it initialises and
  creates its threads. (RPCS3's NID table names `0xBDB18F83` `_sys_malloc`, confirming the
  identification.) They forward to the same bump allocator the `sys_heap_*` family uses.
- **`PS3_SCTRACE` printed the return value in the first-argument column** for every
  *implemented* syscall, because it passed `ctx->gpr[3]` after dispatch had overwritten it.
  The first argument is the object id for most of lv2 — which is the entire reason to read
  a syscall trace. Everything above depended on fixing it first.
- **`sys_io_3733EA3C` confirmed.** RPCS3 has this exact function, with the exact signature
  derived here from the call site — `(u32 port_no, vm::ptr<u32> device_type,
  vm::ptr<CellPadData> data)`, commented *"Used by the ps1 emulator built into the
  firmware"*. It forwards to `cellPadGetDataExtra`, which is what ours does too.
- **`sys_raw_spu_image_load` / `sys_spu_image_close`** — the NIDs identified by candidate
  search last round both appear in RPCS3's name table with those names.

## Next

Find what skips the CD-ROM object's construction. The creator at `0x10FEC8` has a single
caller (`0xD8080`) and is called unconditionally there, so the object that never gets its
semaphores is a *different instance* from the two that do — the question is which code path
was supposed to build it and what it bailed on. A watchpoint on the semaphore-id words
(`PPU_WW`-style) at the failing object's `+0x70B8` would name the writer that never ran.
