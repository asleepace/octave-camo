#!/usr/bin/env bash
# End-to-end check: synth flyby -> attack -> scrub -> AAC 128k (like X) -> attack again.
#   scripts/roundtrip.sh [--hard]
set -euo pipefail
bin="${BIN:-$(dirname "$0")/../.build/release/octave-camo}"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT

aac() {  # simulate the platform re-encode
  ffmpeg -loglevel error -y -i "$1" -c:a aac -b:a 128k "$dir/tmp.m4a"
  ffmpeg -loglevel error -y -i "$dir/tmp.m4a" -c:a pcm_f32le "$2"
}

"$bin" synth "$dir/fly.wav" "$@"

echo; echo "=== BEFORE (original, after AAC) ==="
aac "$dir/fly.wav" "$dir/fly_aac.wav"
"$bin" analyze "$dir/fly_aac.wav"

echo; echo "=== SCRUB ==="
"$bin" scrub "$dir/fly.wav" "$dir/clean.wav" --seed 7
aac "$dir/clean.wav" "$dir/clean_aac.wav"

for th in 10 6 3; do
  echo; echo "=== AFTER (scrubbed, after AAC), attacker threshold ${th} dB ==="
  "$bin" analyze "$dir/clean_aac.wav" --threshold "$th"
done
