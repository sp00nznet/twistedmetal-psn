# The disc body: two files, one signature

**The disc mounts and the PS1 title boots.** Decryption, streaming, hashing and the header
signature check all pass. The last wall was a lifter bug in one Montgomery multiply, found
by bisection and fixed in `ppu_lifter.py`; the story below is how.

## Correcting the previous note

Two things in `docs/npdrm.md` were wrong and are fixed here:

- **The `PSISOIMG0000` compare passes.** A watch on the track count (`cdrom_obj + 0x70D8`)
  shows `func_000EFBA8` writing `1` to it — the match branch at `0xF004C`. The 12-byte magic
  was never the problem.
- **The exit is via `0x111BC8`, not `0x110E50`.** `TTY_BT="ExitPS1"` put the frame in the
  function containing both, but the reader's own return value settles it: `func_000EFBA8`
  returns `-1`, and `0x1111AC` does `blt cr7, 0x111BB0` straight into `ExitPS1(3)`.

## What the two files are

`ps1_netemu` builds **both** paths, unconditionally, in `func_000EFBA8`:

```
0xEFCB8   <base>/USRDIR/ISO.BIN.EDAT          -> buffer at obj+0x6800
0xEFDA4   <base>/USRDIR/CONTENT/EBOOT.PBP     -> buffer at obj+0x6C01
```

The strings around the verification key name the subsystem: `pspi/pspi.c` — the *PSP image*
interface — with `sceNpDrmOpen("%s"): %08x` and `cellFsOpen("%s"): %08x` at lines 531/539.

Comparing the decrypted EDAT against `EBOOT.PBP`'s `DATA.PSAR` (at `0x18000`) settles the
division of labour:

| region | `DATA.PSAR` | `ISO.BIN.EDAT.dec` |
|---|---|---|
| `0x000` | `PSISOIMG0000` + size `0x0416F340` | `PSISOIMG0000`, size field zero |
| `0x400` | `\0PGD` — PGD ciphertext | `_SCUS_94304` in the clear |
| `0x800` | ciphertext | valid CD TOC (A0/A1/A2, tracks 1–9, lead-out 32:19:28) |
| `0x1000`/`0x4000` | ciphertext | the block index, in the clear |

Only 29% of the first megabyte matches, and the first difference is at `0x0C`. So:

**`ISO.BIN.EDAT` is Sony's decrypted, signed copy of the PSAR's `0x100000`-byte header.**
The PS3 never runs PGD — it gets the header in plaintext and streams the compressed body out
of `EBOOT.PBP`. That is why the emulator builds two paths, and it is why the header carries a
signature: plaintext handed to the console needs its own integrity proof.

The index confirms the shape: 20-byte-aligned 32-byte entries from file offset `0x4000`,
`{u32 offset; u16 packed_size; u16 flags; u8 hash[16]; u32 pad[2]}`, offsets chaining exactly
(`0` → `0xEA0` → `0x1C40` = `0xEA0 + 0xDA0`) out to `0x2A31C40` ≈ 44 MB of compressed data
track — the balance of the 68 MB PSAR being the eight CD-DA tracks.

## The producer/consumer machine

`pspi.c` runs two threads over one ring buffer in the CD-ROM object:

| field | meaning |
|---|---|
| `+0x7078` | consumer stream position |
| `+0x7080` | command state: 1 run, 2 open, 3 close, 4 seek |
| `+0x7090` | a stream is valid |
| `+0x7094` | end of file |
| `+0x7098` | **the path to open** |
| `+0x70A0` | total size of the open file |
| `+0x70A4/A8/AC` | ring accounting |

`func_000ED9C8` is the producer: on state 2 it `cellFsOpen`s `*(+0x7098)`, `cellFsFstat`s it,
and stores **the file's own size** into `+0x70A0` (`0xEDE0C`). `func_000ED6F8` is the
consumer, and its first gate is the one that bites:

```
0xED73C:  r0 = *(obj+0x7078) + len      ; position + request
          r9 = *(obj+0x70A0)            ; = 0x100028
          if (r0 > r9) -> return 0      ; past the end of the open file
```

`0x100028` is exactly the size of our decrypted EDAT, so `+0x70A0` is a size, not a pointer —
an earlier reading of that field as the ring base was wrong.

## The proof that our side is right

The consumer streams the whole header in `0x1000` steps — `+0x7078` climbs to exactly
`0x100000`, then to `0x100028` after the 40-byte trailer — and hashes it as it goes
(`0x157600` = SHA1_Init on the context at `0x76B004`, `0x157660` = SHA1_Update,
`0x157828` = SHA1_Final). Watching the digest buffer the guest writes:

