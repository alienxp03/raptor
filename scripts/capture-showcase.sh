#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=${1:-"$root/docs/screenshots"}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out"
swiftc -swift-version 5 -framework AppKit -framework SwiftUI -framework Combine -framework QuartzCore \
  "$root"/Sources/raptor/Host/*.swift \
  "$root/macos/Tests/ShowcaseCapture.swift" \
  -o "$tmp/showcase-capture"
"$tmp/showcase-capture" "$out"
