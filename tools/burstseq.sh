#!/bin/sh
# Dense window capture: screenshots every INT seconds between FROM and TO.
#
# shotseq.sh samples every 15-35 s, which at ~0.4x emulation speed is wide
# enough to miss a short event entirely -- an intro FMV is seconds long. This
# exists to catch one: sample the window where it should be, densely.
cd /g/recomp/ps3games/tmpsn || exit 1
DUR="${DUR:-300}"; FROM="${FROM:-60}"; TO="${TO:-160}"; INT="${INT:-4}"
OUT="${OUT:-scratch/burstseq}"
mkdir -p "$OUT"; rm -f "$OUT"/*.png
powershell -NoProfile -Command \
    "Get-Process tmpsn -ErrorAction SilentlyContinue | Stop-Process -Force" 2>/dev/null
PS1_PC=1 timeout "$DUR" ./tools/run.sh > scratch/burstseq.log 2>&1 &
t=0
while [ "$t" -lt "$FROM" ]; do sleep 1; t=$((t+1)); done
while [ "$t" -lt "$TO" ]; do
    powershell -NoProfile -File tools/screenshot.ps1 \
        "$(printf '%s/t%03d.png' "$OUT" "$t")" >/dev/null 2>&1 || break
    sleep "$INT"; t=$((t+INT))
done
wait
echo "--- $(ls "$OUT" | wc -l) frames ---"
