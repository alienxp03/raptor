package rex

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBlockLookupsWithoutInheritedSession(t *testing.T) {
	t.Setenv("REX_SESSION", "")
	t.Setenv("REX_BLOCK", "")
	dir := t.TempDir()
	log := filepath.Join(dir, "calls")
	t.Setenv("REX_TEST_LOG", log)
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	script := `#!/bin/sh
# Native launches have no terminal environment. All lookups need explicit context.
[ "$1" = do ] && [ "$2" = -b ] && [ "$3" = origin-pane ] && [ "$4" = -e ] || exit 1
printf '%s\n' call >> "$REX_TEST_LOG"
case "$5" in
  *foreground.cwd*) printf '%s\n' "${REX_TEST_PWD:-/source/repo}";;
  *r.pwd*) printf '%s\n' "$REX_TEST_PWD";;
  *foreground.name*) printf '%s\n' zsh;;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "rex"), []byte(script), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("REX_TEST_PWD", "file:///reported/repo")
	if got := BlockPwd("origin-pane"); got != "/reported/repo" {
		t.Fatalf("reported cwd = %q", got)
	}
	if got := BlockCwd("origin-pane"); got != "/reported/repo" {
		t.Fatalf("combined reported cwd = %q", got)
	}
	if err := os.WriteFile(log, nil, 0644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("REX_TEST_PWD", "")
	if got := BlockCwd("origin-pane"); got != "/source/repo" {
		t.Fatalf("foreground cwd fallback = %q", got)
	}
	calls, err := os.ReadFile(log)
	if err != nil || strings.Count(string(calls), "call") != 1 {
		t.Fatalf("cwd fallback must use one Rex invocation: %s (%v)", calls, err)
	}
	if got := BlockForeground("origin-pane"); got != "zsh" {
		t.Fatalf("foreground process = %q", got)
	}
}
