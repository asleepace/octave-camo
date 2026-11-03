#!/usr/bin/env bash
# Build the WebAssembly scrubber (a WASI reactor) for the web app.
# Needs Swift 6.4.2 and its matching WebAssembly SDK (see .github/workflows/ci.yml).
# usage: scripts/build-wasm.sh [out.wasm]
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:-web/public/octave-camo.wasm}
sdk=${SWIFT_WASM_SDK:-swift-6.4.2-RELEASE_wasm}
flags=(-c release --swift-sdk "$sdk" --product octave-camo-wasm
       -Xswiftc -Xclang-linker -Xswiftc -mexec-model=reactor -Xlinker --strip-debug)
swift build "${flags[@]}"
bin=$(swift build "${flags[@]}" --show-bin-path)
mkdir -p "$(dirname "$out")"
cp "$bin/octave-camo-wasm.wasm" "$out"
ls -l "$out"
