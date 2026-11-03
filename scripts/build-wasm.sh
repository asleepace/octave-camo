#!/usr/bin/env bash
# Build the WebAssembly scrubber (a WASI reactor) for the web app.
# Needs Swift 6.4.2 and its matching WebAssembly SDK (see .github/workflows/ci.yml).
# usage: scripts/build-wasm.sh [out.wasm]      CONFIG=debug for a build whose traps print why
set -euo pipefail
cd "$(dirname "$0")/.."
out=${1:-web/public/octave-camo.wasm}
sdk=${SWIFT_WASM_SDK:-swift-6.4.2-RELEASE_wasm}
flags=(-c "${CONFIG:-release}" --swift-sdk "$sdk" --product octave-camo-wasm
       -Xswiftc -Xclang-linker -Xswiftc -mexec-model=reactor)
[ "${CONFIG:-release}" = release ] && flags+=(-Xlinker --strip-debug)
# WASM_LINK_MAP=file writes the linker's map (which symbol sits at which address), for diagnosis.
[ -n "${WASM_LINK_MAP:-}" ] && flags+=(-Xlinker "--Map=$WASM_LINK_MAP")
swift build "${flags[@]}"
bin=$(swift build "${flags[@]}" --show-bin-path)
mkdir -p "$(dirname "$out")"
cp "$bin/octave-camo-wasm.wasm" "$out"
ls -l "$out"
