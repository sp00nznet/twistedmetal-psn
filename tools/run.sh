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

# Git Bash / MSYS rewrites POSIX-looking paths in environment values on the way
# to a native binary, so YDKJ_BOOTPATH=/dev_flash/... arrived at the guest as
# "C:/Program Files/Git/dev_flash/...". These are GUEST paths; leave them alone.
# (MSYS2_ENV_CONV_EXCL governs ENV values only -- MSYS_NO_PATHCONV would also stop
# the ELF path ARGUMENT below being converted to a Windows path, which breaks the load.)
export MSYS2_ENV_CONV_EXCL="*"
# HOST paths must reach the native binary in Windows form. MSYS would normally
# convert them, but MSYS2_ENV_CONV_EXCL above (needed for the GUEST paths) turns
# that off for everything -- so convert them here explicitly instead of relying
# on a heuristic that has to guess which of the two kinds each value is.
ROOT_W="$(cygpath -m "$ROOT")"
export PS3_DEV_FLASH="${PS3_DEV_FLASH:-G:/recomp/tools/rpcs3/dev_flash}"
export PS3_HDD0_ROOT="${PS3_HDD0_ROOT:-$ROOT_W/vfs/dev_hdd0}"
export PS3_VFS_ROOT="${PS3_VFS_ROOT:-$ROOT_W/vfs}"
export RSX_LIVE_DRAW="${RSX_LIVE_DRAW:-1}"
# Window title. The harness would otherwise fall back through PARAM.SFO and
# land on a name from whichever port seeded the shared runtime -- confusing
# when four PS3 ports share one window path. Name it after the disc below.
# Which PSOne Classic to run. Every one of them is the same emulator with a
# different disc, so a second title needs nothing but its own content id and
# serial: unpack its package into vfs/dev_hdd0/game/<content>/ and set these.
#   Twisted Metal    NPUI94304 / SCUS94304   (default)
#   Twisted Metal 2  NPUI94306 / SCUS94306
#   WipEout          NPUI94301 / SCUS94301
#   Crash Bandicoot  NPUI94900 / SCUS94900
PS1_SERIAL="${PS1_SERIAL:-SCUS94304}"
PS1_CONTENT="${PS1_CONTENT:-NPUI94304}"

case "$PS1_CONTENT" in
  NPUI94306) _name="Twisted Metal 2" ;;
  NPUI94301) _name="WipEout" ;;
  NPUI94900) _name="Crash Bandicoot" ;;
  *)         _name="Twisted Metal"   ;;
esac
export PS3_TITLE="${PS3_TITLE:-$_name (PSOne Classic) - ps3recomp}"

# The harness reads the title id from <vfs>/PS3_GAME/PARAM.SFO. Without it
# cellGame keeps the BLES00000 placeholder, and every /dev_hdd0/game/<id> path
# the emulator builds -- its content dir, its save dir -- points at a title that
# does not exist. The package's own SFO is the one to use.
#
# Refreshed whenever it does not match the title being launched: this file is
# shared state, so leaving a previous title's SFO in place sends cellGame (and
# every path built from it) at the wrong game.
if ! cmp -s "$ROOT/vfs/dev_hdd0/game/$PS1_CONTENT/PARAM.SFO" "$ROOT/vfs/PS3_GAME/PARAM.SFO"; then
    mkdir -p "$ROOT/vfs/PS3_GAME"
 cp "$ROOT/vfs/dev_hdd0/game/$PS1_CONTENT/PARAM.SFO" "$ROOT/vfs/PS3_GAME/PARAM.SFO"
fi

# The nine arguments the VSH passes a PSOne Classic. Without them the emulator
# still boots and sits in its "game is running" loop forever, because argv[5] --
# the content directory -- is the ONLY place it learns which disc to load.
# Contract from RPCS3's Emu/System.cpp (m_cat == "1P"):
#
#   argv[0] the emulator self          argv[5] /dev_hdd0/game/<content dir>
#   argv[1] virtual memory card 1      argv[6] 1
#   argv[2] virtual memory card 2      argv[7] 2   (full screen?)
#   argv[3] 0082  region target        argv[8] 1   (smoothing?)
#   argv[4] 1600  resolution scale?
#
# Note argv[1]/[2] are named from the PS1 serial while argv[5] is named from the
# content id -- for a PSOne Classic those differ (SCUS94304 vs NPUI94304).
# A bare "/USRDIR/..." (ps1_netemu saves its CONFIG there) must resolve inside
# the installed game tree, not at the vfs root.
export PS3_USRDIR_BASE="${PS3_USRDIR_BASE:-$ROOT_W/vfs/dev_hdd0/game/${PS1_CONTENT}}"
export YDKJ_BOOTPATH="${YDKJ_BOOTPATH:-/dev_flash/ps1emu/ps1_netemu.self}"
export PS3_ARGV="${PS3_ARGV:-${PS1_SERIAL}_mc1.VM1;${PS1_SERIAL}_mc2.VM1;0082;1600;/dev_hdd0/game/${PS1_CONTENT};1;2;1}"

# The emulator expects its two virtual memory cards to already exist as 128 KB
# zero-filled files; RPCS3 creates them the same way and lets the game format them.
mkdir -p "$ROOT/vfs/dev_hdd0/savedata/vmc"
for mc in "${PS1_SERIAL}_mc1.VM1" "${PS1_SERIAL}_mc2.VM1"; do
    [ -f "$ROOT/vfs/dev_hdd0/savedata/vmc/$mc" ] ||         dd if=/dev/zero of="$ROOT/vfs/dev_hdd0/savedata/vmc/$mc" bs=1024 count=128 2>/dev/null
done

exec "$ROOT/build/tmpsn.exe" "$ROOT/fw/ps1_netemu.elf" "$@"