```
guest  SHA1(header) = 6c55da7ff8eb8c09df8d5269dca4444b561097aa
python SHA1(dec[0:0x100000]) = 6c55da7ff8eb8c09df8d5269dca4444b561097aa
```

Byte for byte. That single comparison validates the whole chain at once: the EDAT decryption
is correct, the block-key derivation is correct, the ring buffer delivers the right bytes in
the right order, and the lifted SHA-1 is correct over a megabyte of data.

## Where it actually stops

`0xF132C`, immediately after the hash is finalised:

```
bl   0x157828                 ; SHA1_Final(digest = r1+128, ctx)
if (pos + 40 > total) -> teardown
<read the 40-byte trailer into r1+152>
r5 = *(TOC-0x7A1C) = 0x175510 ; a 40-byte public key
bl   0x10D24 (sig, hash, key, 2)
cmpwi cr7, r3, 0
beq  cr7, 0xF14F4             ; VERIFY OK -> close the EDAT, open EBOOT.PBP
```

`func_00010D24` is an ECDSA verify: it zeroes a 144-byte context, rejects any curve id
outside `[1,2]`, initialises curve `2` from a table of 120-byte entries at
`*(TOC-0x6B0C) = 0x15F7F0` (six 20-byte fields, loaded 4-zero-padded into 24-byte bignums by
`func_000108F0`), then loads `r` and `s` from the trailer's two 20-byte halves.

The `beq` is not taken. `0xF13D0` closes the file, falls into `0xF1434: b 0xF0930`, and that
runs the teardown and returns `-1` — which is the `ExitPS1(3)`. The trailer is

```
r = 3df7e732dfd6834e25ac8284c5bce7b8451078d4
s = 01351fccdfb8684ed38f7acc54853fb5c49065f4
```

and `0xF1590` — the one instruction in the whole image that points `+0x7098` at the
`EBOOT.PBP` buffer — sits on the far side of that branch. A watch confirms `+0x7098` is
written exactly once per run, always with the EDAT path. **The disc body is never opened
because the header signature does not verify.**

## What that is not

- **Not a stubbed dependency.** `func_00010D24` calls only `0x106B4`, `0x109C4`, `memset`
  and the bignum core at `0x1584A0` — all real code in the image, no import trampolines. It
  is pure computation.
- **Not our carry arithmetic**, as far as review goes. `adde` uses the correct ADC carry-out
  (`result < ra || (ca && result == ra)`), `subfe` the correct two-step borrow, and `addc`,
  `subfc`, `addze` are right. That code path already had one such bug found and fixed via
  newlib's bignum loops.
- **Not the hash input.** See above — it is bit-exact.
- **Not `ps1_newemu` vs `ps1_netemu`**, the argv, the allocator, or the semaphore spin, all
  of which were ruled out earlier and have not come back.

## The signature is valid — the bug is ours

The curve is not in the ELF. `*(TOC-0x6B0C)` points at `0x15F7F0`, but the constants there
do not parse as a curve under any field assignment, because the table is **built at runtime**.
So it was read out of the guest's own memory instead: `func_000109C4` copies six 20-byte
fields into a 144-byte context (each 4-zero-padded to 24 bytes by `func_000108F0`), and
watching that context on the stack — replaying the writes in order, before the struct is
reused as scratch — gives them directly.

```
p  = ffffffffffffffff00000001ffffffffffffffff
a  = ffffffffffffffff00000001fffffffffffffffc     (a = p-3)
b  = a68bedc33418029c1d3ce33b9a321fccbb9e0f0b
Gx = 128ec4256487fd8fdf64e2437bc0a1f6d5afde2c
Gy = 5958557eb1db001260425524dbc379d5ac5f4adf
n  = fffffffffffffffeffffb5ae3c523e63944f2127
```

The table order is `p, a, b, N, Gx, Gy` — the classic `curve_t` layout PS3 tooling uses. Both
the generator and the public key at `0x175510` lie on it, and `n*G` is the point at infinity,
so the curve is genuine and completely determined.

With it, the signature verifies:

```
n*G == infinity : True
SIGNATURE VALID : True
  X.x mod n = 0x3df7e732dfd6834e25ac8284c5bce7b8451078d4
  r         = 0x3df7e732dfd6834e25ac8284c5bce7b8451078d4
```

**So the header is authentic and Sony-signed, and `func_00010D24` returns the wrong answer on
correct data.** This is a ps3recomp lifter bug, not a content problem.

That also settles what the crack does, and it is the ordinary thing: an EDAT is only a
container, so re-wrapping the same plaintext under a free klicensee leaves Sony's signature
intact. It has to — cracked PSOne Classics ran on real consoles, and `ps1_netemu` performs
this check unconditionally. The earlier speculation that the header had been edited was wrong.

## Bisecting the lifter bug

