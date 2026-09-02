# Twisted Metal (PSOne Classic, NPUI-94304) — PPU boot harness.
#
# The lift target is not a game EBOOT: this package has no PS3 code in it at all.
# It is a PS1 disc image plus its EDAT, and what runs it is PS3 firmware. So we
# recompile /dev_flash/ps1emu/ps1_netemu.self and feed it the package. See README.
#
# Same shape as flOw / Simpsons Arcade / Twisted Metal: load the real image ->
# register the lifted functions + HLE NID handlers -> run real code, and every
# unlifted function / unimplemented import / lv2 syscall logs itself.
#
# Graphics come from the harness: RSX_LIVE_DRAW=1 selects caner's (canersaka)
# live NV4097 -> D3D12 draw engine. Note ps1_netemu links libgcm statically and
# reaches RSX through sys_rsx_* syscalls rather than HLE cellGcmSys, so the FIFO
# tap has to move down a layer -- see docs/graphics-path.md.
#
# Toolchain: clang-cl (the harness uses __builtin_bswap + weak symbols MSVC lacks).
#   cmake -S . -B build -G Ninja -DCMAKE_C_COMPILER=clang-cl -DCMAKE_CXX_COMPILER=clang-cl
#   cmake --build build
#   RSX_LIVE_DRAW=1 ./build/tmpsn fw/ps1_netemu.elf
cmake_minimum_required(VERSION 3.20)

# Default to Release. CMake+Ninja pick Debug when no type is given, which on a
# 23 MB generated translation unit means the whole emulator unoptimised -- that
# measured 3x slower on the sister ports and is invisible unless you read
# build.ninja.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "build type" FORCE)
endif()
message(STATUS "build type: ${CMAKE_BUILD_TYPE}")

project(tmpsn CXX C)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_C_STANDARD 17)

set(PS3RECOMP_DIR "G:/recomp/ps3games/ps3recomp" CACHE PATH "ps3recomp repo root")
set(PS3RECOMP_RUNTIME_LIB "${PS3RECOMP_DIR}/build/ps3recomp_runtime.lib"
    CACHE FILEPATH "prebuilt runtime library")

# Lifted code + the generated HLE NID table (all git-ignored, regenerate with
# tools/relift.sh).
file(GLOB RECOMP_SOURCES "src/recomp/*.cpp")
file(GLOB GEN_SOURCES    "src/gen/*.cpp" "src/gen/*.c")
file(GLOB_RECURSE SPU_SOURCES "src/spu_gen/*.c")
if(NOT RECOMP_SOURCES)
    message(FATAL_ERROR "src/recomp/ is empty — run tools/relift.sh first")
endif()
if(NOT SPU_SOURCES)
    message(WARNING "src/spu_gen/ is empty — the GPU/R3000 SPU cores will not run")
endif()

add_executable(tmpsn
    "${PS3RECOMP_DIR}/runtime/ppu/tests/boot_main.cpp"   # generic boot harness
    "${PS3RECOMP_DIR}/runtime/ppu/ppu_loader.cpp"        # vm + ELF loader + run
    "${PS3RECOMP_DIR}/runtime/ppu/ppu_hle.cpp"           # NID -> handler dispatch
    "${PS3RECOMP_DIR}/runtime/ppu/ppu_sysprx.cpp"        # boot-critical CRT
    "${PS3RECOMP_DIR}/runtime/ppu/ppu_fs.cpp"            # cellFs VFS
    "${CMAKE_CURRENT_SOURCE_DIR}/src/spu_images.c"       # lifted SPU modules -> registry
    "${CMAKE_CURRENT_SOURCE_DIR}/src/hle_overrides.c"    # firmware imports we serve ourselves
    "${CMAKE_CURRENT_SOURCE_DIR}/src/ecdsa_probe.c"      # ECDSA_PROBE=1: drive the firmware verify directly
    ${GEN_SOURCES}
    ${SPU_SOURCES}
    ${RECOMP_SOURCES}
)

file(GLOB LIB_INC_DIRS LIST_DIRECTORIES true "${PS3RECOMP_DIR}/libs/*")

target_include_directories(tmpsn PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src/compat"            # <dirent.h>/<unistd.h> Win shims
    "${CMAKE_CURRENT_SOURCE_DIR}/src/recomp"            # ppu_recomp.h
    "${PS3RECOMP_DIR}/runtime/ppu"
    "${PS3RECOMP_DIR}/runtime/spu"
    "${PS3RECOMP_DIR}/runtime/prx"
    "${PS3RECOMP_DIR}/include"
    ${LIB_INC_DIRS}
)

target_link_libraries(tmpsn PRIVATE "${PS3RECOMP_RUNTIME_LIB}")
if(WIN32)
    target_link_libraries(tmpsn PRIVATE ws2_32 bcrypt xinput ole32 d3d12 dxgi dxguid d3dcompiler)
    # Every guest call is a host call, so recompiled call chains nest deeply.
    target_link_options(tmpsn PRIVATE /STACK:268435456 /MAP:tmpsn.map)
endif()
