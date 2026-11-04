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
# Release builds are reproducible: no debug info (it carries build paths, and is stripped at link
# anyway), and no .swift_modhash (a per-object hash of that IR the compiler keeps for incremental
# builds, which otherwise ends up in the wasm and differs between machines and directories).
[ "${CONFIG:-release}" = release ] && flags+=(-Xlinker --strip-debug -Xswiftc -gnone
  -Xswiftc -Xfrontend -Xswiftc -disable-incremental-llvm-codegen)
# OPT=size compiles for size (-Osize) instead of speed (-O, the default).
[ "${OPT:-speed}" = size ] && flags+=(-Xswiftc -Osize)
# WASM_LINK_MAP=file writes the linker's map (which symbol sits at which address), for diagnosis.
[ -n "${WASM_LINK_MAP:-}" ] && flags+=(-Xlinker "--Map=$WASM_LINK_MAP")
swift build "${flags[@]}"
bin=$(swift build "${flags[@]}" --show-bin-path)
mkdir -p "$(dirname "$out")"
# Release builds are shrunk by binaryen's wasm-opt (pinned in tools/wasm-opt; `npm ci --prefix
# tools/wasm-opt` installs it): about half the size raw and a third less gzipped, about 7 % slower
# (measured by the "Wasm size" workflow). Deterministic, so the build stays reproducible. Debug
# builds keep their names for readable traps.
opt=${WASM_OPT:-tools/wasm-opt/node_modules/.bin/wasm-opt}
if [ "${CONFIG:-release}" = release ] && [ -x "$opt" ]; then
  "$opt" -Oz --enable-bulk-memory --enable-sign-ext --enable-mutable-globals --enable-nontrapping-float-to-int \
    "$bin/octave-camo-wasm.wasm" -o "$out"
elif [ "${CONFIG:-release}" = release ] && [ "${REQUIRE_WASM_OPT:-0}" = 1 ]; then
  echo "wasm-opt not found at $opt (npm ci --prefix tools/wasm-opt)" >&2; exit 1
else
  [ "${CONFIG:-release}" = release ] && echo "note: wasm-opt not installed; this build is larger than CI's and its hash differs" >&2
  cp "$bin/octave-camo-wasm.wasm" "$out"
fi
ls -l "$out"
