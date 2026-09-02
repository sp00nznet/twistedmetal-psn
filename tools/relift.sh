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
# 0x15F3AC is the end of the last SHF_EXECINSTR section (the 103-entry
# .lib.stub trampoline table at 0x15E6CC+0xCE0 is the last of them).
rm -rf src/recomp && mkdir -p src/recomp src/gen
python "$PS3RECOMP/tools/ppu_lifter.py" "$ELF" \
    --functions analysis/functions.json \
    --hle-stubs imports.json \
    --code-end 0x15F3AC \
    -o src/recomp

python "$PS3RECOMP/tools/gen_hle_nids.py" --all --out src/gen/ppu_hle_nids.cpp

# ---- SPU -------------------------------------------------------------------
# Unlike the game ports, both SPU modules are real ELFs embedded in the image
# (the R3000/GTE and GPU cores), so they extract statically -- no SPU_DUMP_MISS
# capture run needed.
python "$PS3RECOMP/tools/extract_spu_images.py" "$ELF" --out analysis/spu
#
# --auto-functions, not --functions: it makes the lifter parse the ELF, so the
# code lands at its LOCAL STORE address. Handing the same ELF in positionally
# with --functions reads it as a raw image at base 0, which silently puts every
# function at its FILE OFFSET instead -- here that is LS+0x80 (p_vaddr 0x80,
# p_offset 0x100), so the SPU entry ran the wrong instructions and stopped after
# two of them. The lifter now refuses that combination outright.
i=0
for img in analysis/spu/*.elf; do
    pfx="spu$i"; i=$((i+1))
    rm -rf "src/spu_gen/$pfx" && mkdir -p "src/spu_gen/$pfx"
    python "$PS3RECOMP/tools/spu_lifter.py" "$img" --auto-functions "$img" \
        --symbol-prefix "${pfx}_" -o "src/spu_gen/$pfx"
done
