#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${1:-"$root/docs/raptor-tour.mp4"}
mkdir -p "$(dirname "$out")" "$root/aux"
tmp=$(mktemp -d "$root/aux/raptor-tour.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
command -v ffmpeg >/dev/null || { echo "ffmpeg is required" >&2; exit 1; }
swiftc -swift-version 5 -framework AppKit -framework SwiftUI -framework Combine -framework QuartzCore \
  "$root"/Sources/raptor/Host/*.swift \
  "$root/macos/Tests/TourCapture.swift" \
  -o "$tmp/tour-capture"
"$tmp/tour-capture" "$tmp/frames"

names=(01-overview 02-find 03-rename 04-renamed 05-close-confirm 06-closed 07-pull-request 08-worktree 09-outro)
durations=(3 4 3 3 3 2 4 5 3)
inputs=()
filter=""
for i in "${!names[@]}"; do
  inputs+=(-loop 1 -framerate 30 -t "${durations[$i]}" -i "$tmp/frames/${names[$i]}.png")
  filter+="[$i:v]scale=1920:1080:flags=lanczos,fps=30,setsar=1,settb=1/30,setpts=PTS-STARTPTS,format=yuv420p[v$i];"
done
fade=0.25
prev=v0
elapsed=${durations[0]}
for i in $(seq 1 $((${#names[@]} - 1))); do
  offset=$(awk -v elapsed="$elapsed" -v fade="$fade" 'BEGIN { printf "%.2f", elapsed-fade }')
  next="xf$i"
  filter+="[$prev][v$i]xfade=transition=fade:duration=$fade:offset=$offset[$next];"
  prev=$next
  elapsed=$(awk -v elapsed="$elapsed" -v duration="${durations[$i]}" -v fade="$fade" 'BEGIN { printf "%.2f", elapsed+duration-fade }')
done
ffmpeg -hide_banner -loglevel warning -y "${inputs[@]}" \
  -filter_complex "$filter" -map "[$prev]" -an -c:v libx264 -preset medium -crf 21 \
  -profile:v high -pix_fmt yuv420p -movflags +faststart -r 30 "$out"
printf 'Created synthetic tour: %s\n' "$out"
