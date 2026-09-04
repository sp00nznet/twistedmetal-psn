#!/bin/sh
# Run the title and grab the window every INT seconds, so a boot sequence can be
# reviewed as a strip instead of one lucky frame.
#
# The emulated R3000 runs at roughly 14 MIPS against the PS1's 33, so the intro
# arrives at about 0.4x wall speed -- the Sony Interactive Studios title cards
# land near 75s, not 30s. Anything that samples earlier than that sees black and
# concludes, wrongly, that nothing renders.
cd /g/recomp/ps3games/tmpsn || exit 1
DUR="${DUR:-300}"
INT="${INT:-15}"
OUT="${OUT:-scratch/seq}"
mkdir -p "$OUT"
rm -f "$OUT"/*.png
powershell -NoProfile -Command \
    "Get-Process tmpsn -ErrorAction SilentlyContinue | Stop-Process -Force" 2>/dev/null
PS1_PC=1 timeout "$DUR" ./tools/run.sh > scratch/seq.log 2>&1 &
t=0
while [ "$t" -lt "$DUR" ]; do
    sleep "$INT"
    t=$((t + INT))
    powershell -NoProfile -File tools/screenshot.ps1 \
        "$(printf '%s/t%03d.png' "$OUT" "$t")" >/dev/null 2>&1 || break
done
wait
echo "--- $(ls "$OUT" | wc -l) frames in $OUT ---"
