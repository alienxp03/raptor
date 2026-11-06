// Package task implements the noninteractive new-worktree → tab → fresh Pi flow.
// It is shared by the CLI and Rex action, independent of picker UI routing.
package task

import (
	"encoding/json"
	"fmt"
	"os/exec"
	"path/filepath"

	"github.com/alienxp03/raptor/internal/catalog"
	"github.com/alienxp03/raptor/internal/config"
	"github.com/alienxp03/raptor/internal/rex"
	"github.com/alienxp03/raptor/internal/worktree"
)

type Result struct {
	Path     string `json:"path"`
	Branch   string `json:"branch"`
	WindowID string `json:"window_id,omitempty"`
	BlockID  string `json:"block_id,omitempty"`
}

// Start preserves the worktree/tab on later failure. resumePath reuses an
// existing registered worktree, avoiding another branch on a retry.
func Start(ctx rex.Ctx, cfg config.Config, explicitRepo, resumePath string) (Result, error) {
	result := Result{}
	if ctx.Session == "" {
		return result, fmt.Errorf("no session context")
	}
	if ctx.Client == "" {
		return result, fmt.Errorf("no app client context; target the Rex app with -C")
	}
	pi, err := exec.LookPath("pi")
	if err != nil {
		return result, fmt.Errorf("pi executable not found; install Pi on this host before creating a task")
	}
	repo, err := catalog.ResolveRepo(ctx, explicitRepo)
	if err != nil {
		return result, err
	}
	if repo == "" {
		return result, fmt.Errorf("current pane is not in a Git repository")
	}
	var tree worktree.Worktree
	if resumePath != "" {
		for _, existing := range worktree.List(repo) {
			if canonical(existing.Path) == canonical(resumePath) {
				tree = existing
				break
			}
		}
		if tree.Path == "" {
			return result, fmt.Errorf("retry path is not a registered worktree of this repository: %s", resumePath)
		}
	} else {
		tree, err = worktree.CreateTask(repo, cfg)
		if err != nil {
			return result, err
		}
	}
	result.Path, result.Branch = tree.Path, tree.Branch
	// Rex quotes command arguments and uses the user's login environment. Pass
	// only the executable: no initial prompt, --resume, --fork, or shared session.
	out, err := rex.Run("window", "new", "-s", ctx.Session, tree.Branch, "-c", tree.Path, "--json", "--", pi)
	if err != nil {
		return result, fmt.Errorf("worktree preserved at %s (%s); could not open Pi tab: %w; retry with task --resume PATH", tree.Path, tree.Branch, err)
	}
	var opened struct {
		WindowID string   `json:"window_id"`
		BlockIDs []string `json:"block_ids"`
	}
	if err := json.Unmarshal([]byte(out), &opened); err != nil || opened.WindowID == "" {
		return result, fmt.Errorf("worktree preserved at %s; tab creation response was invalid; inspect the session before retrying", tree.Path)
	}
	result.WindowID = opened.WindowID
	if len(opened.BlockIDs) > 0 {
		result.BlockID = opened.BlockIDs[0]
	}
	if err := rex.Do(ctx.Client, "session.select", "session_id="+ctx.Session, "window_id="+opened.WindowID); err != nil {
		return result, fmt.Errorf("Pi tab %s and worktree %s were created, but switching the app failed: %w; select that tab instead of creating another task", opened.WindowID, tree.Path, err)
	}
	rex.WriteLastPane(ctx)
	return result, nil
}

func canonical(path string) string {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return filepath.Clean(path)
	}
	if real, err := filepath.EvalSymlinks(absolute); err == nil {
		return real
	}
	return absolute
}
