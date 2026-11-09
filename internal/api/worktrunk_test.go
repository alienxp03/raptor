package api

import (
	"os"
	"path/filepath"
	"testing"
)

// Each fixture uses a private Worktrunk config and destination. Tests must not
// read user hooks or create worktrees in the user's configured root.
func isolateWorktrunk(t *testing.T) {
	t.Helper()
	root := t.TempDir()
	empty := filepath.Join(root, "empty.toml")
	if err := os.WriteFile(empty, nil, 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("WORKTRUNK_CONFIG_PATH", empty)
	t.Setenv("WORKTRUNK_SYSTEM_CONFIG_PATH", empty)
	t.Setenv("WORKTRUNK_PROJECT_CONFIG_PATH", filepath.Join(root, "no-project.toml"))
	t.Setenv("WORKTRUNK_WORKTREE_PATH", filepath.Join(root, "trees", "{{ repo }}", "{{ branch | sanitize }}"))
}
