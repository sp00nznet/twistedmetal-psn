#!/bin/sh
# Run the recompiled PS1 emulator against the extracted package.
#
# PS3_DEV_FLASH  -- ppu_fs serves /dev_flash from a real firmware tree; the
#                   runtime's built-in default points at a path that isn't here.
#                   ps1_rom.bin (the 512 KB PS1 BIOS) lives under ps1emu/.
# PS3_HDD0_ROOT  -- /dev_hdd0/game/NPUI94304/ is where the emulator looks for
#                   USRDIR/CONTENT/EBOOT.PBP and USRDIR/ISO.BIN.EDAT.
# RSX_LIVE_DRAW  -- caner's live NV4097 -> D3D12 engine.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PS3_DEV_FLASH="${PS3_DEV_FLASH:-G:/recomp/tools/rpcs3/dev_flash}"
export PS3_HDD0_ROOT="${PS3_HDD0_ROOT:-$ROOT/vfs/dev_hdd0}"
export PS3_VFS_ROOT="${PS3_VFS_ROOT:-$ROOT/vfs}"
export RSX_LIVE_DRAW="${RSX_LIVE_DRAW:-1}"
# The harness reads the title id from <vfs>/PS3_GAME/PARAM.SFO. Without it
# cellGame keeps the BLES00000 placeholder, and every /dev_hdd0/game/<id> path
# the emulator builds -- its content dir, its save dir -- points at a title that
# does not exist. The package's own SFO is the one to use.
[ -f "$ROOT/vfs/PS3_GAME/PARAM.SFO" ] || {
    mkdir -p "$ROOT/vfs/PS3_GAME"
    cp "$ROOT/vfs/dev_hdd0/game/NPUI94304/PARAM.SFO" "$ROOT/vfs/PS3_GAME/PARAM.SFO"
}

exec "$ROOT/build/tmpsn.exe" "$ROOT/fw/ps1_netemu.elf" "$@"
