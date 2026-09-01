#!/bin/sh
# Regenerate everything git-ignored: the lifted PPU tree, the lifted SPU modules,
# and the HLE NID table. Run from the repo root.
#
# The lift target is the PS3 firmware's PS1 emulator, not a game EBOOT -- see
# README.md. Decrypt it yourself from your own console's firmware:
#   cp <dev_flash>/ps1emu/ps1_netemu.self fw/ && rpcs3 --decrypt fw/ps1_netemu.self
set -e
PS3RECOMP="${PS3RECOMP:-../ps3recomp}"
ELF=fw/ps1_netemu.elf

python "$PS3RECOMP/tools/find_functions.py" "$ELF" --output analysis/functions.json
python "$PS3RECOMP/tools/gen_imports.py"    "$ELF" -o imports.json

# --hle-stubs rewrites each import trampoline as ps3_hle_call(nid) so a direct
# `bl` to an import reaches the HLE handler instead of the literal stub.
# --code-end stops the branch-target pass from exploding .rodata into functions;
# 0x1A9328+0x40 is the end of the last executable section.
rm -rf src/recomp && mkdir -p src/recomp src/gen
python "$PS3RECOMP/tools/ppu_lifter.py" "$ELF" \
    --functions analysis/functions.json \
    --hle-stubs imports.json \
    --code-end 0x1A9368 \
    -o src/recomp

python "$PS3RECOMP/tools/gen_hle_nids.py" --all --out src/gen/ppu_hle_nids.cpp

# ---- SPU -------------------------------------------------------------------
# Unlike the game ports, both SPU modules are real ELFs embedded in the image
# (the R3000/GTE and GPU cores), so they extract statically -- no SPU_DUMP_MISS
# capture run needed.
python "$PS3RECOMP/tools/extract_spu_images.py" "$ELF" --out analysis/spu
i=0
for img in analysis/spu/*.elf; do
    pfx="spu$i"; i=$((i+1))
    python "$PS3RECOMP/tools/find_spu_functions.py" "$img" --out "analysis/spu/${pfx}_funcs.json"
    rm -rf "src/spu_gen/$pfx" && mkdir -p "src/spu_gen/$pfx"
    python "$PS3RECOMP/tools/spu_lifter.py" "$img" \
        --functions "analysis/spu/${pfx}_funcs.json" \
        --symbol-prefix "${pfx}_" -o "src/spu_gen/$pfx"
done
