package catalog

import (
	"os"
	"path/filepath"
	"testing"
)

func isolateWorktrunk(t *testing.T) {
	t.Helper()
	root := t.TempDir()
	empty := filepath.Join(root, "empty.toml")
	if err := os.WriteFile(empty, nil, 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WORKTRUNK_CONFIG_PATH", empty)
	t.Setenv("WORKTRUNK_SYSTEM_CONFIG_PATH", empty)
	t.Setenv("WORKTRUNK_PROJECT_CONFIG_PATH", empty)
	t.Setenv("WORKTRUNK_WORKTREE_PATH", filepath.Join(root, "trees", "{{ repo }}", "{{ branch | sanitize }}"))
}