`src/ecdsa_probe.c` drives the firmware's verify directly instead of waiting for a boot.
`ECDSA_PROBE=1` builds the exact arguments `func_00010D24` hands to `func_001584A0` — `r`, `s`,
the hash, the public key and a 144-byte curve context, each value a 24-byte slot of 4 zero
bytes plus 20 big-endian — and calls it through the generated `function_table` (the lifted
symbols are C++; the table has C linkage, and going through it makes the probe
address-driven, which is what bisecting needs).

The curve context is built from the constants above rather than by calling the guest's
`func_000109C4`, because the curve table at `0x15F7F0` is populated at runtime and going
through the initialiser would make the probe depend on when it runs.

```
[ecdsa] calling func_001584A0(sig=0x50004210 e=0x50004310 Q=0x50004410 curve=0x50004510)
[ecdsa] returned -1 (0xFFFFFFFF) -- expected 0 (VALID)  <== BUG REPRODUCED
```

Sub-second, deterministic, and it reproduces what the real boot does — a later run shows the
same code running at `r30=d0022750` on the guest's own stack with the same outcome.

## What is proven correct

Instrumenting the generated C at each stage and comparing against the same computation in
Python:

| stage | guest | |
|---|---|---|
| `w = s^-1 mod n` | `4dc0b56c40d9a33a5b451b9d9dfd920aa233c6f5` | ✅ |
| `u1 = e*w mod n` | `a53abb93bb101112885815809da262a456a2609b` | ✅ |
| `u2 = r*w mod n` | `8c0800d362533422eb2e4ffd349195bb1b6376c2` | ✅ |
| `X.x` | `50042b80a2b51a125fa40d253e2768585c03d66d` | ❌ (`3df7e732…78d4`) |

So the modular inverse and both modular multiplies are exact — which is a lot of bignum
arithmetic working perfectly — and the three ECDSA range checks all pass. The failure is
confined to the point arithmetic. Dumping the Jacobian point the scalar multiply returns and
testing `Y^2 == X^3 + aXZ^4 + bZ^6 (mod p)` in Python: **not on the curve**. The inputs to it
are all correct — `G`, `Q` and the curve are byte-exact where the multiply reads them.

## The corruption

Every wrong value carries the same signature: **limb 2 of a 4-limb bignum holds a pointer.**
Both coordinates of the result, and all three of the point fed to the first double, hold the
identical value `0x50042CA0` in that slot.

Tracing it back with a store watch:

1. `func_0015ABEC` — a leaf that converts a value into the internal form, with no stack frame
   of its own (`addi r22, r1, -224`, all locals in the PPC64 red zone) — is called four times
   to fill a table with `Gx`, `Gy`, `1`, `Qx`. Its **inputs are correct**, its output is not.
2. Inside it, the loop at `loc_0015AF68` shifts the limb array down one limb
   (`buf[i] = buf[i+1]`).
3. That loop propagates a **stale top limb** into limb 2, and the stale value is a pointer
   left in the scratch buffer.
4. The copy loop at `0x15B0AC` then copies the whole thing out to the caller, and the
   corrupted limb flows through the entire point multiply.

So the working buffer's high limb is not being initialised where it should be, and everything
downstream inherits it.

## What has been ruled out

- **No unlifted instructions.** All 29 functions in the subtree lift with zero `TODO: .word`
  slots. (56 functions elsewhere in the image do have them; none here.) The 74 `.word`s a raw
  scan reports in the address range are inter-function padding the lifter correctly skips.
- **No stubbed imports.** The subtree calls only image-internal code.
- **Every rare instruction in it, checked against PowerISA**: `addic` (twice in the whole
  image, once here), `sld`/`sld.`, `srd`, `cmpld` (50 uses), `divdu`, `mulld`, `mfcr` (38
  uses), `mtcrf`, `subfic`, `sradi`, `neg`, `addze`, `subfe`, `subfc`, `stdx` (the image's only
  one), `ldx` — all correct, including 64-bit widths and the `XER[CA]` carry-outs.
- **The MD-form rotate decode**, hand-checked against the encoding: `rldicr r8,r10,32,31` /
  `rldicr r3,r8,32,59` decode and evaluate exactly as the hardware would, so the address
  arithmetic in the point setup is right.
- **Record-form CR0**, which comes from a generic wrapper, so `addic.`/`sld.` are covered; and
  the CR nibble order, which is consistent across the compare handlers, that wrapper and
  `mfcr`.
- **Conditional returns** (`beqlr`/`bgelr`/`blelr`/`bnelr`) — used only in the broken path, so
  a natural suspect — parse and lift correctly, including the no-operand `cr0` form.
- **Not a red-zone violation.** `func_0015ABEC` makes no calls, so its use of the 288-byte
  protected zone below `r1` is legitimate and nothing clobbers it.

