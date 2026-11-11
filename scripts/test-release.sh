#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$root/aux"
work=$(mktemp -d "$root/aux/release-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT
# Fixture bytes test hashing only; the release job builds the real archive.
# The resh-model payload is the bare binary plus the Rex plugin.
printf 'release fixture\n' > "$work/Raptor-1.2.3-universal.zip"
printf 'plugin\n' > "$work/init.lua"
ruby "$root/scripts/release-formula.rb" 1.2.3 "$work" > "$work/raptor.rb"
ruby -c "$work/raptor.rb"
checksum=$(shasum -a 256 "$work/Raptor-1.2.3-universal.zip" | awk '{print $1}')
grep -Fq "sha256 \"$checksum\"" "$work/raptor.rb"
grep -Fq 'releases/download/v1.2.3/Raptor-1.2.3-universal.zip' "$work/raptor.rb"
grep -Fq 'version "1.2.3"' "$work/raptor.rb"
grep -Fq 'head "https://github.com/alienxp03/raptor.git"' "$work/raptor.rb"
for dependency in zoxide fd worktrunk gh; do
  grep -Fq "depends_on \"$dependency\"" "$work/raptor.rb"
done
# The resh-model formula installs the bare binary and the Rex plugin.
grep -Fq 'bin.install buildpath/"raptor"' "$work/raptor.rb"
grep -Fq 'pkgshare.install buildpath/"init.lua"' "$work/raptor.rb"
grep -Fq 'license "MIT"' "$work/raptor.rb"
grep -Fq 'depends_on "fd"' "$work/raptor.rb"
grep -Fq 'raptor init' "$work/raptor.rb"
grep -Fq 'rex config reload' "$work/raptor.rb"
! grep -Fq 'package.path' "$work/raptor.rb"
! grep -Fq 'raptor_sessions' "$work/raptor.rb"
grep -Fq 'managed block' "$work/raptor.rb"
if grep -Eq 'raptor_agents|raptor_worktree_list|bin[[:space:]]*=[[:space:]]*.*\.local/bin|app[[:space:]]*=[[:space:]]*.*Applications' "$work/raptor.rb"; then
  echo 'Formula contains obsolete actions or hardcoded setup overrides' >&2
  exit 1
fi
for version in 1.2 01.2.3 1.2.3-beta '1.2.3"'; do
  if ruby "$root/scripts/release-formula.rb" "$version" "$work" > /dev/null 2>&1; then
    echo "Accepted invalid version: $version" >&2
    exit 1
  fi
done
if ruby "$root/scripts/release-formula.rb" 2.0.0 "$work" > /dev/null 2>&1; then
  echo 'Accepted missing archive' >&2
  exit 1
fi
printf 'Release formula checks passed.\n'
