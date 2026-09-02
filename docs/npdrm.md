# NPDRM: decrypting the disc

**The disc decrypts.** `ISO.BIN.EDAT` now comes back as `PSISOIMG0000` with the PS1
serial `_SCUS_94304` in its header, transparently, through the ordinary filesystem path.

## Why the FS layer and not the guest

An EDAT is an NPD header followed by AES-encrypted blocks. The guest never decrypts one
itself: it calls `sceNpDrmIsAvailable(klicensee, path)`, which primes the kernel, and every
later `cellFsOpen`/read of that path returns **plaintext**. A runtime that opens the file
literally hands the guest ciphertext.

`ps1_netemu` did exactly that — opened `USRDIR/ISO.BIN.EDAT`, read a garbage header, and
quit with `ExitPS1(): code=3` / `CoreBoot() failed`.

So `libs/filesystem/edat.c` resolves it in the FS layer: a file beginning `NPD\0` is
decrypted once into a `<name>.dec` cache and that is opened in its place. Every read, seek
and stat path above works unchanged — which is why this is a *path substitution* rather
than a read hook, and why `sceNpDrmIsAvailable` itself can stay a no-op.

## The format, as implemented

```
0x000  NPD    magic "NPD\0", version, license, type, content_id[0x30],
              digest[0x10], title_hash[0x10], dev_hash[0x10], activate/expire
0x080  EDAT   flags, block_size, file_size
0x100         per-block metadata: 0x10 bytes each (the block's CMAC)
0x100 + n*0x10 + b*block_size   the encrypted blocks
```

Per block: the block key is `dev_hash[0..0xB]` (zeros for NPD version ≤ 1) followed by the
big-endian block index, AES-ECB encrypted under the **file key**. That result is used
twice — as the AES-CBC key for the data and as the AES-CMAC key for the block hash. The
CBC IV is the NPD `digest`, or zeros for version ≤ 1.

The file key depends on the license:

| case | file key |
|---|---|
| SDAT (`flags & 0x01000000`) | `dev_hash ^ SDAT_KEY` |
| license type **3** ("free") | the klicensee itself |
| license type 1 / 2 | the RIF key from a per-console **RAP** |

## Two things the file tells you, if you ask it

**Which klicensee.** `dev_hash` is `CMAC(klic ^ NP_OMAC_KEY_2)` over the header's own first
0x60 bytes, so the file identifies its own key. `edat.c` tries the published candidates
(`NP_PSX_KEY`, `NP_KLIC_FREE`, the two PSP keys) and keeps the one that verifies — simpler
than branching on content type, and a key that does not verify is never used.

For a PSOne Classic the answer is **`NP_PSX_KEY`**.

**But a verified klicensee is not the same as a decryptable file.** The retail
`ISO.BIN.EDAT` here is license type **2**: `NP_PSX_KEY` verifies against its `dev_hash` — and
then every block hash fails, because the *data* is under the RIF key from a RAP we do not
have. That cost a debugging round, so `edat.c` now says so in as many words rather than
reporting a hash mismatch.

The archive's second package carries the same file as license type **3**, where the
klicensee *is* the file key. That one decrypts, and it is what `vfs/` should hold.

## Verification, not hope

Silently-wrong crypto produces plausible-looking garbage, which is the most expensive
failure this file could have. Three checks stand between a wrong key and a bad `.dec`:

1. `edat_selftest()` runs before the first decryption and checks AES-128 against the
   FIPS-197 vector (both directions) and AES-CMAC against RFC 4493. It refused nothing in
   the end, but it is what let the block-hash failures below be read as *data* problems
   rather than "maybe my AES is wrong".
2. The `dev_hash` CMAC selects the klicensee, as above.
3. Every block's CMAC is checked against its metadata entry. A mismatch stops the whole
   decryption and removes the partial cache file rather than writing garbage.

That third check is what caught the NPD-version-1 rule (zero block-key seed, zero IV) — the
first attempt used the version-3 rule and failed block 0 immediately instead of producing a
megabyte of noise.

## Scope

Implemented: uncompressed EDATs with AES-CMAC block hashes — the common case, and what
PSOne Classics use. Refused **by name**, not silently mis-handled: compressed blocks
(`flags & 1`), the `0x20`/`0x10` metadata layouts, encrypted-ERK files, debug data, and
license types needing a RAP.

AES-128 and AES-CMAC are implemented in the file so the runtime keeps no crypto dependency.

## Where it stops now

The disc header decrypts and the emulator opens it, then still exits `code=3`:

```
[edat] ...ISO.BIN.EDAT: version=3 license=3 flags=0x00000000 block=0x4000 size=1048616
[edat] klicensee NP_PSX_KEY verified against dev_hash
[edat] decrypted 1048616 bytes -> ...ISO.BIN.EDAT.dec
[sys_fs] open OK: ...ISO.BIN.EDAT.dec
ExitPS1(): code=3 <0>
```

The exit is precise. At `0x110E20`:

```
lwz  r4, 0x4(r31) / lwz r3, 0x8(r31)
bl   0xEE018                ; mount the image -- returns >= 0, so this SUCCEEDS
bl   0xED2E0                ; three instructions: return *(s32*)(cdrom_obj + 0x70D8)
cmpwi cr7, r3, 0
bgt  cr7, 0x110134          ; > 0 -> carry on
li   r3, 3 ; bl ExitPS1     ; otherwise give up
```

So the image mounts, but the count at `cdrom_obj + 0x70D8` — a track or sector count — stays
zero.

The likely reason is visible in the plaintext: the decrypted file is **1,048,616 bytes with
only 161 of its 2049 512-byte blocks non-zero**. It carries `PSISOIMG0000`, the serial
`_SCUS_94304` at 0x400 and a CD TOC at 0x800, but not a 300 MB disc. This package is the
*hybrid PSP/PS3* form: the real disc image is the 68 MB `DATA.PSAR` inside
`USRDIR/CONTENT/EBOOT.PBP`, and nothing in the run ever opens that file.

## Next

Read `func_0000EE018` — the mount — and find what it expects to fill `+0x70D8` from, and
whether it is supposed to open `EBOOT.PBP` for the sector data. That is the last unknown
between here and a PS1 executable actually running.