## A real diagnostic gap, fixed on the way

`vm_write64` was never hooked into the `LBP_WW` store watch — only the 8/16/32-bit stores
were. Every bignum limb and every 64-bit struct field is written with `std`, so a watch on one
reported nothing and read as *"nobody writes this"*. That is why several earlier searches for
these values in guest memory came up empty. `runtime/ppu/ppu_loader.cpp` now reports the
64-bit store as two halves, so a watch still fires when only one word of it is covered.

## Found: a callee-save heuristic that ate a real load

`func_0015ABEC` is a **Montgomery multiply** — `func_0015ABEC(out, a, b, curve, n')`,
confirmed by its third argument being `2^384 mod p`, which is `R²` for `R = 2^192`, and by
`n' = 1`, which is correct here because `p ≡ -1 (mod 2^64)`.

Its accumulator starts correctly zeroed, and `1 × R²` produces exactly `R²` in the first
stage. The pointer appears in the **reduction** step, and one line explains it:

```c
ctx->gpr[25] = _cs_25;        // what the lifter emitted, mid-loop
ctx->gpr[3]  = ctx->gpr[6] + ctx->gpr[25];   // then used as the carry
```

The guest instruction there is `ld r25, -0x78(r1)` at `0x15AED4` — a genuine load of the
high word of a two-word product temp. But `_cs_25` is the lifter's cached copy of r25 **at
function entry**, i.e. the caller's r25, which held a pointer. That pointer went straight into
the carry chain.

### Why the heuristic misfired

The lifter rewrites `ld rN, off(r1)` into a cached entry value when it believes the load is a
callee-save restore. Three conditions let it fire here, and each was individually reasonable:

- **`not _has_stdu`** — true, because `func_0015ABEC` is a PPC64 **leaf** that keeps its
  locals in the 288-byte protected zone below `r1` (`addi r22, r1, -224`) and never adjusts
  the stack pointer. The heuristic read "no frame" as "must be a tail-entry stub".
- **`_write_counts['-0x78'] == 0`** — true, because the body writes that slot *through a
  pointer*: `addi r5, r1, -128` then `std r9, 0x8(r30)`. Only literal `r1 + off` stores were
  counted, so the write was invisible.
- **`_off_escapes('-0x78')`** — false, because the address taken was `-0x80`, and the check
  matched the exact offset rather than the slot the store actually lands on.

The prologue saves r25 at `-0x38(r1)`, so the offsets never matched — the register did.

### The fix

`tools/ppu_lifter.py` now attributes stores made **through** a frame pointer to the slot they
land on. A small forward pass tracks registers holding `r1 + off` (following the zero-extend
and register-move idioms the compiler emits — `ppc_rldicl(x, 0, 32)` and `or rD, rS, rS`) and
charges `std rX, disp(rN)` to `off + disp`. `-0x78` is then correctly seen as written, the
rewrite does not fire, and the load lifts as `vm_read64(ctx->gpr[1] + -0x78)`.

Two broader fixes were tried first and both regressed the boot, which is worth recording:

- Disabling the rewrite for any function that saves to its own frame broke `GPUCoreInit`.
- Poisoning a 0x100-byte window above every taken address broke it the same way.

The heuristic is load-bearing elsewhere, so the fix had to be exact: only slots that are
*genuinely* written may be excluded. It already carried scars from this same class of bug —
the comments cite newlib's `dtoa` and gcm/cube's vertex pointers.

## Result

```
[ecdsa] returned 0 (0x00000000) -- expected 0 (VALID)
```

and the boot runs past every wall it has ever hit:

```
title: 0xc0546d88U, "SCUS_943.04" P
North American Title detected!
ad hoc param: 0 <11624>
boot from /dev_hdd0/game/NPUI94304[1] 0
```

`ExitPS1(): code=3` and `CoreBoot() failed` are **gone**, `EBOOT.PBP` is opened for the first
time, and the firmware recognises the disc from its own title database. Every earlier
milestone — fonts, menu, `TITLE ID : SCUS94304`, the 30-page manual — still passes, and
`GPUCoreInit` is clean, so nothing regressed.

## Next

The PS1 core start-up. It now stalls with SPU 4 parked on a channel read at `pc=0x0A5E8` and
the PPU spinning on `0xD0009F90` — the R3000/GTE core waiting for work that never arrives.
That is the next thing to trace, and it is a much later failure than anything before it.

Worth doing early: this was a lifter bug, not a title bug, so it affects every port. The other
PSOne Classics in the archive are the natural regression suite — each ships a different
`ISO.BIN.EDAT` with its own valid signature, so pointing the probe at two or three of them
tests the fix against independent data rather than the single case it was found on.
