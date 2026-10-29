#!/bin/bash
# Shared by the macOS packaging scripts. Requires Bash 3.2 or later.
set -euo pipefail

SCRIPT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "Required tool not found: $1"; }
macos_only() { [[ $(uname -s) == Darwin ]] || fail 'This command requires macOS.'; }
version_value() {
  VERSION=${VERSION:-0.0.1}
  [[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'VERSION must use numeric major.minor.patch format.'
}
output_directory() {
  DIST_DIR=${DIST_DIR:-"$SCRIPT_ROOT/dist"}
  mkdir -p "$DIST_DIR"
  DIST_DIR=$(cd "$DIST_DIR" && pwd)
}
require_stopped_app() {
  local app=$1 executable
  while IFS= read -r executable; do
    if [[ $executable == "$app/Contents/MacOS/Raptor" ]]; then
      fail "Raptor is running from $app. Open the picker, press Cmd+Q, then retry."
    fi
  done < <(/bin/ps -axo comm=)
}
verify_app() {
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$1"
}
sign_app() {
  local app=$1
  local identity=${APP_SIGN_IDENTITY:--}
  local opts=()
  if [[ $identity != - ]]; then
    opts=(--options runtime --timestamp)
  fi
  # Bash 3.2 with nounset needs the + guard for an empty array.
  /usr/bin/codesign --force --sign "$identity" ${opts[@]+"${opts[@]}"} "$app/Contents/MacOS/raptor-cli"
  /usr/bin/codesign --force --sign "$identity" ${opts[@]+"${opts[@]}"} "$app"
  verify_app "$app"
}
app_architecture() {
  local app=$1 archs backend
  archs=$(xcrun lipo -archs "$app/Contents/MacOS/Raptor")
  backend=$(xcrun lipo -archs "$app/Contents/MacOS/raptor-cli")
  # RELEASE_ARCH is the result consumed by callers.
  export RELEASE_ARCH
  case "$archs" in
    arm64|x86_64) RELEASE_ARCH=$archs ;;
    'arm64 x86_64'|'x86_64 arm64') RELEASE_ARCH=universal ;;
    *) fail "Unsupported app architectures: $archs" ;;
  esac
  local arch
  for arch in $archs; do
    [[ " $backend " == *" $arch "* ]] || fail "Backend lacks architecture: $arch"
  done
  [[ $(wc -w <<< "$archs") == $(wc -w <<< "$backend") ]] || fail 'App and backend architectures differ.'
}
