#!/usr/bin/env bash
# Scrub a video's audio and remux. The video stream is copied bit-for-bit (no re-encode).
#   scripts/scrub-video.sh in.mov [out.mp4] [extra scrub flags...]
set -euo pipefail

in="${1:?usage: scrub-video.sh in.mov [out.mp4] [scrub flags...]}"
out="${2:-${in%.*}.scrubbed.mp4}"
shift $(( $# >= 2 ? 2 : 1 ))
bin="${BIN:-$(dirname "$0")/../.build/release/octave-camo}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# First audio track only: iPhones add a 4-channel spatial track (direction of arrival) that we drop.
ffmpeg -loglevel error -y -i "$in" -map 0:a:0 -vn -ac 2 -ar 48000 -c:a pcm_f32le "$tmp/in.wav"
# HEVC must be tagged hvc1 in MP4 or Apple players refuse it.
vtag=()
[[ "$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$in")" == hevc ]] && vtag=(-tag:v hvc1)
"$bin" scrub "$tmp/in.wav" "$tmp/out.wav" "$@"
ffmpeg -loglevel error -y -i "$in" -i "$tmp/out.wav" \
  -map 0:v:0 -map 1:a:0 -c:v copy ${vtag[@]+"${vtag[@]}"} -c:a aac -b:a 192k \
  -map_metadata -1 -movflags +faststart "$out"
echo "wrote $out"
