# Toolchain changes upstreamed to ps3recomp

Fixes this port required in the shared runtime and lifter. Moved out of the
README to keep it readable.


- **`libs/video/sys_rsx.c` --- the RSX interrupt queue was never published, and it deadlocked
  the guest.** `RsxDriverInfo::handler_queue` at `+0x12D0` is the event queue id libgcm's
  `_gcm_intr_thread` blocks on; on lv2 it is `sys_rsx_context_allocate` that creates the queue
  and stores the id there (confirmed field-for-field against RPCS3's struct). We zero-filled
  the driver-info page and never wrote it, so the thread received on queue **0**, returned
  immediately and exited --- taking gcm's flip handler with it. In ps1_netemu that parked the
  **main** guest thread on a flip semaphore, and since the main thread is the one running the
  R3000, the emulated PS1 stopped dead.

  Now the queue is created at driver-info init, its id published at `+0x12D0`, and a 60 Hz
  tick drives `SYS_RSX_EVENT_VBLANK` into it, filtered through the handler mask the guest
  publishes at `+0x12C0` --- the same filtering `rsx::thread::send_event` applies, and not
  optional: gcm's ISR dispatches on the flag bits, so an event bit it never asked for reaches
  a handler slot it never filled in. The tick has to be an independent producer rather than
  the flip packet, because the deadlock is circular: the parked main thread cannot issue the
  flip packet that would otherwise be the event source.

- **`runtime/spu/spu_channels.c` --- `rchcnt SPU_RdEventStat` lied, and it deadlocked an SPU.**
  `spu_rchcnt` had no case for that channel, so it fell through to `default: return 1`
  ("channel ready"). The SPU idiom is a *guarded* blocking read:

  ```
  08934  rchcnt $r12, SPU_RdEventStat   ; is an event pending?
  08938  brnz   $r12, 0xA5E8            ; yes -> commit to the blocking rdch
  0893C  il     $r30, 8960              ; no  -> carry on working
  ```

  Answering 1 unconditionally sent the SPU into a `rdch` that then parked forever, because
  `rdch` correctly blocks while `(event_status & event_mask) == 0`. `rchcnt` and `rdch`
  disagreed. ps1_netemu's audio SPU sat at `0x0A5E8` waiting for `MFC_LLR_LOST_EVENT` on a
  line nothing was ever going to touch --- a store watch confirmed `0x2DEF80` is only ever
  zero-initialised --- when on hardware it would simply have fallen through and kept working.
  Now the same condition as `spu_ch_ready`'s case, lost-reservation poll included, so the two
  agree by construction.

- **`tools/ppu_lifter.py` --- jump-table detection missed the biggest dispatcher in the
  image.** Two independent bugs, both found on `ps1_netemu`'s R3000 opcode table:
  - The **table-base search was window-limited.** `discover_jump_tables` looked for the
    `lwz rBase, disp(r2)` inside a fixed 30-instruction window before the `bctr`. Here the
    base load sits **36** instructions back, so the detector found the `mtctr` and the
    `lwzx` and then gave up. The base walk now scans the enclosing function, bounded by the
    nearest preceding `blr` --- the same guard the two-level-base path already used. Safe for
    the cases that already worked, because the walk stops at the *nearest* definition, so a
    base inside the old window still wins.
  - **A leading null slot truncated the table to nothing.** The decoder stopped at the first
    entry that failed validation. A dense opcode table has null slots for the codes it never
    dispatches, and this one's index 0 is exactly that, so a correct base still decoded
    **0 targets**. Leading holes are now skipped (bounded at 4, so a genuinely wrong base
    still fails fast); the first hole *after* real entries still ends the table.

  A dropped dispatcher is silent and expensive: the case targets never get labels, and the
  runtime `bctr` falls through to the generic indirect-call dispatcher, which resolves
  function **entries** only. Every jump-table case is a mid-function address, so the call
  does nothing at all. Across this image the fix went from 67 dispatchers / 654 case targets
  to **68 / 718**.

- **`tools/ppu_lifter.py` --- stores through a frame pointer were invisible.** A PPC64
  red-zone leaf keeps locals below `r1` with no `stdu`, and writes them through a copied
  pointer (`addi r5,r1,-128` -> `r31` -> `r30`, then `std r9,0x8(r30)`). `_write_counts`
  only saw literal `r1 + off` stores, so the slot looked untouched, was treated as a
  callee-save spill, and the matching `ld r25,-0x78(r1)` returned the *caller's* `r25`. In
  `ps1_netemu`'s Montgomery multiply that put a pointer into the carry chain, so every ECDSA
  signature the firmware checked came out wrong and no PSOne disc would mount. The lifter now
  tracks registers holding `r1 + off` through the zero-extend and register-move idioms and
  charges the store to the slot it lands on.

- **`tools/pkg_extract.py` — mixed-key packages.** A PSOne Classic is `pkg_type=2` and
  uses *both* keys at once: entry structs and some payloads on the PSP key
  (`07F2C682…`), the rest on the usual PS3 key, chosen per entry by **bit 28 of the
  entry flags**. The old single-key autodetect asserted out on the file table. A plain
  PS3 package never sets bit 28, so the same rule leaves it on the PS3 key throughout.
- **`tools/gen_imports.py` — new.** Emits the `imports.json` that `ppu_lifter --hle-stubs`
  wants for an `ET_EXEC` image: `prx_analyzer` finds nothing without a dynamic section, so
  this walks the `sys_proc_prx_param` lib.stub tables (`elf_parser` already does) and
  names each NID from `nid_database`. Every port so far had been doing this by hand.
- **`libs/video/sys_rsx.c` — new, the lv2 RSX syscalls.** Routes 666..677 into the state
  `cellGcmSys.c` already keeps, so a guest that talks to RSX through the kernel reaches
  the same live draw engine as one that imports `cellGcmSys`. See above.
- **`sys_process_get_sdk_version` (25).** Was a stub returning `CELL_OK` with the
  out-param untouched. Now reports SDK 3.6.0; `PS3_SDK_VERSION` overrides.
- **`runtime/ppu/ppu_loader.cpp` — `PS3_SCTRACE` now covers the stub path**, which it
  had skipped: it traced everything *except* the unimplemented syscalls, i.e. exactly
  the ones a trace is wanted for. Finding the RSX call contract needed this.
- **`libs/filesystem/edat.c` — new, NPDRM (EDAT/SDAT) decryption.** A file beginning
  `NPD\0` is decrypted once into a cache file and that is opened in its place, so every
  read/seek/stat path stays unchanged. Self-contained AES-128 + AES-CMAC (no new
  dependency), with the FIPS-197 and RFC 4493 vectors checked before first use and every
  block's CMAC verified. See [`docs/npdrm.md`](docs/npdrm.md).
- **`libs/codec/cellAdec.c` — `cellAdecOpen` had the wrong arity.** Five parameters where
  the real one takes four (the guest's `CellAdecCb` struct split in two), so `handle` was
  read from `r7` instead of `r6` and every open failed `ARG`. Confirmed against RPCS3.
- **`runtime/syscalls/sys_semaphore.c` — `SEM_BADID=1`.** On a wait/post against an id that
  was never created, report the caller and its pointer-shaped registers once per (id, lr).
  The id says nothing; where the guest *read* it from is the whole diagnosis.
- **`runtime/ppu/ppu_loader.cpp` — `PS3_ARGV`, multiple guest arguments.** It wrote
  exactly one, which is all a disc title needs and nowhere near enough for a firmware
  module launched by the VSH. Layout matches lv2 (64-bit BE pointer slots, NULL-terminated,
  NULL envp, strings 16-byte aligned), verified against RPCS3's `ppu_load_exe`, and is
  byte-identical to the old output for a single argument.
  See [`docs/boot-argv.md`](docs/boot-argv.md).
- **`sysPrxForUser` — `_sys_malloc` / `_sys_free` / `_sys_memalign` / `_sys_realloc`.**
  Missing entirely, so callers got the unresolved-NID stub: `CELL_OK` with a garbage
  pointer in `r3` that they then wrote through. `cellUsbdInit` failed on it.
- **`PS3_SCTRACE` printed the return value in the first argument's column** for every
  implemented syscall (it passed `ctx->gpr[3]` after dispatch had overwritten it). The
  first argument is the object id across most of lv2 — the whole reason to read the trace.
- **`runtime/spu/spu_raw.c` — new, raw SPUs.** The `0xE0000000` MMIO window plus
  `sys_raw_spu_*`, and `sys_raw_spu_image_load` — which is not a syscall, so its stub NID
  left local store full of zeros and the SPU "ran" straight into them. `spu_context.ls`
  became a pointer so a raw SPU's local store can BE the guest window rather than a copy
  the PPU races. See [`docs/raw-spu.md`](docs/raw-spu.md).
- **`tools/spu_lifter.py` — refuse an ELF passed as a raw image.** Given positionally with
  `--functions` and no `--base`, it lifts the ELF *header* as code and puts every function
  at its file offset instead of its local-store address. It compiles, links and runs the
  wrong instructions. Now an error naming `--auto-functions`.
- **`runtime/syscalls/sys_fs.c` — `/dev_flash` served from a real firmware tree.**
  `ppu_fs.cpp` already had this branch (`$PS3_DEV_FLASH`); the raw-syscall half of the
  split filesystem did not, so a firmware path opened through `sys_fs` resolved under the
  game root and missed. `ps1_netemu` will not boot without
  `/dev_flash/ps1emu/ps1_rom.bin`.

