# Getting to the disc: one wrong function signature

**It opens the disc now.** The emulator reaches `ISO.BIN.EDAT` and stops at the DRM layer,
which is the next piece of work rather than a mystery.

## The chain that found it

The CD-ROM thread was spinning 158,738 times on `sys_semaphore_wait` with **id 0** — a
handle nothing had filled in. Four steps from there to the cause:

**1. Which object?** A `SEM_BADID=1` report (added to `sys_semaphore.c`: on a wait/post
against an id that was never created, dump the caller and every pointer-shaped register)
gave `r26 = 0x00764000`, `r31 = 0x003B4000`. The failing code computes
`addis r26, r31, 0x3B`, so the object is a TOC global + `0x3B0000`, and the two missing
ids live at `0x76B0B8` / `0x76B0BC`.

**2. Which creator?** `+0x70B8`/`+0x70BC` is a `+0`/`+4` pair. Of the ten
`sys_semaphore_create` sites in the image, exactly one creates such a pair —
`0xED5D4` / `0xED600`, inside `func_000ED3CC`. That function reads the *same* TOC global
(`-0x7AEC`), does `addis r30, r9, 0x3B`, and memsets 0x3B8000 bytes: it is the CD-ROM
object's constructor.

**3. Did it run?** The runtime's `[sem] create` line already prints the guest LR. Semaphore
**id=8** was created with `lr=0x000ED4D8` — the return address of the `bl` at `0xED4D4`,
which is inside that constructor. So it ran, and got past its first three gates
(`sys_net_initialize_network_ex`, `sceNpInit`, `cellAdecQueryAttr`). The bail therefore had
to be in the ~0x30 instructions between the create at `0xED518` and the pair at `0xED5D4`.

**4. Which of the two?** That span has exactly two failure exits:

```
000ED568: bl   0x15F12C          ; cellAdecOpen
000ED570: cmpwi cr7, r3, 0
000ED578: bne  cr7, 0xED45C      ; -> return -1
...
000ED594: bl   0xACE94           ; memalign(128, 0x40000)
000ED59C: cmpwi cr7, r3, 0
000ED5A4: beq  cr7, 0xED68C      ; allocation failed
```

And the log said which: `[cellAdec] Open(codecType=5)` appeared, but the
`[cellAdec] Open -> handle=` line that follows a *successful* open did not.

## The bug

`cellAdecOpen` takes **four** arguments — `(type, res, cb, handle)`. Ours took five,
splitting the guest's `CellAdecCb` struct into separate `cbFunc` and `cbArg` parameters:

```c
/* wrong */ s32 cellAdecOpen(const CellAdecType*, const CellAdecResource*,
                             CellAdecCbMsg cbFunc, void* cbArg, CellAdecHandle* handle);
/* right */ s32 cellAdecOpen(const CellAdecType*, const CellAdecResource*,
                             const CellAdecCb* cb, CellAdecHandle* handle);
```

`cb` is a *guest pointer* to `{ u32 cbFunc; u32 cbArg; }`, not two register arguments.
Splitting it pushed `handle` off `r6` onto `r7`, so the handle out-pointer read as whatever
was left in `r7` — usually zero — the null check failed, and **every** `cellAdecOpen`
returned `CELL_ADEC_ERROR_ARG`.

The guest call site confirms the shape directly: `r5 = r1+128`, and the two words written
there just before the call are `stw r11,0x80(r1)` / `stw r25,0x84(r1)` — a two-field struct
built on the stack. RPCS3 has the same four-argument signature
(`Emu/Cell/Modules/cellAdec.cpp:1577`).

`ps1_netemu` opens an audio decoder for CD-DA / XA-ADPCM *inside its CD-ROM constructor*,
so one wrong parameter list meant no disc.

## Where it stops now

```
[cellAdec] Open(codecType=5, cb=0xD0022C80, handle=0x0076A700)
[cellAdec] Open -> handle=0
slot1 = NULL / slot2 = NULL
load config file: /USRDIR/
[sys_fs] open -> EISDIR (directory): .../vfs/        <- see below, non-fatal
failed
[hle] unresolved NID 0xAD218FAF                      <- sceNpDrmIsAvailable
[sys_fs] open OK: .../NPUI94304/USRDIR/ISO.BIN.EDAT  <- the disc
ExitPS1(): code=3 <0>
cell/host.c: 625: CoreBoot() failed
```

It opens the disc image and then fails to boot the PS1 core.

**The wall is NPDRM.** `ISO.BIN.EDAT` is an encrypted EDAT. On lv2,
`sceNpDrmIsAvailable(klicensee, path)` primes the kernel to decrypt that path
*transparently*, so the subsequent `cellFsOpen` hands back plaintext. Ours is unimplemented,
returns `CELL_OK`, and the plain open hands back ciphertext — the emulator reads a garbage
header and exits with code 3.

Confirmed by substitution: the archive ships a second package whose only payload is a
different `ISO.BIN.EDAT` (NPD **version 3, license type 3** — the free form — versus retail's
version 1, type 2, which is bound to a console key). Swapping it in changes nothing, because
nothing decrypts *either* form yet.

## Next

Implement EDAT decryption in the FS layer, plus `sceNpDrmIsAvailable` to arm it.
RPCS3's `Crypto/unedat.cpp` is the oracle and already handles exactly the case the
free EDAT uses (`npd->version == 3`, `(npd->license & 3) == 3`, `validate_dev_klic`),
so no per-title RAP is needed for that form. `tools/ps3sce/` in this tree carries the
same AES/SHA1 primitives.

Smaller, also open:

- **`load config file: /USRDIR/`** resolves to the VFS root and fails `EISDIR`. The
  emulator prints `failed` and carries on, so it is not blocking, but the path mapping is
  wrong: a bare `/USRDIR/` should resolve under the content directory, not the root.
- `cellAdecQueryAttr` (`0x7E4A4A49`) is still unresolved. It returns `CELL_OK` with the
  attr struct untouched, which the constructor tolerates, but the work-buffer sizes it
  should report are presumably used once decoding really starts.
