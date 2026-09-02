# The disc body: two files, one signature

**The disc path works.** Decryption, streaming and hashing are correct end to end — proven,
not assumed. What stops the boot is a single ECDSA signature check on the disc header.

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

## The open question

Either our lifted bignum code is wrong in a way SHA-1 does not exercise, or the header we are
feeding it is not the one Sony signed.

The second is the more likely, and for a concrete reason: the `ISO.BIN.EDAT` in `vfs/` comes
from the archive's **`_Crack.pkg`** (license type 3), not the retail package (license type 2,
whose data is under a RIF key from a per-console RAP we do not have). An EDAT is only a
container, so re-wrapping authentic plaintext under a free klicensee would leave the signature
intact — but any edit to the header itself would not. The size field at `0x0C` being zero
where the PSAR carries `0x0416F340` is the kind of difference that would do it, though it may
equally be by design.

Attempting to confirm this by parsing the curve out of the table did not work: no assignment
of the six 20-byte fields — over a wide range of base offsets, both endiannesses, all
permutations — puts both the generator and the public key on the same curve. So the table
encoding is still unread, and the signature has not been checked independently.

## Next

The legitimate route is the retail `ISO.BIN.EDAT`, which is the file Sony actually signed:
recover the RAP or RIF for `NPUI94304` from the owner's own PSN activation, decrypt the
type-2 EDAT with it, and this check should pass on authentic data.

Failing that, read the curve table properly — most usefully by dumping the ECDSA context the
guest builds rather than guessing at the layout — and verify the signature offline. That
distinguishes a lifter bug from a data problem, and it is the one question worth answering
before anything else here.

Deliberately not done: patching out the check. It is an integrity check on content we did not
author, and disabling it would prove nothing about whether the recompilation is correct.
