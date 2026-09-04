#!/bin/sh
# Loop until a class-B (stalled) run is caught, then keep that log.
#
# A stalled run is unmistakable: the R3000 instruction counter (+0x124, printed
# by the PS1_PC heartbeat) repeats the same value for many consecutive
# heartbeats. Class A runs climb ~11.3M per heartbeat and never repeat.
#
# WATCHDOG_AT dumps host stacks for every thread at 40s and 80s -- both well
# after the ~13.2M stall point, which lands around the second heartbeat.
cd /g/recomp/ps3games/tmpsn || exit 1
for i in 1 2 3 4 5 6; do
    powershell -NoProfile -Command \
        "Get-Process tmpsn -ErrorAction SilentlyContinue | Stop-Process -Force" 2>/dev/null
    WATCHDOG_AT=40,80 PS3_SCENTER=1 PS1_PC=1 \
        timeout 95 ./tools/run.sh > scratch/stall.log 2>&1
    # distinct heartbeat totals vs total heartbeats
    n=$(grep -acE "total=[0-9]+" scratch/stall.log)
    u=$(grep -aoE "total=[0-9]+" scratch/stall.log | sort -u | grep -c "")
    last=$(grep -aoE "total=[0-9]+" scratch/stall.log | tail -1)
    echo "attempt $i: $n heartbeats, $u distinct totals, last $last"
    if [ "$n" -gt 8 ] && [ "$u" -lt 5 ]; then
        echo "=== STALLED RUN CAUGHT on attempt $i ==="
        cp scratch/stall.log scratch/stalled_caught.log
        break
    fi
done
echo "--- done ---"
