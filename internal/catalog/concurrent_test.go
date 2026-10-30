package catalog

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/alienxp03/raptor/internal/rex"
)

func TestContextDirectoriesLoadsIndependentSourcesTogether(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("RAPTOR_TEST_SYNC", dir)
	// Each source waits until the other has started. A sequential implementation
	// times out and cannot return the pinned origin plus the saved directory.
	wait := `for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -f "$RAPTOR_TEST_SYNC/$other" ] && break
  sleep 0.01
done
[ -f "$RAPTOR_TEST_SYNC/$other" ] || exit 1
`
	for name, setup := range map[string]string{
		"zoxide": "touch \"$RAPTOR_TEST_SYNC/zoxide-started\"\nother=rex-started\n",
		"rex":    "touch \"$RAPTOR_TEST_SYNC/rex-started\"\nother=zoxide-started\n",
	} {
		path := "/saved"
		if name == "rex" {
			path = dir
		}
		script := "#!/bin/sh\n" + setup + wait + "printf '%s\\n' '" + path + "'\n"
		if err := os.WriteFile(filepath.Join(dir, name), []byte(script), 0755); err != nil {
			t.Fatal(err)
		}
	}
	items := ContextDirectories(rex.Ctx{Block: "origin"}, false)
	if len(items) != 2 || !items[0].Current || items[0].Path != dir || items[1].Path != "/saved" {
		t.Fatalf("independent sources did not load together: %+v", items)
	}
}
