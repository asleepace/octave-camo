#!/usr/bin/env bash
# Scrub a video's audio and remux, like the web app: the video packets are copied (no re-encode)
# minus SEI (encoder settings, camcorder GPS/date), no metadata, and a neutral random file name
# by default (phone file names carry the capture date and time).
#   scripts/scrub-video.sh in.mov [out.mp4] [extra scrub flags...]
set -euo pipefail

in="${1:?usage: scrub-video.sh in.mov [out.mp4] [scrub flags...]}"
out="${2:-$(dirname "$in")/camo-$(od -An -N4 -tx4 /dev/urandom | tr -d ' \n').mp4}"
shift $(( $# >= 2 ? 2 : 1 ))
bin="${BIN:-$(dirname "$0")/../.build/release/octave-camo}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# First audio track only: iPhones add a 4-channel spatial track (direction of arrival) that we drop.
ffmpeg -loglevel error -y -i "$in" -map 0:a:0 -vn -ac 2 -ar 48000 -c:a pcm_f32le "$tmp/in.wav"
# HEVC must be tagged hvc1 in MP4 or Apple players refuse it.
vtag=()
codec="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$in")"
[[ "$codec" == hevc ]] && vtag=(-tag:v hvc1 -bsf:v "filter_units=remove_types=39|40")
[[ "$codec" == h264 ]] && vtag=(-bsf:v "filter_units=remove_types=6")
"$bin" scrub "$tmp/in.wav" "$tmp/out.wav" "$@"
ffmpeg -loglevel error -y -i "$in" -i "$tmp/out.wav" \
  -map 0:v:0 -map 1:a:0 -c:v copy ${vtag[@]+"${vtag[@]}"} -c:a aac -b:a 192k \
  -map_metadata -1 -map_chapters -1 -fflags +bitexact -flags:v +bitexact -flags:a +bitexact \
  -movflags +faststart "$out"
echo "wrote $out"
