#!/bin/sh
# Run the title, wait for the R3000 instruction counter to stop moving, then ask
# the frozen process what it is doing over the PS3_DEBUG console.
#
# Why a console and not another printf probe: the freeze is not reproducible at
# a fixed instruction count (13.6M, 61.8M, 893M, 2.36G observed), so a probe
# that only fires on a yield says nothing when the guest thread is parked. The
# console runs on its own thread and reads memory regardless.
#
# What it dumps, and why:
#   0x0076C080  R3000 state -- GPRs, SR/CAUSE, pc, budget(+0x120),
#               total(+0x124), reason(+0x138)
#   0x0076C5C0  state+0x540, the event-list sentinel (next/prev/due)
#   *(0x001B4FE4)  the struct func_000D2298 spins on: it yields (syscall 43 at
#               0xD22E4) until *(s+0x88) == *(s+0x00). Five sites in that module
#               load +0x88 and NONE stores it, so it is written from outside --
#               DMA'd back by the GPU SPUs. Its two words are the whole
#               question: which side is behind.
cd /g/recomp/ps3games/tmpsn || exit 1
DUR="${DUR:-260}"
DBG=scratch/dbg.cmd
rm -f "$DBG" "$DBG".out
powershell -NoProfile -Command \
    "Get-Process tmpsn -ErrorAction SilentlyContinue | Stop-Process -Force" 2>/dev/null
PS3_DEBUG="$DBG" PS1_PC=1 timeout "$DUR" ./tools/run.sh > scratch/freeze.log 2>&1 &
run=$!

say() { printf '%s\n' "$1" > "$DBG"; sleep 3; }

frozen=0
i=0
while [ "$i" -lt 60 ]; do
    sleep 4
    i=$((i + 1))
    set -- $(grep -ao "total=[0-9]*" scratch/freeze.log | tail -3 | sed 's/total=//')
    [ $# -eq 3 ] || continue
    if [ "$1" = "$2" ] && [ "$2" = "$3" ] && [ "$1" != "0" ]; then
        echo "=== frozen at $1 ==="; frozen=1; break
    fi
done
[ "$frozen" = 1 ] || echo "=== never froze; probing anyway ==="

say "mem 001B4FE0 16"
# second word of that line is the pointer at 0x001B4FE4
SP=$(grep -a "^  0x001B4FE0" "$DBG".out | tail -1 | \
     awk '{printf "%s%s%s%s", $6, $7, $8, $9}')
echo "=== sync struct = 0x$SP ==="
say "mem $SP 160"
say "mem 0076C080 320"
say "mem 0076C5C0 48"
HEAD=$(grep -ao "evhead=0x[0-9A-Fa-f]*" scratch/freeze.log | tail -1 | sed 's/.*0x//')
[ -n "$HEAD" ] && say "mem $HEAD 32"
say "stat"

kill "$run" 2>/dev/null
powershell -NoProfile -Command \
    "Get-Process tmpsn -ErrorAction SilentlyContinue | Stop-Process -Force" 2>/dev/null
echo "--- console output ---"
cat "$DBG".out
