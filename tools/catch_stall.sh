#!/bin/sh
# Loop until a class-B (stalled) run is caught, then keep that log.
#
# Class B: the R3000 instruction counter (+0x124, printed by the PS1_PC
# heartbeat) reaches a NON-ZERO value and then repeats it for many consecutive
# heartbeats. Class A climbs ~11.3M per heartbeat and never repeats.
#
# The non-zero requirement matters: a run where the R3000 never starts prints
# total=0 on every heartbeat, which looks identical to a plateau by the
# distinct-count test alone. That produced a false positive once already --
# PS3_SCENTER's logging is heavy enough (668 MB) to keep the R3000 from ever
# running, so this uses the census probes instead, which are free.
#
# WATCHDOG_AT dumps host stacks for every thread at 40s and 80s, both well after
# the ~13.2M stall point.
cd /g/recomp/ps3games/tmpsn || exit 1
for i in 1 2 3 4 5 6 7 8; do
    powershell -NoProfile -Command \
        "Get-Process tmpsn -ErrorAction SilentlyContinue | Stop-Process -Force" 2>/dev/null
    WATCHDOG_AT=40,80 PS1_R3000_PC=1 PS1_PC_CENSUS=1 PS1_PC=1 \
        timeout 95 ./tools/run.sh > scratch/stall.log 2>&1
    n=$(grep -acE "total=[0-9]+" scratch/stall.log)
    u=$(grep -aoE "total=[0-9]+" scratch/stall.log | sort -u | grep -c "")
    last=$(grep -aoE "total=[0-9]+" scratch/stall.log | tail -1 | sed 's/total=//')
    echo "attempt $i: $n heartbeats, $u distinct totals, last=$last"
    if [ "$n" -gt 8 ] && [ "$u" -lt 5 ] && [ "${last:-0}" -gt 1000000 ]; then
        echo "=== STALLED RUN CAUGHT on attempt $i (plateau at $last) ==="
        cp scratch/stall.log scratch/stalled_caught.log
        break
    fi
done
echo "--- done ---"
