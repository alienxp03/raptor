#!/bin/bash
set -euo pipefail
# shellcheck source=scripts/lib/macos-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/macos-common.sh"

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  printf '%s\n' 'Usage: scripts/install-macos.sh' \
    'Build nothing; install the already-built bare backend/host binary and the Rex plugin.' \
    'Defaults: DIST_DIR/raptor, PREFIX=$HOME/.local, REX_PLUGIN_DIR=$HOME/.config/rex/raptor.' \
    'Customized plugin files and symlinks are kept; unchanged installer-owned copies upgrade.' \
    'Also removes the pre-resh-model LaunchAgent and Raptor.app panel service if present.' \
    'No user init.lua edits or key bindings. No sudo, build, or publishing.'
  exit 0
fi
macos_only
need install
need shasum
[[ -f $SCRIPT_ROOT/init.lua ]] || fail 'Missing root init.lua'
[[ -f ${DIST_DIR:-"$SCRIPT_ROOT/dist"}/raptor ]] || fail "Missing ${DIST_DIR:-$SCRIPT_ROOT/dist}/raptor binary (run make build first)."
PREFIX=${PREFIX:-"$HOME/.local"}
REX_PLUGIN_DIR=${REX_PLUGIN_DIR:-"$HOME/.config/rex/raptor"}
mkdir -p "$PREFIX/bin"
PREFIX_BIN=$(cd "$PREFIX/bin" && pwd -P)
[[ ! -L $PREFIX_BIN/raptor && ! -d $PREFIX_BIN/raptor ]] || fail "Refusing to replace CLI symlink/directory: $PREFIX_BIN/raptor"

# The resh model has no resident service job: the panel client spawns the host
# on demand under Rex. Retire the pre-resh-model LaunchAgent if it exists, and
# stop any app-bundle host so the bare host owns the panel socket.
OLD_LABEL=com.alienxp03.raptor.panel
launchctl bootout "gui/$(id -u)/$OLD_LABEL" >/dev/null 2>&1 || true
rm -f "$HOME/Library/LaunchAgents/$OLD_LABEL.plist" "$HOME/Library/Caches/raptor/launcher.plist" 2>/dev/null || true
# Never execute the old app binary to stop it: an app-era binary with an
# unknown argument falls through to its GUI run loop and hangs the install.
pkill -f 'Raptor.app/Contents/MacOS/Raptor serve' 2>/dev/null || true
pkill -f 'raptor serve' 2>/dev/null || true
rm -f "$HOME/Library/Caches/raptor/panel.sock" 2>/dev/null || true

install -m 0755 "${DIST_DIR:-$SCRIPT_ROOT/dist}/raptor" "$PREFIX_BIN/raptor"
# The backend child resolves its sibling binary through symlinks; keep the
# real file installed so PATH shims and symlinked prefixes both work.

mkdir -p "$REX_PLUGIN_DIR"
marker="$REX_PLUGIN_DIR/.raptor-installed-sha256"
write_plugin() {
  install -m 0644 "$SCRIPT_ROOT/init.lua" "$REX_PLUGIN_DIR/init.lua"
  shasum -a 256 "$REX_PLUGIN_DIR/init.lua" | awk '{print $1}' > "$marker"
}
if [[ -L $REX_PLUGIN_DIR ]]; then
  printf 'Kept plugin symlink: %s\n' "$REX_PLUGIN_DIR"
elif [[ -f $REX_PLUGIN_DIR/init.lua && ! -L $REX_PLUGIN_DIR/init.lua && -f $marker && ! -L $marker ]]; then
  expected=''
  IFS= read -r expected < "$marker" || true
  actual=$(shasum -a 256 "$REX_PLUGIN_DIR/init.lua" | awk '{print $1}')
  if [[ $actual == "$expected" ]]; then
    write_plugin
    printf 'Updated installer-owned plugin: %s\n' "$REX_PLUGIN_DIR/init.lua"
  else
    printf 'Kept customized plugin: %s\n' "$REX_PLUGIN_DIR/init.lua"
  fi
else
  write_plugin
  printf 'Installed plugin: %s\n' "$REX_PLUGIN_DIR/init.lua"
fi
printf 'Installed host/CLI: %s\n' "$PREFIX_BIN/raptor"
printf '%s\n' 'Rex configuration unchanged. Run raptor init, then rex config reload.'
printf 'For a custom PREFIX, set the plugin setup bin option to: %s\n' "$PREFIX_BIN/raptor"
