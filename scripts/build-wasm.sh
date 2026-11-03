#!/usr/bin/env bash
# Build the WebAssembly scrubber (a WASI reactor) for the web app.
# Needs Swift 6.4.2 and its matching WebAssembly SDK (see .github/workflows/ci.yml).
# usage: scripts/build-wasm.sh [out.wasm]      CONFIG=debug for a build whose traps print why
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:-web/public/octave-camo.wasm}
sdk=${SWIFT_WASM_SDK:-swift-6.4.2-RELEASE_wasm}
flags=(-c "${CONFIG:-release}" --swift-sdk "$sdk" --product octave-camo-wasm
       -Xswiftc -Xclang-linker -Xswiftc -mexec-model=reactor
       # WebAssembly has no guard page: by default the shadow stack sits next to global data and
       # an overflow silently corrupts it. Give it 8 MB and put it first, so overflowing traps
       # (out-of-bounds write below address 0) instead.
       -Xlinker -z -Xlinker stack-size=8388608 -Xlinker --stack-first)
[ "${CONFIG:-release}" = release ] && flags+=(-Xlinker --strip-debug)
swift build "${flags[@]}"
bin=$(swift build "${flags[@]}" --show-bin-path)
mkdir -p "$(dirname "$out")"
cp "$bin/octave-camo-wasm.wasm" "$out"
ls -l "$out"
